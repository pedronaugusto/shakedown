//! Targeted search from outside: properties that fail only past a score
//! random drawing does not reach within the budget, which `check` finds by
//! climbing toward it, steering inputs and a simulation alike.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const gen = shakedown.gen;
const Case = shakedown.Case;
const Sim = shakedown.Sim;

/// A list of bytes that fails once it sums to `fails_at`, scored by its sum
/// when `steered`.
pub const Sum = struct {
    fails_at: u64,
    steered: bool,

    fn byte(s: *shakedown.Source) u8 {
        return gen.int(s, u8);
    }

    pub fn body(p: *const Sum, c: *Case) !void {
        const list = try gen.slice(c.source, u8, byte, c.gpa, .{});
        var sum: u64 = 0;
        for (list) |x| sum += x;
        if (p.steered) c.target(@floatFromInt(sum), "sum");
        if (sum >= p.fails_at) return error.SumTooLarge;
    }
};

/// A 48-bit number that fails within a thousand of `needle`, scored by how
/// close it is when `steered`: its distance is exact as an f64.
pub const Needle = struct {
    needle: u48 = 0x1234_5678_9abc,
    steered: bool,

    pub fn body(p: *const Needle, c: *Case) !void {
        const x = gen.int(c.source, u48);
        const distance = if (x > p.needle) x - p.needle else p.needle - x;
        if (p.steered) c.target(-@as(f64, @floatFromInt(distance)), "closeness");
        if (distance < 1000) return error.FoundTheNeedle;
    }
};

/// A producer and a consumer on a simulated clock, each item taking them 1
/// to 4 ms that the simulation's `random` draws: the queue between them
/// fails when it holds `fails_at` items, scored by the most it held.
pub const Queue = struct {
    fails_at: u32,
    steered: bool,
    items: u32 = 64,

    const State = struct { depth: u32 = 0, most: u32 = 0, items: u32 };

    fn pause(io: Io) Io.Cancelable!void {
        var b: [1]u8 = undefined;
        io.random(&b);
        try io.sleep(.fromMilliseconds(1 + b[0] % 4), .awake);
    }

    fn consume(io: Io, s: *State) Io.Cancelable!void {
        for (0..s.items) |_| {
            while (s.depth == 0) try io.sleep(.fromMilliseconds(1), .awake);
            try pause(io);
            s.depth -= 1;
        }
    }

    fn produce(io: Io, s: *State) !void {
        var consumer = try io.concurrent(consume, .{ io, s });
        // glint-ignore: Z026 -- on a failure before the await, the consumer's own end is not the one to report
        defer consumer.cancel(io) catch {};
        for (0..s.items) |_| {
            try pause(io);
            s.depth += 1;
            s.most = @max(s.most, s.depth);
        }
        try consumer.await(io);
    }

    pub fn body(p: *const Queue, c: *Case) !void {
        const sim = try c.sim(.{});
        var state: State = .{ .items = p.items };
        switch (sim.run(produce, .{ sim.io(), &state })) {
            .finished => {},
            else => return error.RunDidNotFinish,
        }
        if (p.steered) c.target(@floatFromInt(state.most), "queue depth");
        if (state.most >= p.fails_at) return error.QueueFull;
    }
};

fn found(ctx: anytype, comptime body: anytype, seed: u64, cases: u32) !bool {
    var report: shakedown.CheckReport = undefined;
    shakedown.check(testing.allocator, ctx, body, .{ .seed = seed, .cases = cases, .diagnostics = &report, .fuzz = false }) catch |err| switch (err) {
        error.PropertyFailed => {
            report.deinit();
            return true;
        },
        else => |e| return e,
    };
    return false;
}

test "random cases miss a sum that a climb toward it reaches, and the report names the climb" {
    // Unsteered, 256 cases come nowhere near; steered, the first half's best
    // list climbs there.
    try testing.expect(!try found(&Sum{ .fails_at = 16_000, .steered = false }, Sum.body, 1, 256));
    var report: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, &Sum{ .fails_at = 16_000, .steered = true }, Sum.body, .{ .seed = 1, .diagnostics = &report, .fuzz = false }));
    defer report.deinit();
    try testing.expectEqual(error.SumTooLarge, report.err);
    try testing.expect(std.mem.find(u8, report.text, "of the climb toward the highest \"sum\"") != null);
    try testing.expect(std.mem.find(u8, report.text, "targets, the highest score a passing case reached:\n    sum: ") != null);
}

test "a climb finds a 48-bit needle that random cases never do" {
    try testing.expect(!try found(&Needle{ .steered = false }, Needle.body, 1, 1000));
    try testing.expect(try found(&Needle{ .steered = true }, Needle.body, 1, 1000));
}

test "a climb steers a simulation's own draws until its queue fills" {
    // The producer's and the consumer's times are the simulation's `random`,
    // drawn from the case's tape: the climb slows the one and speeds the other.
    try testing.expect(!try found(&Queue{ .fails_at = 22, .steered = false }, Queue.body, 0, 2000));
    try testing.expect(try found(&Queue{ .fails_at = 22, .steered = true }, Queue.body, 0, 2000));
}

test "a seed climbs the same way twice" {
    var tapes: [2][]u64 = undefined;
    var reports: [2]shakedown.CheckReport = undefined;
    for (&reports, &tapes) |*report, *tape| {
        try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, &Sum{ .fails_at = 16_000, .steered = true }, Sum.body, .{ .seed = 9, .diagnostics = report, .fuzz = false }));
        tape.* = report.tape;
    }
    defer for (&reports) |*report| report.deinit();
    try testing.expectEqualSlices(u64, tapes[0], tapes[1]);
    try testing.expectEqualStrings(reports[0].text, reports[1].text);
}

const Explored = struct {
    fn body(_: void, c: *Case) !void {
        c.target(@floatFromInt(c.source.below(3)), "anything");
    }
};

test "a target under explore does nothing" {
    const result = try shakedown.explore(testing.allocator, {}, Explored.body, .{});
    try testing.expect(result.complete);
    try testing.expectEqual(@as(u64, 4), result.runs);
}
