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
    try shakedown.check(testing.allocator, &ctx, Commutes.body, .{ .cases = 100, .seed = 1, .fuzz = false });
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
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .seed = 7, .diagnostics = &report, .fuzz = false }));
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
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .seed = 7, .diagnostics = &report, .fuzz = false }));
    defer report.deinit();
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.print("{f}", .{shakedown.Tape{ .choices = report.tape }});

    var again: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .regressions = &.{text.written()}, .cases = 0, .diagnostics = &again, .fuzz = false }));
    defer again.deinit();
    try testing.expectEqualSlices(u64, report.tape, again.tape);
    try testing.expect(std.mem.find(u8, again.text, "regression 0") != null);

    try testing.expectError(error.InvalidTape, shakedown.check(testing.allocator, {}, sumBelow300, .{ .regressions = &.{"not a tape"}, .fuzz = false }));
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
    try testing.expectError(error.Unsatisfiable, shakedown.check(testing.allocator, {}, wantsEven, .{ .cases = 10, .fuzz = false }));
}

test "a tape as fuzz input draws the same choices under Smith" {
    var recording: Source = try .initRecording(testing.allocator, .{ .prng = 11 }, .{});
    defer recording.deinit();
    var drawn: [32]u64 = undefined;
    for (&drawn, 0..) |*d, i| d.* = recording.below(@as(u64, 1) << @intCast((i * 2) % 64));
    const input = try shakedown.corpus.fromTape(testing.allocator, recording.tape().choices);
    defer testing.allocator.free(input);
    var smith: std.testing.Smith = .{ .in = input };
    var fuzzed: Source = try .init(testing.allocator, .{ .smith = &smith });
    defer fuzzed.deinit();
    for (drawn, 0..) |d, i| try testing.expectEqual(d, fuzzed.below(@as(u64, 1) << @intCast((i * 2) % 64)));
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
    try shakedown.check(testing.allocator, &first, Commutes.body, .{ .cases = 5, .seed = 99, .fuzz = false });
    var second: Commutes = .{};
    try shakedown.check(testing.allocator, &second, Commutes.body, .{ .cases = 5, .seed = 99, .fuzz = false });
    try testing.expectEqual(first.cases, second.cases);
}

const SimCases = struct {
    cases: u32 = 0,

    fn body(self: *SimCases, c: *Case) !void {
        const sim = try c.sim(.{});
        try testing.expectEqual(shakedown.Sim.Outcome.finished, sim.run(nothing, .{sim.io()}));
        // The run's watchdog watches it: it started no thread of its own.
        try testing.expect(sim.own_watchdog.started() == null);
        try testing.expect(sim.watched_by != null);
        self.cases += 1;
    }

    fn nothing(_: std.Io) void {}
};

test "every case's simulation shares the run's one watchdog" {
    var ctx: SimCases = .{};
    try shakedown.check(testing.allocator, &ctx, SimCases.body, .{ .cases = 20, .seed = 3, .fuzz = false });
    try testing.expectEqual(@as(u32, 20), ctx.cases);
}

fn groupWork(_: void, c: *Case) !void {
    const n = gen.intRange(c.source, usize, 1, 8);
    const io = c.io();
    var sums: [8]u64 = @splat(0);
    var group: std.Io.Group = .init;
    for (sums[0..n], 0..) |*sum, i| group.async(io, struct {
        fn add(out: *u64, k: usize) void {
            out.* = k * k;
        }
    }.add, .{ sum, i });
    try group.await(io);
    for (sums[0..n], 0..) |sum, i| try testing.expectEqual(i * i, sum);
}

test "a case's Io runs its group's tasks, and under the fuzzer they end with the input" {
    try shakedown.check(testing.allocator, {}, groupWork, .{ .cases = 64 });
}

/// Draws a digit and marks what it reached: below five, and, never, past
/// a hundred.
const Digits = struct {
    cases: u32 = 0,

    fn body(self: *Digits, c: *Case) !void {
        self.cases += 1;
        const digit = c.source.below(9);
        if (digit < 5) c.reached("a digit below five");
        if (digit > 100) c.reached("a digit past a hundred");
        c.reached("a label no option names");
    }
};

