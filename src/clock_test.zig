//! `Clock` from outside, with real tasks waiting on it.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Clock = @import("shakedown.zig").Clock;
const build_options = @import("build_options");

/// Long enough that a barrier never fails on a loaded machine; a passing
/// test waits only as long as the task it waits for.
const patience: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } };

fn sleepFor(io: Io, d: Io.Duration, clock: Io.Clock) Io.Cancelable!void {
    return io.sleep(d, clock);
}

test "a sleep ends when the clock reaches it, and not before" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    const start = Io.Timestamp.now(io, .awake);
    var task = try io.concurrent(sleepFor, .{ io, .fromSeconds(3600), .awake });
    defer _ = task.cancel(io) catch {};
    try clock.awaitArmed(1, patience);
    try testing.expectEqual(@as(?Io.Clock.Timestamp, .{ .raw = start.addDuration(.fromSeconds(3600)), .clock = .awake }), clock.nextDeadline());
    clock.advance(.fromSeconds(3599));
    try testing.expectEqual(@as(usize, 1), clock.armed());
    try testing.expectEqual(@as(?Io.Duration, .fromSeconds(1)), clock.advanceToNext());
    try task.await(io);
    try testing.expectEqual(@as(usize, 0), clock.armed());
    try testing.expectEqual(@as(i96, 3600 * std.time.ns_per_s), start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
}

test "a canceled sleep returns Canceled and disarms its timer" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    var task = try io.concurrent(sleepFor, .{ io, .fromSeconds(60), .awake });
    try clock.awaitArmed(1, patience);
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expectEqual(@as(usize, 0), clock.armed());
    try testing.expectEqual(@as(?Io.Duration, null), clock.advanceToNext());
}

test "a sleep already due returns at once and arms nothing" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    try io.sleep(.zero, .awake);
    try io.sleep(.fromSeconds(-1), .boot);
    try Io.Clock.Timestamp.wait(.{ .raw = .fromNanoseconds(0), .clock = .real }, io);
    try testing.expectEqual(@as(usize, 0), clock.armed());
}

fn waitEvent(io: Io, event: *Io.Event, timeout: Io.Timeout) Io.Event.WaitTimeoutError!void {
    return event.waitTimeout(io, timeout);
}

test "a timed wait times out when the clock reaches its deadline" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    var event: Io.Event = .unset;
    var task = try io.concurrent(waitEvent, .{ io, &event, .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } } });
    try clock.awaitArmed(1, patience);
    clock.advance(.fromMilliseconds(249));
    try testing.expectEqual(@as(usize, 1), clock.armed());
    clock.advance(.fromMilliseconds(1));
    try testing.expectError(error.Timeout, task.await(io));
}

test "a timed wait woken before its deadline returns at once, and its timer goes" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    var event: Io.Event = .unset;
    var task = try io.concurrent(waitEvent, .{ io, &event, .{ .duration = .{ .raw = .fromSeconds(3600), .clock = .awake } } });
    try clock.awaitArmed(1, patience);
    event.set(io);
    try task.await(io);
    try testing.expectEqual(@as(usize, 0), clock.armed());
}

test "suspend moves boot and real time but not awake time" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    const awake = Io.Timestamp.now(io, .awake);
    const boot = Io.Timestamp.now(io, .boot);
    const real = Io.Timestamp.now(io, .real);
    var on_awake = try io.concurrent(sleepFor, .{ io, .fromSeconds(60), .awake });
    defer _ = on_awake.cancel(io) catch {};
    var on_boot = try io.concurrent(sleepFor, .{ io, .fromSeconds(60), .boot });
    try clock.awaitArmed(2, patience);
    clock.suspendFor(.fromSeconds(3600));
    try on_boot.await(io);
    try testing.expectEqual(awake, Io.Timestamp.now(io, .awake));
    try testing.expectEqual(@as(i96, 3600 * std.time.ns_per_s), boot.durationTo(Io.Timestamp.now(io, .boot)).nanoseconds);
    try testing.expectEqual(@as(i96, 3600 * std.time.ns_per_s), real.durationTo(Io.Timestamp.now(io, .real)).nanoseconds);
    try testing.expectEqual(@as(usize, 1), clock.armed());
    clock.advance(.fromSeconds(60));
    try on_awake.await(io);
}

test "a backward step of real time moves only real time and delays real-time timers" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    const awake = Io.Timestamp.now(io, .awake);
    const real = Io.Timestamp.now(io, .real);
    const deadline: Io.Clock.Timestamp = .{ .raw = real.addDuration(.fromSeconds(10)), .clock = .real };
    var task = try io.concurrent(Io.Clock.Timestamp.wait, .{ deadline, io });
    defer _ = task.cancel(io) catch {};
    try clock.awaitArmed(1, patience);
    clock.stepReal(real.subDuration(.fromSeconds(50)));
    try testing.expectEqual(awake, Io.Timestamp.now(io, .awake));
    try testing.expectEqual(real.subDuration(.fromSeconds(50)), Io.Timestamp.now(io, .real));
    clock.advance(.fromSeconds(59));
    try testing.expectEqual(@as(usize, 1), clock.armed());
    clock.stepReal(real.addDuration(.fromSeconds(10)));
    try task.await(io);
    try testing.expectEqual(awake.addDuration(.fromSeconds(59)), Io.Timestamp.now(io, .awake));
}

