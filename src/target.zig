//! Targeted search: steering `check` toward cases that score higher.
//!
//! A property reports a score per label (`Case.target`). `Targets` keeps,
//! for each label, the highest score a passing case reached and that case's
//! tape. `climb` then hill-climbs a label's best tape (targeted property
//! testing, Löscher and Sagonas, ISSTA 2017, here over the tape): each span's
//! children written twice, a list's elements doubled; then from the last
//! choice back, each choice jumped to its bound and to 0, then raised and
//! lowered by the largest step that raises the score, found by an
//! exponential then a binary search. It knows nothing of what the choices
//! mean, so it steers a property's inputs and its simulation's schedules,
//! faults and latencies alike.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const Tape = Source.Tape;
const shrink = @import("shrink.zig");

/// A label's best case so far: its score and its tape.
pub const Best = struct {
    score: f64,
    choices: []u64,
    bounds: []u64,
    spans: []Tape.Span,

    fn of(gpa: Allocator, score: f64, tape: Tape) Allocator.Error!Best {
        const choices = try gpa.dupe(u64, tape.choices);
        errdefer gpa.free(choices);
        const bounds = try gpa.dupe(u64, tape.bounds);
        errdefer gpa.free(bounds);
        return .{ .score = score, .choices = choices, .bounds = bounds, .spans = try gpa.dupe(Tape.Span, tape.spans) };
    }

    fn deinit(b: *Best, gpa: Allocator) void {
        gpa.free(b.choices);
        gpa.free(b.bounds);
        gpa.free(b.spans);
        b.* = undefined;
    }

    /// Whether a case scoring `score` with `choices` beats this one: a higher
    /// score, or the same one on a simpler tape (shortlex).
    fn beatenBy(b: *const Best, score: f64, choices: []const u64) bool {
        if (score != b.score) return score > b.score;
        return shrink.simpler(choices, b.choices);
    }
};

/// The labels a run's cases reported and the best case of each.
pub const Targets = struct {
    gpa: Allocator,
    /// Each label, owned, in the order first reported.
    labels: std.ArrayList([]u8) = .empty,
    /// Per label: the highest score the current case reported.
    seen: std.ArrayList(?f64) = .empty,
    /// Per label: the best passing case, once one reported it.
    best: std.ArrayList(?Best) = .empty,

    pub fn init(gpa: Allocator) Targets {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Targets) void {
        for (t.labels.items) |label| t.gpa.free(label);
        for (t.best.items) |*best| if (best.*) |*b| b.deinit(t.gpa);
        t.labels.deinit(t.gpa);
        t.seen.deinit(t.gpa);
        t.best.deinit(t.gpa);
        t.* = undefined;
    }

    /// A new case begins: it has reported nothing.
    pub fn startCase(t: *Targets) void {
        @memset(t.seen.items, null);
    }

    /// The current case reached `score` on `label`; a label reported again
    /// keeps its highest.
    pub fn observe(t: *Targets, score: f64, label: []const u8) Allocator.Error!void {
        const i = try t.index(label);
        const seen = &t.seen.items[i];
        seen.* = if (seen.*) |s| @max(s, score) else score;
    }

    fn index(t: *Targets, label: []const u8) Allocator.Error!usize {
        for (t.labels.items, 0..) |have, i| if (std.mem.eql(u8, have, label)) return i;
        try t.labels.ensureUnusedCapacity(t.gpa, 1);
        try t.seen.ensureUnusedCapacity(t.gpa, 1);
        try t.best.ensureUnusedCapacity(t.gpa, 1);
        t.labels.appendAssumeCapacity(try t.gpa.dupe(u8, label));
        t.seen.appendAssumeCapacity(null);
        t.best.appendAssumeCapacity(null);
        return t.labels.items.len - 1;
    }

    /// The current case passed, drawing `tape`: each label it reported
    /// keeps it as its best when it beats the best so far.
    pub fn record(t: *Targets, tape: Tape) Allocator.Error!void {
        for (t.seen.items, t.best.items) |seen, *best| {
            const score = seen orelse continue;
            if (best.*) |*b| if (!b.beatenBy(score, tape.choices)) continue;
            const better: Best = try .of(t.gpa, score, tape);
            if (best.*) |*b| b.deinit(t.gpa);
            best.* = better;
        }
    }

    /// The score the current case reported on label `i`.
    pub fn reported(t: *const Targets, i: usize) ?f64 {
        return t.seen.items[i];
    }

    /// Whether any case has reported a label and passed.
    pub fn any(t: *const Targets) bool {
        for (t.best.items) |best| if (best != null) return true;
        return false;
    }
};

