//! Real crash replay: what `Sim.Fs` says a crash may leave, checked against
//! what a real file system does leave.
//!
//! For each workload, on each file system named, it runs the workload on a
//! real disk under dm-log-writes, which records every block write, flush and
//! mark in order; then replays the log onto the disk as it was before the
//! run, one entry at a time, and after each one mounts a copy-on-write
//! snapshot of the disk (the file system recovers as after a power cut) and
//! reads what the workload's directory holds. Every state the real file
//! system recovers to must be one `everyCrash` reaches on `Sim.Fs` from the
//! same workload; a state it does not reach is a crash the model would let a
//! test miss, and is printed with the step it came after.
//!
//! Linux only, as root, by hand and before each cut, never in CI:
//!
//!     zig build crash-replay
//!     sudo zig-out/bin/shakedown-crash-replay --fs ext4 --fs xfs --fs btrfs
//!
//! It needs dm-log-writes and dm-snapshot (`modprobe dm-log-writes`),
//! `losetup`, `dmsetup`, `mount` and the file systems' `mkfs`. It works in
//! `--scratch` (default `/var/tmp/shakedown-crash-replay`), which it leaves
//! for a later look, and takes down every device it made.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const shakedown = @import("shakedown");
const Log = @import("Log.zig");
const workloads = @import("workloads.zig");

const Fs = enum {
    ext4,
    xfs,
    btrfs,

    /// The smallest disk each makes by default, with room to spare.
    fn megabytes(fs: Fs) u64 {
        return switch (fs) {
            .ext4 => 32,
            .xfs => 320,
            .btrfs => 160,
        };
    }
};

const Options = struct {
    file_systems: []const Fs,
    only: ?[]const u8,
    scratch: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    if (builtin.os.tag != .linux) {
        try say(init.io, "shakedown-crash-replay: dm-log-writes is Linux's; run it on Linux\n", .{});
        return 2;
    }
    if (std.os.linux.geteuid() != 0) {
        try say(init.io, "shakedown-crash-replay: it makes loop and device-mapper devices; run it as root\n", .{});
        return 2;
    }
    const a = init.arena.allocator();
    const options = try parse(a, try init.minimal.args.toSlice(a));
    var failed = false;
    for (options.file_systems) |fs| {
        for (workloads.all) |w| {
            if (options.only) |name| if (!std.mem.eql(u8, name, w.name)) continue;
            var arena: std.heap.ArenaAllocator = .init(init.gpa);
            defer arena.deinit();
            const ok = try replay(arena.allocator(), init.io, fs, w, options.scratch);
            failed = failed or !ok;
        }
    }
    return if (failed) 1 else 0;
}

fn parse(a: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var file_systems: std.ArrayList(Fs) = .empty;
    var options: Options = .{ .file_systems = &.{}, .only = null, .scratch = "/var/tmp/shakedown-crash-replay" };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fs") and i + 1 < args.len) {
            i += 1;
            try file_systems.append(a, std.meta.stringToEnum(Fs, args[i]) orelse return error.UnknownFileSystem);
        } else if (std.mem.eql(u8, arg, "--workload") and i + 1 < args.len) {
            i += 1;
            options.only = args[i];
        } else if (std.mem.eql(u8, arg, "--scratch") and i + 1 < args.len) {
            i += 1;
            options.scratch = args[i];
        } else return error.UnknownArgument;
    }
    if (file_systems.items.len == 0) try file_systems.append(a, .ext4);
    options.file_systems = file_systems.items;
    return options;
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buffer);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

/// Runs `argv`; its output when it succeeds, an error naming it when not.
fn run(a: std.mem.Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = argv });
    if (!result.term.success()) {
        try say(io, "shakedown-crash-replay: {s} failed: {s}\n", .{ argv[0], result.stderr });
        return error.CommandFailed;
    }
    return std.mem.trim(u8, result.stdout, " \n");
}

