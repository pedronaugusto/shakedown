//! References for the places this package takes aegis types, written with
//! plain integers and no aegis import: what a simulation and a quarantine
//! do is checked against a model that cannot share a bug with the types
//! they are built on. aegis's own tests run on this package's simulation,
//! so a flaw common to both must not be able to confirm itself.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Sim = shakedown.Sim;
const Quarantine = shakedown.alloc.Quarantine;

/// An event as it was before ids were types: same fields, same order, plain
/// integers.
const PlainEvent = struct {
    call: shakedown.IoCall,
    task: u32,
    node: u32 = 0,
    decision: ?u64 = null,
    outcome: u64 = 0,
};

fn hashOf(value: anytype) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHashStrat(&hasher, value, .Deep);
    return hasher.final();
}

test "an event with typed ids is laid out and hashed as one with plain integers" {
    try testing.expectEqual(@sizeOf(PlainEvent), @sizeOf(Sim.Event));
    try testing.expectEqual(@alignOf(PlainEvent), @alignOf(Sim.Event));
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (0..200) |_| {
        const task = random.int(u32);
        const node = random.int(u32);
        const decision: ?u64 = if (random.boolean()) random.int(u64) else null;
        const outcome = random.int(u64);
        const typed: Sim.Event = .{ .call = .async, .task = .fromRaw(task), .node = .fromRaw(node), .decision = decision, .outcome = outcome };
        const plain: PlainEvent = .{ .call = .async, .task = task, .node = node, .decision = decision, .outcome = outcome };
        try testing.expectEqual(hashOf(plain), hashOf(typed));
    }
}

fn clockRead(io: Io) void {
    _ = Io.Timestamp.now(io, .awake);
}

fn spawnAll(io: Io, children: u32) !void {
    var group: Io.Group = .init;
    for (0..children) |_| try group.concurrent(io, clockRead, .{io});
    try group.await(io);
    clockRead(io);
}

test "task ids are issued from 1 in the order tasks start, whatever the schedule" {
    for ([_]u32{ 0, 1, 2, 7, 40 }) |children| {
        for (0..4) |seed| {
            const sim = try Sim.init(testing.allocator, .{ .seed = seed, .trace = .all, .yield_per_million = 100_000 });
            defer sim.deinit();
            try testing.expectEqual(Sim.Outcome.finished, sim.run(spawnAll, .{ sim.io(), children }));
            // The model: the root is task 1 and its children are 2, 3, ...
            // in the order `concurrent` returned them.
            var next_child: u64 = 2;
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(testing.allocator);
            for (sim.trace().records()) |record| {
                try seen.put(testing.allocator, record.event.task.raw(), {});
                if (record.event.call == .groupConcurrent) {
                    try testing.expectEqual(next_child, record.event.outcome);
                    next_child += 1;
                }
            }
            try testing.expectEqual(@as(u64, children) + 2, next_child);
            try testing.expectEqual(@as(u32, children) + 1, seen.count());
            var id: u32 = 1;
            while (id <= children + 1) : (id += 1) try testing.expect(seen.contains(id));
        }
    }
}

/// The model of a quarantine that keeps freed address space up to a limit:
/// the spans of the blocks freed and still held, oldest first, and their
/// total. A free adds its span and, while the total is over the limit,
/// gives the oldest back.
const Model = struct {
    held: std.ArrayList(usize) = .empty,
    head: usize = 0,
    total: usize = 0,

    fn free(m: *Model, span: usize, limit: usize) !void {
        try m.held.append(testing.allocator, span);
        m.total += span;
        while (m.total > limit and m.head < m.held.items.len) {
            m.total -= m.held.items[m.head];
            m.head += 1;
        }
    }

    fn count(m: *const Model) usize {
        return m.held.items.len - m.head;
    }
};

test "the oldest freed blocks go back exactly when the held space passes the limit" {
    if (!Quarantine.supported) return error.SkipZigTest;
    const page = std.heap.pageSize();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for ([_]Quarantine.Options.Guard{ .none, .after }) |guard| {
        for ([_]usize{ 0, page - 1, page, 3 * page, 5 * page + 1 }) |limit| {
            var q: Quarantine = .init(.{ .guard = guard, .reuse_after = .fromRaw(limit) });
            defer q.deinit();
            const gpa = q.allocator();
            var model: Model = .{};
            defer model.held.deinit(testing.allocator);
            var live: std.ArrayList([]u8) = .empty;
            defer live.deinit(testing.allocator);
            for (0..60) |_| {
                const len = random.intRangeAtMost(usize, 1, 3 * page);
                try live.append(testing.allocator, try gpa.alloc(u8, len));
                if (random.boolean() and live.items.len > 1) {
                    const block = live.swapRemove(random.uintLessThan(usize, live.items.len));
                    const data = std.mem.alignForward(usize, block.len, page);
                    gpa.free(block);
                    try model.free(data + if (guard == .after) page else 0, limit);
                    var held = q.state.acquire();
                    defer held.deinit();
                    const state = held.value();
                    try testing.expectEqual(model.total, state.quarantined);
                    // What the quarantine still maps: the blocks not freed yet and those it holds.
                    try testing.expectEqual(live.items.len + model.count(), state.mappings.count());
                }
            }
            for (live.items) |block| gpa.free(block);
        }
    }
}

test "blocks allocated and freed on several threads never share an address" {
    if (!Quarantine.supported) return error.SkipZigTest;
    var q: Quarantine = .init(.{});
    defer q.deinit();
    const gpa = q.allocator();
    const per_thread = 200;
    const Worker = struct {
        fn run(a: std.mem.Allocator, ranges: *[per_thread][2]usize, seed: u64, failed: *std.atomic.Value(bool)) void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            for (ranges) |*range| {
                const len = random.intRangeAtMost(usize, 1, 2 * std.heap.pageSize());
                const block = a.alloc(u8, len) catch {
                    failed.store(true, .release);
                    return;
                };
                @memset(block, 0x5a);
                range.* = .{ @intFromPtr(block.ptr), @intFromPtr(block.ptr) + len };
                a.free(block);
            }
        }
    };
    var all: [4][per_thread][2]usize = undefined;
    var threads: [4]std.Thread = undefined;
    var failed: std.atomic.Value(bool) = .init(false);
    for (&threads, &all, 0..) |*t, *ranges, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ gpa, ranges, testing.random_seed +% i, &failed });
    for (threads) |t| t.join();
    try testing.expect(!failed.load(.acquire));
    // Nothing is given back, so no address was handed out twice, by any thread.
    var flat: std.ArrayList([2]usize) = .empty;
    defer flat.deinit(testing.allocator);
    for (&all) |*ranges| try flat.appendSlice(testing.allocator, ranges);
    std.mem.sort([2]usize, flat.items, {}, struct {
        fn less(_: void, a: [2]usize, b: [2]usize) bool {
            return a[0] < b[0];
        }
    }.less);
    for (flat.items[0 .. flat.items.len - 1], flat.items[1..]) |before, after| try testing.expect(before[1] <= after[0]);
}
