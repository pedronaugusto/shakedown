//! `explore` from outside: every run within the bounds, once; preemptions
//! as the bound; orders that differ only in independent steps searched once;
//! a body that depends on something besides its source caught.
const std = @import("std");
const Io = std.Io;
const t = std.testing;
const shakedown = @import("shakedown.zig");
const Case = shakedown.Case;
const Sim = shakedown.Sim;

fn explored(comptime body: anytype, ctx: anytype, options: shakedown.ExploreOptions) !shakedown.Exploration {
    return shakedown.explore(t.allocator, ctx, body, options);
}

const Pairs = struct {
    seen: [3][3]u32 = @splat(@splat(0)),

    fn body(p: *Pairs, c: *Case) !void {
        const a = c.source.below(2);
        const b = c.source.below(2);
        p.seen[a][b] += 1;
    }
};

test "every choice is made once, depth first" {
    var p: Pairs = .{};
    const result = try explored(Pairs.body, &p, .{});
    try t.expect(result.complete);
    try t.expectEqual(@as(u64, 9), result.runs);
    for (p.seen) |row| for (row) |count| try t.expectEqual(@as(u32, 1), count);
}

const Wide = struct {
    fn body(_: void, c: *Case) !void {
        // More alternatives than the search spans: held at the simplest.
        if (c.source.below(1000) != 0) return error.NotHeld;
        _ = c.source.below(1);
    }
};

test "a choice of more alternatives than max_branch keeps its simplest value" {
    const result = try explored(Wide.body, {}, .{ .max_branch = 16 });
    try t.expectEqual(@as(u64, 2), result.runs);
    try t.expectEqual(@as(u64, 1), result.held);
}

/// Two tasks add to a counter by reading it, making a call, and writing it
/// back: an update is lost only if a task is preempted at that call.
const Counter = struct {
    value: u32 = 0,

    fn add(c: *Counter, io: Io) Io.Cancelable!void {
        const seen = c.value;
        try io.checkCancel();
        c.value = seen + 1;
    }

    fn twice(c: *Counter, io: Io) !void {
        var a = try io.concurrent(add, .{ c, io });
        var b = try io.concurrent(add, .{ c, io });
        try a.await(io);
        try b.await(io);
        if (c.value != 2) return error.LostUpdate;
    }

    fn body(_: void, c: *Case) !void {
        var counter: Counter = .{};
        const sim = try c.sim(.{});
        switch (sim.run(twice, .{ &counter, sim.io() })) {
            .finished => {},
            .failed => |err| return err,
            else => return error.Unexpected,
        }
    }
};

test "a lost update that needs a preemption is not there without one, and is found with one" {
    const none = try explored(Counter.body, {}, .{ .preemptions = 0 });
    try t.expect(none.complete);
    var report: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, explored(Counter.body, {}, .{ .preemptions = 1, .diagnostics = &report }));
    defer report.deinit();
    try t.expectEqual(error.LostUpdate, report.err);
}

/// Three tasks, each through a few calls of its own, with a shared result.
const Three = struct {
    order: [12]u8 = undefined,
    len: usize = 0,

    fn work(s: *Three, io: Io, id: u8) Io.Cancelable!void {
        for (0..2) |_| {
            try io.checkCancel();
            s.order[s.len] = id;
            s.len += 1;
        }
    }

    fn all(s: *Three, io: Io) !void {
        var group: Io.Group = .init;
        for (0..3) |i| try group.concurrent(io, work, .{ s, io, @as(u8, @intCast(i)) });
        try group.await(io);
    }

    fn body(orders: *std.StringHashMapUnmanaged(void), c: *Case) !void {
        var s: Three = .{};
        const sim = try c.sim(.{});
        if (sim.run(all, .{ &s, sim.io() }) != .finished) return error.Unexpected;
        const key = try t.allocator.dupe(u8, s.order[0..s.len]);
        const gop = try orders.getOrPut(t.allocator, key);
        if (gop.found_existing) t.allocator.free(key);
    }
};

fn distinctOrders(options: shakedown.ExploreOptions) !struct { runs: u64, orders: usize } {
    var orders: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = orders.keyIterator();
        while (it.next()) |k| t.allocator.free(k.*);
        orders.deinit(t.allocator);
    }
    const result = try explored(Three.body, &orders, options);
    try t.expect(result.complete);
    return .{ .runs = result.runs, .orders = orders.count() };
}

test "with shared memory, the reduction searches every order the full search does" {
    for (0..3) |preemptions| {
        const full = try distinctOrders(.{ .preemptions = @intCast(preemptions), .reduction = .none });
        const reduced = try distinctOrders(.{ .preemptions = @intCast(preemptions) });
        try t.expectEqual(full.orders, reduced.orders);
        try t.expect(reduced.runs <= full.runs);
    }
}

