//! `Sim` from outside: time, tasks, futexes, cancelation, the outcomes a
//! run ends in, and runs that repeat from their seed on every executor.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Sim = shakedown.Sim;
const Core = @import("sim/Core.zig");

fn sleepHour(io: Io) !void {
    try io.sleep(.fromSeconds(3600), .awake);
}

test "an hour of sleep takes no real time and moves every clock by an hour" {
    const sim = try Sim.init(testing.allocator, .{});
    defer sim.deinit();
    const before = sim.now(.real);
    const outcome = sim.run(sleepHour, .{sim.io()});
    try testing.expectEqual(Sim.Outcome.finished, outcome);
    try testing.expectEqual(@as(i96, 3600 * std.time.ns_per_s), before.durationTo(sim.now(.real)).nanoseconds);
}

const PingPong = struct {
    ping: Io.Event = .unset,
    pong: Io.Event = .unset,
    rounds: u32 = 0,

    fn other(p: *PingPong, io: Io) !void {
        try p.ping.wait(io);
        p.rounds += 1;
        p.pong.set(io);
    }

    fn main(p: *PingPong, io: Io) !void {
        var task = try io.concurrent(other, .{ p, io });
        p.ping.set(io);
        try p.pong.wait(io);
        try task.await(io);
    }
};

test "a concurrent task and its awaiter hand off through events" {
    inline for (.{ Sim.Executor.auto, Sim.Executor.threads }) |executor| {
        const sim = try Sim.init(testing.allocator, .{ .executor = executor, .seed = 3 });
        defer sim.deinit();
        var p: PingPong = .{};
        try testing.expectEqual(Sim.Outcome.finished, sim.run(PingPong.main, .{ &p, sim.io() }));
        try testing.expectEqual(@as(u32, 1), p.rounds);
    }
}

const Counter = struct {
    mutex: Io.Mutex = .init,
    count: u32 = 0,

    fn add(c: *Counter, io: Io, times: u32) Io.Cancelable!void {
        for (0..times) |_| {
            try c.mutex.lock(io);
            const seen = c.count;
            try io.sleep(.fromNanoseconds(1), .awake);
            c.count = seen + 1;
            c.mutex.unlock(io);
        }
    }

    fn main(c: *Counter, io: Io) !void {
        var group: Io.Group = .init;
        for (0..8) |_| try group.concurrent(io, add, .{ c, io, 25 });
        try group.await(io);
    }
};

test "a mutex excludes, whatever the schedule" {
    for (0..20) |seed| {
        const sim = try Sim.init(testing.allocator, .{ .seed = seed, .yield_per_million = 200_000 });
        defer sim.deinit();
        var c: Counter = .{};
        try testing.expectEqual(Sim.Outcome.finished, sim.run(Counter.main, .{ &c, sim.io() }));
        try testing.expectEqual(@as(u32, 200), c.count);
    }
}

const Stuck = struct {
    a: Io.Event = .unset,
    b: Io.Event = .unset,

    fn waitA(s: *Stuck, io: Io) Io.Cancelable!void {
        try s.a.wait(io);
    }

    fn main(s: *Stuck, io: Io) !void {
        var task = try io.concurrent(waitA, .{ s, io });
        try s.b.wait(io);
        try task.await(io);
    }
};

test "every task waiting with no timer armed is a deadlock that names each" {
    const sim = try Sim.init(testing.allocator, .{});
    defer sim.deinit();
    var s: Stuck = .{};
    const outcome = sim.run(Stuck.main, .{ &s, sim.io() });
    const reports = switch (outcome) {
        .deadlock => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), reports.len);
    for (reports) |r| {
        try testing.expect(r.waiting == .futex);
        try testing.expect(r.len > 0);
    }
}

fn traceHash(seed: u64, executor: Sim.Executor) !u64 {
    const sim = try Sim.init(testing.allocator, .{ .seed = seed, .executor = executor, .yield_per_million = 300_000 });
    defer sim.deinit();
    var c: Counter = .{};
    try testing.expectEqual(Sim.Outcome.finished, sim.run(Counter.main, .{ &c, sim.io() }));
    return sim.trace().hash();
}

test "a seed repeats its run, on every executor" {
    for (0..10) |seed| {
        const a = try traceHash(seed, .auto);
        try testing.expectEqual(a, try traceHash(seed, .auto));
        try testing.expectEqual(a, try traceHash(seed, .threads));
    }
    try testing.expect(try traceHash(1, .auto) != try traceHash(2, .auto));
}

