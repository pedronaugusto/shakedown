//! `check`: a property run as many seeded cases, its failures shrunk.
//!
//! The body draws what it needs from its `Case`'s source, through `gen` or
//! directly, and fails by returning an error. `check` runs the committed
//! regressions first, then fresh cases, each from its own seed mixed from
//! the run's. On a failure it shrinks the case's tape, replays the minimal
//! tape once more for its notes and its error return trace, prints all of
//! it with the line that replays it, and returns `error.PropertyFailed`.
//!
//! Built for the fuzzer (`zig build test --fuzz`), `check` hands the body
//! to `std.testing.fuzz` instead, with the regressions as its corpus and a
//! source that reads the fuzzer's input; a failure the fuzzer finds prints
//! as a tape the normal run then shrinks.
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const Tape = Source.Tape;
const shrinker = @import("shrink.zig");
const corpus = @import("corpus.zig");

/// One run of a property's body.
pub const Case = struct {
    /// Every draw of the case comes from here.
    source: *Source,
    /// An arena, emptied after each case.
    gpa: Allocator,
    /// Private: the run this case belongs to.
    runner: *Runner,

    /// Kept, and printed, only for the final, minimal failing case.
    pub fn note(c: *Case, comptime fmt: []const u8, args: anytype) void {
        const notes = &(c.runner.notes orelse return);
        // ziglint-ignore: Z026 a note that cannot be kept is lost; the failure itself is still reported
        notes.print(c.runner.gpa, "    " ++ fmt ++ "\n", args) catch {};
    }
};

pub const CheckOptions = struct {
    /// Fresh cases to run. `SHAKEDOWN_CASES` overrides it.
    cases: u32 = 256,
    /// The run's seed; `SHAKEDOWN_SEED` overrides it, and without either
    /// the test runner's seed is used.
    seed: ?u64 = null,
    /// Tapes (as `Tape.format` writes them) run first, every time.
    regressions: []const []const u8 = &.{},
    /// Replays the shrinker may make.
    max_shrink_runs: u32 = 5_000,
    /// The most choices a case may draw; a larger one is discarded.
    max_choices: u32 = 1 << 16,
    /// Filled when a case fails, if given, and then nothing is printed.
    /// Free with `CheckReport.deinit`.
    diagnostics: ?*CheckReport = null,
};

/// How a property failed: its minimal tape, and the report `check` prints.
pub const CheckReport = struct {
    /// What the minimal case returned.
    err: anyerror,
    /// The minimal failing tape.
    tape: []u64,
    /// Replays the shrinker made.
    shrink_runs: u32,
    /// The printed report: origin, tape, notes, error return trace.
    text: []u8,
    /// Private: what `tape` and `text` were allocated with.
    gpa: Allocator,

    pub fn deinit(r: *CheckReport) void {
        r.gpa.free(r.tape);
        r.gpa.free(r.text);
        r.* = undefined;
    }
};

/// `PropertyFailed`: a case failed (printed). `Unsatisfiable`: fewer than
/// `cases` valid cases came of ten times as many tries. `InvalidTape`: a
/// regression or `SHAKEDOWN_TAPE` is not a tape.
pub const CheckError = error{ PropertyFailed, OutOfMemory, Unsatisfiable, InvalidTape };

