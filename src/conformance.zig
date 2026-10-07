//! `conformance`: std's `Io` guarantees as checks, run against any `Io`.
//!
//! Each check uses only the `Io` interface, so the same checks pass on
//! std's threaded `Io`, through a `Layer` or a `FaultIo` with nothing
//! planned, and on a `Sim`, inside the task `Sim.run` starts. They cover
//! time and sleep, futexes, mutexes, conditions, events, queues,
//! semaphores and read-write locks, `async`, `concurrent`, `await` and
//! `cancel`, cancel protection and `recancel`, groups and select, and
//! randomness. An implementation without some calls skips the checks that
//! need them.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const IoCall = @import("io_call.zig").IoCall;

pub const Options = struct {
    /// Checks that need any of these calls are skipped.
    skip: []const IoCall = &.{},
    /// Filled when a check fails, if given.
    failure: ?*Failure = null,
};

/// The check that failed, and what it returned.
pub const Failure = struct { check: []const u8, err: anyerror };

pub const RunError = error{Nonconforming};

/// One guarantee: its name, the calls it needs, and the check.
pub const Check = struct {
    name: []const u8,
    needs: []const IoCall,
    run: *const fn (gpa: Allocator, io: Io) anyerror!void,
};

/// Runs every check `options.skip` leaves, in order, and stops at the
/// first that fails.
pub fn run(gpa: Allocator, io: Io, options: Options) RunError!void {
    for (checks) |c| {
        if (skipped(c, options.skip)) continue;
        c.run(gpa, io) catch |err| {
            if (options.failure) |f| f.* = .{ .check = c.name, .err = err };
            return error.Nonconforming;
        };
    }
}

fn skipped(c: Check, skip: []const IoCall) bool {
    for (c.needs) |need| for (skip) |s| if (need == s) return true;
    return false;
}

pub const checks = [_]Check{
    .{ .name = "time moves forward, by at least a sleep", .needs = &.{ .now, .sleep }, .run = timeMoves },
    .{ .name = "a futex wait returns when the word is not what was expected", .needs = &.{.futexWait}, .run = futexMismatch },
    .{ .name = "a futex wait ends at its timeout", .needs = &.{ .futexWait, .now }, .run = futexTimeout },
    .{ .name = "a mutex excludes", .needs = &.{ .concurrent, .groupConcurrent, .groupAwait, .futexWait, .sleep }, .run = mutexExcludes },
    .{ .name = "a condition hands every item to a waiting consumer", .needs = &.{ .concurrent, .await, .futexWait }, .run = conditionHandsOff },
    .{ .name = "a condition wait times out", .needs = &.{ .futexWait, .now }, .run = conditionTimesOut },
    .{ .name = "an event wakes its waiters, and its timed wait times out", .needs = &.{ .concurrent, .await, .futexWait, .now }, .run = eventWakes },
    .{ .name = "a queue delivers in order and closes", .needs = &.{ .concurrent, .await, .futexWait }, .run = queueInOrder },
    .{ .name = "a semaphore counts", .needs = &.{ .concurrent, .await, .futexWait }, .run = semaphoreCounts },
    .{ .name = "a read-write lock shares reads and excludes writes", .needs = &.{ .groupConcurrent, .groupAwait, .futexWait, .sleep }, .run = rwLockExcludes },
    .{ .name = "async returns its function's result", .needs = &.{ .async, .await }, .run = asyncResult },
    .{ .name = "concurrent runs beside its caller", .needs = &.{ .concurrent, .await, .futexWait }, .run = concurrentRuns },
    .{ .name = "cancel lands at a sleep", .needs = &.{ .concurrent, .cancel, .sleep }, .run = cancelSleep },
    .{ .name = "cancel of a finished task returns its result", .needs = &.{ .concurrent, .cancel, .await, .futexWait }, .run = cancelFinished },
    .{ .name = "cancel protection holds a cancel back until lifted", .needs = &.{ .concurrent, .cancel, .await, .swapCancelProtection, .checkCancel, .futexWait, .sleep }, .run = cancelProtected },
    .{ .name = "recancel delivers a cancel again", .needs = &.{ .concurrent, .cancel, .recancel, .checkCancel, .futexWait }, .run = recancelAgain },
    .{ .name = "a group's await waits for every member", .needs = &.{ .groupAsync, .groupConcurrent, .groupAwait, .sleep }, .run = groupAwaits },
    .{ .name = "a group's cancel cancels every member", .needs = &.{ .groupConcurrent, .groupCancel, .sleep }, .run = groupCancels },
    .{ .name = "select returns the first to finish", .needs = &.{ .groupConcurrent, .groupCancel, .futexWait, .sleep }, .run = selectFirst },
    .{ .name = "random fills its buffer", .needs = &.{ .random, .randomSecure }, .run = randomFills },
};