const Frames = struct {
    frames: u32 = 0,
    input: u32 = 0,

    fn loop(f: *Frames, io: Io) Io.Cancelable!void {
        while (f.frames < 100) {
            f.frames += 1;
            try io.sleep(.fromNanoseconds(16_666_667), .awake);
        }
    }

    fn press(_: Io, ctx: *anyopaque) void {
        const f: *Frames = @ptrCast(@alignCast(ctx));
        f.input = f.frames;
    }
};

test "frame stepping: runFor moves time by a frame, and at injects input at an instant" {
    const sim = try Sim.init(testing.allocator, .{});
    defer sim.deinit();
    var f: Frames = .{};
    try sim.start(Frames.loop, .{ &f, sim.io() });
    const t0 = sim.now(.awake);
    try sim.at(t0.addDuration(.fromMilliseconds(100)), &f, Frames.press);
    for (0..10) |_| try testing.expectEqual(@as(?Sim.Outcome, null), sim.runFor(.fromNanoseconds(16_666_667)));
    // A frame at the start, then one per period: a timer due exactly at
    // the end of a step runs within it.
    try testing.expectEqual(@as(u32, 11), f.frames);
    // At 100 ms six frames had run; the seventh is due just after.
    try testing.expectEqual(@as(u32, 6), f.input);
    try testing.expectEqual(@as(i96, 10 * 16_666_667), t0.durationTo(sim.now(.awake)).nanoseconds);
    try testing.expectEqual(@as(?Sim.Outcome, .finished), sim.runFor(.fromSeconds(10)));
    try testing.expectEqual(@as(u32, 100), f.frames);
}

const Waiter = struct {
    fn wait(io: Io, gate: *Io.Event) Io.Cancelable!u32 {
        try gate.wait(io);
        return 1;
    }

    fn awaitThenReport(io: Io, gate: *Io.Event, outcome: *?Io.Cancelable!u32) (Io.ConcurrentError || Io.Cancelable)!void {
        var inner = try io.concurrent(wait, .{ io, gate });
        outcome.* = inner.await(io);
        try io.checkCancel();
    }

    fn main(io: Io, gate: *Io.Event, outcome: *?Io.Cancelable!u32, saw: *?anyerror) !void {
        var outer = try io.concurrent(awaitThenReport, .{ io, gate, outcome });
        try io.sleep(.fromMilliseconds(1), .awake);
        outer.cancel(io) catch |err| {
            saw.* = err;
        };
    }
};

test "a cancel of a task awaiting another passes to the awaited one" {
    const sim = try Sim.init(testing.allocator, .{ .spurious_wake_per_million = 0 });
    defer sim.deinit();
    var gate: Io.Event = .unset;
    var inner: ?Io.Cancelable!u32 = null;
    var saw: ?anyerror = null;
    try testing.expectEqual(Sim.Outcome.finished, sim.run(Waiter.main, .{ sim.io(), &gate, &inner, &saw }));
    // The awaited task took the cancel at its wait, so the awaiter's
    // await returns its error and the awaiter's own cancel is spent.
    try testing.expectError(error.Canceled, inner.?);
    try testing.expectEqual(@as(?anyerror, null), saw);
}

const Order = struct {
    log: [4]u8 = undefined,
    len: usize = 0,

    fn after(o: *Order, io: Io, d: i64, tag: u8) Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(d), .awake);
        o.log[o.len] = tag;
        o.len += 1;
    }

    fn main(o: *Order, io: Io) !void {
        var group: Io.Group = .init;
        try group.concurrent(io, after, .{ o, io, 30, 'c' });
        try group.concurrent(io, after, .{ o, io, 10, 'a' });
        try group.concurrent(io, after, .{ o, io, 20, 'b' });
        try group.concurrent(io, after, .{ o, io, 10, 'x' });
        try group.await(io);
    }
};

test "timers fire in deadline order, ties in the order they were armed" {
    const sim = try Sim.init(testing.allocator, .{ .schedule = .fifo, .spurious_wake_per_million = 0 });
    defer sim.deinit();
    var o: Order = .{};
    try testing.expectEqual(Sim.Outcome.finished, sim.run(Order.main, .{ &o, sim.io() }));
    try testing.expectEqualStrings("axbc", o.log[0..o.len]);
}