/// A sparse file of `bytes` bytes.
fn sparse(io: Io, path: []const u8, bytes: u64) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.setLength(io, bytes);
}

const Devices = struct {
    a: std.mem.Allocator,
    io: Io,
    loops: std.ArrayList([]const u8) = .empty,
    mapped: std.ArrayList([]const u8) = .empty,
    mounted: ?[]const u8 = null,

    fn loop(d: *Devices, path: []const u8) ![]const u8 {
        const dev = try d.a.dupe(u8, try run(d.a, d.io, &.{ "losetup", "--find", "--show", path }));
        try d.loops.append(d.a, dev);
        return dev;
    }

    fn unloop(d: *Devices, dev: []const u8) void {
        _ = run(d.a, d.io, &.{ "losetup", "--detach", dev }) catch {};
        for (d.loops.items, 0..) |l, i| if (std.mem.eql(u8, l, dev)) {
            _ = d.loops.swapRemove(i);
            break;
        };
    }

    fn map(d: *Devices, name: []const u8, table: []const u8) ![]const u8 {
        _ = try run(d.a, d.io, &.{ "dmsetup", "create", name, "--table", table });
        try d.mapped.append(d.a, name);
        return d.a.print("/dev/mapper/{s}", .{name});
    }

    fn unmap(d: *Devices, name: []const u8) void {
        _ = run(d.a, d.io, &.{ "dmsetup", "remove", name }) catch {};
        for (d.mapped.items, 0..) |m, i| if (std.mem.eql(u8, m, name)) {
            _ = d.mapped.swapRemove(i);
            break;
        };
    }

    fn mount(d: *Devices, fs: Fs, dev: []const u8, at: []const u8) !void {
        _ = try run(d.a, d.io, &.{ "mount", "-t", @tagName(fs), dev, at });
        d.mounted = at;
    }

    fn unmount(d: *Devices) void {
        const at = d.mounted orelse return;
        _ = run(d.a, d.io, &.{ "umount", at }) catch {};
        d.mounted = null;
    }

    /// Takes down whatever is still up, last made first.
    fn down(d: *Devices) void {
        d.unmount();
        while (d.mapped.items.len > 0) d.unmap(d.mapped.items[d.mapped.items.len - 1]);
        while (d.loops.items.len > 0) d.unloop(d.loops.items[d.loops.items.len - 1]);
    }
};

fn mark(ctx: *anyopaque, name: []const u8) void {
    const m: *Marking = @ptrCast(@alignCast(ctx)); // safe: `replay` pairs this function with its Marking
    _ = run(m.a, m.io, &.{ "dmsetup", "message", m.device, "0", "mark", name }) catch {};
}

const Marking = struct { a: std.mem.Allocator, io: Io, device: []const u8 };