fn ms(n: i64) Io.Duration {
    return .fromMilliseconds(n);
}

// Time and futexes.

fn timeMoves(_: Allocator, io: Io) !void {
    const awake = Io.Timestamp.now(io, .awake);
    const boot = Io.Timestamp.now(io, .boot);
    try io.sleep(ms(2), .awake);
    const slept = awake.durationTo(.now(io, .awake));
    if (slept.nanoseconds < ms(2).nanoseconds) return error.SleptShort;
    if (boot.durationTo(.now(io, .boot)).nanoseconds < 0) return error.BootWentBack;
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = ms(1), .clock = .awake });
    try deadline.wait(io);
    if (deadline.compare(.gt, .now(io, .awake))) return error.WokeBeforeDeadline;
}

fn futexMismatch(_: Allocator, io: Io) !void {
    var word: u32 = 1;
    try io.futexWait(u32, &word, 0);
    io.futexWake(u32, &word, 1);
}

fn futexTimeout(_: Allocator, io: Io) !void {
    var word: u32 = 0;
    const start = Io.Timestamp.now(io, .awake);
    // Spurious wakes are allowed: wait until the timeout has passed.
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = ms(2), .clock = .awake });
    while (deadline.compare(.gt, .now(io, .awake))) {
        try io.futexWaitTimeout(u32, &word, 0, .{ .deadline = deadline });
    }
    if (start.durationTo(.now(io, .awake)).nanoseconds < ms(2).nanoseconds) return error.TimedOutEarly;
}

// Locks.

const Counter = struct {
    mutex: Io.Mutex = .init,
    count: u32 = 0,

    fn add(c: *Counter, io: Io, times: u32) Io.Cancelable!void {
        for (0..times) |_| {
            try c.mutex.lock(io);
            defer c.mutex.unlock(io);
            const seen = c.count;
            try io.sleep(.fromNanoseconds(1), .awake);
            c.count = seen + 1;
        }
    }
};

fn mutexExcludes(_: Allocator, io: Io) !void {
    var c: Counter = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..4) |_| try group.concurrent(io, Counter.add, .{ &c, io, 25 });
    try group.await(io);
    if (c.count != 100) return error.LostUpdate;
}

const Box = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    items: u32 = 0,
    taken: u32 = 0,
    total: u32 = 20,

    fn consume(b: *Box, io: Io) Io.Cancelable!u32 {
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        while (b.taken < b.total) {
            while (b.items == 0) try b.cond.wait(io, &b.mutex);
            b.items -= 1;
            b.taken += 1;
        }
        return b.taken;
    }
};

fn conditionHandsOff(_: Allocator, io: Io) !void {
    var b: Box = .{};
    var consumer = try io.concurrent(Box.consume, .{ &b, io });
    defer _ = consumer.cancel(io) catch {};
    for (0..b.total) |_| {
        try b.mutex.lock(io);
        b.items += 1;
        b.mutex.unlock(io);
        b.cond.signal(io);
    }
    if (try consumer.await(io) != b.total) return error.ItemsLost;
}

fn conditionTimesOut(_: Allocator, io: Io) !void {
    var mutex: Io.Mutex = .init;
    var cond: Io.Condition = .init;
    try mutex.lock(io);
    defer mutex.unlock(io);
    const result = cond.waitTimeout(io, &mutex, .{ .duration = .{ .raw = ms(2), .clock = .awake } });
    if (result != error.Timeout) return error.NoTimeout;
}

fn eventWakes(_: Allocator, io: Io) !void {
    var ready: Io.Event = .unset;
    ready.set(io);
    try ready.wait(io);
    var gate: Io.Event = .unset;
    var waiter = try io.concurrent(Io.Event.wait, .{ &gate, io });
    defer _ = waiter.cancel(io) catch {};
    gate.set(io);
    try waiter.await(io);
    var never: Io.Event = .unset;
    if (never.waitTimeout(io, .{ .duration = .{ .raw = ms(2), .clock = .awake } }) != error.Timeout) return error.NoTimeout;
}

