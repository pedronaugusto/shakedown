//! The one source of random decisions in a test.
//!
//! Everything shakedown decides at random draws from a `Source`, so one
//! seed reproduces a whole run. `below` is the primitive; every other draw
//! is made of it, so every decision is a sequence of integer choices, and
//! a choice of 0 is always the simplest one: no fault, no spurious wake,
//! the first task, the end of a list.
//!
//! A source draws from a seeded generator, from the choices of a recorded
//! tape, or from `std.testing.Smith`, so the same property runs as seeded
//! cases and under `zig build test --fuzz`. A recording source keeps every
//! draw on its tape, grouped into the spans that `begin` and `end` mark:
//! the shrinker reduces a failing run by editing that tape and replaying it.
//!
//! The draws are the same on every target and every optimisation mode: the
//! generator is xoshiro256** seeded through SplitMix64, and a bounded draw
//! is Lemire's multiply-and-reject, written out here rather than borrowed
//! from `std.Random`. Replayed and fuzzed draws read a choice the way Smith
//! reads an integer, so a tape written as Smith input (`corpus.fromTape`)
//! replays the same draws.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Source = @This();

/// Private: the allocator the source was made with.
gpa: Allocator,
/// Private: where the choices come from.
from: From,
/// Private: the choices drawn so far, when recording. Its capacity is the
/// most a run may draw.
choices: std.ArrayList(u64) = .empty,
/// Private: the bound each recorded choice was drawn under.
bounds: std.ArrayList(u64) = .empty,
/// Private: the spans begun so far, when recording.
spans: std.ArrayList(Tape.Span) = .empty,
/// Private: how many spans are open.
depth: u16 = 0,
/// Private: whether this source keeps a tape.
recording: bool = false,
/// Private: a recording ran past its limit; every later draw was 0.
overran: bool = false,
/// Private: see `setGrowth`.
growth: u16 = 1000,

/// Where the choices come from.
pub const Backend = union(enum) {
    /// A pseudo-random generator from this seed.
    prng: u64,
    /// The choices of a tape, in order. Past its end, and wherever a choice
    /// is larger than the draw allows, the draw is 0.
    replay: []const u64,
    /// The fuzzer's input. `Smith` reads each draw as an integer.
    smith: *std.testing.Smith,
};

const From = union(enum) {
    prng: std.Random.Xoshiro256,
    replay: struct { choices: []const u64, at: usize = 0 },
    smith: *std.testing.Smith,
};

/// A run's choices, and the spans its generators grouped them into.
pub const Tape = struct {
    choices: []const u64,
    /// The largest value each choice could have taken, when recorded: the
    /// shrinker moves value only between choices of one bound.
    bounds: []const u64 = &.{},
    spans: []const Span = &.{},

    /// The choices one generator call drew: `[start, end)`, at a nesting
    /// depth, an outer span holding the spans of the calls it made.
    pub const Span = struct { start: u32, end: u32, depth: u16 };

    /// The choices as text: lowercase hex, separated by `:`. The spans are
    /// not written; a replay records them again.
    pub fn format(t: Tape, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (t.choices, 0..) |choice, i| {
            if (i > 0) try w.writeByte(':');
            try w.print("{x}", .{choice});
        }
    }

    pub const ParseError = error{ InvalidTape, OutOfMemory };

    /// The choices `text` names, as `format` writes them. Spaces and line
    /// breaks around the text are ignored; empty text is the empty tape.
    pub fn parse(gpa: Allocator, text: []const u8) ParseError![]u64 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return gpa.alloc(u64, 0);
        const out = try gpa.alloc(u64, std.mem.countScalar(u8, trimmed, ':') + 1);
        errdefer gpa.free(out);
        var it = std.mem.splitScalar(u8, trimmed, ':');
        for (out) |*choice| {
            choice.* = std.fmt.parseUnsigned(u64, it.next().?, 16) catch return error.InvalidTape;
        }
        return out;
    }
};

pub const InitError = error{OutOfMemory};

/// A source that keeps nothing: its draws are all it gives.
pub fn init(gpa: Allocator, backend: Backend) InitError!Source {
    return .{ .gpa = gpa, .from = fromBackend(backend) };
}