const Inline = struct {
    fn ran(flag: *bool) void {
        flag.* = true;
    }

    fn main(io: Io, eager: *bool) !void {
        var flag = false;
        var f = io.async(ran, .{&flag});
        eager.* = flag;
        f.await(io);
    }
};

test "async runs at once under eager, starts a task under concurrent, and either under any" {
    var seen = [_]bool{ false, false };
    for (0..32) |seed| {
        inline for (.{ Sim.AsyncStart.eager, Sim.AsyncStart.concurrent, Sim.AsyncStart.any }) |policy| {
            const sim = try Sim.init(testing.allocator, .{ .seed = seed, .async_start = policy });
            defer sim.deinit();
            var eager = false;
            try testing.expectEqual(Sim.Outcome.finished, sim.run(Inline.main, .{ sim.io(), &eager }));
            switch (policy) {
                .eager => try testing.expect(eager),
                .concurrent => try testing.expect(!eager),
                else => seen[@intFromBool(eager)] = true,
            }
        }
    }
    try testing.expect(seen[0] and seen[1]);
}

const PingPongRounds = struct {
    fn other(io: Io, a: *Io.Event, b: *Io.Event, rounds: u32) Io.Cancelable!void {
        for (0..rounds) |_| {
            try a.wait(io);
            a.reset();
            b.set(io);
        }
    }

    fn main(io: Io, rounds: u32) !void {
        var a: Io.Event = .unset;
        var b: Io.Event = .unset;
        var task = try io.concurrent(other, .{ io, &a, &b, rounds });
        for (0..rounds) |_| {
            a.set(io);
            try b.wait(io);
            b.reset();
        }
        try task.await(io);
    }
};

fn allocationsFor(rounds: u32) !u64 {
    var counting: shakedown.alloc.Counting = .init(testing.allocator);
    const sim = try Sim.init(counting.allocator(), .{ .spurious_wake_per_million = 0 });
    defer sim.deinit();
    try testing.expectEqual(Sim.Outcome.finished, sim.run(PingPongRounds.main, .{ sim.io(), rounds }));
    return counting.allocations;
}

test "a run allocates nothing per step once its tasks exist" {
    const few = try allocationsFor(10);
    try testing.expectEqual(few, try allocationsFor(10_000));
}

const Spinner = struct {
    fn spin(io: Io, sim: *Sim) Io.Cancelable!void {
        // Runs without an Io call until the watchdog has seen it, then
        // makes one, where the run ends.
        while (!sim.core.stuck.load(.monotonic)) std.atomic.spinLoopHint();
        try io.checkCancel();
    }
};

test "the watchdog ends a run whose task stopped calling into it" {
    const sim = try Sim.init(testing.allocator, .{ .watchdog = .fromMilliseconds(50) });
    defer sim.deinit();
    const outcome = sim.run(Spinner.spin, .{ sim.io(), sim });
    const report = switch (outcome) {
        .stuck => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u32, 1), report.id);
    try testing.expect(report.len > 0);
}

fn twoRandoms(io: Io, out: *[2]u64) !void {
    var a: [8]u8 = undefined;
    io.random(&a);
    out[0] = std.mem.readInt(u64, &a, .little);
    io.random(&a);
    out[1] = std.mem.readInt(u64, &a, .little);
}

test "io.random is the simulation's source: one seed, one sequence" {
    var runs: [2][2]u64 = undefined;
    for (&runs) |*r| {
        const sim = try Sim.init(testing.allocator, .{ .seed = 77 });
        defer sim.deinit();
        try testing.expectEqual(Sim.Outcome.finished, sim.run(twoRandoms, .{ sim.io(), r }));
    }
    try testing.expectEqual(runs[0], runs[1]);
    try testing.expect(runs[0][0] != runs[0][1]);
}

const FaultySleep = struct {
    fn main(io: Io) !void {
        try io.sleep(.fromSeconds(1), .awake);
    }
};

test "a fault plan is the simulation's outermost part" {
    const sim = try Sim.init(testing.allocator, .{ .faults = &.{.{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel }} });
    defer sim.deinit();
    try testing.expectEqual(Sim.Outcome{ .failed = error.Canceled }, sim.run(FaultySleep.main, .{sim.io()}));
    try testing.expectEqual(@as(u64, 1), sim.faults().?.count(.sleep));
}

