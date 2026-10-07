//! `check` and `gen` from outside: properties that pass, properties that
//! fail and shrink to their minimal case, regressions, notes, filters, the
//! tape as fuzz input, and the edge bias of the generators.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const gen = shakedown.gen;
const Case = shakedown.Case;
const Source = shakedown.Source;

const Commutes = struct {
    cases: u32 = 0,

    fn body(self: *Commutes, c: *Case) !void {
        self.cases += 1;
        const a = gen.int(c.source, i32);
        const b = gen.int(c.source, i32);
        try testing.expectEqual(a +% b, b +% a);
    }
};

test "a property that holds runs every case and passes" {
    var ctx: Commutes = .{};
    try shakedown.check(testing.allocator, &ctx, Commutes.body, .{ .cases = 100, .seed = 1 });
    try testing.expectEqual(@as(u32, 100), ctx.cases);
}

fn byteList(s: *Source) u8 {
    return gen.int(s, u8);
}

/// Fails once a list of bytes sums to 300: the minimal case is two
/// elements, the larger 255, the other as small as it can be.
fn sumBelow300(_: void, c: *Case) !void {
    const list = try gen.slice(c.source, u8, byteList, c.gpa, .{});
    var sum: u32 = 0;
    for (list) |x| sum += x;
    c.note("list {any} sums to {d}", .{ list, sum });
    if (sum >= 300) return error.SumTooLarge;
}

test "a failing property shrinks to its minimal case, with notes, and returns PropertyFailed" {
    var report: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .seed = 7, .diagnostics = &report }));
    defer report.deinit();
    try testing.expectEqual(error.SumTooLarge, report.err);
    // Replayed, the minimal tape draws the minimal list.
    var s: Source = try .init(testing.allocator, .{ .replay = report.tape });
    defer s.deinit();
    const list = try gen.slice(&s, u8, byteList, testing.allocator, .{});
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(u32, 300), @as(u32, list[0]) + list[1]);
    try testing.expect(std.mem.find(u8, report.text, "sums to 300") != null);
    try testing.expect(std.mem.find(u8, report.text, "tape: ") != null);
}

test "a regression runs first and fails at once, and a fixed one passes" {
    var report: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .seed = 7, .diagnostics = &report }));
    defer report.deinit();
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.print("{f}", .{shakedown.Tape{ .choices = report.tape }});

    var again: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .regressions = &.{text.written()}, .cases = 0, .diagnostics = &again }));
    defer again.deinit();
    try testing.expectEqualSlices(u64, report.tape, again.tape);
    try testing.expect(std.mem.find(u8, again.text, "regression 0") != null);

    try testing.expectError(error.InvalidTape, shakedown.check(testing.allocator, {}, sumBelow300, .{ .regressions = &.{"not a tape"} }));
}

fn neverEven(s: *Source) u8 {
    return gen.int(s, u8) | 1;
}

fn isEven(x: u8) bool {
    return x % 2 == 0;
}

fn wantsEven(_: void, c: *Case) !void {
    _ = try gen.filter(c.source, u8, neverEven, isEven, 10);
}

test "a filter nothing passes makes the property unsatisfiable" {
    try testing.expectError(error.Unsatisfiable, shakedown.check(testing.allocator, {}, wantsEven, .{ .cases = 10 }));
}

test "a tape as fuzz input draws the same choices under Smith" {
    var recording: Source = try .initRecording(testing.allocator, .{ .prng = 11 }, .{});
    defer recording.deinit();
    var drawn: [32]u64 = undefined;
    for (&drawn, 0..) |*d, i| d.* = recording.below(@as(u64, 1) << @intCast(i * 2 % 64));
    const input = try shakedown.corpus.fromTape(testing.allocator, recording.tape().choices);
    defer testing.allocator.free(input);
    var smith: std.testing.Smith = .{ .in = input };
    var fuzzed: Source = try .init(testing.allocator, .{ .smith = &smith });
    defer fuzzed.deinit();
    for (drawn, 0..) |d, i| try testing.expectEqual(d, fuzzed.below(@as(u64, 1) << @intCast(i * 2 % 64)));
}

test "integers lean on their edges, and every width shows up" {
    var s: Source = try .init(testing.allocator, .{ .prng = 5 });
    defer s.deinit();
    var zeros: u32 = 0;
    var maxes: u32 = 0;
    var small: u32 = 0;
    var large: u32 = 0;
    const n = 100_000;
    for (0..n) |_| {
        const x = gen.int(&s, u32);
        zeros += @intFromBool(x == 0);
        maxes += @intFromBool(x == std.math.maxInt(u32));
        small += @intFromBool(x < 256);
        large += @intFromBool(x >= 1 << 24);
    }
    // An edge draw is 3 in 16, and u32 has 25 edges, so 0 and the maximum
    // each come about 0.75% of the time, where a uniform u32 would show
    // neither at all.
    try testing.expect(zeros > n / 200 and zeros < n * 3 / 200);
    try testing.expect(maxes > n / 200 and maxes < n * 3 / 200);
    // The rest draw one of three widths (8, 16, 32 bits): with the small
    // edges, about a third of all values fall below 256.
    try testing.expect(small > n / 4 and small < n * 2 / 5);
    try testing.expect(large > n / 5);
}

test "a seed draws the same cases every time" {
    var first: Commutes = .{};
    try shakedown.check(testing.allocator, &first, Commutes.body, .{ .cases = 5, .seed = 99 });
    var second: Commutes = .{};
    try shakedown.check(testing.allocator, &second, Commutes.body, .{ .cases = 5, .seed = 99 });
    try testing.expectEqual(first.cases, second.cases);
}

const SimCases = struct {
    cases: u32 = 0,

    fn body(self: *SimCases, c: *Case) !void {
        const sim = try c.sim(.{});
        try testing.expectEqual(shakedown.Sim.Outcome.finished, sim.run(nothing, .{sim.io()}));
        // The run's watchdog watches it: it started no thread of its own.
        try testing.expect(sim.own_watchdog.thread == null);
        try testing.expect(sim.watched_by != null);
        self.cases += 1;
    }

    fn nothing(_: std.Io) void {}
};

test "every case's simulation shares the run's one watchdog" {
    var ctx: SimCases = .{};
    try shakedown.check(testing.allocator, &ctx, SimCases.body, .{ .cases = 20, .seed = 3 });
    try testing.expectEqual(@as(u32, 20), ctx.cases);
}