fn produce(io: Io, q: *Io.Queue(u32), n: u32) (Io.QueueClosedError || Io.Cancelable)!void {
    for (0..n) |i| try q.putOne(io, @intCast(i));
    q.close(io);
}

fn queueInOrder(_: Allocator, io: Io) !void {
    var buffer: [4]u32 = undefined;
    var q: Io.Queue(u32) = .init(&buffer);
    var producer = try io.concurrent(produce, .{ io, &q, 50 });
    defer producer.cancel(io) catch {};
    for (0..50) |i| if (try q.getOne(io) != i) return error.OutOfOrder;
    if (q.getOne(io)) |_| return error.NotClosed else |err| if (err != error.Closed) return err;
    try producer.await(io);
}

fn postEach(io: Io, s: *Io.Semaphore, n: u32) void {
    for (0..n) |_| s.post(io);
}

fn semaphoreCounts(_: Allocator, io: Io) !void {
    var s: Io.Semaphore = .{};
    var poster = try io.concurrent(postEach, .{ io, &s, 10 });
    defer poster.cancel(io);
    for (0..10) |_| try s.wait(io);
    poster.await(io);
    if (s.waitTimeout(io, .{ .duration = .{ .raw = ms(1), .clock = .awake } }) != error.Timeout) return error.CountedTooMany;
}

/// Readers hold the lock together, so what they count is atomic: on a
/// threaded `Io` they run at once.
const Shared = struct {
    lock: Io.RwLock = .init,
    readers: std.atomic.Value(u32) = .init(0),
    writing: std.atomic.Value(bool) = .init(false),
    broken: std.atomic.Value(bool) = .init(false),

    fn read(s: *Shared, io: Io) Io.Cancelable!void {
        for (0..10) |_| {
            try s.lock.lockShared(io);
            defer s.lock.unlockShared(io);
            _ = s.readers.fetchAdd(1, .acq_rel);
            if (s.writing.load(.acquire)) s.broken.store(true, .release);
            try io.sleep(.fromNanoseconds(1), .awake);
            _ = s.readers.fetchSub(1, .acq_rel);
        }
    }

    fn write(s: *Shared, io: Io) Io.Cancelable!void {
        for (0..10) |_| {
            try s.lock.lock(io);
            defer s.lock.unlock(io);
            if (s.readers.load(.acquire) != 0 or s.writing.load(.acquire)) s.broken.store(true, .release);
            s.writing.store(true, .release);
            try io.sleep(.fromNanoseconds(1), .awake);
            s.writing.store(false, .release);
        }
    }
};

fn rwLockExcludes(_: Allocator, io: Io) !void {
    var s: Shared = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..3) |_| try group.concurrent(io, Shared.read, .{ &s, io });
    for (0..2) |_| try group.concurrent(io, Shared.write, .{ &s, io });
    try group.await(io);
    if (s.broken.load(.acquire)) return error.NotExcluded;
}

// Tasks.

fn square(x: u64) u64 {
    return x * x;
}

fn asyncResult(_: Allocator, io: Io) !void {
    var a = io.async(square, .{7});
    var b = io.async(square, .{9});
    if (a.await(io) != 49 or b.await(io) != 81) return error.WrongResult;
}

const PingPong = struct {
    ping: Io.Event = .unset,
    pong: Io.Event = .unset,

    fn answer(p: *PingPong, io: Io) Io.Cancelable!void {
        try p.ping.wait(io);
        p.pong.set(io);
    }
};

fn concurrentRuns(_: Allocator, io: Io) !void {
    var p: PingPong = .{};
    var task = try io.concurrent(PingPong.answer, .{ &p, io });
    defer task.cancel(io) catch {};
    p.ping.set(io);
    try p.pong.wait(io);
    try task.await(io);
}

fn sleepHour(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .awake);
}

fn cancelSleep(_: Allocator, io: Io) !void {
    var task = try io.concurrent(sleepHour, .{io});
    if (task.cancel(io)) |_| return error.NotCanceled else |err| if (err != error.Canceled) return err;
}

fn finishAt(io: Io, gate: *Io.Event) Io.Cancelable!u32 {
    gate.set(io);
    return 5;
}