/// What a replay of a candidate did.
pub const Ran = union(enum) {
    /// It failed the property: the climb ends, and its caller reports it.
    failed,
    /// It passed or was discarded, scoring this on the label climbed (null
    /// when it did not report it, or was discarded) and drawing this tape,
    /// valid until the next replay.
    ran: struct { score: ?f64, tape: Tape },
};

/// Replays a candidate tape.
pub const Probe = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, choices: []const u64) Allocator.Error!Ran,
};

/// How a climb ended.
pub const Climbed = enum {
    /// Its score rose, and no choice raises it further.
    improved,
    /// No choice raised its score.
    flat,
    /// A replay failed the property.
    failed,
    /// Its replays ran out first.
    spent,
};

/// Strict improvements a climb makes before it yields to the next label.
pub const max_improvements = 100;

/// Hill-climbs `start`, the best case of the label the probe scores, in at
/// most `budget.*` replays, counting them off it.
pub fn climb(gpa: Allocator, start: *const Best, probe: Probe, budget: *u32) Allocator.Error!Climbed {
    var c: Climb = .{ .gpa = gpa, .probe = probe, .budget = budget, .score = start.score };
    c.choices = try .initCapacity(gpa, start.choices.len);
    defer c.choices.deinit(gpa);
    c.bounds = try .initCapacity(gpa, start.bounds.len);
    defer c.bounds.deinit(gpa);
    c.spans = try .initCapacity(gpa, start.spans.len);
    defer c.spans.deinit(gpa);
    c.choices.appendSliceAssumeCapacity(start.choices);
    c.bounds.appendSliceAssumeCapacity(start.bounds);
    c.spans.appendSliceAssumeCapacity(start.spans);
    c.candidate = try .initCapacity(gpa, start.choices.len);
    defer c.candidate.deinit(gpa);

    var improvements: u32 = 0;
    var i = c.choices.items.len;
    var scan_begins = true;
    while (i > 0 and improvements < max_improvements) {
        // A scan begins with the spans doubled: the one move that grows a
        // list by its whole length in a replay.
        if (scan_begins) {
            scan_begins = false;
            try c.repeatSpans();
            const rose = c.improved > 0;
            improvements += c.improved;
            c.improved = 0;
            if (c.stop) |stop| return stop;
            if (rose) {
                i = c.choices.items.len;
                scan_begins = true;
                continue;
            }
        }
        i -= 1;
        for ([_]Direction{ .up, .down }) |direction| {
            c.at = i;
            c.base = c.choices.items[i];
            c.direction = direction;
            if (!try c.jump()) try c.findStep();
            const rose = c.improved > 0;
            improvements += c.improved;
            c.improved = 0;
            if (c.stop) |stop| return stop;
            // A rise may open choices already passed over: start again from
            // the end. Moving the risen choice back the other way would
            // mostly replay the tape it rose from.
            if (rose) {
                i = c.choices.items.len;
                scan_begins = true;
                break;
            }
            if (i >= c.choices.items.len) break;
        }
    }
    return if (improvements > 0) .improved else .flat;
}

const Direction = enum { up, down };

