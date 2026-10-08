const std = @import("std");
const builtin = @import("builtin");
const Sim = @import("Sim.zig");
const Io = std.Io;
const t = std.testing;
test "Fs basic tree and files" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.fs().write("old", "before");
    const Work = struct {
        fn run(io: Io) !void {
            const cwd = Io.Dir.cwd();
            const file = try cwd.createFile(io, "new", .{ .read = true });
            defer file.close(io);
            try file.writePositionalAll(io, "after", 0);
            var bytes: [5]u8 = undefined;
            try t.expectEqual(5, try file.readPositional(io, &.{&bytes}, 0));
            try t.expectEqualStrings("after", &bytes);
            try file.sync(io);
            try cwd.rename("new", cwd, "old", io);
        }
    };
    try t.expect(sim.run(Work.run, .{sim.io()}) == .finished);
    const bytes = try sim.fs().read(t.allocator, "old");
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("after", bytes);
}

fn bytesEqual(fs: *Sim.Fs, path: []const u8, expected: []const u8) !void {
    const bytes = try fs.read(t.allocator, path);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}

test "Fs snapshots share pages, restore faults, and invalidate handles" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    var page: [8192]u8 = @splat('a');
    try sim.fs().write("file", &page);
    const snap = try sim.fs().snapshot();
    defer snap.deinit();
    const file = try sim.fs().model.openHandle(try sim.fs().model.resolve(0, "file", true), true, true, false, false);
    _ = try sim.fs().model.put(try sim.fs().model.resolve(0, "file", true), 4096, "b");
    try sim.fs().failReads("file", 0, 1);
    sim.fs().restore(snap);
    try t.expectError(error.BadHandle, sim.fs().model.handle(file.handle));
    try bytesEqual(sim.fs(), "file", &page);
    page[0] = 'a';
}

test "Fs sector subsets and write reordering are all reachable" {
    const sim = try Sim.init(t.allocator, .{ .fs = .{ .sector = 1 }, .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "00");
    const id = try fs.model.resolve(0, "file", true);
    _ = try fs.model.put(id, 0, "11");
    var states = try fs.crashStates(16);
    defer states.deinit();
    var mask: u8 = 0;
    var count: usize = 0;
    while (try states.next()) |snap| {
        defer snap.deinit();
        fs.restore(snap);
        const bytes = try fs.read(t.allocator, "file");
        defer t.allocator.free(bytes);
        const bits: u3 = @intCast(@as(u8, @intFromBool(bytes[0] == '1')) + 2 * @as(u8, @intFromBool(bytes[1] == '1')));
        mask |= @as(u8, 1) << bits;
        count += 1;
    }
    try t.expectEqual(4, count);
    try t.expectEqual(15, mask);
    // Both orders of two overlapping writes are explored, including an older
    // pending write overwriting the later one after a crash.
    const second = try Sim.init(t.allocator, .{ .fs = .{ .sector = 1 }, .watchdog = null });
    defer second.deinit();
    try second.fs().write("file", "0");
    const inode = try second.fs().model.resolve(0, "file", true);
    _ = try second.fs().model.put(inode, 0, "1");
    _ = try second.fs().model.put(inode, 0, "2");
    var reordered = try second.fs().crashStates(16);
    defer reordered.deinit();
    var values: u8 = 0;
    while (try reordered.next()) |snap| {
        defer snap.deinit();
        second.fs().restore(snap);
        const b = try second.fs().read(t.allocator, "file");
        defer t.allocator.free(b);
        values |= @as(u8, 1) << @as(u3, @intCast(b[0] - '0'));
    }
    try t.expectEqual(7, values);
}

test "Fs three-file batch has exactly the eight hand-derived atomic name states" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    const dest = [_][]const u8{ "a", "b", "c" };
    const temp = [_][]const u8{ "ta", "tb", "tc" };
    for (dest, temp) |d, tmp| {
        try fs.write(d, "old");
        try fs.write(tmp, "new");
    }
    for (dest, temp) |d, tmp| try fs.model.rename(0, tmp, 0, d, false);
    var states = try fs.crashStates(64);
    defer states.deinit();
    var mask: u8 = 0;
    var count: usize = 0;
    while (try states.next()) |snap| {
        defer snap.deinit();
        fs.restore(snap);
        var bits: u3 = 0;
        for (dest, temp, 0..) |d, tmp, i| {
            const b = try fs.read(t.allocator, d);
            defer t.allocator.free(b);
            const is_new = std.mem.eql(u8, b, "new");
            try t.expect(is_new or std.mem.eql(u8, b, "old"));
            if (is_new) {
                bits |= @as(u3, 1) << @intCast(i);
                try t.expectError(error.FileNotFound, fs.read(t.allocator, tmp));
            } else try bytesEqual(fs, tmp, "new");
        }
        mask |= @as(u8, 1) << bits;
        count += 1;
    }
    try t.expectEqual(8, count);
    try t.expectEqual(255, mask);
}