test "CPU clocks are frozen, or the base's" {
    var frozen: Clock = .init(testing.io, .{});
    const a = Io.Timestamp.now(frozen.io(), .cpu_process);
    frozen.advance(.fromSeconds(1));
    try testing.expectEqual(a, Io.Timestamp.now(frozen.io(), .cpu_thread));
    try testing.expectEqual(@as(i96, 1), (try Io.Clock.resolution(.cpu_process, frozen.io())).nanoseconds);
    // A deadline a frozen clock has already reached is due at once.
    try frozen.io().sleep(.zero, .cpu_process);

    var based: Clock = .init(testing.io, .{ .cpu = .base });
    // The base's CPU clock moves while this thread spins on it.
    const start = Io.Timestamp.now(based.io(), .cpu_process);
    var moved = false;
    for (0..100_000_000) |_| {
        if (start.durationTo(Io.Timestamp.now(based.io(), .cpu_process)).nanoseconds != 0) {
            moved = true;
            break;
        }
    }
    try testing.expect(moved);
}

test "awaitArmed gives up after its timeout, a duration or a deadline on the base" {
    var clock: Clock = .init(testing.io, .{});
    try testing.expectError(error.Timeout, clock.awaitArmed(1, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }));

    // One deadline shared by several waits, on the base and not on the
    // clock: moving the clock past it does not end the wait early.
    const deadline: Io.Timeout = .{ .deadline = .fromNow(testing.io, .{ .raw = .fromMilliseconds(20), .clock = .awake }) };
    clock.advance(.fromSeconds(3600));
    try testing.expectError(error.Timeout, clock.awaitArmed(1, deadline));
    try testing.expectError(error.Timeout, clock.awaitArmed(1, deadline));
    try testing.expect(deadline.deadline.compare(.lte, .now(testing.io, .awake)));
}

/// The shape of a test that steps a task through its waits one by one: the
/// task sleeps a second at a time, and the test lets one second pass at a
/// time once the task is waiting.
fn ticker(io: Io, ticks: *std.atomic.Value(u32), n: u32) Io.Cancelable!void {
    for (0..n) |_| {
        try io.sleep(.fromSeconds(1), .awake);
        _ = ticks.fetchAdd(1, .release);
    }
}

test "a barrier and an advance step a task through its sleeps one by one" {
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    var ticks: std.atomic.Value(u32) = .init(0);
    var task = try io.concurrent(ticker, .{ io, &ticks, 5 });
    for (0..5) |i| {
        try clock.awaitArmed(1, patience);
        try testing.expectEqual(@as(u32, @intCast(i)), ticks.load(.acquire));
        clock.advance(.fromSeconds(1));
        // The task may not have counted yet; it has once it sleeps again or ends.
    }
    try task.await(io);
    try testing.expectEqual(@as(u32, 5), ticks.load(.acquire));
}

fn readWithin(io: Io, file: Io.File, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!usize {
    var buffer: [16]u8 = undefined;
    var data = [_][]u8{&buffer};
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    _ = batch.add(.{ .file_read_streaming = .{ .file = file, .data = &data } });
    batch.awaitConcurrent(io, timeout) catch |err| {
        batch.cancel(io);
        return err;
    };
    const done = batch.next().?;
    return done.result.file_read_streaming catch 0;
}

test "a batch wait with a deadline times out on the clock, and completes when its read does" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest; // a pipe read is not a pollable batch operation there
    var clock: Clock = .init(testing.io, .{});
    const io = clock.io();
    const fds = try Io.Threaded.pipe2(.{});
    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(testing.io);
    defer write_end.close(testing.io);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(30), .clock = .awake } };

    var silent = try io.concurrent(readWithin, .{ io, read_end, timeout });
    try clock.awaitArmed(1, patience);
    clock.advance(.fromMilliseconds(30));
    try testing.expectError(error.Timeout, silent.await(io));

    var answered = try io.concurrent(readWithin, .{ io, read_end, timeout });
    try clock.awaitArmed(1, patience);
    try write_end.writeStreamingAll(testing.io, "ping");
    try testing.expectEqual(@as(usize, 4), try answered.await(io));
    try testing.expectEqual(@as(usize, 0), clock.armed());
}

/// A tick of five milliseconds until fifty have passed on the clock, as an
/// interval loop measures them.
fn tickFor(io: Io, sleeps: *u32) Io.Cancelable!void {
    const start = Io.Timestamp.now(io, .awake);
    while (start.durationTo(.now(io, .awake)).nanoseconds < 50 * std.time.ns_per_ms) {
        try io.sleep(.fromMilliseconds(5), .awake);
        sleeps.* += 1;
    }
}

