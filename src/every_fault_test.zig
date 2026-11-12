//! `everyFault` from outside: a save that survives every single fault passes,
//! and a save that does not, a leak on an error path and a run whose calls
//! depend on state outside its `Io` are each caught. A run that draws a
//! name from `io.random` draws the same name in every run.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const FaultIo = shakedown.FaultIo;

/// Saves "new" over "old" in `dir/save`, one of four ways.
pub const Save = struct {
    dir: Io.Dir,
    how: How,
    counting: shakedown.alloc.Counting = undefined,
    gpa: std.mem.Allocator = undefined,
    fio: *FaultIo = undefined,
    /// The last buffer a run allocated, for the test to free what leaked.
    kept: ?[]u8 = null,
    /// Runs set up so far.
    runs: u32 = 0,
    /// What this run drew from `io.random`, if it got that far.
    drawn: ?[4]u8 = null,
    /// What the clean run drew.
    first: ?[4]u8 = null,

    pub const How = enum {
        /// Temp file, sync, rename: the old save survives any fault.
        atomic,
        /// Truncates the save, then writes it: a fault loses the old one.
        in_place,
        /// As atomic, but leaks its buffer when the write fails.
        leaky,
        /// As atomic, with a temp name drawn from `io.random`.
        random_name,
        /// As atomic, with a temp name from how many runs came before:
        /// state outside the `Io`, so each run makes different calls.
        counted_name,
    };

    pub fn setUp(s: *Save, fio: *FaultIo) !void {
        try s.dir.writeFile(testing.io, .{ .sub_path = "save", .data = "old" });
        s.dir.deleteFile(testing.io, "save.tmp") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        s.counting = .init(testing.allocator);
        s.gpa = try fio.allocator(s.counting.allocator());
        s.fio = fio;
        s.drawn = null;
        s.runs += 1;
    }

    pub fn run(s: *Save, io: Io) !void {
        const contents = try s.gpa.dupe(u8, "new");
        s.kept = contents;
        switch (s.how) {
            .atomic, .random_name, .counted_name => {
                defer s.gpa.free(contents);
                var name_buffer: [32]u8 = undefined;
                const name = switch (s.how) {
                    .random_name => name: {
                        var bytes: [4]u8 = undefined;
                        io.random(&bytes);
                        s.drawn = bytes;
                        break :name try std.mem.print(&name_buffer, "save.{x}", .{bytes});
                    },
                    .counted_name => try std.mem.print(&name_buffer, "save.{d}", .{s.runs}),
                    .atomic, .in_place, .leaky => "save.tmp",
                };
                try writeSynced(io, s.dir, name, contents);
                errdefer s.dir.deleteFile(testing.io, name) catch {};
                try s.dir.rename(name, s.dir, "save", io);
            },
            .in_place => {
                defer s.gpa.free(contents);
                try writeSynced(io, s.dir, "save", contents);
            },
            .leaky => {
                try writeSynced(io, s.dir, "save.tmp", contents);
                defer s.gpa.free(contents);
                try s.dir.rename("save.tmp", s.dir, "save", io);
            },
        }
    }

    fn writeSynced(io: Io, dir: Io.Dir, name: []const u8, contents: []const u8) !void {
        const file = try dir.createFile(io, name, .{});
        defer file.close(io);
        try file.writePositionalAll(io, contents, 0);
        try file.sync(io);
    }

    pub fn check(s: *Save, io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = io;
        _ = injected;
        var buffer: [16]u8 = undefined;
        const now = try s.dir.readFile(testing.io, "save", &buffer);
        if (result) |_| {
            try testing.expectEqualStrings("new", now);
        } else |_| {
            if (!std.mem.eql(u8, now, "old") and !std.mem.eql(u8, now, "new")) return error.SaveLost;
        }
        if (s.counting.live_bytes != 0) return error.Leaked;
        if (s.drawn) |drawn| {
            const first = s.first orelse drawn;
            s.first = first;
            if (!std.mem.eql(u8, &first, &drawn)) return error.DrawDiffered;
        }
    }

    pub fn tearDown(s: *Save) void {
        _ = s;
    }
};

test "a save through a temp file and a rename survives every single fault" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .atomic };
    const report = try shakedown.everyFault(testing.allocator, testing.io, &save, .{});
    try testing.expect(report.steps >= 6);
    // Several faults at most steps: far more runs than steps.
    try testing.expect(report.runs > 2 * report.steps);
}