test "Fs airlock contract: writeout barrier publish and flush on every platform" {
    // airlock's durability table: Linux fdatasync -> rename -> fsync(dir);
    // Darwin writeouts -> barrier -> rename -> directory writeout -> full;
    // Windows writeouts -> full -> rename -> directory writeout -> full.
    for ([_]enum { linux, darwin, windows }{ .linux, .darwin, .windows }) |platform| {
        const sim = try Sim.init(t.allocator, .{ .fs = .{ .sector = 1 }, .watchdog = null });
        defer sim.deinit();
        const fs = sim.fs();
        try fs.write("dest", "old");
        const tmp = try fs.model.create(0, "temp", .file, .default_file, null);
        const file = try fs.model.openHandle(tmp, true, true, false, false);
        _ = try fs.model.put(tmp, 0, "new");
        if (platform == .linux) try fs.flush(file.handle, .data) else {
            try fs.flush(file.handle, .writeout);
            try fs.flush(file.handle, if (platform == .darwin) .barrier else .full);
        }
        try fs.model.rename(0, "temp", 0, "dest", false);
        var states = try fs.crashStates(512);
        defer states.deinit();
        var old_seen = false;
        var new_seen = false;
        const published = try fs.snapshot();
        defer published.deinit();
        while (try states.next()) |snap| {
            defer snap.deinit();
            fs.restore(snap);
            const b = try fs.read(t.allocator, "dest");
            defer t.allocator.free(b);
            if (std.mem.eql(u8, b, "old")) old_seen = true else if (std.mem.eql(u8, b, "new")) new_seen = true else return error.TornPublish;
        }
        try t.expect(old_seen and new_seen);
        fs.restore(published);
        if (platform != .linux) try fs.flushDir(Io.Dir.cwd().handle, .writeout);
        try fs.flushDir(Io.Dir.cwd().handle, .full);
        try fs.crash(.lose_all);
        try bytesEqual(fs, "dest", "new");
    }
}