/// One climb's state: its current tape, and the step being searched.
const Climb = struct {
    gpa: Allocator,
    probe: Probe,
    budget: *u32,
    score: f64,
    choices: std.ArrayList(u64) = .empty,
    bounds: std.ArrayList(u64) = .empty,
    spans: std.ArrayList(Tape.Span) = .empty,
    candidate: std.ArrayList(u64) = .empty,
    /// The choice being moved, its value when the search began, and which way.
    at: usize = 0,
    base: u64 = 0,
    direction: Direction = .up,
    /// Strict improvements made by the current search.
    improved: u32 = 0,
    /// Set when the climb must end.
    stop: ?Climbed = null,

    /// The choice moved all the way, to its bound or to 0, kept when the
    /// score does not fall: a higher score, or the same one on a tape no
    /// longer, a plateau crossed. A yes-or-no draw is a threshold inside a
    /// wide range (`more`, `chance`), where a step search would spend some
    /// forty replays to cross from one answer to the other.
    fn jump(c: *Climb) Allocator.Error!bool {
        const to: u64 = switch (c.direction) {
            .up => c.bounds.items[c.at],
            .down => 0,
        };
        if (to == c.base) return false;
        return c.attempt(to, .level);
    }

    /// The largest step `k` that raises the
    /// score, trying 1 to 4, then doubling, then halving the gap, so a step
    /// of `k` costs about `2 log k` replays.
    fn findStep(c: *Climb) Allocator.Error!void {
        var k: u64 = 1;
        while (k <= 4) : (k += 1) if (!try c.step(k)) return;
        var lo: u64 = 4;
        var hi: u64 = 8;
        while (try c.step(hi)) {
            lo = hi;
            hi = std.math.mul(u64, hi, 2) catch return;
        }
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try c.step(mid)) lo = mid else hi = mid;
        }
    }

    fn step(c: *Climb, k: u64) Allocator.Error!bool {
        const value = switch (c.direction) {
            .up => std.math.add(u64, c.base, k) catch return false,
            .down => std.math.sub(u64, c.base, k) catch return false,
        };
        return c.attempt(value, .rise);
    }

    /// What a move must do to the score to be kept: raise it, or not lower
    /// it on a tape no longer.
    const Keep = enum { rise, level };

    /// Each span with two children or more, from the last back, with its
    /// children but the last written again after themselves: a list's
    /// elements twice, its closing choice after them. The first that
    /// raises the score is kept.
    fn repeatSpans(c: *Climb) Allocator.Error!void {
        var s = c.spans.items.len;
        while (s > 0) {
            s -= 1;
            const outer = c.spans.items[s];
            // Spans are kept in the order they began, so a span's own are
            // the deeper ones after it; its children are one level down.
            // The last is left out, so the run ends where it starts.
            var children: u32 = 0;
            var run_start: u32 = 0;
            var run_end: u32 = 0;
            for (c.spans.items[s + 1 ..]) |inner| {
                if (inner.depth <= outer.depth) break;
                if (inner.depth != outer.depth + 1) continue;
                if (children == 0) run_start = inner.start;
                children += 1;
                run_end = inner.start;
            }
            if (children < 2 or run_end <= run_start) continue;
            try c.candidate.ensureTotalCapacity(c.gpa, c.choices.items.len + (run_end - run_start));
            c.candidate.clearRetainingCapacity();
            c.candidate.appendSliceAssumeCapacity(c.choices.items[0..run_end]);
            c.candidate.appendSliceAssumeCapacity(c.choices.items[run_start..run_end]);
            c.candidate.appendSliceAssumeCapacity(c.choices.items[run_end..]);
            if (try c.replay(.rise)) return;
            if (c.stop != null) return;
        }
    }

    /// Replays the current tape with the choice set to `value`, and keeps
    /// the result as `keep` says. False when the value is past the choice's
    /// bound, the climb must stop, or the result is not kept.
    fn attempt(c: *Climb, value: u64, keep: Keep) Allocator.Error!bool {
        if (c.stop != null or c.at >= c.choices.items.len) return false;
        if (value > c.bounds.items[c.at]) return false;
        c.candidate.clearRetainingCapacity();
        c.candidate.appendSliceAssumeCapacity(c.choices.items);
        c.candidate.items[c.at] = value;
        return c.replay(keep);
    }

    /// Replays `candidate`, and keeps the result as `keep` says.
    fn replay(c: *Climb, keep: Keep) Allocator.Error!bool {
        if (c.budget.* == 0) {
            c.stop = .spent;
            return false;
        }
        c.budget.* -= 1;
        const ran = switch (try c.probe.run(c.probe.ctx, c.candidate.items)) {
            .failed => {
                c.stop = .failed;
                return false;
            },
            .ran => |r| r,
        };
        const score = ran.score orelse return false;
        if (score < c.score) return false;
        if (score == c.score and (keep == .rise or ran.tape.choices.len > c.choices.items.len)) return false;
        if (score > c.score) c.improved += 1;
        c.score = score;
        try c.adopt(ran.tape);
        return true;
    }

    fn adopt(c: *Climb, tape: Tape) Allocator.Error!void {
        try c.choices.ensureTotalCapacity(c.gpa, tape.choices.len);
        try c.bounds.ensureTotalCapacity(c.gpa, tape.bounds.len);
        try c.spans.ensureTotalCapacity(c.gpa, tape.spans.len);
        try c.candidate.ensureTotalCapacity(c.gpa, tape.choices.len);
        c.choices.clearRetainingCapacity();
        c.bounds.clearRetainingCapacity();
        c.spans.clearRetainingCapacity();
        c.choices.appendSliceAssumeCapacity(tape.choices);
        c.bounds.appendSliceAssumeCapacity(tape.bounds);
        c.spans.appendSliceAssumeCapacity(tape.spans);
    }
};