test "everyFault's shards fault the clean run's steps between them, each once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .atomic };
    const whole = try shakedown.everyFault(testing.allocator, testing.io, &save, .{});
    // Each shard makes the clean run too; its faulted runs are its own.
    var faulted: u64 = 0;
    for (0..3) |index| {
        const shard: shakedown.Shard = .{ .index = @intCast(index), .count = 3 };
        const part = try shakedown.everyFault(testing.allocator, testing.io, &save, .{ .shard = shard });
        try testing.expectEqual(whole.steps, part.steps);
        try testing.expect(part.runs > 1);
        faulted += part.runs - 1;
    }
    try testing.expectEqual(whole.runs - 1, faulted);
    try testing.expectError(error.CheckFailed, shakedown.everyFault(testing.allocator, testing.io, &save, .{ .shard = .{ .index = 3, .count = 3 } }));
}

test "a save in place is caught losing the old save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .in_place };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    try testing.expectError(error.CheckFailed, shakedown.everyFault(testing.allocator, testing.io, &save, .{ .diagnostics = &report }));
    const failure = report.failure.?;
    try testing.expectEqual(@as(anyerror, error.SaveLost), failure.err);
    // The file was created, so truncated; the write is where the old save dies.
    try testing.expectEqual(shakedown.IoCall.fileWritePositional, failure.injected.?.call);
    try testing.expect(std.mem.find(u8, failure.trace, "fileWritePositional") != null);
}

test "a buffer leaked on an error path is caught by an allocator check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .leaky };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyFault(testing.allocator, testing.io, &save, .{ .diagnostics = &report });
    // The leak is real: free what the failing run left behind.
    try testing.expectError(error.CheckFailed, result);
    try testing.expectEqual(@as(anyerror, error.Leaked), report.failure.?.err);
    try testing.expectEqual(@as(usize, 3), save.counting.live_bytes);
    testing.allocator.free(save.kept.?);
}

test "a run that names its temp file from io.random draws the same name in every run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .random_name };
    const report = try shakedown.everyFault(testing.allocator, testing.io, &save, .{});
    try testing.expect(report.runs > 2 * report.steps);

    // The seed is the options', so another seed draws another name.
    var other: Save = .{ .dir = tmp.dir, .how = .random_name };
    _ = try shakedown.everyFault(testing.allocator, testing.io, &other, .{ .random_seed = 1 });
    try testing.expect(!std.mem.eql(u8, &save.first.?, &other.first.?));
    var again: Save = .{ .dir = tmp.dir, .how = .random_name };
    _ = try shakedown.everyFault(testing.allocator, testing.io, &again, .{ .random_seed = 1 });
    try testing.expectEqualSlices(u8, &other.first.?, &again.first.?);
}

test "a run whose calls depend on state outside its Io is refused as nondeterministic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .counted_name };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    try testing.expectError(error.Nondeterministic, shakedown.everyFault(testing.allocator, testing.io, &save, .{ .diagnostics = &report }));
    try testing.expect(report.failure.?.difference != null);
}

const Raw = enum { barrier };

/// A seam that makes one raw call between two `Io` calls.
pub const Seam = struct {
    fio: *FaultIo = undefined,
    raw_failures: u32 = 0,

    pub fn setUp(s: *Seam, fio: *FaultIo) !void {
        s.fio = fio;
    }

    pub fn run(s: *Seam, io: Io) !void {
        _ = Io.Timestamp.now(io, .awake);
        const begun = s.fio.beginForeign(Raw, .barrier, "journal");
        if (begun.fault) |fault| {
            s.fio.endForeign(begun, .{ .err = fault.fail });
            return fault.fail;
        }
        s.fio.endForeign(begun, .{ .ok = 0 });
        try io.sleep(.zero, .awake);
    }

    pub fn check(s: *Seam, io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = io;
        const at = injected orelse return result;
        if (at.call == .foreign) {
            try testing.expectError(error.InputOutput, result);
            s.raw_failures += 1;
        }
    }

    pub fn tearDown(s: *Seam) void {
        _ = s;
    }

    pub fn faultsFor(s: *Seam, record: shakedown.IoTrace.Record) []const shakedown.IoFault {
        _ = s;
        _ = record;
        return &.{.{ .fail = error.InputOutput }};
    }
};

test "a seam's raw calls are faulted with the Io calls around them" {
    var seam: Seam = .{};
    const report = try shakedown.everyFault(testing.allocator, testing.io, &seam, .{});
    try testing.expectEqual(@as(u64, 3), report.steps);
    try testing.expectEqual(@as(u32, 1), seam.raw_failures);
}