fn cancelFinished(_: Allocator, io: Io) !void {
    var done: Io.Event = .unset;
    var task = try io.concurrent(finishAt, .{ io, &done });
    try done.wait(io);
    if (try task.cancel(io) != 5) return error.WrongResult;
}

const Protected = struct {
    started: Io.Event = .unset,
    release: Io.Event = .unset,
    waited: bool = false,

    fn run(p: *Protected, io: Io) Io.Cancelable!void {
        const old = io.swapCancelProtection(.blocked);
        p.started.set(io);
        p.release.waitUncancelable(io);
        // Still protected: a cancel point lets nothing through.
        io.checkCancel() catch unreachable; // unreachable: cancel protection is blocked here
        p.waited = true;
        _ = io.swapCancelProtection(old);
        try io.checkCancel();
    }

    fn lift(p: *Protected, io: Io) Io.Cancelable!void {
        try p.started.wait(io);
        try io.sleep(ms(1), .awake);
        p.release.set(io);
    }
};

fn cancelProtected(_: Allocator, io: Io) !void {
    var p: Protected = .{};
    var task = try io.concurrent(Protected.run, .{ &p, io });
    var lifter = try io.concurrent(Protected.lift, .{ &p, io });
    defer lifter.cancel(io) catch {};
    try p.started.wait(io);
    if (task.cancel(io)) |_| return error.NotCanceled else |err| if (err != error.Canceled) return err;
    if (!p.waited) return error.CancelLeaked;
    try lifter.await(io);
}

fn twice(io: Io, started: *Io.Event) error{ Canceled, Missed }!void {
    started.set(io);
    // Wait for the cancel, which this sleep receives.
    if (io.sleep(.fromSeconds(3600), .awake)) |_| return error.Missed else |_| {}
    io.recancel();
    if (io.checkCancel()) |_| return error.Missed else |err| return err;
}

fn recancelAgain(_: Allocator, io: Io) !void {
    var started: Io.Event = .unset;
    var task = try io.concurrent(twice, .{ io, &started });
    try started.wait(io);
    if (task.cancel(io)) |_| return error.NotCanceled else |err| if (err != error.Canceled) return err;
}

fn mark(io: Io, flag: *bool) Io.Cancelable!void {
    try io.sleep(ms(1), .awake);
    flag.* = true;
}

fn groupAwaits(_: Allocator, io: Io) !void {
    var flags: [6]bool = @splat(false);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (flags[0..3]) |*f| group.async(io, mark, .{ io, f });
    for (flags[3..]) |*f| try group.concurrent(io, mark, .{ io, f });
    try group.await(io);
    for (flags) |f| if (!f) return error.MemberNotRun;
}

fn sleepCounted(io: Io, canceled: *std.atomic.Value(u32)) Io.Cancelable!void {
    io.sleep(.fromSeconds(3600), .awake) catch |err| {
        _ = canceled.fetchAdd(1, .acq_rel);
        return err;
    };
}

fn groupCancels(_: Allocator, io: Io) !void {
    var canceled: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..4) |_| try group.concurrent(io, sleepCounted, .{ io, &canceled });
    group.cancel(io);
    if (canceled.load(.acquire) != 4) return error.MemberNotCanceled;
}

const Raced = union(enum) { quick: Io.Cancelable!void, slow: Io.Cancelable!void };

fn after(io: Io, d: Io.Duration) Io.Cancelable!void {
    try io.sleep(d, .awake);
}

fn selectFirst(_: Allocator, io: Io) !void {
    var buffer: [2]Raced = undefined;
    var select: Io.Select(Raced) = .init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.slow, after, .{ io, .fromSeconds(3600) });
    try select.concurrent(.quick, after, .{ io, ms(1) });
    switch (try select.await()) {
        .quick => |r| try r,
        .slow => return error.WrongWinner,
    }
}

fn randomFills(_: Allocator, io: Io) !void {
    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    io.random(&a);
    io.random(&b);
    if (std.mem.eql(u8, &a, &b)) return error.SameBytes;
    var c: [32]u8 = @splat(0);
    io.randomSecure(&c) catch |err| switch (err) {
        error.EntropyUnavailable => return,
        else => return err,
    };
    if (std.mem.allEqual(u8, &c, 0)) return error.NotFilled;
}