/// Nodes that each work through calls on their own disk, then send one
/// message to a collector: only the order the messages arrive in matters.
const Nodes = struct {
    const port = 7000;

    fn worker(io: Io, id: u8, collector: Io.net.IpAddress) !void {
        const dir = Io.Dir.cwd();
        for (0..2) |i| {
            var name: [8]u8 = undefined;
            try dir.writeFile(io, .{ .sub_path = try std.mem.print(&name, "f{d}", .{i}), .data = "x" });
        }
        // The collector may not listen yet: a search finds that order.
        var stream = while (true) break collector.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => {
                try io.sleep(.fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        defer stream.close(io);
        var buffer: [8]u8 = undefined;
        var w = stream.writer(io, &buffer);
        try w.interface.writeByte(id);
        try w.interface.flush();
    }

    fn collect(io: Io, listen: Io.net.IpAddress, out: *[2]u8) !void {
        var server = try listen.listen(io, .{});
        defer server.deinit(io);
        for (out) |*slot| {
            var stream = try server.accept(io);
            defer stream.close(io);
            var buffer: [8]u8 = undefined;
            var r = stream.reader(io, &buffer);
            slot.* = try r.interface.takeByte();
        }
    }

    fn body(firsts: *[2]u32, c: *Case) !void {
        const sim = try c.sim(.{});
        const address: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 9 }, .port = port } };
        const collector = try sim.node("collector", .{ .addresses = &.{address} });
        const a = try sim.node("a", .{});
        const b = try sim.node("b", .{});
        var out: [2]u8 = undefined;
        try collector.restart(collect, .{ collector.io(), address, &out });
        try a.restart(worker, .{ a.io(), 0, address });
        try b.restart(worker, .{ b.io(), 1, address });
        const Root = struct {
            fn run(io: Io) !void {
                try io.sleep(.fromSeconds(60), .awake);
            }
        };
        switch (sim.run(Root.run, .{sim.io()})) {
            .finished => {},
            .failed => |err| return err,
            else => return error.Unexpected,
        }
        firsts[out[0]] += 1;
    }
};

test "nodes that share no memory: steps on different nodes are searched in one order unless they meet" {
    var shared: [2]u32 = @splat(0);
    const full = try explored(Nodes.body, &shared, .{ .preemptions = 1, .max_runs = 100_000 });
    var isolated: [2]u32 = @splat(0);
    const reduced = try explored(Nodes.body, &isolated, .{ .preemptions = 1, .memory = .per_process });
    try t.expect(full.complete and reduced.complete);
    // Either worker's message can arrive first, in both searches.
    try t.expect(shared[0] > 0 and shared[1] > 0);
    try t.expect(isolated[0] > 0 and isolated[1] > 0);
    try t.expect(reduced.runs * 4 < full.runs);
}

var drift: u64 = 0;

const Drifting = struct {
    fn body(_: void, c: *Case) !void {
        // A choice whose alternatives depend on a run before: not a function
        // of the source.
        drift += 1;
        _ = c.source.below(1 + drift % 2);
        _ = c.source.below(1);
    }
};

test "a body whose choices change between runs of one tape is reported" {
    drift = 0;
    try t.expectError(error.Nondeterministic, explored(Drifting.body, {}, .{}));
}

/// A simulated process and its parent, each with work of its own, meeting
/// at the pipe: under `per_process`, their own steps are not interleaved.
const Piped = struct {
    fn child(init: std.process.Init) !void {
        for (0..3) |_| try init.io.checkCancel();
        try Io.File.stdout().writeStreamingAll(init.io, "done");
    }

    fn parent(io: Io) !void {
        var c = try std.process.spawn(io, .{ .argv = &.{"child"}, .stdout = .pipe });
        for (0..3) |_| try io.checkCancel();
        var buffer: [8]u8 = undefined;
        var r = c.stdout.?.reader(io, &buffer);
        var got: [4]u8 = undefined;
        try r.interface.readSliceAll(&got);
        if (!std.mem.eql(u8, &got, "done")) return error.Garbled;
        _ = try c.wait(io);
    }

    fn body(_: void, c: *Case) !void {
        const sim = try c.sim(.{});
        try sim.programs().register("child", child, .{});
        switch (sim.run(parent, .{sim.io()})) {
            .finished => {},
            .failed => |err| return err,
            else => return error.Unexpected,
        }
    }
};

test "a process and its parent are searched as separate memories" {
    const full = try explored(Piped.body, {}, .{ .preemptions = 2 });
    const reduced = try explored(Piped.body, {}, .{ .preemptions = 2, .memory = .per_process });
    try t.expect(full.complete and reduced.complete);
    try t.expect(reduced.runs < full.runs);
}
