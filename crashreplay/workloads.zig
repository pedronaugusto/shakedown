//! What the replay runs: small programs of the shapes durable code takes
//! (an atomic replace, an appended log, an overwrite, files made and named),
//! written once against `std.Io`, so the same code runs on a real file
//! system under dm-log-writes and on `Sim.Fs`. Each starts from files
//! already on the disk, synced, and works in one directory.
const std = @import("std");
const Io = std.Io;
const repeat = @import("shakedown").corpus.repeat;

pub const File = struct { name: []const u8, bytes: []const u8 };

pub const Workload = struct {
    name: []const u8,
    /// Files on the disk, synced, before the run.
    initial: []const File,
    run: *const fn (io: Io, dir: Io.Dir, marker: Marker) anyerror!void,
};

/// Marks the log between a run's steps, so a crash point can be named by
/// the step it follows. A simulation marks nothing. Names have no spaces:
/// device-mapper splits a message on them.
pub const Marker = struct {
    ctx: ?*anyopaque = null,
    f: ?*const fn (ctx: *anyopaque, name: []const u8) void = null,

    pub fn mark(m: Marker, name: []const u8) void {
        if (m.f) |f| f(m.ctx.?, name);
    }
};

fn syncDir(io: Io, dir: Io.Dir) !void {
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

fn writeSynced(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
    try file.sync(io);
}

const old_text = repeat("old ", 300);
const new_text = repeat("new ", 1100);

/// A temp file written and synced, renamed over the target, the directory
/// synced: the target is the old file or the new one, never part of one.
fn replace(io: Io, dir: Io.Dir, marker: Marker) !void {
    try writeSynced(io, dir, "target.tmp", new_text);
    marker.mark("temp-synced");
    try dir.rename("target.tmp", dir, "target", io);
    marker.mark("renamed");
    try syncDir(io, dir);
    marker.mark("directory-synced");
}

/// Records appended to a log, each synced.
fn append(io: Io, dir: Io.Dir, marker: Marker) !void {
    const file = try dir.openFile(io, "log", .{ .mode = .read_write });
    defer file.close(io);
    var at: u64 = (try file.stat(io)).size;
    for (0..4) |i| {
        var record: [600]u8 = undefined;
        @memset(&record, 'a' + @as(u8, @intCast(i)));
        try file.writePositionalAll(io, &record, at);
        at += record.len;
        try file.sync(io);
        marker.mark("record-synced");
    }
}

/// A temp file renamed over the target with no sync at all, then the
/// directory synced: what a careless save does.
fn careless(io: Io, dir: Io.Dir, marker: Marker) !void {
    {
        const file = try dir.createFile(io, "target.tmp", .{});
        defer file.close(io);
        try file.writePositionalAll(io, new_text, 0);
    }
    marker.mark("temp-written");
    try dir.rename("target.tmp", dir, "target", io);
    try syncDir(io, dir);
    marker.mark("directory-synced");
}

/// The middle of a file overwritten in place and synced.
fn overwrite(io: Io, dir: Io.Dir, marker: Marker) !void {
    const file = try dir.openFile(io, "target", .{ .mode = .read_write });
    defer file.close(io);
    var middle: [4096]u8 = undefined;
    @memset(&middle, 'N');
    try file.writePositionalAll(io, &middle, 2048);
    marker.mark("written");
    try file.sync(io);
    marker.mark("synced");
}

/// Three files made and synced, the directory synced once after them.
fn create(io: Io, dir: Io.Dir, marker: Marker) !void {
    for ([_][]const u8{ "one", "two", "three" }) |name| {
        try writeSynced(io, dir, name, name);
        marker.mark("file-synced");
    }
    try syncDir(io, dir);
    marker.mark("directory-synced");
}

pub const all = [_]Workload{
    .{ .name = "replace", .initial = &.{.{ .name = "target", .bytes = old_text }}, .run = replace },
    .{ .name = "append", .initial = &.{.{ .name = "log", .bytes = "" }}, .run = append },
    .{ .name = "careless", .initial = &.{.{ .name = "target", .bytes = old_text }}, .run = careless },
    .{ .name = "overwrite", .initial = &.{.{ .name = "target", .bytes = repeat("o", 8192) }}, .run = overwrite },
    .{ .name = "create", .initial = &.{}, .run = create },
};

/// What a crash left in the directory, as text two disks can be compared
/// by: each entry in name order, its size, a hash of its bytes and the first
/// byte of each 512-byte sector, so a torn file reads as where it tore.
pub fn describe(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) ![]u8 {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "lost+found")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (names.items) |name| {
        const bytes = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch |err| {
            try out.writer.print("{s}: {t}\n", .{ name, err });
            continue;
        };
        defer gpa.free(bytes);
        try out.writer.print("{s} {d} {x:0>16} ", .{ name, bytes.len, std.hash.Wyhash.hash(0, bytes) });
        var at: usize = 0;
        while (at < bytes.len) : (at += 512) {
            const c = bytes[at];
            try out.writer.writeByte(if (std.ascii.isPrint(c)) c else '.');
        }
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}