test "a clean run longer than max_steps is refused" {
    var seam: Seam = .{};
    try testing.expectError(error.TooManySteps, shakedown.everyFault(testing.allocator, testing.io, &seam, .{ .max_steps = 2 }));
}

/// Records the order of its hooks, and frees in `tearDown` what `check`
/// reads.
pub const Ordered = struct {
    log: [256]u8 = undefined,
    len: usize = 0,
    /// Owned between `setUp` and `tearDown`.
    scratch: ?[]u8 = null,
    fail_check: bool = false,

    fn note(o: *Ordered, c: u8) void {
        o.log[o.len] = c;
        o.len += 1;
    }

    pub fn setUp(o: *Ordered, fio: *FaultIo) !void {
        _ = fio;
        o.note('s');
        o.scratch = try testing.allocator.dupe(u8, "state");
    }

    pub fn run(o: *Ordered, io: Io) !void {
        o.note('r');
        try io.sleep(.zero, .awake);
    }

    pub fn check(o: *Ordered, io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = io;
        o.note('c');
        // The clean run passes; the one faulted run is the cancel of its sleep.
        if (injected == null) try result else try testing.expectError(error.Canceled, result);
        const scratch = o.scratch orelse return error.TornDown;
        try testing.expectEqualStrings("state", scratch);
        if (o.fail_check) return error.Judged;
    }

    pub fn tearDown(o: *Ordered) void {
        o.note('t');
        testing.allocator.free(o.scratch.?);
        o.scratch = null;
    }
};

test "check judges a run before its tearDown, on passing and failing runs" {
    var ordered: Ordered = .{};
    const report = try shakedown.everyFault(testing.allocator, testing.io, &ordered, .{ .short = false });
    // One clean run, then one run per fault of the one sleep.
    try testing.expectEqual(@as(u64, 1), report.steps);
    try testing.expectEqual(@as(u64, 2), report.runs);
    try testing.expectEqualStrings("srctsrct", ordered.log[0..ordered.len]);

    var failing: Ordered = .{ .fail_check = true };
    var failed: shakedown.EveryFaultReport = .{};
    defer failed.deinit();
    try testing.expectError(error.CheckFailed, shakedown.everyFault(testing.allocator, testing.io, &failing, .{ .diagnostics = &failed }));
    try testing.expectEqual(@as(anyerror, error.Judged), failed.failure.?.err);
    try testing.expectEqualStrings("srct", failing.log[0..failing.len]);
}

/// Writes a file with cancel protection blocked, as code does that must
/// not be interrupted halfway, then sleeps where a cancel may land: on a
/// task of its own, since a task is what has a protection to block.
pub const Protected = struct {
    dir: Io.Dir,
    /// Runs whose fault landed, and runs given none.
    faulted: u32 = 0,
    clean: u32 = 0,

    pub fn setUp(p: *Protected, fio: *FaultIo) !void {
        _ = p;
        _ = fio;
    }

    fn work(io: Io, dir: Io.Dir) !void {
        const was = io.swapCancelProtection(.blocked);
        {
            defer _ = io.swapCancelProtection(was);
            dir.writeFile(io, .{ .sub_path = "whole", .data = "written whole" }) catch |err| switch (err) {
                error.Canceled => unreachable, // unreachable: cancel protection is blocked
                else => |e| return e,
            };
        }
        try io.sleep(.zero, .awake);
    }

    pub fn run(p: *Protected, io: Io) !void {
        // Only the child's file calls and sleep belong to the compared trace.
        // Tracing the parent's await races those calls on native threads.
        var task = try testing.io.concurrent(work, .{ io, p.dir });
        try task.await(testing.io);
    }

    pub fn check(p: *Protected, io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = io;
        const fault = injected orelse {
            p.clean += 1;
            return result;
        };
        p.faulted += 1;
        // Only cancels are tried, and one that lands is the run's error.
        try testing.expect(fault.fault == .cancel);
        try testing.expectError(error.Canceled, result);
    }

    pub fn tearDown(p: *Protected) void {
        _ = p;
    }
};

test "a cancel the protection keeps out is no fault, and its run is checked as a clean one" {
    for (0..64) |_| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var protected: Protected = .{ .dir = tmp.dir };
        const report = try shakedown.everyFault(testing.allocator, testing.io, &protected, .{ .errors = &.{}, .short = false });
        // Every cancelation point in the child was tried; only its sleep's
        // landed. The clean run, and each one inside the protection, were
        // checked as clean.
        try testing.expectEqual(report.runs, protected.faulted + protected.clean);
        try testing.expect(protected.clean > 1);
        try testing.expect(protected.faulted >= 1);
    }
}