/// A cancel requested while the task holds its protection blocked lands
/// at its first cancelation point after: a call the simulation does not
/// have, which still is one.
const LateCancel = struct {
    fn target(io: Io, file: Io.File) !void {
        const was = io.swapCancelProtection(.blocked);
        io.sleep(.fromSeconds(1), .awake) catch unreachable; // unreachable: protection is blocked
        _ = io.swapCancelProtection(was);
        try file.sync(io);
    }

    fn main(io: Io) !void {
        const nothing: Io.File = .{ .handle = Io.File.stdout().handle, .flags = .{ .nonblocking = false } };
        var task = try io.concurrent(target, .{ io, nothing });
        try io.sleep(.fromMilliseconds(1), .awake);
        try testing.expectError(error.Canceled, task.cancel(io));
    }
};

test "every call that can be canceled is a cancelation point, those the simulation lacks too" {
    const sim = try Sim.init(testing.allocator, .{ .async_start = .concurrent });
    defer sim.deinit();
    try testing.expectEqual(Sim.Outcome.finished, sim.run(LateCancel.main, .{sim.io()}));
}

const Rearmed = struct {
    fn main(io: Io) !void {
        try testing.expectError(error.Canceled, io.sleep(.fromSeconds(1), .awake));
        io.recancel();
        try testing.expectError(error.Canceled, io.checkCancel());
        try io.checkCancel();
    }
};

test "a cancel the fault plan landed is the task's to re-arm" {
    const sim = try Sim.init(testing.allocator, .{ .faults = &.{.{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel }} });
    defer sim.deinit();
    try testing.expectEqual(Sim.Outcome.finished, sim.run(Rearmed.main, .{sim.io()}));
    try testing.expectEqual(@as(u64, 1), sim.faults().?.count(.recancel));
}

test "simulations share one watchdog, which finds each stuck run" {
    var watchdog: Sim.Watchdog = .init();
    defer watchdog.deinit();
    for (0..2) |_| {
        const sim = try Sim.init(testing.allocator, .{ .watchdog = .fromMilliseconds(50), .watched_by = &watchdog });
        defer sim.deinit();
        const thread = watchdog.thread;
        switch (sim.run(Spinner.spin, .{ sim.io(), sim })) {
            .stuck => {},
            else => return error.TestUnexpectedResult,
        }
        // One thread watched both; the simulation started none of its own.
        if (thread) |t| try testing.expectEqual(t.getHandle(), watchdog.thread.?.getHandle());
        try testing.expect(sim.own_watchdog.thread == null);
    }
}

const Pointers = struct {
    order: [16]u64 = undefined,

    fn body(p: *Pointers, io: Io) !void {
        _ = io;
        const sim: *Sim = @fieldParentPtr("core", Core.running_core.?);
        const gpa = sim.allocator();
        var map: std.AutoHashMapUnmanaged(*u64, void) = .empty;
        var values: [16]*u64 = undefined;
        for (&values, 0..) |*v, i| {
            v.* = try gpa.create(u64);
            v.*.* = i;
            try map.put(gpa, v.*, {});
        }
        var it = map.keyIterator();
        var n: usize = 0;
        while (it.next()) |k| : (n += 1) p.order[n] = k.*.*;
    }
};

test "pointer-keyed maps iterate alike in two runs on the simulation's allocator" {
    var p: Pointers = .{};
    try shakedown.expectDeterministic(testing.allocator, &p, Pointers.body, .{ .seed = 3, .checksum = struct {
        fn sum(q: *Pointers) u64 {
            return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&q.order));
        }
    }.sum });
}

const Leaky = struct {
    leaks: bool,
    runs: u32 = 0,

    fn body(l: *Leaky, io: Io) !void {
        // State kept outside the run steers it: every other run sleeps once
        // more.
        l.runs += 1;
        if (l.leaks and l.runs % 2 == 1) try io.sleep(.fromSeconds(1), .awake);
        try io.sleep(.fromSeconds(1), .awake);
    }
};

test "expectDeterministic passes one seed's runs, and names where two differ" {
    var steady: Leaky = .{ .leaks = false };
    try shakedown.expectDeterministic(testing.allocator, &steady, Leaky.body, .{});
    var leaky: Leaky = .{ .leaks = true };
    var report: shakedown.DeterminismReport = undefined;
    try testing.expectError(error.Nondeterministic, shakedown.expectDeterministic(testing.allocator, &leaky, Leaky.body, .{ .diagnostics = &report }));
    defer report.deinit();
    try testing.expectEqual(@as(u64, 1), report.index);
    try testing.expect(std.mem.find(u8, report.text, "different calls at record 1") != null);
}
