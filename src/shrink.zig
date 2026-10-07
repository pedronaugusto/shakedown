//! The shrinker: from a failing tape to the smallest one it can find that
//! fails the same way.
//!
//! It knows nothing of what the choices mean. It edits the tape, asks its
//! caller to replay the edit, and keeps an edit only when the replay fails
//! the same way and draws a tape simpler than the best so far. Simpler is
//! shortlex: shorter, then smaller choice by choice. Because generators map
//! smaller choices to simpler values, and a simulation maps a choice of 0
//! to no fault, no wake-up and the first task, shrinking the tape shrinks
//! inputs, fault plans and schedules alike.
//!
//! The cheap passes run until they stop helping: delete spans, delete runs
//! of 8, 4, 2 and 1 choices, zero spans, and minimise each choice by binary
//! search. Only when they stall do the costly ones run: sort adjacent spans
//! of the same length, and move value from one choice to a later one of the
//! same bound. Every replayed tape is remembered, so none is replayed twice.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const Tape = Source.Tape;

/// What a replay of a candidate did.
pub const Verdict = union(enum) {
    /// It failed the same way, drawing this tape (valid until the next replay).
    fails: Tape,
    /// It passed, failed another way, or was discarded.
    other,
};

/// Replays a candidate tape.
pub const Replay = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, choices: []const u64) Allocator.Error!Verdict,
};

pub const Result = struct {
    /// The smallest failing tape found. Owned by the caller.
    choices: []u64,
    /// Replays made.
    runs: u32,
};

pub const Error = Allocator.Error;

/// Shrinks `failing`, the tape of a run that failed, within `max_runs`
/// replays.
pub fn shrink(gpa: Allocator, failing: Tape, replay: Replay, max_runs: u32) Error!Result {
    var s: Shrinker = .{ .gpa = gpa, .replay = replay, .max_runs = max_runs };
    defer s.deinit();
    try s.keep(failing);
    while (s.runs < s.max_runs) {
        const before = s.improvements;
        const len = s.best.items.len;
        try s.deleteSpans();
        try s.deleteRuns();
        try s.zeroSpans();
        try s.minimise();
        // A shorter tape: the cheap passes again first. Values that only
        // crept down may be held by one another, which only the costly
        // passes move together.
        if (s.best.items.len < len) continue;
        try s.passToDescendant();
        try s.sortSpans();
        try s.lowerTogether();
        try s.redistribute();
        try s.deleteAndCompensate();
        if (s.improvements == before) break;
    }
    return .{ .choices = try gpa.dupe(u64, trimmed(s.best.items)), .runs = s.runs };
}