pub const RecordOptions = struct {
    /// The most choices a run may draw. Past it every draw is 0, which ends
    /// any generator quickly, and `overran` reports it.
    max_choices: u32 = 1 << 16,
};

/// A source that keeps every draw on its tape. The tape's storage is
/// taken here, whole, so a draw never allocates.
pub fn initRecording(gpa: Allocator, backend: Backend, options: RecordOptions) InitError!Source {
    var s: Source = .{ .gpa = gpa, .from = fromBackend(backend), .recording = true };
    s.choices = try .initCapacity(gpa, options.max_choices);
    errdefer s.choices.deinit(gpa);
    s.bounds = try .initCapacity(gpa, options.max_choices);
    errdefer s.bounds.deinit(gpa);
    s.spans = try .initCapacity(gpa, options.max_choices);
    return s;
}

/// Draws from `backend` from here on, and forgets the tape: a recording
/// source reused for another run without allocating.
pub fn restart(s: *Source, backend: Backend) void {
    s.from = fromBackend(backend);
    s.choices.clearRetainingCapacity();
    s.bounds.clearRetainingCapacity();
    s.spans.clearRetainingCapacity();
    s.depth = 0;
    s.overran = false;
}

fn fromBackend(backend: Backend) From {
    return switch (backend) {
        .prng => |seed| .{ .prng = .init(seed) },
        .replay => |choices| .{ .replay = .{ .choices = choices } },
        .smith => |smith| .{ .smith = smith },
    };
}

pub fn deinit(s: *Source) void {
    s.choices.deinit(s.gpa);
    s.bounds.deinit(s.gpa);
    s.spans.deinit(s.gpa);
    s.* = undefined;
}

/// An integer in `[0, max]`, uniformly from a generator; 0 is the simplest.
/// `below(0)` has no choice to make: it draws nothing and is not recorded.
pub fn below(s: *Source, max: u64) u64 {
    if (max == 0) return 0;
    // The generator's own path, kept short: `FaultIo` fills `io.random`
    // through it.
    if (!s.recording) switch (s.from) {
        .prng => |*prng| return lemire(prng, max),
        .replay, .smith => {},
    };
    return s.draw(max, @returnAddress());
}

fn draw(s: *Source, max: u64, site: usize) u64 {
    if (s.full()) return 0;
    const choice = switch (s.from) {
        .prng => |*prng| lemire(prng, max),
        .replay => |*replay| choice: {
            if (replay.at == replay.choices.len) break :choice 0;
            const c = replay.choices[replay.at];
            replay.at += 1;
            break :choice if (c <= max) c else 0;
        },
        .smith => |smith| smith.valueRangeAtMostWithHash(u64, 0, max, @truncate(std.hash.int(@as(u64, site)))),
    };
    return s.keep(choice, max);
}

/// Whether a recording has no room for another choice; it then says so.
fn full(s: *Source) bool {
    if (!s.recording or s.choices.items.len < s.choices.capacity) return false;
    s.overran = true;
    return true;
}

/// Records `choice`, drawn under `max`, when recording, and returns it.
fn keep(s: *Source, choice: u64, max: u64) u64 {
    if (s.recording) {
        s.choices.appendAssumeCapacity(choice);
        s.bounds.appendAssumeCapacity(max);
    }
    return choice;
}

/// An integer in `[0, max]`, drawn the way tests find bugs: about one in
/// five is an edge (0, 1, 2, the largest values, powers of two and their
/// neighbours), and the rest spread over magnitudes, small as often as
/// large. Only the drawing leans: the value is recorded as one choice and
/// replays, fuzzes and shrinks like any other, so an edge shrinks toward
/// its neighbours as smoothly as any value.
pub fn integer(s: *Source, max: u64) u64 {
    if (max == 0) return 0;
    switch (s.from) {
        .prng => |*prng| return if (s.full()) 0 else s.keep(leaning(prng, max), max),
        .replay, .smith => return s.draw(max, @returnAddress()),
    }
}

/// Of every 16 draws, how many are edges.
const edge_share = 3;

