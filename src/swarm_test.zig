//! Swarm testing: knobs drawn within their bounds, each off and on across
//! cases, all off at choices of 0, shrinking toward the plain configuration,
//! and nothing drawn under `explore`.
const std = @import("std");
const t = std.testing;
const shakedown = @import("shakedown.zig");
const swarm = @import("swarm.zig");
const Source = shakedown.Source;
const Sim = shakedown.Sim;
const Case = shakedown.Case;

const every_knob: shakedown.Swarm = .{
    .tasks = .{ .min = 1, .max = 8 },
    .latency = .fromMilliseconds(5),
    .loss_per_million = 50_000,
    .duplicate_per_million = 10_000,
    .reorder_per_million = 10_000,
    .late = .fromMilliseconds(2),
    .skew = .{ .real = .fromSeconds(1), .drift_ppm = 100 },
    .storage = .{ .rot_per_million = 100, .latent_error_per_million = 100, .misdirect_per_million = 100, .lost_write_per_million = 100, .sync_lie_per_million = 100 },
    .spurious_wake_per_million = 100_000,
    .yield_per_million = 100_000,
    .async_start = &.{ .eager, .concurrent },
};

test "swarm: bounds of 0 draw nothing and leave the base as it is" {
    var s: Source = try .initRecording(t.allocator, .{ .prng = 1 }, .{});
    defer s.deinit();
    const base: Sim.Options = .{};
    const drawn = swarm.draw(&s, base, .{});
    try t.expectEqual(@as(usize, 0), s.tape().choices.len);
    try t.expectEqual(@as(u32, 1), drawn.knobs.tasks);
    try t.expect(std.meta.eql(base.net.?.default_link, drawn.options.net.?.default_link));
    try t.expect(std.meta.eql(base.fs.?.faults, drawn.options.fs.?.faults));
}

test "swarm: every choice at 0 is the plain configuration: the base, the fewest tasks" {
    var s: Source = try .init(t.allocator, .{ .replay = &.{} });
    defer s.deinit();
    const base: Sim.Options = .{};
    const drawn = swarm.draw(&s, base, every_knob);
    try t.expect(std.meta.eql(swarm.Knobs{ .tasks = 1 }, drawn.knobs));
    try t.expect(std.meta.eql(base.net.?.default_link, drawn.options.net.?.default_link));
    try t.expect(std.meta.eql(base.fs.?.faults, drawn.options.fs.?.faults));
    try t.expectEqual(base.clock.late, drawn.options.clock.late);
    try t.expectEqual(base.spurious_wake_per_million, drawn.options.spurious_wake_per_million);
    try t.expectEqual(base.async_start, drawn.options.async_start);
}

test "swarm: each knob stays within its bound and is off in some cases and on in others" {
    var on: [12]u32 = @splat(0);
    const cases = 400;
    for (0..cases) |seed| {
        var s: Source = try .init(t.allocator, .{ .prng = seed });
        defer s.deinit();
        const d = swarm.draw(&s, .{}, every_knob);
        const k = d.knobs;
        try t.expect(k.tasks >= 1 and k.tasks <= 8);
        try t.expect(k.latency <= 5_000_000 and k.late <= 2_000_000);
        try t.expect(k.loss_per_million <= 50_000 and k.duplicate_per_million <= 10_000 and k.reorder_per_million <= 10_000);
        try t.expect(k.spurious_wake_per_million <= 100_000 and k.yield_per_million <= 100_000);
        inline for (@typeInfo(Sim.Fs.Faults).@"struct".field_names) |field| try t.expect(@field(k.storage, field) <= 100);
        // What the knobs say is what the options carry.
        if (k.loss_per_million != 0) try t.expectEqual(k.loss_per_million, d.options.net.?.default_link.loss_per_million);
        if (k.late != 0) try t.expectEqual(@as(i96, k.late), d.options.clock.late.nanoseconds);
        if (k.latency != 0) try t.expectEqual(@as(i96, 100_000 + k.latency), d.options.net.?.default_link.latency.uniform.max.nanoseconds);
        if (k.async_start) |start| try t.expectEqual(start, d.options.async_start);
        const flags = [_]bool{ k.tasks > 1, k.latency != 0, k.loss_per_million != 0, k.duplicate_per_million != 0, k.reorder_per_million != 0, k.late != 0, k.skew, k.storage.rot_per_million != 0, k.storage.sync_lie_per_million != 0, k.spurious_wake_per_million != 0, k.yield_per_million != 0, k.async_start != null };
        for (flags, &on) |flag, *count| count.* += @intFromBool(flag);
    }
    for (on) |count| try t.expect(count > 0 and count < cases);
}

test "swarm: a sweep's absent subsystems draw nothing: no network, no disk" {
    var s: Source = try .initRecording(t.allocator, .{ .prng = 3 }, .{});
    defer s.deinit();
    const bounds: shakedown.Swarm = .{ .loss_per_million = 1000, .storage = .{ .rot_per_million = 10 } };
    const drawn = swarm.draw(&s, .{ .net = null, .fs = null }, bounds);
    try t.expectEqual(@as(usize, 0), s.tape().choices.len);
    try t.expect(std.meta.eql(swarm.Knobs{ .tasks = 1 }, drawn.knobs));
}

/// Fails only with three tasks or more and a lossy link: the minimal case
/// is exactly three tasks, loss at its smallest, every other knob off.
fn needsLossAndThree(_: void, c: *Case) !void {
    const s = try c.swarm(.{}, every_knob);
    if (s.tasks >= 3 and s.knobs.loss_per_million != 0) return error.LostUnderLoad;
}

test "swarm: a failing case shrinks toward the plain configuration, keeping only the knobs it needs" {
    var report: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, shakedown.check(t.allocator, {}, needsLossAndThree, .{ .seed = 11, .diagnostics = &report, .fuzz = false }));
    defer report.deinit();
    try t.expectEqual(error.LostUnderLoad, report.err);
    var s: Source = try .init(t.allocator, .{ .replay = report.tape });
    defer s.deinit();
    const k = swarm.draw(&s, .{}, every_knob).knobs;
    try t.expect(std.meta.eql(swarm.Knobs{ .tasks = 3, .loss_per_million = 1 }, k));
}

const Explored = struct {
    runs: u32 = 0,
    fn body(e: *Explored, c: *Case) !void {
        const s = try c.swarm(.{}, every_knob);
        e.runs += 1;
        if (!std.meta.eql(swarm.Knobs{ .tasks = 1 }, s.knobs)) return error.Drew;
    }
};

test "swarm: under explore it draws nothing and gives the base" {
    var e: Explored = .{};
    const result = try shakedown.explore(t.allocator, &e, Explored.body, .{});
    try t.expect(result.complete);
    try t.expectEqual(@as(u32, 1), e.runs);
}

test "swarm: a node made through the swarm takes a drawn clock when skew is on, the simulation's when off" {
    var skewed = false;
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var s: Source = try .init(t.allocator, .{ .prng = seed });
        defer s.deinit();
        const drawn = swarm.draw(&s, .{ .source = &s }, every_knob);
        const sim = try Sim.init(t.allocator, drawn.options);
        defer sim.deinit();
        const swarmed: shakedown.Swarmed = .{ .sim = sim, .tasks = drawn.knobs.tasks, .knobs = drawn.knobs, .skew = every_knob.skew };
        const n = try swarmed.node("b", .{});
        const apart = n.now(.real).nanoseconds != sim.now(.real).nanoseconds;
        if (!drawn.knobs.skew) try t.expect(!apart);
        skewed = skewed or apart;
    }
    try t.expect(skewed);
}
