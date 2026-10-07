//! `everyFault` from outside: a save that survives every single fault passes,
//! and a save that does not, a leak on an error path and a run that
//! depends on randomness are each caught.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const FaultIo = shakedown.FaultIo;

/// Saves "new" over "old" in `dir/save`, one of four ways.
const Save = struct {
    dir: Io.Dir,
    how: How,
    counting: shakedown.alloc.Counting = undefined,
    gpa: std.mem.Allocator = undefined,
    fio: *FaultIo = undefined,
    /// The last buffer a run allocated, for the test to free what leaked.
    kept: ?[]u8 = null,

    const How = enum {
        /// Temp file, sync, rename: the old save survives any fault.
        atomic,
        /// Truncates the save, then writes it: a fault loses the old one.
        in_place,
        /// As atomic, but leaks its buffer when the write fails.
        leaky,
        /// As atomic, with a temp name drawn from `io.random`.
        random_name,
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
    }

    pub fn run(s: *Save, io: Io) !void {
        const contents = try s.gpa.dupe(u8, "new");
        s.kept = contents;
        switch (s.how) {
            .atomic, .random_name => {
                defer s.gpa.free(contents);
                var name_buffer: [32]u8 = undefined;
                const name = if (s.how == .random_name) name: {
                    var bytes: [4]u8 = undefined;
                    io.random(&bytes);
                    break :name try std.mem.print(&name_buffer, "save.{x}", .{bytes});
                } else "save.tmp";
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

test "a run that depends on io.random is refused as nondeterministic" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .how = .random_name };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    try testing.expectError(error.Nondeterministic, shakedown.everyFault(testing.allocator, testing.io, &save, .{ .diagnostics = &report }));
    try testing.expect(report.failure.?.difference != null);
}

const Raw = enum { barrier };

/// A seam that makes one raw call between two `Io` calls.
const Seam = struct {
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
const Ordered = struct {
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
