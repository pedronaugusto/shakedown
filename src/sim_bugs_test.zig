//! Bugs a simulation must find, each in an ordering the code does not
//! control: a condition that swallows a cancel (Zig 0.16's), a queue that
//! loses a wake-up, work started with `async` whose output is awaited before
//! it can run, and an ABA in a lock-free stack. `check` runs each over
//! simulations whose every decision comes from the case's source, finds the
//! bug, and shrinks the schedule that shows it to a handful of choices. The
//! fixed versions pass.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Case = shakedown.Case;
const Sim = shakedown.Sim;
const Condition016 = @import("testing/Condition016.zig");

/// Runs `property` under `check` and returns the failure, which the test
/// frees, or null when every case passed.
fn failure(comptime property: anytype, cases: u32) !?shakedown.CheckReport {
    var report: shakedown.CheckReport = undefined;
    shakedown.check(testing.allocator, {}, property, .{ .seed = 2026, .cases = cases, .diagnostics = &report }) catch |err| switch (err) {
        error.PropertyFailed => return report,
        else => return err,
    };
    return null;
}

/// The choices a tape holds that are not 0: the decisions that had to go
/// one particular way.
fn decisions(tape: []const u64) usize {
    return tape.len - std.mem.count(u64, tape, &.{0});
}

fn finishes(sim: *Sim, outcome: Sim.Outcome) !void {
    _ = sim;
    switch (outcome) {
        .finished => {},
        .deadlock => return error.Deadlock,
        else => return error.Unexpected,
    }
}

// A reader waits for records on a condition; the stop cancels it after a
// writer's last record. With 0.16's condition the cancel can be swallowed
// by the record's wake, and the stop then waits for ever (chronicle,
// dcdc0ed).

fn Journal(comptime Cond: type) type {
    return struct {
        mutex: Io.Mutex = .init,
        cond: Cond = .init,
        seq: u32 = 0,

        const Self = @This();

        fn waitPast(j: *Self, io: Io, seen: u32) Io.Cancelable!u32 {
            try j.mutex.lock(io);
            defer j.mutex.unlock(io);
            while (j.seq == seen) try j.cond.wait(io, &j.mutex);
            return j.seq;
        }

        fn read(j: *Self, io: Io) Io.Cancelable!void {
            var seen: u32 = 0;
            while (true) seen = try j.waitPast(io, seen);
        }

        fn append(j: *Self, io: Io) void {
            j.mutex.lockUncancelable(io);
            j.seq += 1;
            j.mutex.unlock(io);
            j.cond.broadcast(io);
        }

        fn stop(io: Io) !void {
            var j: Self = .{};
            var reader = try io.concurrent(read, .{ &j, io });
            var writer = try io.concurrent(append, .{ &j, io });
            writer.await(io);
            reader.cancel(io) catch |err| switch (err) {
                error.Canceled => {},
            };
        }

        fn property(_: void, c: *Case) !void {
            const sim = try c.sim(.{});
            try finishes(sim, sim.run(stop, .{sim.io()}));
        }
    };
}

test "0.16's condition loses a cancel to a wake, found and shrunk; 0.17's does not" {
    var report = (try failure(Journal(Condition016).property, 1000)) orelse return error.BugNotFound;
    defer report.deinit();
    try testing.expectEqual(error.Deadlock, report.err);
    try testing.expect(decisions(report.tape) <= 6);
    try testing.expectEqual(@as(?shakedown.CheckReport, null), try failure(Journal(Io.Condition).property, 300));
}

// A consumer checks for work, notes the time, then resets its event and
// waits: a put landing between the check and the reset is never seen.

const Inbox = struct {
    mutex: Io.Mutex = .init,
    ready: Io.Event = .unset,
    items: u32 = 0,
    fixed: bool,

    fn take(q: *Inbox, io: Io) Io.Cancelable!void {
        while (true) {
            q.mutex.lockUncancelable(io);
            if (q.fixed) q.ready.reset();
            if (q.items > 0) {
                q.items -= 1;
                q.mutex.unlock(io);
                return;
            }
            q.mutex.unlock(io);
            _ = Io.Timestamp.now(io, .awake);
            if (!q.fixed) q.ready.reset();
            try q.ready.wait(io);
        }
    }

    fn put(q: *Inbox, io: Io) void {
        q.mutex.lockUncancelable(io);
        q.items += 1;
        q.mutex.unlock(io);
        q.ready.set(io);
    }

    fn exchange(io: Io, fixed: bool) !void {
        var q: Inbox = .{ .fixed = fixed };
        var consumer = try io.concurrent(take, .{ &q, io });
        var producer = try io.concurrent(put, .{ &q, io });
        producer.await(io);
        try consumer.await(io);
    }

    fn property(fixed: bool, c: *Case) !void {
        const sim = try c.sim(.{ .yield_per_million = 250_000 });
        try finishes(sim, sim.run(exchange, .{ sim.io(), fixed }));
    }

    fn lossy(_: void, c: *Case) !void {
        return property(false, c);
    }

    fn sound(_: void, c: *Case) !void {
        return property(true, c);
    }
};