test "auto: each sleep returns at once, its deadline reached and as late as asked" {
    var on_time: Clock = .init(testing.io, .{ .advance = .{ .auto = .{} } });
    const start = on_time.read(.awake);
    var sleeps: u32 = 0;
    try tickFor(on_time.io(), &sleeps);
    try testing.expectEqual(@as(u32, 10), sleeps);
    try testing.expectEqual(Io.Duration.fromMilliseconds(50), start.durationTo(on_time.read(.awake)));

    // Each five-millisecond tick resumes twenty-five late: two ticks pass
    // the fifty.
    var late: Clock = .init(testing.io, .{ .advance = .{ .auto = .{ .late = .fromMilliseconds(25) } } });
    sleeps = 0;
    const late_start = late.read(.awake);
    try tickFor(late.io(), &sleeps);
    try testing.expectEqual(@as(u32, 2), sleeps);
    try testing.expectEqual(Io.Duration.fromMilliseconds(60), late_start.durationTo(late.read(.awake)));
    try testing.expectEqual(@as(usize, 0), late.armed());
}

test "auto: a timed futex wait and a batch wait time out at once, on the clock" {
    var clock: Clock = .init(testing.io, .{ .advance = .{ .auto = .{} } });
    const io = clock.io();
    const start = clock.read(.awake);
    var event: Io.Event = .unset;
    try testing.expectError(error.Timeout, event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } }));
    try testing.expectEqual(Io.Duration.fromSeconds(30), start.durationTo(clock.read(.awake)));
    if (builtin.target.os.tag == .windows) return; // a pipe read is not a pollable batch operation there
    const fds = try Io.Threaded.pipe2(.{});
    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(testing.io);
    defer write_end.close(testing.io);
    // An hour on the clock, and no real time: the wait looks once.
    const real_start = Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.Timeout, readWithin(io, read_end, .{ .duration = .{ .raw = .fromSeconds(3600), .clock = .awake } }));
    try testing.expect(real_start.durationTo(.now(testing.io, .awake)).nanoseconds < std.time.ns_per_s);
    try testing.expectEqual(Io.Duration.fromSeconds(3630), start.durationTo(clock.read(.awake)));
}

test "no timed wait hangs or times out early while the clock moves from another thread" {
    var clock: Clock = .init(testing.io, .{});
    const threads = build_options.stress_threads;
    var stop: std.atomic.Value(bool) = .init(false);
    var finished: std.atomic.Value(u32) = .init(0);
    var early: std.atomic.Value(u32) = .init(0);
    var waits: std.atomic.Value(u64) = .init(0);
    const handles = try testing.allocator.alloc(std.Thread, threads);
    defer testing.allocator.free(handles);
    for (handles, 0..) |*h, i| h.* = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, waiter, .{
        &clock, i, &stop, &finished, &early, &waits,
    });
    for (0..build_options.stress_rounds) |round| {
        clock.advance(.fromMilliseconds(1));
        if (round % 64 == 0) std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    stop.store(true, .release);
    // Every waiter is now at most a few milliseconds of clock time from its
    // deadline; keep the clock moving until all are out.
    const limit = patience.toTimestamp(testing.io).?;
    while (finished.load(.acquire) < threads) {
        clock.advance(.fromMilliseconds(1));
        std.Thread.yield() catch std.atomic.spinLoopHint();
        if (limit.compare(.lte, .now(testing.io, .awake))) return error.WaiterHung;
    }
    for (handles) |h| h.join();
    try testing.expectEqual(@as(u32, 0), early.load(.acquire));
    try testing.expect(waits.load(.acquire) >= threads);
}

fn waiter(
    clock: *Clock,
    index: usize,
    stop: *std.atomic.Value(bool),
    finished: *std.atomic.Value(u32),
    early: *std.atomic.Value(u32),
    waits: *std.atomic.Value(u64),
) void {
    defer _ = finished.fetchAdd(1, .release);
    const io = clock.io();
    var n: u64 = 0;
    while (!stop.load(.acquire)) : (n += 1) {
        var event: Io.Event = .unset;
        const span: i64 = @intCast(1 + (index + n) % 4);
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(span), .clock = .awake });
        if (event.waitTimeout(io, .{ .deadline = deadline })) |_| {
            // Nobody sets the event: a return without Timeout is wrong too.
            _ = early.fetchAdd(1, .release);
        } else |err| switch (err) {
            error.Timeout => if (Io.Clock.Timestamp.now(io, .awake).compare(.lt, deadline)) {
                _ = early.fetchAdd(1, .release);
            },
            error.Canceled => unreachable, // unreachable: nothing cancels a plain thread
        }
        _ = waits.fetchAdd(1, .monotonic);
    }
}