test "lost answers are tried where asked, and a save through a rename survives them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .atomic };
    const without = try shakedown.everyFault(testing.allocator, testing.io, &save, .{});
    const with = try shakedown.everyFault(testing.allocator, testing.io, &save, .{ .lost_answers = &.{error.InputOutput} });
    // The write and the sync can lose their answer with InputOutput.
    try testing.expectEqual(without.runs + 2, with.runs);
}

/// Reads a whole file positionally: every faulted run either fails or reads
/// it all, since a short positional read is followed by another.
pub const PositionalRead = struct {
    dir: Io.Dir,

    pub fn setUp(p: *PositionalRead, fio: *FaultIo) !void {
        _ = fio;
        try p.dir.writeFile(testing.io, .{ .sub_path = "whole", .data = "read to the end" });
    }

    pub fn run(p: *PositionalRead, io: Io) !void {
        const file = try p.dir.openFile(io, "whole", .{});
        defer file.close(io);
        var buffer: [32]u8 = undefined;
        const n = try file.readPositionalAll(io, &buffer, 0);
        if (!std.mem.eql(u8, buffer[0..n], "read to the end")) return error.ShortFile;
    }

    pub fn check(p: *PositionalRead, io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = p;
        _ = io;
        if (result) |_| {} else |err| {
            if (err == error.ShortFile) return err;
            if (injected == null) return err;
        }
    }

    pub fn tearDown(p: *PositionalRead) void {
        _ = p;
    }
};

test "no fault makes a positional read end before the end of the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var read: PositionalRead = .{ .dir = tmp.dir };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    _ = try shakedown.everyFault(testing.allocator, testing.io, &read, .{ .diagnostics = &report });
}

// What a call owes its caller on an error, when FaultIo answers in its place.

/// A simulation's root task ran to its end.
fn simFinished(outcome: shakedown.Sim.Outcome) !void {
    switch (outcome) {
        .finished => {},
        .failed => |err| return err,
        else => {
            std.debug.print("{t}\n", .{outcome});
            return error.TestUnexpectedResult;
        },
    }
}

test "a lookup failed in place of the call closes its queue, as the call would" {
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const server = try sim.node("server", .{ .addresses = &.{try Io.net.IpAddress.parseIp4("10.0.0.2", 80)} });
    try sim.net().dns("server.test", server);
    const Work = struct {
        fn run(base: Io) !void {
            const fio = try FaultIo.init(testing.allocator, base, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .netLookup, .n = 1 } }, .fault = .{ .fail = error.NameServerFailure } }} });
            defer fio.deinit();
            var buffer: [4]Io.net.HostName.LookupResult = undefined;
            var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buffer);
            try testing.expectError(error.NameServerFailure, Io.net.HostName.lookup(try .init("server.test"), fio.io(), &queue, .{ .port = 80 }));
            // A reader of the queue is told it ended, where it waited forever.
            try testing.expectError(error.Closed, queue.getOne(base));
        }
    };
    try simFinished(sim.run(Work.run, .{sim.io()}));
}

test "a group's await canceled in place of the call returns once every member has run" {
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const Work = struct {
        fn member(io: Io, ran: *bool) void {
            io.sleep(.fromSeconds(1), .awake) catch |err| switch (err) {
                // The group's cancel reached it: it ends here.
                error.Canceled => {},
            };
            ran.* = true;
        }

        fn run(base: Io) !void {
            const fio = try FaultIo.init(testing.allocator, base, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .groupAwait, .n = 1 } }, .fault = .cancel }} });
            defer fio.deinit();
            const io = fio.io();
            var ran = false;
            var group: Io.Group = .init;
            try group.concurrent(io, member, .{ io, &ran });
            try testing.expectError(error.Canceled, group.await(io));
            try testing.expect(ran);
        }
    };
    try simFinished(sim.run(Work.run, .{sim.io()}));
}

test "the write-file calls' reader errors are never injected in place of the call" {
    for ([_]shakedown.IoCall{ .netWriteFile, .fileWriteFileStreaming, .fileWriteFilePositional }) |call| {
        for ([_]anyerror{ error.ReadFailed, error.EndOfStream }) |err| {
            try testing.expectError(error.FaultNotInErrorSet, FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = call, .n = 1 } }, .fault = .{ .fail = err } }} }));
        }
    }
    // The call's own errors still are.
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .netWriteFile, .n = 1 } }, .fault = .{ .fail = error.ConnectionResetByPeer } }} });
    fio.deinit();
}