const Shrinker = struct {
    gpa: Allocator,
    replay: Replay,
    max_runs: u32,
    runs: u32 = 0,
    improvements: u32 = 0,
    best: std.ArrayList(u64) = .empty,
    bounds: std.ArrayList(u64) = .empty,
    spans: std.ArrayList(Tape.Span) = .empty,
    candidate: std.ArrayList(u64) = .empty,
    /// Hashes of every tape replayed, so none is replayed twice.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn deinit(s: *Shrinker) void {
        s.best.deinit(s.gpa);
        s.bounds.deinit(s.gpa);
        s.spans.deinit(s.gpa);
        s.candidate.deinit(s.gpa);
        s.seen.deinit(s.gpa);
        s.* = undefined;
    }

    /// Keeps `t` as the best, as it was drawn: a tape without its trailing
    /// zeros replays the same, but only the drawn tapes of two runs order
    /// them as their values do.
    fn keep(s: *Shrinker, t: Tape) Error!void {
        const kept = t.choices;
        s.best.clearRetainingCapacity();
        try s.best.appendSlice(s.gpa, kept);
        s.bounds.clearRetainingCapacity();
        try s.bounds.appendSlice(s.gpa, t.bounds[0..@min(t.bounds.len, kept.len)]);
        s.spans.clearRetainingCapacity();
        try s.spans.appendSlice(s.gpa, t.spans);
    }

    /// The bound choice `i` was drawn under; the largest when not recorded.
    fn bound(s: *const Shrinker, i: usize) u64 {
        return if (i < s.bounds.items.len) s.bounds.items[i] else std.math.maxInt(u64);
    }

    /// Replays `s.candidate`; keeps what it drew when that is simpler and
    /// fails the same way. Returns whether it did.
    fn attempt(s: *Shrinker) Error!bool {
        if (s.runs >= s.max_runs) return false;
        if (!simpler(s.candidate.items, s.best.items)) return false;
        const seen = try s.seen.getOrPut(s.gpa, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(trimmed(s.candidate.items))));
        if (seen.found_existing) return false;
        s.runs += 1;
        const verdict = try s.replay.run(s.replay.ctx, s.candidate.items);
        const drawn = switch (verdict) {
            .fails => |t| t,
            .other => return false,
        };
        if (!simpler(drawn.choices, s.best.items)) return false;
        try s.keep(drawn);
        s.improvements += 1;
        return true;
    }

    fn startCandidate(s: *Shrinker) Error!void {
        s.candidate.clearRetainingCapacity();
        try s.candidate.appendSlice(s.gpa, s.best.items);
    }

    /// Deletes each span whole, the last first: removing an element of a
    /// list removes its choice to continue too.
    fn deleteSpans(s: *Shrinker) Error!void {
        var i = s.spans.items.len;
        while (i > 0) {
            i -= 1;
            if (i >= s.spans.items.len) continue;
            const span = s.spans.items[i];
            if (span.end <= span.start or span.end > s.best.items.len) continue;
            try s.startCandidate();
            s.candidate.replaceRangeAssumeCapacity(span.start, span.end - span.start, &.{});
            _ = try s.attempt();
        }
    }

    /// Deletes runs of 8, 4, 2 and 1 choices at every position.
    fn deleteRuns(s: *Shrinker) Error!void {
        for ([_]usize{ 8, 4, 2, 1 }) |k| {
            var at = s.best.items.len;
            while (at >= k) : (at -= 1) {
                if (at > s.best.items.len) continue;
                try s.startCandidate();
                s.candidate.replaceRangeAssumeCapacity(at - k, k, &.{});
                _ = try s.attempt();
            }
        }
    }

    fn zeroSpans(s: *Shrinker) Error!void {
        var i: usize = 0;
        while (i < s.spans.items.len) : (i += 1) {
            const span = s.spans.items[i];
            if (span.end > s.best.items.len) continue;
            if (std.mem.allEqual(u64, s.best.items[span.start..span.end], 0)) continue;
            try s.startCandidate();
            @memset(s.candidate.items[span.start..span.end], 0);
            _ = try s.attempt();
        }
    }

    /// Each choice down as far as it goes: 0 first, then a binary search
    /// between the largest value known to pass and the smallest known to fail.
    fn minimise(s: *Shrinker) Error!void {
        var i: usize = 0;
        while (i < s.best.items.len) : (i += 1) {
            if (s.best.items[i] == 0) continue;
            if (try s.tryValue(i, 0)) continue;
            var low: u64 = 0;
            while (i < s.best.items.len and s.best.items[i] > low + 1 and s.runs < s.max_runs) {
                const high = s.best.items[i];
                const mid = low + (high - low) / 2;
                if (!try s.tryValue(i, mid)) low = mid;
            }
        }
    }

    fn tryValue(s: *Shrinker, i: usize, value: u64) Error!bool {
        try s.startCandidate();
        s.candidate.items[i] = value;
        return s.attempt();
    }

    /// Replaces each span with one of the spans inside it: a tree by one of
    /// its subtrees, a wrapper by what it wraps.
    fn passToDescendant(s: *Shrinker) Error!void {
        var i: usize = 0;
        while (i < s.spans.items.len) : (i += 1) {
            const outer = s.spans.items[i];
            if (outer.end > s.best.items.len) continue;
            var tried: usize = 0;
            var k = i + 1;
            while (k < s.spans.items.len and tried < 16) : (k += 1) {
                const inner = s.spans.items[k];
                if (inner.start >= outer.end) break;
                if (inner.end > outer.end or inner.depth <= outer.depth) continue;
                if (inner.end - inner.start == outer.end - outer.start) continue;
                tried += 1;
                try s.startCandidate();
                const kept = s.best.items[inner.start..inner.end];
                s.candidate.replaceRangeAssumeCapacity(outer.start, outer.end - outer.start, kept);
                if (try s.attempt()) break;
            }
        }
    }

    /// Deletes each span and then pushes one of the next eight choices as
    /// far as it goes, then down as far as it still fails: two small values
    /// that together make what one larger value can.
    fn deleteAndCompensate(s: *Shrinker) Error!void {
        var i = s.spans.items.len;
        while (i > 0) {
            i -= 1;
            if (i >= s.spans.items.len) continue;
            const span = s.spans.items[i];
            const width = span.end - span.start;
            if (width == 0 or span.end > s.best.items.len) continue;
            if (try s.deleteShifting(span)) continue;
            var j = span.end;
            while (j < s.best.items.len and j < span.end + 8) : (j += 1) {
                if (try s.deleteSetting(span, j, s.bound(j))) {
                    try s.minimiseAt(j - width);
                    break;
                }
            }
        }
    }

    /// Deletes a span and lowers by one every later choice drawn under the
    /// bound of its last: an element gone from a list of indices into the
    /// list moves every index after it down one.
    fn deleteShifting(s: *Shrinker, span: Tape.Span) Error!bool {
        const kind = s.bound(span.end - 1);
        var any = false;
        try s.startCandidate();
        for (s.candidate.items[span.end..], span.end..) |*c, j| {
            if (s.bound(j) == kind and c.* > 0) {
                c.* -= 1;
                any = true;
            }
        }
        if (!any) return false;
        s.candidate.replaceRangeAssumeCapacity(span.start, span.end - span.start, &.{});
        return s.attempt();
    }

    fn deleteSetting(s: *Shrinker, span: Tape.Span, j: usize, value: u64) Error!bool {
        try s.startCandidate();
        s.candidate.items[j] = value;
        s.candidate.replaceRangeAssumeCapacity(span.start, span.end - span.start, &.{});
        return s.attempt();
    }

    /// The binary search of `minimise`, for one choice.
    fn minimiseAt(s: *Shrinker, i: usize) Error!void {
        var low: u64 = 0;
        while (i < s.best.items.len and s.best.items[i] > low + 1 and s.runs < s.max_runs) {
            const high = s.best.items[i];
            const mid = low + (high - low) / 2;
            if (!try s.tryValue(i, mid)) low = mid;
        }
    }

    /// Sorts each run of adjacent sibling spans of one length by their
    /// choices, all at once and then pair by pair.
    fn sortSpans(s: *Shrinker) Error!void {
        var i: usize = 0;
        while (i + 1 < s.spans.items.len) : (i += 1) {
            var j = i;
            while (j + 1 < s.spans.items.len and sibling(s.spans.items[j], s.spans.items[j + 1])) j += 1;
            if (j == i) continue;
            try s.sortRun(i, j);
        }
    }

    fn sibling(a: Tape.Span, b: Tape.Span) bool {
        return a.depth == b.depth and a.end == b.start and a.end - a.start == b.end - b.start and a.end > a.start;
    }

    fn sortRun(s: *Shrinker, first: usize, last: usize) Error!void {
        if (last >= s.spans.items.len or s.spans.items[last].end > s.best.items.len) return;
        const width = s.spans.items[first].end - s.spans.items[first].start;
        const start = s.spans.items[first].start;
        const count = last - first + 1;
        try s.startCandidate();
        const region = s.candidate.items[start..][0 .. width * count];
        // Insertion sort of `count` blocks of `width` choices.
        var k: usize = 1;
        while (k < count) : (k += 1) {
            var m = k;
            while (m > 0 and lessBlock(region, width, m, m - 1)) : (m -= 1) swapBlocks(region, width, m, m - 1);
        }
        if (try s.attempt()) return;
        var a: usize = 0;
        while (a + 1 < count) : (a += 1) {
            if (first + a + 1 >= s.spans.items.len or s.spans.items[first + a + 1].end > s.best.items.len) return;
            try s.startCandidate();
            const blocks = s.candidate.items[start..][0 .. width * count];
            if (!lessBlock(blocks, width, a + 1, a)) continue;
            swapBlocks(blocks, width, a, a + 1);
            _ = try s.attempt();
        }
    }

    /// Lowers each choice and one of the next eight drawn under the same
    /// bound by one amount: values that must stay equal, or a set distance
    /// apart, shrink together where neither can alone.
    fn lowerTogether(s: *Shrinker) Error!void {
        var i: usize = 0;
        while (i < s.best.items.len) : (i += 1) {
            var j = i + 1;
            while (j < s.best.items.len and j <= i + 8) : (j += 1) {
                if (s.bound(i) != s.bound(j)) continue;
                var amount = @min(s.best.items[i], s.best.items[j]);
                // After each success, as far again from where it landed.
                while (amount > 0 and s.runs < s.max_runs) {
                    if (try s.tryLower(i, j, amount)) {
                        if (j >= s.best.items.len) break;
                        amount = @min(s.best.items[i], s.best.items[j]);
                    } else amount /= 2;
                }
            }
        }
    }

    fn tryLower(s: *Shrinker, i: usize, j: usize, amount: u64) Error!bool {
        if (j >= s.best.items.len) return false;
        try s.startCandidate();
        s.candidate.items[i] -= amount;
        s.candidate.items[j] -= amount;
        return s.attempt();
    }

    /// Moves value from each choice to one of the next eight drawn under the
    /// same bound: the earlier smaller, the later larger by as much. All of
    /// it first, then half as much, and so on.
    fn redistribute(s: *Shrinker) Error!void {
        var i: usize = 0;
        while (i < s.best.items.len) : (i += 1) {
            var j = i + 1;
            while (j < s.best.items.len and j <= i + 8) : (j += 1) {
                if (s.best.items[i] == 0) break;
                if (s.bound(i) != s.bound(j)) continue;
                try s.move(i, j);
            }
        }
    }

    /// All of choice `i` that `j` has room for, then half as much, and so
    /// on, until one fails the same way.
    fn move(s: *Shrinker, i: usize, j: usize) Error!void {
        var amount = @min(s.best.items[i], s.bound(j) - s.best.items[j]);
        while (amount > 0 and s.runs < s.max_runs) {
            if (try s.tryMove(i, j, amount)) {
                if (j >= s.best.items.len) return;
                amount = @min(s.best.items[i], s.bound(j) - s.best.items[j]);
            } else amount /= 2;
        }
    }

    fn tryMove(s: *Shrinker, i: usize, j: usize, amount: u64) Error!bool {
        if (j >= s.best.items.len) return false;
        try s.startCandidate();
        s.candidate.items[i] -= amount;
        s.candidate.items[j] += amount;
        return s.attempt();
    }
};