test "Fs airlock contract detects a missing barrier and distinguishes data from full" {
    const sim = try Sim.init(t.allocator, .{ .fs = .{ .sector = 1 }, .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("dest", "old");
    const tmp = try fs.model.create(0, "temp", .file, .default_file, null);
    _ = try fs.model.put(tmp, 0, "new");
    try fs.model.flushInode(tmp, .writeout);
    try fs.model.rename(0, "temp", 0, "dest", false);
    var states = try fs.crashStates(512);
    defer states.deinit();
    var torn = false;
    while (try states.next()) |snap| {
        defer snap.deinit();
        fs.restore(snap);
        const b = try fs.read(t.allocator, "dest");
        defer t.allocator.free(b);
        if (!std.mem.eql(u8, b, "old") and !std.mem.eql(u8, b, "new")) torn = true;
    }
    try t.expect(torn);
    try fs.write("meta", "x");
    const id = try fs.model.resolve(0, "meta", true);
    var meta = fs.model.root.nodes.items[id].meta;
    meta.mtime = .fromNanoseconds(7);
    try fs.model.metadata(id, meta);
    try fs.model.flushInode(id, .data);
    try fs.crash(.lose_all);
    try t.expect(fs.model.stat(id).mtime.nanoseconds != 7);
    meta = fs.model.root.nodes.items[id].meta;
    meta.mtime = .fromNanoseconds(9);
    try fs.model.metadata(id, meta);
    try fs.model.flushInode(id, .full);
    try fs.crash(.lose_all);
    try t.expectEqual(9, fs.model.stat(id).mtime.nanoseconds);
}

test "Fs ordered metadata requires all earlier file data" {
    const sim = try Sim.init(t.allocator, .{ .fs = .{ .sector = 1, .durability = .ordered_metadata }, .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("dest", "old");
    const tmp = try fs.model.create(0, "temp", .file, .default_file, null);
    _ = try fs.model.put(tmp, 0, "new");
    try fs.model.rename(0, "temp", 0, "dest", false);
    var states = try fs.crashStates(512);
    defer states.deinit();
    while (try states.next()) |snap| {
        defer snap.deinit();
        fs.restore(snap);
        const b = try fs.read(t.allocator, "dest");
        defer t.allocator.free(b);
        try t.expect(std.mem.eql(u8, b, "old") or std.mem.eql(u8, b, "new"));
    }
}

test "Fs storage faults, capacity, timestamp rounding and name dialects" {
    const sim = try Sim.init(t.allocator, .{ .fs = .{ .capacity = 8, .timestamp_granularity = .fromSeconds(2) }, .clock = .{ .real = .fromNanoseconds(3_000_000_000) }, .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "1234");
    const id = try fs.model.resolve(0, "file", true);
    try t.expectEqual(2_000_000_000, fs.model.stat(id).mtime.nanoseconds);
    try t.expectError(error.NoSpaceLeft, fs.model.put(id, 8, "x"));
    try fs.misdirectNextWrite("file", 1);
    _ = try fs.model.put(id, 0, "Q");
    try bytesEqual(fs, "file", "1Q34");
    try fs.failReads("file", 1, 1);
    var one: [1]u8 = undefined;
    try t.expectError(error.InputOutput, fs.model.get(id, 1, &one));
    try t.expectEqual(1, try fs.model.get(id, 3, &one));
    try fs.failReads("file", 0, 0);
    try fs.corrupt("file", 0, 1);
    try t.expectEqual(1, try fs.model.get(id, 0, &one));
    try t.expectEqual(@as(u8, '1' ^ 0xff), one[0]);
    for ([_]enum { posix, darwin, windows }{ .posix, .darwin, .windows }) |dialect| {
        const s = try Sim.init(t.allocator, .{ .fs = .{ .names = switch (dialect) {
            .posix => .posix,
            .darwin => .darwin,
            .windows => .windows,
        } }, .watchdog = null });
        defer s.deinit();
        try s.fs().write("Name", "x");
        if (dialect == .posix) try t.expectError(error.FileNotFound, s.fs().read(t.allocator, "name")) else try bytesEqual(s.fs(), "name", "x");
        try s.fs().write("é", "utf8");
        if (dialect == .darwin) try bytesEqual(s.fs(), "E\u{301}", "utf8");
        if (dialect == .windows) {
            try t.expectError(error.BadPathName, s.fs().model.create(0, "CON.txt", .file, .default_file, null));
            try t.expectError(error.BadPathName, s.fs().model.create(0, "trailing.", .file, .default_file, null));
            try s.fs().mkdir("dir");
            try s.fs().write("dir\\file", "windows");
            try bytesEqual(s.fs(), "DIR/FILE", "windows");
        }
    }
}

const shakedown = @import("shakedown.zig");
const CrashContext = struct {
    fs: *Sim.Fs = undefined,
    recovered: u64 = 0,
    pub fn setUp(ctx: *CrashContext, sim: *Sim) !void {
        ctx.fs = sim.fs();
        try ctx.fs.write("dest", "old");
    }
    pub fn run(_: *CrashContext, io: Io) !void {
        const cwd = Io.Dir.cwd();
        const file = try cwd.createFile(io, "temp", .{});
        defer file.close(io);
        try file.writePositionalAll(io, "new", 0);
        try file.sync(io);
        try cwd.rename("temp", cwd, "dest", io);
    }
    pub fn recover(ctx: *CrashContext, io: Io) !void {
        _ = io;
        ctx.recovered += 1;
    }
    pub fn check(_: *CrashContext, io: Io) !void {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, "dest", t.allocator, .limited(32));
        defer t.allocator.free(bytes);
        try t.expect(std.mem.eql(u8, bytes, "old") or std.mem.eql(u8, bytes, "new"));
    }
};
test "Fs everyCrash sweeps call boundaries and recovery on fresh schedulers" {
    var ctx: CrashContext = .{};
    const report = try shakedown.everyCrash(t.allocator, &ctx, .{ .sim = .{ .watchdog = null }, .max_states = 64 });
    try t.expect(report.steps >= 5);
    try t.expect(report.runs > report.steps);
    try t.expectEqual(0, report.bounded);
    try t.expectEqual(ctx.recovered + 1, report.runs);
}

test "Fs crash fault abandons every task and skips defers" {
    const entries = [_]shakedown.IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .dirRename, .n = 1 } }, .fault = .crash }};
    const Work = struct {
        fn run(io: Io, deferred: *bool, finished: *bool) !void {
            defer deferred.* = true;
            const file = try Io.Dir.cwd().createFile(io, "temp", .{});
            try file.writePositionalAll(io, "new", 0);
            try Io.Dir.cwd().rename("temp", .cwd(), "dest", io);
            finished.* = true;
        }
    };
    for ([_]Sim.Executor{ .auto, .threads }) |executor| {
        const sim = try Sim.init(t.allocator, .{ .executor = executor, .faults = &entries, .watchdog = null });
        defer sim.deinit();
        try sim.fs().write("dest", "old");
        var deferred = false;
        var finished = false;
        try t.expect(sim.run(Work.run, .{ sim.io(), &deferred, &finished }) == .finished);
        try t.expect(!deferred and !finished);
        try bytesEqual(sim.fs(), "dest", "old");
    }
    try t.expectError(error.FaultNotApplicable, shakedown.FaultIo.init(t.allocator, t.io, .{ .plan = &entries }));
}

