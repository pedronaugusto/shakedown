//! The one source of random decisions in a test.
//!
//! Everything shakedown decides at random draws from a `Source`, so one
//! seed reproduces a whole run. `below` is the primitive; `chance` and
//! `bytes` are made of it, so every decision is a sequence of integer
//! choices.
//!
//! The draws are the same on every target and every optimisation mode: the
//! generator is xoshiro256** seeded through SplitMix64, and a bounded draw
//! is Lemire's multiply-and-reject, written out here rather than borrowed
//! from `std.Random`.
const std = @import("std");

const Source = @This();

/// Private: the allocator the source was made with.
gpa: std.mem.Allocator,
/// Private: the generator.
prng: std.Random.Xoshiro256,

/// Where the choices come from.
pub const Backend = union(enum) {
    /// A pseudo-random generator from this seed.
    prng: u64,
};

pub const InitError = error{OutOfMemory};

pub fn init(gpa: std.mem.Allocator, backend: Backend) InitError!Source {
    return switch (backend) {
        .prng => |seed| .{ .gpa = gpa, .prng = .init(seed) },
    };
}

pub fn deinit(s: *Source) void {
    s.* = undefined;
}

/// An integer in `[0, max]`, uniformly.
pub fn below(s: *Source, max: u64) u64 {
    if (max == std.math.maxInt(u64)) return s.prng.next();
    const range = max + 1;
    // Lemire: the high half of x * range is uniform once the low half
    // clears the bias threshold.
    var product = @as(u128, s.prng.next()) * range;
    if (@as(u64, @truncate(product)) < range) {
        const threshold = (0 -% range) % range;
        while (@as(u64, @truncate(product)) < threshold) product = @as(u128, s.prng.next()) * range;
    }
    return @intCast(product >> 64);
}

/// True with probability `per_million` in a million.
pub fn chance(s: *Source, per_million: u32) bool {
    if (per_million == 0) return false;
    if (per_million >= 1_000_000) return true;
    return s.below(999_999) < per_million;
}

/// Fills `out`, one choice per byte.
pub fn bytes(s: *Source, out: []u8) void {
    for (out) |*b| b.* = @intCast(s.below(255));
}

test "the same seed gives the same draws, and another seed others" {
    var a: Source = try .init(std.testing.allocator, .{ .prng = 42 });
    defer a.deinit();
    var b: Source = try .init(std.testing.allocator, .{ .prng = 42 });
    defer b.deinit();
    var c: Source = try .init(std.testing.allocator, .{ .prng = 43 });
    defer c.deinit();
    var differs = false;
    for (0..1000) |i| {
        const max: u64 = i * 7919;
        const x = a.below(max);
        try std.testing.expectEqual(x, b.below(max));
        try std.testing.expect(x <= max);
        differs = differs or x != c.below(max);
    }
    try std.testing.expect(differs);
}

test "draws are fixed for a seed: a change here breaks every recorded seed" {
    var s: Source = try .init(std.testing.allocator, .{ .prng = 0 });
    defer s.deinit();
    var got: [6]u64 = undefined;
    for (&got) |*g| g.* = s.below(1_000_000);
    try std.testing.expectEqualSlices(u64, &golden, &got);
}

/// The first six draws below a million from seed 0.
const golden = [_]u64{ 324575, 382239, 359617, 11455, 495270, 20565 };

test "bounds hold at the edges" {
    var s: Source = try .init(std.testing.allocator, .{ .prng = 7 });
    defer s.deinit();
    for (0..100) |_| try std.testing.expectEqual(@as(u64, 0), s.below(0));
    var seen = [_]bool{ false, false };
    for (0..100) |_| seen[s.below(1)] = true;
    try std.testing.expect(seen[0] and seen[1]);
    _ = s.below(std.math.maxInt(u64));
    try std.testing.expect(!s.chance(0));
    try std.testing.expect(s.chance(1_000_000));
}

test "a bounded draw is uniform" {
    var s: Source = try .init(std.testing.allocator, .{ .prng = 1 });
    defer s.deinit();
    var counts: [6]u32 = @splat(0);
    const n = 60_000;
    for (0..n) |_| counts[s.below(5)] += 1;
    // Each bucket expects 10,000; six standard deviations is about 550.
    for (counts) |count| try std.testing.expect(count > 9_450 and count < 10_550);
    var hits: u32 = 0;
    for (0..n) |_| hits += @intFromBool(s.chance(250_000));
    try std.testing.expect(hits > 14_400 and hits < 15_600);
}