/// One workload on one file system: false when the real disk recovered to
/// a state the model does not reach.
fn replay(a: std.mem.Allocator, io: Io, fs: Fs, w: workloads.Workload, scratch_root: []const u8) !bool {
    const scratch = try a.print("{s}/{t}-{s}", .{ scratch_root, fs, w.name });
    try Io.Dir.cwd().createDirPath(io, scratch);
    const size = fs.megabytes() << 20;
    const sectors = size / 512;
    const data_path = try a.print("{s}/data.img", .{scratch});
    const log_path = try a.print("{s}/log.img", .{scratch});
    const base_path = try a.print("{s}/base.img", .{scratch});
    const crash_path = try a.print("{s}/crash.img", .{scratch});
    const cow_path = try a.print("{s}/cow.img", .{scratch});
    const mnt = try a.print("{s}/mnt", .{scratch});
    try Io.Dir.cwd().createDirPath(io, mnt);
    try sparse(io, data_path, size);
    try sparse(io, log_path, size * 4);

    var d: Devices = .{ .a = a, .io = io };
    defer d.down();
    const data_dev = try d.loop(data_path);
    _ = try run(a, io, &.{ try a.print("mkfs.{t}", .{fs}), if (fs == .ext4) "-F" else "-f", "-q", data_dev });
    // The workload's directory and its files, synced: the disk the run
    // starts from.
    try d.mount(fs, data_dev, mnt);
    {
        const root = try Io.Dir.cwd().openDir(io, mnt, .{});
        defer root.close(io);
        try root.createDir(io, "work", .default_dir);
        const work = try root.openDir(io, "work", .{ .iterate = true });
        defer work.close(io);
        for (w.initial) |f| {
            const file = try work.createFile(io, f.name, .{});
            defer file.close(io);
            try file.writePositionalAll(io, f.bytes, 0);
            try file.sync(io);
        }
        try (Io.File{ .handle = work.handle, .flags = .{ .nonblocking = false } }).sync(io);
    }
    d.unmount();
    _ = try run(a, io, &.{ "cp", "--sparse=always", data_path, base_path });

    // The run, every block write logged.
    const log_dev = try d.loop(log_path);
    const lw = try a.print("shakedown-lw-{d}", .{std.os.linux.getpid()});
    const lw_dev = try d.map(lw, try a.print("0 {d} log-writes {s} {s}", .{ sectors, data_dev, log_dev }));
    try d.mount(fs, lw_dev, mnt);
    var marking: Marking = .{ .a = a, .io = io, .device = lw };
    const marker: workloads.Marker = .{ .ctx = &marking, .f = mark };
    {
        // Opened to be read, not only named, so the workload can sync it.
        const work = try Io.Dir.cwd().openDir(io, try a.print("{s}/work", .{mnt}), .{ .iterate = true });
        defer work.close(io);
        marker.mark("start");
        try w.run(io, work, marker);
        marker.mark("end");
    }
    d.unmount();
    d.unmap(lw);
    d.unloop(log_dev);

    // What the model allows.
    const allowed = try modelStates(a, io, w);

    // The replay: the disk as it was, then each entry in turn.
    const log_bytes = try Io.Dir.cwd().readFileAlloc(io, log_path, a, .unlimited);
    const log = try Log.parse(log_bytes);
    _ = try run(a, io, &.{ "cp", "--sparse=always", base_path, crash_path });
    const crash_file = try Io.Dir.cwd().openFile(io, crash_path, .{ .mode = .read_write });
    defer crash_file.close(io);
    const crash_dev = try d.loop(crash_path);
    var seen: std.StringArrayHashMapUnmanaged(Seen) = .empty;
    var started = false;
    var last_mark: []const u8 = "before the run";
    var points: u64 = 0;
    var it = log.iterator();
    var index: u64 = 0;
    while (try it.next()) |entry| : (index += 1) {
        if (entry.flags.mark) {
            last_mark = entry.data;
            if (std.mem.eql(u8, entry.data, "start")) started = true;
            continue;
        }
        if (!entry.flags.discard and entry.sectors > 0) {
            try crash_file.writePositionalAll(io, entry.data, entry.sector * log.sectorsize);
        } else if (entry.flags.discard) {
            const zeros = try a.alloc(u8, @intCast(entry.sectors * log.sectorsize));
            @memset(zeros, 0);
            try crash_file.writePositionalAll(io, zeros, entry.sector * log.sectorsize);
        }
        if (!started) continue;
        points += 1;
        const state = try crashState(a, io, &d, fs, crash_dev, cow_path, mnt, sectors);
        const gop = try seen.getOrPut(a, state);
        if (!gop.found_existing) gop.value_ptr.* = .{ .entry = index, .after = last_mark };
    }
    // The replayed disk must be the disk the run left: the log is whole.
    try crash_file.sync(io);
    const replayed = try Io.Dir.cwd().readFileAlloc(io, crash_path, a, .unlimited);
    const left = try Io.Dir.cwd().readFileAlloc(io, data_path, a, .unlimited);
    const whole = std.mem.eql(u8, replayed, left);
    var missing: usize = 0;
    var gap_ordered: usize = 0;
    for (seen.keys(), seen.values()) |state, where| {
        if (!allowed.strict.contains(state)) {
            missing += 1;
            try say(io, "{t} {s}: entry {d}, after \"{s}\", recovered to a state the model does not reach:\n{s}", .{ fs, w.name, where.entry, where.after, state });
        }
        if (!allowed.ordered.contains(state)) gap_ordered += 1;
    }
    try say(io, "{t} {s}: {d} crash points, {d} states recovered, {d} reached by the model (strict), {d} not; {d} not reached under ordered_metadata; replay {s}\n", .{
        fs, w.name, points, seen.count(), allowed.strict.count(), missing, gap_ordered, if (whole) "whole" else "NOT WHOLE",
    });
    return missing == 0 and whole;
}