fn allocations(gpa: std.mem.Allocator) !void {
    const sim = try Sim.init(gpa, .{ .watchdog = null, .trace = .off });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("a", "old");
    const snap = try fs.snapshot();
    defer snap.deinit();
    const id = try fs.model.create(0, "b", .file, .default_file, null);
    const dir = try fs.model.create(0, "dir", .directory, .default_dir, null);
    _ = try fs.model.create(dir, "sym", .sym_link, .default_file, "../b");
    try fs.model.link(id, dir, "hard");
    fs.model.at = .fromNanoseconds(fs.model.at.nanoseconds + 7);
    _ = try fs.model.put(id, 0, "new");
    try fs.model.flushInode(id, .writeout);
    try fs.model.flushInode(id, .barrier);
    try fs.model.rename(0, "b", 0, "a", false);
    var states = try fs.crashStates(8);
    defer states.deinit();
    while (try states.next()) |state_| {
        state_.deinit();
    }
    try fs.flushDir(Io.Dir.cwd().handle, .full);
    try fs.corrupt("a", 0, 1);
    try fs.failReads("a", 0, 1);
    try fs.misdirectNextWrite("a", 0);
    try fs.crash(.random);
    fs.restore(snap);
}
test "Fs all allocation failures free tree versions pages and crash iterators" {
    var stable = shakedown.alloc.NoResize.init(t.allocator);
    try t.checkAllAllocationFailures(stable.allocator(), allocations, .{});
}

const LockWork = struct {
    fn wait(io: Io, file: Io.File, ready: *Io.Event, obtained: *bool) !void {
        ready.set(io);
        try file.lock(io, .exclusive);
        obtained.* = true;
        file.unlock(io);
    }
    fn run(io: Io) !void {
        const cwd = Io.Dir.cwd();
        const first = try cwd.createFile(io, "lock", .{ .read = true });
        defer first.close(io);
        try cwd.hardLink("lock", cwd, "alias", io, .{});
        const second = try cwd.openFile(io, "alias", .{});
        defer second.close(io);
        try first.lock(io, .exclusive);
        try t.expect(!try second.tryLock(io, .shared));
        var ready: Io.Event = .unset;
        var obtained = false;
        var waiter = try io.concurrent(wait, .{ io, second, &ready, &obtained });
        defer waiter.cancel(io) catch {};
        try ready.wait(io);
        try t.expect(!obtained);
        try t.expectError(error.Canceled, waiter.cancel(io));
        try t.expect(!obtained);
        ready = .unset;
        waiter = try io.concurrent(wait, .{ io, second, &ready, &obtained });
        try ready.wait(io);
        first.unlock(io);
        try waiter.await(io);
        try t.expect(obtained);
    }
};
test "Fs blocking locks share hard-link identity and honor cancelation" {
    for ([_]Sim.Executor{ .auto, .threads }) |executor| {
        const sim = try Sim.init(t.allocator, .{ .executor = executor, .watchdog = null });
        defer sim.deinit();
        try t.expect(sim.run(LockWork.run, .{sim.io()}) == .finished);
    }
}