/// A probe for the tests: a list of bytes drawn with `more`, scored by its
/// sum, failing when the sum reaches `fails_at`. Each replay's draws past
/// its tape come from a generator seeded by the replay's number.
const SumProbe = struct {
    source: Source,
    fails_at: u64 = std.math.maxInt(u64),
    runs: u32 = 0,
    top: f64 = 0,

    fn init(gpa: Allocator) Allocator.Error!SumProbe {
        return .{ .source = try .initRecording(gpa, .{ .prng = 0 }, .{}) };
    }

    fn run(ctx: *anyopaque, choices: []const u64) Allocator.Error!Ran {
        const p: *SumProbe = @ptrCast(@alignCast(ctx)); // aegis: no-danger: the tests pair this function with a SumProbe
        p.runs += 1;
        p.source.restart(.{ .extend = .{ .choices = choices, .seed = p.runs } });
        var sum: u64 = 0;
        while (p.source.more(4)) sum += p.source.below(255);
        if (sum >= p.fails_at) return .failed;
        p.top = @max(p.top, @as(f64, @floatFromInt(sum)));
        return .{ .ran = .{ .score = @floatFromInt(sum), .tape = p.source.tape() } };
    }

    fn probe(p: *SumProbe) Probe {
        return .{ .ctx = p, .run = run };
    }

    fn best(p: *SumProbe, gpa: Allocator, choices: []const u64) Allocator.Error!Best {
        const ran = try run(p, choices);
        return .of(gpa, ran.ran.score.?, ran.ran.tape);
    }
};

test "a climb raises each choice as far as the score keeps rising, and lengthens a list for a higher score" {
    const gpa = std.testing.allocator;
    var p: SumProbe = try .init(gpa);
    defer p.source.deinit();
    // Two bytes, 3 and 10, and the list's end: `more` goes on at 200_000
    // and above, for an average of 4.
    var start = try p.best(gpa, &.{ 999_999, 3, 999_999, 10, 0 });
    defer start.deinit(gpa);
    var budget: u32 = 2_000;
    // It makes its hundred rises before its replays run out.
    try std.testing.expectEqual(Climbed.improved, try climb(gpa, &start, p.probe(), &budget));
    try std.testing.expect(budget > 0);
    // The list grew past its two bytes, both raised to 255.
    try std.testing.expect(p.top > 4 * 255);
}

test "a climb stops at the replay that fails, and when its replays run out" {
    const gpa = std.testing.allocator;
    var p: SumProbe = try .init(gpa);
    defer p.source.deinit();
    var start = try p.best(gpa, &.{ 999_999, 3, 999_999, 10, 0 });
    defer start.deinit(gpa);
    p.fails_at = 400;
    var budget: u32 = 10_000;
    try std.testing.expectEqual(Climbed.failed, try climb(gpa, &start, p.probe(), &budget));
    try std.testing.expect(budget > 10_000 - 10);

    p.fails_at = std.math.maxInt(u64);
    p.runs = 0;
    var few: u32 = 3;
    try std.testing.expectEqual(Climbed.spent, try climb(gpa, &start, p.probe(), &few));
    try std.testing.expectEqual(@as(u32, 0), few);
    try std.testing.expectEqual(@as(u32, 3), p.runs);
}