fn leaning(prng: *std.Random.Xoshiro256, max: u64) u64 {
    const r = prng.next();
    if (r % 16 < edge_share) {
        var edges: [32]u64 = undefined;
        const n = edgesOf(max, &edges);
        return edges[@intCast((r >> 4) % n)];
    }
    // A width of 8, 16, 32 or 64 bits, as far as `max` reaches, then a
    // value below it: a small value as likely as a large one.
    const reach = 64 - @clz(max);
    const widths = [_]u7{ 8, 16, 32, 64 };
    var count: u64 = 1;
    while (count < widths.len and widths[count - 1] < reach) count += 1;
    const width = widths[@intCast((r >> 8) % count)];
    const cap = if (width >= 64) max else @min(max, (@as(u64, 1) << @intCast(width)) - 1);
    return lemire(prng, cap);
}

/// The edges of `[0, max]`, distinct, into `out`; returns how many.
fn edgesOf(max: u64, out: *[32]u64) usize {
    var n: usize = 0;
    const candidates = [_]u64{ 0, 1, 2, 3, max, max -| 1, max -| 2, max -| 3, max / 2, max / 2 + 1 };
    for (candidates) |c| n = addEdge(out, n, c, max);
    for ([_]u6{ 7, 8, 15, 16, 31, 32, 63 }) |k| {
        const p = @as(u64, 1) << k;
        for ([_]u64{ p - 1, p, p +% 1 }) |c| n = addEdge(out, n, c, max);
    }
    return n;
}

fn addEdge(out: *[32]u64, n: usize, value: u64, max: u64) usize {
    if (value > max or n == out.len) return n;
    for (out[0..n]) |have| if (have == value) return n;
    out[n] = value;
    return n + 1;
}

fn lemire(prng: *std.Random.Xoshiro256, max: u64) u64 {
    if (max == std.math.maxInt(u64)) return prng.next();
    const range = max + 1;
    // Lemire: the high half of x * range is uniform once the low half
    // clears the bias threshold.
    var product = @as(u128, prng.next()) * range;
    if (@as(u64, @truncate(product)) < range) {
        const threshold = (0 -% range) % range;
        while (@as(u64, @truncate(product)) < threshold) product = @as(u128, prng.next()) * range;
    }
    return @intCast(product >> 64);
}

/// True with probability `per_million` in a million. A choice of 0 is
/// false, so a shrunk run keeps only the chances it needs.
pub fn chance(s: *Source, per_million: u32) bool {
    if (per_million == 0) return false;
    if (per_million >= 1_000_000) return true;
    return s.below(999_999) >= 1_000_000 - per_million;
}

/// Fills `out`, one choice per byte.
pub fn bytes(s: *Source, out: []u8) void {
    for (out) |*b| b.* = @intCast(s.below(255));
}

/// One more element of a collection? Lists drawn this way are `average`
/// long on average, and a choice of 0 ends the list.
pub fn more(s: *Source, average: u32) bool {
    if (average == 0) return false;
    // Continue with probability average / (average + 1): a geometric
    // length whose mean is `average`.
    const stop = 1_000_000 / (@as(u64, average) + 1);
    switch (s.from) {
        .prng => |*prng| if (s.growth < 1000) {
            // Smaller lists while the run is young: the decision leans,
            // and the choice recorded is one that reads as that decision.
            if (s.full()) return false;
            const young = 1_000_000_000 / (@as(u64, average) * s.growth + 1000);
            const going = lemire(prng, 999_999) >= young;
            const choice = if (going) stop + lemire(prng, 999_999 - stop) else lemire(prng, stop - 1);
            return s.keep(choice, 999_999) >= stop;
        },
        .replay, .smith => {},
    }
    return s.below(999_999) >= stop;
}

/// How far collections drawn with `more` grow, in thousandths of their
/// average: `check` grows it over a run's first cases, so the first
/// failure found tends to be small. It changes only what a generator
/// draws, never what a recorded choice replays as.
pub fn setGrowth(s: *Source, per_mille: u16) void {
    s.growth = @min(per_mille, 1000);
}

/// Where a span begins, from `begin` to its `end`.
pub const Mark = enum(u32) { none = std.math.maxInt(u32), _ };

/// Starts a span: the draws until its `end` are one generator call's, which
/// the shrinker may delete, zero or reorder as a whole.
pub fn begin(s: *Source) Mark {
    if (!s.recording or s.spans.items.len == s.spans.capacity) return .none;
    const index = s.spans.items.len;
    s.spans.appendAssumeCapacity(.{ .start = @intCast(s.choices.items.len), .end = 0, .depth = s.depth });
    s.depth += 1;
    return @fromBackingInt(@intCast(index));
}