fn lessBlock(region: []const u64, width: usize, a: usize, b: usize) bool {
    return std.mem.order(u64, region[a * width ..][0..width], region[b * width ..][0..width]) == .lt;
}

fn swapBlocks(region: []u64, width: usize, a: usize, b: usize) void {
    for (region[a * width ..][0..width], region[b * width ..][0..width]) |*x, *y| std.mem.swap(u64, x, y);
}

/// `choices` without its trailing zeros.
pub fn trimmed(choices: []const u64) []const u64 {
    var n = choices.len;
    while (n > 0 and choices[n - 1] == 0) n -= 1;
    return choices[0..n];
}

/// Shortlex: shorter is simpler, then smaller at the first difference.
pub fn simpler(a: []const u64, b: []const u64) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u64, a, b) == .lt;
}

test "shortlex orders by length, then choice by choice" {
    try std.testing.expect(simpler(&.{9}, &.{ 0, 0 }));
    try std.testing.expect(simpler(&.{ 1, 2 }, &.{ 1, 3 }));
    try std.testing.expect(!simpler(&.{ 1, 3 }, &.{ 1, 3 }));
}

/// A replay for the tests: the "property" fails when the sum of a list of
/// bytes, drawn with `more`, reaches a threshold.
const SumAtLeast = struct {
    threshold: u64,
    source: Source,

    fn run(ctx: *anyopaque, choices: []const u64) Allocator.Error!Verdict {
        const self: *SumAtLeast = @ptrCast(@alignCast(ctx)); // safe: the test hands its own context to `shrink`
        self.source.restart(.{ .replay = choices });
        var sum: u64 = 0;
        const list = self.source.begin();
        while (true) {
            const item = self.source.begin();
            defer self.source.end(item);
            if (!self.source.more(4)) break;
            sum += self.source.below(255);
        }
        self.source.end(list);
        return if (sum >= self.threshold) .{ .fails = self.source.tape() } else .other;
    }
};