const Operation = union(enum) { write: struct { name: u8, offset: u8, value: u8 }, remove: u8, rename: struct { from: u8, to: u8 }, length: struct { name: u8, len: u8 }, link: struct { from: u8, to: u8 } };
fn filename(index: u8) [1]u8 {
    return .{'a' + index};
}
fn apply(io: Io, dir: Io.Dir, op: Operation) !void {
    switch (op) {
        .write => |w| {
            const name = filename(w.name);
            const file = try dir.createFile(io, &name, .{ .truncate = false });
            defer file.close(io);
            try file.writePositionalAll(io, &.{w.value}, w.offset);
        },
        .remove => |i| {
            const name = filename(i);
            try dir.deleteFile(io, &name);
        },
        .rename => |r| {
            const from = filename(r.from);
            const to = filename(r.to);
            try dir.rename(&from, dir, &to, io);
        },
        .length => |l| {
            const name = filename(l.name);
            const file = try dir.openFile(io, &name, .{ .mode = .read_write });
            defer file.close(io);
            try file.setLength(io, l.len);
        },
        .link => |l| {
            const from = filename(l.from);
            const to = filename(l.to);
            try dir.hardLink(&from, dir, &to, io, .{});
        },
    }
}
const Content = struct { bytes: [64]u8, len: usize };
fn contents(io: Io, dir: Io.Dir, name: []const u8) !Content {
    const bytes = try dir.readFileAlloc(io, name, t.allocator, .limited(64));
    defer t.allocator.free(bytes);
    var result: Content = .{ .bytes = undefined, .len = bytes.len };
    @memcpy(result.bytes[0..bytes.len], bytes);
    return result;
}
const Differential = struct {
    operations: []const Operation,
    results: [64]anyerror!void = undefined,
    images: [64][4]anyerror!Content = undefined,
    fn run(io: Io, ctx: *Differential) !void {
        for (ctx.operations, 0..) |op, step| {
            ctx.results[step] = apply(io, .cwd(), op);
            for (0..4) |i| {
                const name = filename(@intCast(i));
                ctx.images[step][i] = contents(io, .cwd(), &name);
            }
        }
    }
    fn compare(ctx: *Differential, dir: Io.Dir) !void {
        // Native Windows pathname conversion needs large stack buffers. Native
        // calls belong on this OS thread, outside the simulated fiber's stack.
        for (ctx.operations, 0..) |op, step| {
            if (apply(t.io, dir, op)) |_| try ctx.results[step] else |err| try t.expectError(err, ctx.results[step]);
            for (0..4) |i| {
                const name = filename(@intCast(i));
                const fake = ctx.images[step][i];
                if (contents(t.io, dir, &name)) |a| {
                    const b = try fake;
                    try t.expectEqualSlices(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
                } else |err| try t.expectError(err, fake);
            }
        }
    }
};
fn differential(_: void, case: *shakedown.Case) !void {
    var ops: [64]Operation = undefined;
    const count = shakedown.gen.intRange(case.source, u8, 1, ops.len);
    for (ops[0..count]) |*op| {
        const a = shakedown.gen.intRange(case.source, u8, 0, 3);
        const b = shakedown.gen.intRange(case.source, u8, 0, 3);
        op.* = switch (shakedown.gen.intRange(case.source, u8, 0, if (builtin.os.tag == .windows) 3 else 4)) {
            0 => .{ .write = .{ .name = a, .offset = shakedown.gen.intRange(case.source, u8, 0, 12), .value = shakedown.gen.int(case.source, u8) } },
            1 => .{ .remove = a },
            2 => .{ .rename = .{ .from = a, .to = b } },
            3 => .{ .length = .{ .name = a, .len = shakedown.gen.intRange(case.source, u8, 0, 16) } },
            else => .{ .link = .{ .from = a, .to = b } },
        };
    }
    var real = t.tmpDir(.{});
    defer real.cleanup();
    const sim = try case.sim(.{ .watchdog = null });
    var ctx: Differential = .{ .operations = ops[0..count] };
    const outcome = sim.run(Differential.run, .{ sim.io(), &ctx });
    if (outcome == .failed) return outcome.failed;
    try t.expect(outcome == .finished);
    try ctx.compare(real.dir);
}
test "Fs random file sequences conform to Threaded" {
    try shakedown.check(t.allocator, {}, differential, .{ .seed = 0xb4, .cases = 256 });
}

test "Fs writeout survives an OS crash, but can be lost at power loss" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "old");
    const id = try fs.model.resolve(0, "file", true);
    _ = try fs.model.put(id, 0, "new");
    try fs.model.flushInode(id, .writeout);
    const written = try fs.snapshot();
    defer written.deinit();
    try fs.crash(.os_crash);
    try bytesEqual(fs, "file", "new");
    fs.restore(written);
    try fs.crash(.lose_all);
    try bytesEqual(fs, "file", "old");
}