pub fn end(s: *Source, mark: Mark) void {
    if (mark == .none) return;
    s.spans.items[@backingInt(mark)].end = @intCast(s.choices.items.len);
    s.depth -= 1;
}

/// The draws recorded so far, and their spans. Empty when not recording.
/// Valid until the next draw.
pub fn tape(s: *const Source) Tape {
    return .{ .choices = s.choices.items, .bounds = s.bounds.items, .spans = s.spans.items };
}

/// Whether a recording ran past `RecordOptions.max_choices`.
pub fn overrun(s: *const Source) bool {
    return s.overran;
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

test "a recording keeps every draw, and its replay draws them again" {
    var s: Source = try .initRecording(std.testing.allocator, .{ .prng = 5 }, .{});
    defer s.deinit();
    const outer = s.begin();
    const a = s.below(100);
    const inner = s.begin();
    const b = s.below(1 << 40);
    s.end(inner);
    const c = s.chance(500_000);
    s.end(outer);
    const t = s.tape();
    try std.testing.expectEqual(@as(usize, 3), t.choices.len);
    try std.testing.expectEqualSlices(Tape.Span, &.{
        .{ .start = 0, .end = 3, .depth = 0 },
        .{ .start = 1, .end = 2, .depth = 1 },
    }, t.spans);

    var replay: Source = try .init(std.testing.allocator, .{ .replay = t.choices });
    defer replay.deinit();
    try std.testing.expectEqual(a, replay.below(100));
    try std.testing.expectEqual(b, replay.below(1 << 40));
    try std.testing.expectEqual(c, replay.chance(500_000));
    // Past the tape every draw is the simplest.
    try std.testing.expectEqual(@as(u64, 0), replay.below(9));
    try std.testing.expect(!replay.chance(999_999));
    try std.testing.expect(!replay.more(1000));
}

test "a replayed choice too large for its draw is 0, as Smith reads it" {
    var s: Source = try .init(std.testing.allocator, .{ .replay = &.{ 7, 3 } });
    defer s.deinit();
    try std.testing.expectEqual(@as(u64, 0), s.below(5));
    try std.testing.expectEqual(@as(u64, 3), s.below(5));
}

test "a recording past its limit draws zeros and says so" {
    var s: Source = try .initRecording(std.testing.allocator, .{ .prng = 1 }, .{ .max_choices = 4 });
    defer s.deinit();
    for (0..4) |_| _ = s.below(1 << 50);
    try std.testing.expect(!s.overrun());
    try std.testing.expectEqual(@as(u64, 0), s.below(1 << 50));
    try std.testing.expect(s.overrun());
    try std.testing.expectEqual(@as(usize, 4), s.tape().choices.len);
    s.restart(.{ .prng = 2 });
    try std.testing.expect(!s.overrun());
    try std.testing.expectEqual(@as(usize, 0), s.tape().choices.len);
}

test "a tape round-trips through its text" {
    const choices = [_]u64{ 0, 0xa03, 2, std.math.maxInt(u64) };
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{Tape{ .choices = &choices }});
    try std.testing.expectEqualStrings("0:a03:2:ffffffffffffffff", w.buffered());
    const parsed = try Tape.parse(std.testing.allocator, w.buffered());
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqualSlices(u64, &choices, parsed);
    const empty = try Tape.parse(std.testing.allocator, " \n");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidTape, Tape.parse(std.testing.allocator, "1:x"));
    try std.testing.expectError(error.InvalidTape, Tape.parse(std.testing.allocator, "1::2"));
}

test "a list drawn with more is about its average long" {
    var s: Source = try .init(std.testing.allocator, .{ .prng = 3 });
    defer s.deinit();
    var total: u64 = 0;
    const lists = 4000;
    for (0..lists) |_| {
        while (s.more(8)) total += 1;
    }
    // The mean of a geometric length with mean 8 over 4,000 lists lies
    // within 0.6 of it with overwhelming probability.
    const mean = @as(f64, @floatFromInt(total)) / lists;
    try std.testing.expect(mean > 7.4 and mean < 8.6);
}