test "a wake-up lost between a check and a reset, found and shrunk; the fixed inbox passes" {
    var report = (try failure(Inbox.lossy, 1000)) orelse return error.BugNotFound;
    defer report.deinit();
    try testing.expectEqual(error.Deadlock, report.err);
    try testing.expect(decisions(report.tape) <= 6);
    try testing.expectEqual(@as(?shakedown.CheckReport, null), try failure(Inbox.sound, 300));
}

// Work started with `async`, then waited on through a queue it fills:
// std lets `async` run the function at once, and then it blocks on the
// full queue before anyone reads it (the 0.17 audit's relic httpclient).

const Pipe = struct {
    fn produce(io: Io, q: *Io.Queue(u32)) (Io.QueueClosedError || Io.Cancelable)!void {
        for (0..3) |i| try q.putOne(io, @intCast(i));
    }

    fn drain(io: Io) !void {
        var buffer: [1]u32 = undefined;
        var q: Io.Queue(u32) = .init(&buffer);
        var producer = io.async(produce, .{ io, &q });
        for (0..3) |_| _ = try q.getOne(io);
        try producer.await(io);
    }
};

test "async, then a wait on its output, deadlocks when async runs at once" {
    for ([_]Sim.AsyncStart{ .eager, .concurrent }) |policy| {
        const sim = try Sim.init(testing.allocator, .{ .async_start = policy });
        defer sim.deinit();
        const outcome = sim.run(Pipe.drain, .{sim.io()});
        switch (policy) {
            .eager => {
                const reports = switch (outcome) {
                    .deadlock => |r| r,
                    else => return error.TestUnexpectedResult,
                };
                try testing.expectEqual(@as(usize, 1), reports.len);
            },
            else => try testing.expectEqual(Sim.Outcome.finished, outcome),
        }
    }
}

// A lock-free stack whose pop reads the next node, makes an Io call, then
// swaps the head: meanwhile another task pops the head and the next node
// and pushes the head back, and the swap puts a node in use back on the
// stack.

const Stack = struct {
    const Node = struct { next: ?*Node, id: u8 };

    head: ?*Node,
    tagged: bool,
    version: u32 = 0,

    fn pop(s: *Stack, io: Io) Io.Cancelable!?*Node {
        while (true) {
            const head = @atomicLoad(?*Node, &s.head, .acquire) orelse return null;
            const version = @atomicLoad(u32, &s.version, .acquire);
            const next = head.next;
            try io.checkCancel();
            if (s.tagged and @atomicLoad(u32, &s.version, .acquire) != version) continue;
            if (@cmpxchgStrong(?*Node, &s.head, head, next, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(u32, &s.version, .Add, 1, .release);
                return head;
            }
        }
    }

    fn push(s: *Stack, node: *Node) void {
        while (true) {
            const head = @atomicLoad(?*Node, &s.head, .acquire);
            node.next = head;
            if (@cmpxchgStrong(?*Node, &s.head, head, node, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(u32, &s.version, .Add, 1, .release);
                return;
            }
        }
    }

    fn popOne(s: *Stack, io: Io) Io.Cancelable!?*Node {
        return s.pop(io);
    }

    fn popTwoPushFirst(s: *Stack, io: Io) Io.Cancelable!?*Node {
        const a = (try s.pop(io)) orelse return null;
        const b = try s.pop(io);
        s.push(a);
        return b;
    }

    fn race(io: Io, tagged: bool) !void {
        var nodes = [_]Node{ .{ .next = null, .id = 0 }, .{ .next = null, .id = 1 }, .{ .next = null, .id = 2 } };
        nodes[0].next = &nodes[1];
        nodes[1].next = &nodes[2];
        var s: Stack = .{ .head = &nodes[0], .tagged = tagged };
        var one = try io.concurrent(popOne, .{ &s, io });
        var two = try io.concurrent(popTwoPushFirst, .{ &s, io });
        const taken_one = try one.await(io);
        const taken_two = try two.await(io);
        // Every node is in exactly one place: on the stack, or taken.
        var seen: [3]u8 = @splat(0);
        var it = s.head;
        while (it) |n| : (it = n.next) seen[n.id] += 1;
        if (taken_one) |n| seen[n.id] += 1;
        if (taken_two) |n| seen[n.id] += 1;
        for (seen) |count| if (count != 1) return error.NodeInTwoPlaces;
    }

    fn property(tagged: bool, c: *Case) !void {
        const sim = try c.sim(.{ .yield_per_million = 250_000 });
        switch (sim.run(race, .{ sim.io(), tagged })) {
            .finished => {},
            .failed => |err| return err,
            else => return error.Unexpected,
        }
    }

    fn untagged(_: void, c: *Case) !void {
        return property(false, c);
    }

    fn versioned(_: void, c: *Case) !void {
        return property(true, c);
    }
};

test "an ABA in a lock-free stack, found and shrunk; a versioned head passes" {
    var report = (try failure(Stack.untagged, 1000)) orelse return error.BugNotFound;
    defer report.deinit();
    try testing.expectEqual(error.NodeInTwoPlaces, report.err);
    try testing.expect(decisions(report.tape) <= 6);
    try testing.expectEqual(@as(?shakedown.CheckReport, null), try failure(Stack.versioned, 300));
}
