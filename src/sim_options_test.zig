//! What a simulation does with the values it is given: schedules that make
//! no sense are refused when it is made, contexts a task frame cannot hold
//! are an `async` that runs at once, and a trace that keeps nothing keeps
//! nothing.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Sim = shakedown.Sim;

test "a PCT schedule needs a depth of 1 to 16 and a length of at least 1" {
    for ([_]Sim.Schedule{
        .{ .pct = .{ .depth = 0 } },
        .{ .pct = .{ .depth = 17 } },
        .{ .pct = .{ .depth = 255 } },
        .{ .pct = .{ .length = 0 } },
    }) |schedule| {
        try testing.expectError(error.InvalidSchedule, Sim.init(testing.allocator, .{ .schedule = schedule }));
    }
    for ([_]u8{ 1, 3, 16 }) |depth| {
        const sim = try Sim.init(testing.allocator, .{ .schedule = .{ .pct = .{ .depth = depth, .length = 1 } } });
        sim.deinit();
    }
}

/// A context the frame of a task cannot align: more than the 64 bytes it
/// guarantees.
const Wide = struct { value: u32 align(128) = 7 };

fn readWide(wide: Wide) u32 {
    return wide.value;
}

fn asyncWide(io: Io, out: *u32) !void {
    var future = io.async(readWide, .{Wide{}});
    out.* = future.await(io);
}

fn concurrentWide(io: Io, out: *?anyerror) !void {
    var future = io.concurrent(readWide, .{Wide{}}) catch |err| {
        out.* = err;
        return;
    };
    _ = future.await(io);
}

test "a context wider than a task frame runs at once under async, and is unavailable to concurrent" {
    const at_once = try Sim.init(testing.allocator, .{});
    defer at_once.deinit();
    var value: u32 = 0;
    try testing.expectEqual(Sim.Outcome.finished, at_once.run(asyncWide, .{ at_once.io(), &value }));
    try testing.expectEqual(@as(u32, 7), value);
    const unavailable = try Sim.init(testing.allocator, .{});
    defer unavailable.deinit();
    var refused: ?anyerror = null;
    try testing.expectEqual(Sim.Outcome.finished, unavailable.run(concurrentWide, .{ unavailable.io(), &refused }));
    try testing.expectEqual(@as(?anyerror, error.ConcurrencyUnavailable), refused);
}

fn calls(io: Io, times: u64) void {
    for (0..times) |_| _ = Io.Timestamp.now(io, .awake);
}

/// The calls a run of `times` clock reads makes, with no limit in the way.
fn stepsOf(times: u64) !u64 {
    const sim = try Sim.init(testing.allocator, .{});
    defer sim.deinit();
    try testing.expectEqual(Sim.Outcome.finished, sim.run(calls, .{ sim.io(), times }));
    return sim.steps();
}

test "a run ends as step_limit exactly when it would make more calls than max_steps" {
    const total = try stepsOf(10);
    try testing.expect(total >= 10);
    // One call fewer than the run makes ends it; as many as it makes does not.
    for ([_]u64{ 0, 1, total - 1 }) |limit| {
        const sim = try Sim.init(testing.allocator, .{ .max_steps = limit });
        defer sim.deinit();
        try testing.expectEqual(Sim.Outcome.step_limit, sim.run(calls, .{ sim.io(), 10 }));
    }
    for ([_]u64{ total, total + 1, 1_000_000 }) |limit| {
        const sim = try Sim.init(testing.allocator, .{ .max_steps = limit });
        defer sim.deinit();
        try testing.expectEqual(Sim.Outcome.finished, sim.run(calls, .{ sim.io(), 10 }));
    }
}

fn sleeps(io: Io, nanoseconds: i96) !void {
    try io.sleep(.fromNanoseconds(nanoseconds), .awake);
}

test "a run ends as time_limit when time would pass max_time, and not before" {
    for ([_]struct { sleep: i96, finished: bool }{
        .{ .sleep = 999, .finished = true },
        .{ .sleep = 1000, .finished = true },
        .{ .sleep = 1001, .finished = false },
        .{ .sleep = std.math.maxInt(i96), .finished = false },
    }) |case| {
        const sim = try Sim.init(testing.allocator, .{ .max_time = .fromNanoseconds(1000) });
        defer sim.deinit();
        const expected: Sim.Outcome = if (case.finished) .finished else .time_limit;
        try testing.expectEqual(expected, sim.run(sleeps, .{ sim.io(), case.sleep }));
    }
}

test "a trace that keeps no records keeps none, and still hashes every one" {
    const Trace = shakedown.Trace(struct { value: u32 });
    var off: Trace = .init(testing.allocator, .off);
    defer off.deinit();
    for ([_]Trace.Mode{ .{ .window = 0 }, .{ .last = 0 } }) |mode| {
        var none: Trace = .init(testing.allocator, mode);
        defer none.deinit();
        var all: Trace = .init(testing.allocator, .all);
        defer all.deinit();
        for (0..10) |i| {
            const record: Trace.Record = .{ .step = i, .event = .{ .value = @intCast(i) } };
            try none.append(record);
            try all.append(record);
        }
        try testing.expectEqual(@as(usize, 0), none.records().len);
        try testing.expectEqual(@as(u64, 10), none.len());
        try testing.expectEqual(all.hash(), none.hash());
    }
}