test "Fs writeout and a later full directory flush persist implicit file timestamps" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "old");
    const id = try fs.model.resolve(0, "file", true);
    const expected = fs.model.at.nanoseconds + 7;
    fs.model.at = .fromNanoseconds(expected);
    _ = try fs.model.put(id, 0, "new");
    try fs.model.flushInode(id, .writeout);
    try fs.flushDir(Io.Dir.cwd().handle, .full);
    try fs.crash(.lose_all);
    try t.expectEqual(expected, fs.model.stat(id).mtime.nanoseconds);
}

const NondeterministicCrash = struct {
    calls: u8 = 0,
    pub fn setUp(ctx: *NondeterministicCrash, sim: *Sim) !void {
        ctx.calls +%= 1;
        try sim.fs().write("dest", "old");
    }
    pub fn run(ctx: *NondeterministicCrash, io: Io) !void {
        const file = try Io.Dir.cwd().createFile(io, if (ctx.calls % 2 == 1) "a" else "b", .{});
        file.close(io);
    }
    pub fn recover(_: *NondeterministicCrash, _: Io) !void {}
    pub fn check(_: *NondeterministicCrash, _: Io) !void {}
};
test "Fs everyCrash rejects a nondeterministic path even when both opens succeed" {
    var ctx: NondeterministicCrash = .{};
    try t.expectError(error.Nondeterministic, shakedown.everyCrash(t.allocator, &ctx, .{ .sim = .{ .watchdog = null } }));
}

const FailedRecovery = struct {
    pub fn setUp(_: *FailedRecovery, sim: *Sim) !void {
        try sim.fs().write("dest", "old");
    }
    pub fn run(_: *FailedRecovery, io: Io) !void {
        const file = try Io.Dir.cwd().openFile(io, "dest", .{});
        file.close(io);
    }
    pub fn recover(_: *FailedRecovery, io: Io) !void {
        _ = try Io.Dir.cwd().statFile(io, "dest", .{});
    }
    pub fn check(_: *FailedRecovery, _: Io) !void {
        return error.InvariantBroken;
    }
};
test "Fs everyCrash reports the crash point and the recovery trace" {
    var ctx: FailedRecovery = .{};
    var report: shakedown.EveryFaultReport = .{};
    try t.expectError(error.CheckFailed, shakedown.everyCrash(t.allocator, &ctx, .{ .sim = .{ .watchdog = null }, .diagnostics = &report }));
    defer report.deinit();
    try t.expectEqual(error.InvariantBroken, report.failure.?.err);
    try t.expectEqual(1, report.failure.?.injected.?.step);
    try t.expect(report.failure.?.trace.len > 0);
}