test "a failing list shrinks to the fewest, smallest elements that still fail" {
    var ctx: SumAtLeast = .{ .threshold = 300, .source = try .initRecording(std.testing.allocator, .{ .prng = 0 }, .{}) };
    defer ctx.source.deinit();
    // A run with many elements that sums past the threshold.
    var start: std.ArrayList(u64) = .empty;
    defer start.deinit(std.testing.allocator);
    for (0..12) |i| try start.appendSlice(std.testing.allocator, &.{ 999_999, 50 + i * 7 });
    const first = try SumAtLeast.run(&ctx, start.items);
    const gpa = std.testing.allocator;
    const choices = try gpa.dupe(u64, first.fails.choices);
    defer gpa.free(choices);
    const bounds = try gpa.dupe(u64, first.fails.bounds);
    defer gpa.free(bounds);
    const spans = try gpa.dupe(Tape.Span, first.fails.spans);
    defer gpa.free(spans);
    const result = try shrink(gpa, .{ .choices = choices, .bounds = bounds, .spans = spans }, .{ .ctx = &ctx, .run = SumAtLeast.run }, 5000);
    defer gpa.free(result.choices);
    // Two elements at the smallest "continue" choice: 45 + 255 = 300.
    const stop = 1_000_000 / 5;
    try std.testing.expectEqualSlices(u64, &.{ stop, 45, stop, 255 }, result.choices);
}
