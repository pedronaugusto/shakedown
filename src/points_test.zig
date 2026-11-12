//! The fault point driver: inert unless the run names the points, firing in some cases and not
//! others, shrinking to the firings a failure needs, counted, failing a run whose point never
//! fired, marking reach, and answering only on the case's thread or a simulation's task.
const std = @import("std");
const t = std.testing;
const aegis = @import("aegis");
const shakedown = @import("shakedown.zig");
const Case = shakedown.Case;

const Point = enum { append_fails, short_read, slow_path, recovered };
const all = aegis.points.list(Point);

fn faultNever(_: void, _: *Case) !void {
    if (aegis.points.fault(Point.append_fails)) return error.Fired;
}

test "points: a run that names no points leaves every point inert" {
    try shakedown.check(t.allocator, {}, faultNever, .{ .seed = 1, .fuzz = false });
}

/// Meets every point and fails on nothing.
fn meetsAll(_: void, _: *Case) !void {
    for (0..4) |_| {
        _ = aegis.points.fault(Point.append_fails);
        const n = aegis.points.shorten(Point.short_read, 4096);
        if (n < 1 or n > 4096) return error.OutOfBounds;
        aegis.points.yield(Point.slow_path);
    }
    aegis.points.reached(Point.recovered);
}

test "points: named points fire in some cases and not others, and the run counts them" {
    var counts: [4]shakedown.PointCount = undefined;
    try shakedown.check(t.allocator, {}, meetsAll, .{ .seed = 2, .fuzz = false, .points = &.{all}, .points_must_fire = false, .point_counts = &counts });
    for ([_]usize{ 0, 1, 3 }) |i| try t.expect(counts[i].fired_passing > 0);
    // Outside a simulation's task a yield point has no task to yield: met, never armed or fired.
    try t.expect(counts[2].evaluated > 0 and counts[2].armed == 0 and counts[2].fired == 0);
    // Faults and shortenings are armed in some cases only, and fire in only some of those.
    for (counts[0..2]) |count| {
        try t.expect(count.armed > 0 and count.armed < 256);
        try t.expect(count.fired > 0 and count.fired < count.evaluated);
    }
    // A reached point fires each time it is met; it is never armed, it draws nothing.
    try t.expectEqual(counts[3].evaluated, counts[3].fired);
    try t.expectEqualStrings("append_fails", counts[0].point.name);
}

fn failsOnFault(_: void, _: *Case) !void {
    for (0..8) |_| if (aegis.points.fault(Point.append_fails)) return error.AppendFailed;
}

test "points: a failure shrinks to the firing it needs: one arming, one firing" {
    var report: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, shakedown.check(t.allocator, {}, failsOnFault, .{ .seed = 3, .fuzz = false, .points = &.{all}, .points_must_fire = false, .diagnostics = &report }));
    defer report.deinit();
    try t.expectEqual(error.AppendFailed, report.err);
    // The point armed on its first meeting and fired there: two choices, nothing before them.
    try t.expectEqual(@as(usize, 2), report.tape.len);
}

fn meetsOnlyFault(_: void, _: *Case) !void {
    _ = aegis.points.fault(Point.append_fails);
}

test "points: a named point that no passing case fired fails the run, unless the test says otherwise" {
    var report: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, shakedown.check(t.allocator, {}, meetsOnlyFault, .{ .seed = 4, .fuzz = false, .points = &.{all}, .diagnostics = &report }));
    defer report.deinit();
    try t.expectEqual(error.Unfired, report.err);
    try t.expect(std.mem.find(u8, report.text, "short_read: 0, 0, 0, 0  <- never fired") != null);
    try shakedown.check(t.allocator, {}, meetsOnlyFault, .{ .seed = 4, .fuzz = false, .points = &.{all}, .points_must_fire = false });
}

test "points: a fired point marks the reach label of its name" {
    try shakedown.check(t.allocator, {}, meetsOnlyFault, .{ .seed = 5, .fuzz = false, .points = &.{all}, .points_must_fire = false, .reach = &.{@typeName(Point) ++ ".append_fails"} });
    var report: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, shakedown.check(t.allocator, {}, meetsOnlyFault, .{ .seed = 5, .fuzz = false, .points = &.{all}, .points_must_fire = false, .reach = &.{@typeName(Point) ++ ".short_read"}, .diagnostics = &report }));
    defer report.deinit();
    try t.expectEqual(error.Unreached, report.err);
}

/// A real thread of the case's: the driver must not answer there.
fn onThread(fired: *bool) void {
    for (0..1000) |_| if (aegis.points.fault(Point.append_fails)) {
        fired.* = true;
    };
}

fn onThreadAndTask(_: void, c: *Case) !void {
    var fired = false;
    const thread = try std.Thread.spawn(.{}, onThread, .{&fired});
    thread.join();
    if (fired) return error.AnsweredOnAnotherThread;
    const sim = try c.sim(.{});
    switch (sim.run(inTask, .{})) {
        .finished => {},
        else => return error.TaskDidNotFinish,
    }
}

fn inTask() void {
    for (0..64) |_| {
        _ = aegis.points.fault(Point.append_fails);
        aegis.points.yield(Point.slow_path);
    }
}

test "points: the driver answers in a simulation's task, never on another thread of the case" {
    var counts: [4]shakedown.PointCount = undefined;
    try shakedown.check(t.allocator, {}, onThreadAndTask, .{ .seed = 6, .cases = 64, .fuzz = false, .points = &.{all}, .points_must_fire = false, .point_counts = &counts });
    // Every evaluation counted came from a task: 128 a case at most, none of the thread's 1000.
    try t.expect(counts[0].evaluated <= 64 * 64 and counts[0].fired > 0);
    try t.expect(counts[2].fired > 0);
}