/// Runs `body` on the regressions, then on `cases` fresh cases. A case
/// whose body returns `error.Unsatisfiable`, as a failed `gen.filter`
/// does, is discarded. `SHAKEDOWN_TAPE=<tape>` replays exactly that tape
/// instead, in every property the test binary runs; select one with
/// `-Dtest-filter`.
pub fn check(
    gpa: Allocator,
    ctx: anytype,
    // ziglint-ignore: Z023 the body's type is made from the context's, so it follows it
    comptime body: fn (@TypeOf(ctx), *Case) anyerror!void,
    options: CheckOptions,
) CheckError!void {
    if (builtin.fuzz) return fuzz(gpa, ctx, body, options);
    var runner: Runner = try .init(gpa, options);
    defer runner.deinit();
    const Body = Bound(@TypeOf(ctx), body);
    var bound: Body = .{ .ctx = ctx };
    runner.body = .{ .ctx = &bound, .run = Body.run };

    if (try environment(gpa, "SHAKEDOWN_TAPE")) |text| {
        defer gpa.free(text);
        const choices = Tape.parse(gpa, text) catch |err| return invalid(err);
        defer gpa.free(choices);
        return runner.replayOnly(choices);
    }
    for (options.regressions, 0..) |text, i| {
        const choices = Tape.parse(gpa, text) catch |err| return invalid(err);
        defer gpa.free(choices);
        switch (try runner.once(.{ .replay = choices })) {
            .fail => |err| return runner.failed(err, .{ .regression = i }),
            .pass, .discard => {},
        }
    }
    const seed = try seedOf(gpa, options);
    const cases = (try environmentNumber(gpa, "SHAKEDOWN_CASES")) orelse options.cases;
    var valid: u64 = 0;
    var tries: u64 = 0;
    while (valid < cases) : (tries += 1) {
        if (tries >= @as(u64, cases) * 10) return error.Unsatisfiable;
        // Collections grow over the first half of the cases, so the first
        // failure found is a small one when a small one exists.
        runner.source.setGrowth(@intCast(@min(1000, 2000 * (tries + 1) / @max(cases, 1))));
        switch (try runner.once(.{ .prng = caseSeed(seed, tries) })) {
            .pass => valid += 1,
            .discard => {},
            .fail => |err| return runner.failed(err, .{ .case = .{ .seed = seed, .index = tries, .passed = valid } }),
        }
    }
}

fn invalid(err: Tape.ParseError) CheckError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidTape => error.InvalidTape,
    };
}