/// A probe for the tests: a list of bytes in spans, as `gen.slice` draws
/// one, scored by its sum.
const ListProbe = struct {
    source: Source,
    top: f64 = 0,

    fn run(ctx: *anyopaque, choices: []const u64) Allocator.Error!Ran {
        const p: *ListProbe = @ptrCast(@alignCast(ctx)); // aegis: no-danger: the test pairs this function with a ListProbe
        p.source.restart(.{ .replay = choices });
        const list = p.source.begin();
        var sum: u64 = 0;
        while (true) {
            const item = p.source.begin();
            defer p.source.end(item);
            if (!p.source.more(4)) break;
            sum += p.source.below(255);
        }
        p.source.end(list);
        p.top = @max(p.top, @as(f64, @floatFromInt(sum)));
        return .{ .ran = .{ .score = @floatFromInt(sum), .tape = p.source.tape() } };
    }
};

test "a climb first writes a list's elements twice, in one replay" {
    const gpa = std.testing.allocator;
    var p: ListProbe = .{ .source = try .initRecording(gpa, .{ .prng = 0 }, .{}) };
    defer p.source.deinit();
    const ran = try ListProbe.run(&p, &.{ 999_999, 3, 999_999, 10, 999_999, 7, 0 });
    var start: Best = try .of(gpa, ran.ran.score.?, ran.ran.tape);
    defer start.deinit(gpa);
    try std.testing.expectEqual(@as(f64, 20), start.score);
    var budget: u32 = 1;
    try std.testing.expectEqual(Climbed.spent, try climb(gpa, &start, .{ .ctx = &p, .run = ListProbe.run }, &budget));
    try std.testing.expectEqual(@as(f64, 40), p.top);
}

/// A probe whose score is the first choice alone, below 1000, and whose
/// later draws score nothing.
const FirstProbe = struct {
    source: Source,
    runs: u32 = 0,

    fn run(ctx: *anyopaque, choices: []const u64) Allocator.Error!Ran {
        const p: *FirstProbe = @ptrCast(@alignCast(ctx)); // aegis: no-danger: the test pairs this function with a FirstProbe
        p.runs += 1;
        p.source.restart(.{ .replay = choices });
        const first = p.source.below(999);
        _ = p.source.below(9);
        return .{ .ran = .{ .score = @floatFromInt(first), .tape = p.source.tape() } };
    }
};

test "a climb at its maximum is flat, within each choice's bound, and pays a few replays a choice" {
    const gpa = std.testing.allocator;
    var p: FirstProbe = .{ .source = try .initRecording(gpa, .{ .prng = 0 }, .{}) };
    defer p.source.deinit();
    const ran = try FirstProbe.run(&p, &.{ 999, 4 });
    var start: Best = try .of(gpa, ran.ran.score.?, ran.ran.tape);
    defer start.deinit(gpa);
    p.runs = 0;
    var budget: u32 = 10_000;
    try std.testing.expectEqual(Climbed.flat, try climb(gpa, &start, .{ .ctx = &p, .run = FirstProbe.run }, &budget));
    // The first choice is at its bound; each direction of each choice is a
    // jump and a step, at most.
    try std.testing.expect(p.runs <= 2 * 2 * 2);
}

test "a label keeps its highest score in a case, and its best is the highest case, simplest on a tie" {
    const gpa = std.testing.allocator;
    var t: Targets = .init(gpa);
    defer t.deinit();
    t.startCase();
    try t.observe(3, "depth");
    try t.observe(7, "depth");
    try t.observe(1, "depth");
    try std.testing.expectEqual(@as(?f64, 7), t.reported(0));
    try t.record(.{ .choices = &.{ 5, 5 }, .bounds = &.{ 9, 9 } });
    t.startCase();
    try std.testing.expectEqual(@as(?f64, null), t.reported(0));
    try t.observe(7, "depth");
    try t.record(.{ .choices = &.{ 5, 4 }, .bounds = &.{ 9, 9 } });
    try std.testing.expectEqualSlices(u64, &.{ 5, 4 }, t.best.items[0].?.choices);
    t.startCase();
    try t.observe(6, "depth");
    try t.observe(1, "other");
    try t.record(.{ .choices = &.{1}, .bounds = &.{9} });
    try std.testing.expectEqual(@as(f64, 7), t.best.items[0].?.score);
    try std.testing.expectEqual(@as(f64, 1), t.best.items[1].?.score);
    try std.testing.expect(t.any());
}