test "Fs a Windows cross-directory rename permits both or neither name" {
    const sim = try Sim.init(t.allocator, .{ .fs = .{ .names = .windows }, .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.mkdir("other");
    try fs.write("old", "data");
    try fs.model.rename(0, "old", 0, "other/new", false);
    var states = try fs.crashStates(32);
    defer states.deinit();
    var mask: u8 = 0;
    while (try states.next()) |snap| {
        defer snap.deinit();
        fs.restore(snap);
        const old = fs.model.resolve(0, "old", true) catch null;
        const new = fs.model.resolve(0, "other/new", true) catch null;
        const bits: u3 = @as(u3, @intFromBool(old != null)) + 2 * @as(u3, @intFromBool(new != null));
        mask |= @as(u8, 1) << bits;
    }
    try t.expectEqual(15, mask);
}

test "Fs sparse terabyte images and truncation copy only the changed radix paths" {
    var count = shakedown.alloc.Counting.init(t.allocator);
    const sim = try Sim.init(count.allocator(), .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("sparse", "first");
    const id = try fs.model.resolve(0, "sparse", true);
    const large: u64 = 1 << 40;
    try fs.model.setLength(id, large);
    const snap = try fs.snapshot();
    defer snap.deinit();
    const before = count.total_bytes;
    _ = try fs.model.put(id, large - 1, "Z");
    try t.expect(count.total_bytes - before < 32 * 1024);
    var bytes: [8]u8 = undefined;
    _ = try fs.model.get(id, large - 8, &bytes);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 'Z' }, &bytes);
    try fs.model.setLength(id, 2);
    try fs.model.setLength(id, large);
    _ = try fs.model.get(id, 0, &bytes);
    try t.expectEqualSlices(u8, &.{ 'f', 'i', 0, 0, 0, 0, 0, 0 }, &bytes);
    _ = try fs.model.get(id, large - 8, &bytes);
    try t.expect(std.mem.allEqual(u8, &bytes, 0));
    fs.restore(snap);
    _ = try fs.model.get(id, large - 8, &bytes);
    try t.expect(std.mem.allEqual(u8, &bytes, 0));
}

fn sparseAllocations(gpa: std.mem.Allocator) !void {
    const sim = try Sim.init(gpa, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "prefix");
    const id = try fs.model.resolve(0, "file", true);
    const snap = try fs.snapshot();
    defer snap.deinit();
    _ = try fs.model.put(id, 1 << 40, "tail");
    const extended = try fs.snapshot();
    defer extended.deinit();
    try fs.model.setLength(id, (1 << 40) + 2);
    try fs.model.setLength(id, 3);
    try fs.model.setLength(id, 1 << 40);
}
test "Fs all allocation failures free sparse radix paths and shared subtrees" {
    var stable = shakedown.alloc.NoResize.init(t.allocator);
    try t.checkAllAllocationFailures(stable.allocator(), sparseAllocations, .{});
}

test "Fs reclaim unreachable pending file metadata and inode slots" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const model = sim.fs().model;
    for (0..1000) |i| {
        model.at = .fromNanoseconds(@intCast(i + 1));
        const id = try model.create(0, "file", .file, .default_file, null);
        _ = try model.put(id, 0, "data");
        try model.flushInode(id, .data);
        try model.remove(0, "file", false);
        try model.flushInode(0, .full);
        try t.expectEqual(0, model.root.pending.items.len);
        try t.expect(model.root.nodes.items.len <= 2);
    }
}

test "Fs crash-state equality traverses sparse pages, not holes" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("sparse", "");
    const id = try fs.model.resolve(0, "sparse", true);
    try fs.model.setLength(id, 1 << 40);
    try fs.model.flushInode(id, .full);
    _ = try fs.model.put(id, (1 << 40) - 1, "X");
    var states = try fs.crashStates(8);
    defer states.deinit();
    var count: usize = 0;
    while (try states.next()) |snap| {
        snap.deinit();
        count += 1;
    }
    try t.expectEqual(2, count);
}

test "Fs ordered metadata enforces data prerequisites on directory sync and OS crash" {
    for ([_]Sim.Fs.Flush{ .full, .writeout }) |flush| {
        const sim = try Sim.init(t.allocator, .{ .fs = .{ .durability = .ordered_metadata }, .watchdog = null });
        defer sim.deinit();
        const fs = sim.fs();
        try fs.write("dest", "old");
        const id = try fs.model.create(0, "temp", .file, .default_file, null);
        _ = try fs.model.put(id, 0, "new");
        try fs.model.rename(0, "temp", 0, "dest", false);
        try fs.flushDir(Io.Dir.cwd().handle, flush);
        try fs.crash(if (flush == .writeout) .os_crash else .lose_all);
        try bytesEqual(fs, "dest", "new");
    }
}