test "a point no passing case reaches fails the run, naming it, after every case ran" {
    var ctx: Digits = .{};
    var report: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, &ctx, Digits.body, .{
        .cases = 50,
        .seed = 4,
        .reach = &.{ "a digit below five", "a digit past a hundred" },
        .diagnostics = &report,
        .fuzz = false,
    }));
    defer report.deinit();
    try testing.expectEqual(@as(u32, 50), ctx.cases);
    try testing.expectEqual(error.Unreached, report.err);
    try testing.expectEqual(@as(usize, 0), report.tape.len);
    try testing.expect(std.mem.find(u8, report.text, "1 of 2 points") != null);
    try testing.expect(std.mem.find(u8, report.text, "never reached:\n    a digit past a hundred\n") != null);
    try testing.expect(std.mem.find(u8, report.text, "below five") == null);

    // The same seed reports the same way.
    var again: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, &ctx, Digits.body, .{
        .cases = 50,
        .seed = 4,
        .reach = &.{ "a digit below five", "a digit past a hundred" },
        .diagnostics = &again,
        .fuzz = false,
    }));
    defer again.deinit();
    try testing.expectEqualStrings(report.text, again.text);
}

test "every point reached passes, and a label the options do not name is not kept" {
    var ctx: Digits = .{};
    try shakedown.check(testing.allocator, &ctx, Digits.body, .{ .cases = 50, .seed = 4, .reach = &.{"a digit below five"}, .fuzz = false });
    // With no points named, marking costs nothing and fails nothing.
    try shakedown.check(testing.allocator, &ctx, Digits.body, .{ .cases = 50, .seed = 4, .fuzz = false });
}

/// Marks a point only in cases it then discards: a discarded case's points
/// do not count.
fn reachesThenDiscards(_: void, c: *Case) !void {
    if (c.source.below(1) == 1) {
        c.reached("only discarded");
        return error.Unsatisfiable;
    }
}

test "a point reached only by discarded cases is not reached" {
    var report: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, reachesThenDiscards, .{ .cases = 40, .seed = 2, .reach = &.{"only discarded"}, .diagnostics = &report, .fuzz = false }));
    defer report.deinit();
    try testing.expectEqual(error.Unreached, report.err);
}

/// A simulated task marks the point: a waiter woken by a timeout rather
/// than by its signal, which happens only when the signaller sleeps long.
const TimedOut = struct {
    fn waiter(c: *Case, io: std.Io, event: *std.Io.Event) !void {
        event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => c.reached("the waiter timed out"),
            else => |e| return e,
        };
    }

    fn main(c: *Case, io: std.Io, delay: u64) !void {
        var event: std.Io.Event = .unset;
        var task = try io.concurrent(waiter, .{ c, io, &event });
        try io.sleep(.fromMilliseconds(@intCast(delay)), .awake);
        event.set(io);
        try task.await(io);
    }

    fn body(_: void, c: *Case) !void {
        const delay = c.source.below(9);
        const sim = try c.sim(.{});
        switch (sim.run(main, .{ c, sim.io(), delay })) {
            .finished => {},
            .failed => |err| return err,
            else => return error.Unexpected,
        }
    }
};

test "a simulated task marks a point, and the run counts it" {
    try shakedown.check(testing.allocator, {}, TimedOut.body, .{ .cases = 30, .seed = 6, .reach = &.{"the waiter timed out"}, .fuzz = false });
}

/// `sumBelow300` with a point: a list of three elements or more.
fn sumBelow300Reaching(_: void, c: *Case) !void {
    const list = try gen.slice(c.source, u8, byteList, c.gpa, .{});
    if (list.len >= 3) c.reached("a long list");
    var sum: u32 = 0;
    for (list) |x| sum += x;
    if (sum >= 300) return error.SumTooLarge;
}

test "a failing case found with points to reach shrinks as without them and replays to the same failure" {
    var plain: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300, .{ .seed = 7, .diagnostics = &plain, .fuzz = false }));
    defer plain.deinit();
    var reaching: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300Reaching, .{ .seed = 7, .reach = &.{"a long list"}, .diagnostics = &reaching, .fuzz = false }));
    defer reaching.deinit();
    // Marking draws nothing: the same cases, the same minimal tape.
    try testing.expectEqual(error.SumTooLarge, reaching.err);
    try testing.expectEqualSlices(u64, plain.tape, reaching.tape);
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.print("{f}", .{shakedown.Tape{ .choices = reaching.tape }});
    var replayed: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, sumBelow300Reaching, .{ .regressions = &.{text.written()}, .cases = 0, .reach = &.{"a long list"}, .diagnostics = &replayed, .fuzz = false }));
    defer replayed.deinit();
    try testing.expectEqual(error.SumTooLarge, replayed.err);
    try testing.expectEqualSlices(u64, reaching.tape, replayed.tape);
}