/// The seed of case `index`: SplitMix64 of the two. A case replays exactly
/// from its tape, which the report prints.
pub fn caseSeed(seed: u64, index: u64) u64 {
    var x = seed +% index *% 0x9e37_79b9_7f4a_7c15;
    x = (x ^ (x >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    x = (x ^ (x >> 27)) *% 0x94d0_49bb_1331_11eb;
    return x ^ (x >> 31);
}

fn seedOf(gpa: Allocator, options: CheckOptions) CheckError!u64 {
    if (try environmentNumber(gpa, "SHAKEDOWN_SEED")) |seed| return seed;
    return options.seed orelse std.testing.random_seed;
}

/// A variable of the test binary's environment; null outside tests.
fn environment(gpa: Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    if (!builtin.is_test) return null;
    return std.testing.environ.getAlloc(gpa, name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn environmentNumber(gpa: Allocator, name: []const u8) CheckError!?u64 {
    const text = (try environment(gpa, name)) orelse return null;
    defer gpa.free(text);
    return std.fmt.parseUnsigned(u64, std.mem.trim(u8, text, " \t\r\n"), 0) catch error.InvalidTape;
}

/// The body with its context, behind one function pointer.
fn Bound(comptime Ctx: type, comptime body: fn (Ctx, *Case) anyerror!void) type {
    return struct {
        ctx: Ctx,

        const Self = @This();

        fn run(erased: *anyopaque, c: *Case) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(erased)); // safe: `Runner.body` pairs this function with a pointer to its own struct
            return body(self.ctx, c);
        }
    };
}

const Outcome = union(enum) { pass, discard, fail: anyerror };

/// Where a failure came from, for the report.
const Origin = union(enum) {
    regression: usize,
    case: struct { seed: u64, index: u64, passed: u64 },
    replay,
};

/// The state of one `check`: the recording source and the arena every case
/// reuses, and the notes of the final run.
const Runner = struct {
    gpa: Allocator,
    options: CheckOptions,
    source: Source,
    arena: std.heap.ArenaAllocator,
    body: struct { ctx: *anyopaque, run: *const fn (*anyopaque, *Case) anyerror!void } = undefined,
    notes: ?std.ArrayList(u8) = null,
    /// The final run's error return trace, taken before the error is
    /// handled and its frames are let go.
    trace: [32]usize = undefined,
    trace_len: usize = 0,

    fn init(gpa: Allocator, options: CheckOptions) error{OutOfMemory}!Runner {
        return .{
            .gpa = gpa,
            .options = options,
            .source = try .initRecording(gpa, .{ .prng = 0 }, .{ .max_choices = options.max_choices }),
            .arena = .init(gpa),
        };
    }

    fn keepTrace(r: *Runner) void {
        const t = @errorReturnTrace() orelse return;
        const n = @min(t.index, t.instruction_addresses.len, r.trace.len);
        @memcpy(r.trace[0..n], t.instruction_addresses[0..n]);
        r.trace_len = n;
    }

    fn deinit(r: *Runner) void {
        r.source.deinit();
        r.arena.deinit();
        if (r.notes) |*n| n.deinit(r.gpa);
        r.* = undefined;
    }

    /// One case from `backend`. Its tape stays in `r.source` until the next.
    fn once(r: *Runner, backend: Source.Backend) error{OutOfMemory}!Outcome {
        r.source.restart(backend);
        _ = r.arena.reset(.retain_capacity);
        var c: Case = .{ .source = &r.source, .gpa = r.arena.allocator(), .runner = r };
        if (@errorReturnTrace()) |t| t.index = 0;
        const result = r.body.run(r.body.ctx, &c);
        if (r.notes != null) if (result) |_| {} else |_| r.keepTrace();
        if (r.source.overrun()) return .discard;
        result catch |err| return switch (err) {
            error.Unsatisfiable => .discard,
            else => .{ .fail = err },
        };
        return .pass;
    }

    fn replayOnly(r: *Runner, choices: []const u64) CheckError!void {
        switch (try r.once(.{ .replay = choices })) {
            .pass => return,
            .discard => return error.Unsatisfiable,
            .fail => |err| return r.report(err, .replay, choices, 0),
        }
    }

    /// Shrinks the failing case in `r.source`, then reports it.
    fn failed(r: *Runner, err: anyerror, origin: Origin) CheckError {
        const first = r.source.tape();
        const choices = r.gpa.dupe(u64, first.choices) catch return error.OutOfMemory;
        defer r.gpa.free(choices);
        const spans = r.gpa.dupe(Tape.Span, first.spans) catch return error.OutOfMemory;
        defer r.gpa.free(spans);
        const bounds = r.gpa.dupe(u64, first.bounds) catch return error.OutOfMemory;
        defer r.gpa.free(bounds);
        var same: Same = .{ .runner = r, .err = err };
        const result = shrinker.shrink(r.gpa, .{ .choices = choices, .bounds = bounds, .spans = spans }, .{ .ctx = &same, .run = Same.run }, r.options.max_shrink_runs) catch return error.OutOfMemory;
        defer r.gpa.free(result.choices);
        return r.report(err, origin, result.choices, result.runs);
    }

    /// Replays the minimal tape once more, keeping its notes and its error
    /// return trace, and reports the failure: into `diagnostics` when the
    /// options name one, to stderr otherwise.
    fn report(r: *Runner, err: anyerror, origin: Origin, choices: []const u64, shrink_runs: u32) CheckError {
        r.notes = .empty;
        r.trace_len = 0;
        const outcome = r.once(.{ .replay = choices }) catch return error.OutOfMemory;
        var text: std.Io.Writer.Allocating = .init(r.gpa);
        defer text.deinit();
        print(&text.writer, err, origin, choices, shrink_runs, outcome, r.notes.?.items) catch return error.OutOfMemory;
        if (r.trace_len > 0) {
            const t: std.builtin.StackTrace = .{ .instruction_addresses = r.trace[0..r.trace_len], .index = r.trace_len };
            // ziglint-ignore: Z026 a trace that cannot be written leaves the report without it
            std.debug.writeErrorReturnTrace(&t, .{ .writer = &text.writer, .mode = .no_color }) catch {};
        }
        const diagnostics = r.options.diagnostics orelse {
            var buffer: [256]u8 = undefined;
            const stderr = std.debug.lockStderr(&buffer).terminal();
            defer std.debug.unlockStderr();
            // ziglint-ignore: Z026 a report stderr cannot take is lost; the error still fails the test
            stderr.writer.writeAll(text.written()) catch {};
            return error.PropertyFailed;
        };
        const tape = r.gpa.dupe(u64, choices) catch return error.OutOfMemory;
        const owned = text.toOwnedSlice() catch {
            r.gpa.free(tape);
            return error.OutOfMemory;
        };
        diagnostics.* = .{ .err = err, .tape = tape, .shrink_runs = shrink_runs, .text = owned, .gpa = r.gpa };
        return error.PropertyFailed;
    }
};

fn print(w: *std.Io.Writer, err: anyerror, origin: Origin, choices: []const u64, shrink_runs: u32, outcome: Outcome, notes: []const u8) std.Io.Writer.Error!void {
    switch (origin) {
        .regression => |i| try w.print("shakedown: property failed on regression {d}", .{i}),
        .case => |c| try w.print("shakedown: property failed after {d} passing cases (seed 0x{x}, case {d})", .{ c.passed, c.seed, c.index }),
        .replay => try w.writeAll("shakedown: property failed on SHAKEDOWN_TAPE"),
    }
    if (shrink_runs > 0) try w.print(", shrunk in {d} runs", .{shrink_runs});
    try w.print(": error.{t}\n", .{err});
    try w.print("  tape: {f}\n  (SHAKEDOWN_TAPE=<tape> replays it; add it to .regressions to keep it)\n", .{Tape{ .choices = choices }});
    if (notes.len > 0) try w.print("  notes:\n{s}", .{notes});
    switch (outcome) {
        .fail => |again| if (again != err) try w.print("  the replay failed with error.{t} instead\n", .{again}),
        .pass, .discard => try w.writeAll("  the replay did not fail again: the property depends on something outside its source\n"),
    }
}

/// The shrinker's replay: fails the same way when the body returns the
/// same error.
const Same = struct {
    runner: *Runner,
    err: anyerror,

    fn run(ctx: *anyopaque, choices: []const u64) Allocator.Error!shrinker.Verdict {
        const self: *Same = @ptrCast(@alignCast(ctx)); // safe: `shrink` hands back the context `failed` gave it
        const outcome = try self.runner.once(.{ .replay = choices });
        return switch (outcome) {
            .fail => |err| if (err == self.err) .{ .fails = self.runner.source.tape() } else .other,
            .pass, .discard => .other,
        };
    }
};

/// The property under the fuzzer: each input is one case.
fn fuzz(
    gpa: Allocator,
    ctx: anytype,
    // ziglint-ignore: Z023 the body's type is made from the context's, so it follows it
    comptime body: fn (@TypeOf(ctx), *Case) anyerror!void,
    options: CheckOptions,
) CheckError!void {
    var inputs: std.ArrayList([]const u8) = .empty;
    defer {
        for (inputs.items) |input| gpa.free(input);
        inputs.deinit(gpa);
    }
    for (options.regressions) |text| {
        const choices = Tape.parse(gpa, text) catch |err| return invalid(err);
        defer gpa.free(choices);
        const input = try corpus.fromTape(gpa, choices);
        errdefer gpa.free(input);
        try inputs.append(gpa, input);
    }
    var runner: Runner = try .init(gpa, options);
    defer runner.deinit();
    const Body = Bound(@TypeOf(ctx), body);
    var bound: Body = .{ .ctx = ctx };
    runner.body = .{ .ctx = &bound, .run = Body.run };
    std.testing.fuzz(&runner, fuzzOne, .{ .corpus = inputs.items }) catch return error.PropertyFailed;
}

fn fuzzOne(r: *Runner, smith: *std.testing.Smith) anyerror!void {
    switch (try r.once(.{ .smith = smith })) {
        .pass, .discard => {},
        .fail => |err| {
            var buffer: [256]u8 = undefined;
            const stderr = std.debug.lockStderr(&buffer).terminal();
            defer std.debug.unlockStderr();
            try stderr.writer.print("shakedown: the fuzzer found error.{t}; shrink it with SHAKEDOWN_TAPE={f}\n", .{ err, r.source.tape() });
            return err;
        },
    }
}

test "case seeds differ by index and repeat by seed" {
    try std.testing.expectEqual(caseSeed(7, 3), caseSeed(7, 3));
    try std.testing.expect(caseSeed(7, 3) != caseSeed(7, 4));
    try std.testing.expect(caseSeed(7, 3) != caseSeed(8, 3));
}