// The determinism check compares by step.

/// A task waits long on a sleep while the root makes three short ones, then
/// cancels it: its call returns last, after calls made after it.
pub const Waiting = struct {
    pub fn setUp(_: *Waiting, _: *FaultIo) !void {}

    fn wait(io: Io) Io.Cancelable!void {
        try io.sleep(.fromSeconds(10), .awake);
    }

    pub fn run(_: *Waiting, io: Io) !void {
        var long = try io.concurrent(wait, .{io});
        defer long.cancel(io) catch {};
        for (0..3) |_| try io.sleep(.fromMilliseconds(1), .awake);
    }

    pub fn check(_: *Waiting, _: Io, result: anyerror!void, _: ?shakedown.Injected) !void {
        result catch |err| if (err != error.Canceled) return err;
    }

    pub fn tearDown(_: *Waiting) void {}
};

test "a fault that ends a waiting call early moves its record, and is no nondeterminism" {
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const Work = struct {
        fn run(base: Io) !void {
            var waiting: Waiting = .{};
            var report = try shakedown.everyFault(testing.allocator, base, &waiting, .{ .errors = &.{}, .short = false, .alloc = false });
            defer report.deinit();
            // A fault on a short sleep fired while the long one waited: its outcome was excused.
            try testing.expect(report.excused > 0);
            try testing.expect(report.runs > 3);
        }
    };
    try simFinished(sim.run(Work.run, .{sim.io()}));
}

/// Writes as many bytes as runs came before, then syncs: a call that returns
/// before a later fault returns differently in each run.
pub const Growing = struct {
    dir: Io.Dir,
    runs: usize = 0,

    pub fn setUp(g: *Growing, _: *FaultIo) !void {
        g.runs += 1;
    }

    pub fn run(g: *Growing, io: Io) !void {
        const file = try g.dir.createFile(io, "growing", .{ .read = true });
        defer file.close(io);
        const bytes = "abcdefghijklmnopqrstuvwxyz";
        try file.writePositionalAll(io, bytes[0..@min(g.runs, bytes.len)], 0);
        try file.sync(io);
    }

    pub fn check(_: *Growing, _: Io, _: anyerror!void, _: ?shakedown.Injected) !void {}

    pub fn tearDown(_: *Growing) void {}
};

test "a call that returned before the fault fired, differently from the clean run, is still nondeterminism" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var growing: Growing = .{ .dir = tmp.dir };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    try testing.expectError(error.Nondeterministic, shakedown.everyFault(testing.allocator, testing.io, &growing, .{ .diagnostics = &report, .short = false, .alloc = false }));
    try testing.expect(report.failure.?.difference != null);
}

/// A group's member waits long on a sleep while the root makes short ones,
/// then awaits the group: a cancel in place of the await goes to the member,
/// whose sleep returns `Canceled` as the fault's own consequence.
pub const Members = struct {
    pub fn setUp(_: *Members, _: *FaultIo) !void {}

    fn member(io: Io) void {
        io.sleep(.fromSeconds(10), .awake) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    pub fn run(_: *Members, io: Io) !void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, member, .{io});
        for (0..2) |_| try io.sleep(.fromMilliseconds(1), .awake);
        try group.await(io);
    }

    pub fn check(_: *Members, _: Io, result: anyerror!void, _: ?shakedown.Injected) !void {
        result catch |err| if (err != error.Canceled) return err;
    }

    pub fn tearDown(_: *Members) void {}
};

test "a group's await canceled in place of the call: what its members return for the cancel follows the fault, and is no nondeterminism" {
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const Work = struct {
        fn run(base: Io) !void {
            var members: Members = .{};
            var report: shakedown.EveryFaultReport = .{};
            defer report.deinit();
            var done = shakedown.everyFault(testing.allocator, base, &members, .{ .errors = &.{}, .short = false, .alloc = false, .diagnostics = &report }) catch |err| {
                if (report.failure) |f| std.debug.print("{t} at {any}, first difference {any}\n{s}\n", .{ f.err, f.injected, f.difference, f.trace });
                return err;
            };
            defer done.deinit();
            // The member's sleep, still waiting when the await's cancel fired, was excused.
            try testing.expect(done.excused > 0);
        }
    };
    try simFinished(sim.run(Work.run, .{sim.io()}));
}