test "Fs symlinks, hard links, timestamps and atomic files use the same Io tree" {
    const sim = try Sim.init(t.allocator, .{ .fs = .{ .timestamp_granularity = .fromSeconds(2) }, .watchdog = null });
    defer sim.deinit();
    const Work = struct {
        fn run(io: Io) !void {
            const cwd = Io.Dir.cwd();
            var atomic = try cwd.createFileAtomic(io, "dir/file", .{ .make_path = true, .replace = true });
            defer atomic.deinit(io);
            try atomic.file.writePositionalAll(io, "contents", 0);
            try atomic.file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(7_000_000_000) } });
            try atomic.replace(io);
            try cwd.symLink(io, "file", "dir/sym", .{});
            try cwd.hardLink("dir/file", cwd, "hard", io, .{});
            var link: [32]u8 = undefined;
            try t.expectEqualStrings("file", link[0..try cwd.readLink(io, "dir/sym", &link)]);
            const file = try cwd.openFile(io, "dir/sym", .{});
            defer file.close(io);
            const stat = try file.stat(io);
            try t.expectEqual(2, stat.nlink);
            try t.expectEqual(6_000_000_000, stat.mtime.nanoseconds);
            try t.expectEqual(Io.File.Kind.sym_link, (try cwd.statFile(io, "dir/sym", .{ .follow_symlinks = false })).kind);
            try cwd.symLink(io, "loop", "loop", .{});
            try t.expectError(error.SymLinkLoop, cwd.openFile(io, "loop", .{}));
            try cwd.deleteFile(io, "dir/file");
            var bytes: [8]u8 = undefined;
            try t.expectEqual(8, try file.readPositionalAll(io, &bytes, 0));
            try t.expectEqualStrings("contents", &bytes);
            try t.expectError(error.FileNotFound, cwd.openFile(io, "dir/sym", .{}));
        }
    };
    try t.expect(sim.run(Work.run, .{sim.io()}) == .finished);
    try bytesEqual(sim.fs(), "hard", "contents");
}

test "Fs preserves standard output operation routing" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const Work = struct {
        fn run(io: Io) !void {
            for ([_]Io.File{ .stdout(), .stderr() }) |file| {
                const result = try io.operate(.{ .file_write_streaming = .{ .file = file, .data = &.{""} } });
                try t.expectEqual(0, try result.file_write_streaming);
            }
        }
    };
    try t.expectEqual(Sim.Outcome.finished, sim.run(Work.run, .{sim.io()}));
}

test "Fs setup mkdir rejects a file" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "x");
    try t.expectError(error.NotDir, fs.mkdir("file"));
}

test "Fs read faults stop at EOF" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const fs = sim.fs();
    try fs.write("file", "x");
    try fs.failReads("file", 8, 1);
    const id = try fs.model.resolve(0, "file", true);
    var bytes: [16]u8 = undefined;
    try t.expectEqual(1, try fs.model.get(id, 0, &bytes));
    try t.expectEqual(0, try fs.model.get(id, 2, &bytes));
    try fs.failReads("file", 0, 32);
    try t.expectEqual(0, try fs.model.get(id, 2, &bytes));
}

test "Fs create follows dangling symlinks and exclusive create refuses them" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const Work = struct {
        fn run(io: Io) !void {
            const cwd = Io.Dir.cwd();
            _ = try cwd.createDirPath(io, "dir");
            try cwd.symLink(io, "target", "dir/sym", .{});
            try t.expectError(error.PathAlreadyExists, cwd.createFile(io, "dir/sym", .{ .exclusive = true }));
            const file = try cwd.createFile(io, "dir/sym", .{});
            defer file.close(io);
            try file.writePositionalAll(io, "through", 0);
            try cwd.symLink(io, "loop", "loop", .{});
            try t.expectError(error.PathAlreadyExists, cwd.createFile(io, "loop", .{ .exclusive = true }));
            try t.expectError(error.SymLinkLoop, cwd.createFile(io, "loop", .{}));
        }
    };
    switch (sim.run(Work.run, .{sim.io()})) {
        .finished => {},
        .failed => |err| return err,
        else => return error.TestUnexpectedResult,
    }
    try bytesEqual(sim.fs(), "dir/target", "through");
}