const Seen = struct { entry: u64, after: []const u8 };

/// What the disk recovers to now: a snapshot of it mounted, so the
/// recovery's own writes go to the snapshot, and the directory read.
fn crashState(a: std.mem.Allocator, io: Io, d: *Devices, fs: Fs, origin: []const u8, cow_path: []const u8, mnt: []const u8, sectors: u64) ![]const u8 {
    try sparse(io, cow_path, @max(sectors * 512 / 4, 16 << 20));
    const cow_dev = try d.loop(cow_path);
    defer d.unloop(cow_dev);
    const name = try a.print("shakedown-snap-{d}", .{std.os.linux.getpid()});
    const snap = try d.map(name, try a.print("0 {d} snapshot {s} {s} N 8", .{ sectors, origin, cow_dev }));
    defer d.unmap(name);
    d.mount(fs, snap, mnt) catch return a.dupe(u8, "(does not mount)\n");
    defer d.unmount();
    const work = Io.Dir.cwd().openDir(io, try a.print("{s}/work", .{mnt}), .{ .iterate = true }) catch return a.dupe(u8, "(no work directory)\n");
    defer work.close(io);
    return workloads.describe(a, io, work);
}

const Allowed = struct {
    strict: std.StringHashMapUnmanaged(void) = .empty,
    ordered: std.StringHashMapUnmanaged(void) = .empty,
};

/// Every state `everyCrash` reaches from the workload on `Sim.Fs`, under
/// each durability model.
fn modelStates(a: std.mem.Allocator, io: Io, w: workloads.Workload) !Allowed {
    _ = io;
    var allowed: Allowed = .{};
    inline for (.{ .strict, .ordered_metadata }) |durability| {
        var ctx: Collect = .{ .a = a, .w = w, .into = if (durability == .strict) &allowed.strict else &allowed.ordered };
        _ = try shakedown.everyCrash(a, &ctx, .{ .sim = .{ .watchdog = null, .fs = .{ .durability = durability } }, .max_states = 4096 });
    }
    return allowed;
}

const Collect = struct {
    a: std.mem.Allocator,
    w: workloads.Workload,
    into: *std.StringHashMapUnmanaged(void),

    pub fn setUp(c: *Collect, sim: *shakedown.Sim) !void {
        try sim.fs().mkdir("work");
        for (c.w.initial) |f| try sim.fs().write(try c.a.print("work/{s}", .{f.name}), f.bytes);
    }

    pub fn run(c: *Collect, io: Io) !void {
        const work = try Io.Dir.cwd().openDir(io, "work", .{ .iterate = true });
        defer work.close(io);
        try c.w.run(io, work, .{});
    }

    pub fn recover(_: *Collect, _: Io) !void {}

    pub fn check(c: *Collect, io: Io) !void {
        const work = try Io.Dir.cwd().openDir(io, "work", .{ .iterate = true });
        defer work.close(io);
        try c.into.put(c.a, try workloads.describe(c.a, io, work), {});
    }
};

test {
    _ = Log;
}
