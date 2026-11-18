//! `everyFault`: every single fault at every step of an operation.
//!
//! One clean run records the operation's calls. Then, for each step and
//! each fault that applies to the call made there, a fresh run injects that
//! fault at that step and the caller's `check` judges the result. Every
//! faulted run must make the same calls as the clean run up to its step;
//! one that does not fails the whole as `Nondeterministic`, naming the
//! first record that differed, so a faulted run never silently tests the
//! wrong call. Every run's `io.random` draws from the same seed, so a
//! name drawn from it is the same in every run.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const io_call = @import("../io_call.zig");
const IoCall = io_call.IoCall;
const IoFault = io_call.IoFault;
const FaultIo = @import("../FaultIo.zig");
const IoTrace = FaultIo.IoTrace;
const Sim = @import("../Sim.zig");

/// One of `count` contiguous ranges of a sweep's points, so a long
/// operation's sweep runs as several tests, each well inside a watchdog:
/// shard `index` takes the points from `points * index / count` up to the
/// next shard's first. `everyFault`'s points are the clean run's steps,
/// `everyCrash`'s its crash points.
pub const Shard = struct {
    index: u32 = 0,
    count: u32 = 1,

    /// The points, numbered from 0 of `points`, this shard explores.
    pub fn range(s: Shard, points: u64) struct { first: u64, end: u64 } {
        return .{ .first = s.boundary(points, s.index), .end = s.boundary(points, s.index + 1) };
    }
    fn boundary(s: Shard, points: u64, at: u32) u64 {
        return points / s.count * at + (points % s.count) * at / s.count;
    }
    /// Whether `index` names one of `count` shards.
    pub fn valid(s: Shard) bool {
        return s.count != 0 and s.index < s.count;
    }
};

/// What `everyFault` tries, and what it keeps when a run fails.
pub const EveryFaultOptions = struct {
    /// Errors tried at every step whose call can return them.
    errors: []const anyerror = &.{ error.InputOutput, error.NoSpaceLeft, error.AccessDenied },
    /// Reads and writes that moved bytes: `short(0)` (not on a positional
    /// read, where it is the end of the file), and `short(half)`.
    short: bool = true,
    /// `cancel` at every cancelation point. A run whose cancel could not
    /// land, under blocked cancel protection, is checked as a clean run.
    cancel: bool = true,
    /// Errors tried as lost answers (`fail_after`): the call is made, then
    /// returns the error, at every step whose call can.
    lost_answers: []const anyerror = &.{},
    /// `fail(OutOfMemory)` at every call through `FaultIo.allocator`.
    alloc: bool = true,
    /// Every run's `io.random` and `randomSecure` draw from a generator
    /// seeded with this, so a name drawn from them is the same name in
    /// every run and the determinism check holds. A run never sees the
    /// base's randomness.
    random_seed: u64 = 0,
    /// A clean run longer than this is refused as `TooManySteps`.
    max_steps: u64 = 100_000,
    /// What a failing run's trace keeps for the report.
    trace: IoTrace.Mode = .{ .last = 64 },
    /// Filled when a run fails, if given. Free with `EveryFaultReport.deinit`.
    diagnostics: ?*EveryFaultReport = null,
    /// The steps this call faults: one of `count` contiguous ranges of the
    /// clean run's steps. Every shard makes the clean run, which each
    /// faulted run is held to.
    shard: Shard = .{},
    /// Each run, the clean one and every faulted one, on a fresh `Sim`
    /// made with these options: the same seed, so the same schedule, and
    /// the run's one fault planned as the simulation's fault part. `setUp`,
    /// `run`, `check` and `tearDown` run inside the simulation's root task,
    /// and the `base` `everyFault` is given is not used. Code that runs
    /// tasks concurrently is then swept in one order its seed draws, the
    /// same order every run, where on a real `Io` the order is the
    /// machine's and a faulted run may part from the clean one for that
    /// alone; other seeds explore other orders. Null runs on `base`.
    sim: ?Sim.Options = null,
};

/// Why `everyFault` failed: a run failed its check (or its `setUp`), a
/// faulted run left the clean run's calls, the clean run took more than
/// `max_steps`, or memory ran out.
pub const EveryFaultError = error{ OutOfMemory, Nondeterministic, CheckFailed, TooManySteps };

/// The fault a run injected, and where.
pub const Injected = struct { step: u64, call: IoCall, fault: IoFault };

/// What `everyFault` did: the clean run's steps, the runs made and, when
/// one failed, how.
pub const EveryFaultReport = struct {
    /// Steps in the clean run.
    steps: u64 = 0,
    /// Runs made, the clean one included.
    runs: u64 = 0,
    /// everyCrash: crash points at which the state bound stopped exploration.
    bounded: u64 = 0,
    /// everyCrash: crash states an earlier point already recovered, whose
    /// recovery is not made again: a state recovers as it did.
    repeated: u64 = 0,
    /// everyFault: calls a faulted run made as the clean run did, before its
    /// fault's step, that were still waiting when the fault fired, so their
    /// outcomes were not compared (an accept, a read another task waits on).
    excused: u64 = 0,
    failure: ?Failure = null,
    /// Private: what `failure.trace` was allocated with.
    gpa: ?Allocator = null,

    pub const Failure = struct {
        /// Null when the clean run failed its check.
        injected: ?Injected,
        /// What `check` (or `setUp`) returned, or `error.Nondeterministic`.
        err: anyerror,
        /// For `Nondeterministic`: the first record of the failing run that
        /// the clean run did not have.
        difference: ?u64 = null,
        /// The failing run's trace, one line per record.
        trace: []const u8,
    };

    pub fn deinit(r: *EveryFaultReport) void {
        if (r.failure) |f| if (r.gpa) |gpa| gpa.free(f.trace);
        r.* = undefined;
    }
};

/// Runs the operation `ctx` describes once clean, then once per single
/// fault at each of its steps. `ctx` is
/// a pointer to a struct with:
///
///     fn setUp(ctx, fio: *FaultIo) anyerror!void      fresh state for each run
///     fn run(ctx, io: Io) anyerror!void               the operation under test
///     fn check(ctx, io: Io, result: anyerror!void, injected: ?Injected) anyerror!void
///     fn tearDown(ctx) void
///     fn faultsFor(ctx, record: IoTrace.Record) []const IoFault   optional, for a seam's calls
///
/// `check` gets the run's `Io` and judges what the operation left behind;
/// it fails the whole by returning an error. Its `injected` is the fault
/// the run was given, or null for the clean run and for a cancel that
/// could not land. `check` runs before
/// `tearDown`, and `tearDown` follows every run whose `setUp` succeeded.
/// Allocation is faulted through the allocators `setUp` makes with
/// `fio.allocator`.
///
/// Make every call through the faulted `Io`, and every allocation through
/// `fio.allocator`, inside `run`: a second request, a client's or a server's
/// teardown included. A faulted run is held to the clean run's calls when
/// `run` returns, but the clean run's trace keeps whatever `check` and
/// `tearDown` call through it too, so each of those calls becomes a step
/// whose fault never fires in time and the run is called `Nondeterministic`.
/// Keep what `run` saw in `ctx`, and let `check` judge that; it may make
/// calls of its own on an `Io` no fault reaches.
///
/// Faulted runs are compared with the clean run by step, not by the order
/// calls returned in: a fault that ends a waiting call early (an accept, a
/// read another task waits on) moves its record and nothing else. Up to the
/// fault's step a run makes exactly the clean run's calls, and every call
/// that returned before the fault fired returned as it did; a call still
/// waiting then is excused its outcome and counted in `excused`.
pub fn everyFault(gpa: Allocator, base: Io, ctx: anytype, options: EveryFaultOptions) EveryFaultError!EveryFaultReport {
    if (!options.shard.valid()) return error.CheckFailed;
    var report: EveryFaultReport = .{};
    const clean_run = try Run.init(gpa, base, options, &report, .all, &.{});
    defer clean_run.deinit();
    const clean = clean_run.fio;
    try clean_run.once(gpa, ctx, options, &report, null);
    report.steps = clean.steps().peek();
    if (report.steps > options.max_steps) return error.TooManySteps;

    const records = clean.trace().records();
    const range = options.shard.range(records.len);
    // The clean run's calls by step, for each faulted run to be held to.
    const by_step = gpa.dupe(Entry, clean.trace().entriesKept().?) catch return error.OutOfMemory;
    defer gpa.free(by_step);
    std.mem.sort(Entry, by_step, {}, earlier);
    var faults: [max_faults]IoFault = undefined;
    for (records[@intCast(range.first)..@intCast(range.end)]) |record| {
        for (candidates(ctx, options, record, &faults)) |fault| {
            const injected: Injected = .{ .step = record.step, .call = record.event.call, .fault = fault };
            const mode: IoTrace.Mode = if (options.trace == .off) .{ .last = 1 } else options.trace;
            const run = try Run.init(gpa, base, options, &report, mode, &.{.{ .at = .{ .step = record.step }, .fault = fault }});
            defer run.deinit();
            try run.once(gpa, ctx, options, &report, .{ .injected = injected, .clean = by_step, .clean_run = clean });
        }
    }
    return report;
}

/// One run's `Io`: a `FaultIo` over the base, or the fault part of a fresh
/// simulation (`EveryFaultOptions.sim`), whose root task the run is made in.
const Run = struct {
    fio: *FaultIo,
    sim: ?*Sim,

    fn init(gpa: Allocator, base: Io, options: EveryFaultOptions, report: *EveryFaultReport, mode: IoTrace.Mode, plan: []const FaultIo.IoPlan.Entry) EveryFaultError!Run {
        const sim_options = options.sim orelse {
            const fio = FaultIo.init(gpa, base, .{ .trace = mode, .random_seed = options.random_seed, .plan = plan }) catch |err| return outOfMemory(err);
            return .{ .fio = fio, .sim = null };
        };
        var config = sim_options;
        config.faults = plan;
        config.fault_part = .{ .trace = mode, .random_seed = options.random_seed };
        const sim = Sim.init(gpa, config) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A one-entry plan built from a call's own fault always applies.
            error.FaultNotInErrorSet, error.FaultNotApplicable => unreachable, // unreachable: candidates checks every fault
            // The simulation's own options cannot be met: no run is made.
            error.ExecutorUnavailable, error.InvalidLink, error.InvalidSchedule => {
                if (options.diagnostics) |d| d.* = .{ .runs = report.runs, .failure = .{ .injected = null, .err = err, .trace = "" } };
                return error.CheckFailed;
            },
        };
        return .{ .fio = sim.faults().?, .sim = sim };
    }

    fn deinit(r: Run) void {
        if (r.sim) |sim| sim.deinit() else r.fio.deinit();
    }

    /// `once`, in the simulation's root task when there is one, where
    /// `check` is given the simulation's `Io` past its fault part, so its
    /// calls are not steps of the run. A run the
    /// simulation ends otherwise (a deadlock, a stuck task, a call it does
    /// not model) fails the whole as `CheckFailed`, named by its outcome.
    fn once(r: Run, gpa: Allocator, ctx: anytype, options: EveryFaultOptions, report: *EveryFaultReport, faulted: ?Faulted) EveryFaultError!void {
        const sim = r.sim orelse return onceOn(gpa, ctx, r.fio, r.fio.io(), r.fio.io(), options, report, faulted);
        var verdict: EveryFaultError!void = {};
        const Root = struct {
            fn root(g: Allocator, c: @TypeOf(ctx), fio: *FaultIo, io: Io, judged: Io, o: EveryFaultOptions, into: *EveryFaultReport, f: ?Faulted, out: *(EveryFaultError!void)) void {
                out.* = onceOn(g, c, fio, io, judged, o, into, f);
            }
        };
        const err: anyerror = switch (sim.run(Root.root, .{ gpa, ctx, r.fio, sim.io(), sim.unfaultedIo(), options, report, faulted, &verdict })) {
            .finished => return verdict,
            .step_limit => return error.TooManySteps,
            .failed => |err| err,
            .deadlock => error.Deadlock,
            .time_limit => error.TimeLimit,
            .stuck => error.Stuck,
            .double_close => error.DoubleClose,
            .unmodeled => error.Unmodeled,
        };
        return fail(gpa, options, r.fio, report.*, .{ .injected = if (faulted) |f| f.injected else null, .err = err, .trace = "" });
    }
};

/// The most faults tried at one step.
const max_faults = 32;

const Entry = IoTrace.Entry;

fn earlier(_: void, a: Entry, b: Entry) bool {
    return a.step < b.step;
}

/// A faulted run: its fault, the clean run's calls, by step, it must make up
/// to it, and the clean run itself, whose records a `Nondeterministic`
/// report shows beside the faulted run's.
const Faulted = struct { injected: Injected, clean: []const Entry, clean_run: *FaultIo };

/// One run: set up, run, check, tear down. `check` judges the run before
/// `tearDown` releases what it left, and `tearDown` follows every run whose
/// `setUp` succeeded, the failing ones included.
fn onceOn(gpa: Allocator, ctx: anytype, fio: *FaultIo, io: Io, judged: Io, options: EveryFaultOptions, report: *EveryFaultReport, faulted: ?Faulted) EveryFaultError!void {
    report.runs += 1;
    ctx.setUp(fio) catch |err| {
        if (options.diagnostics) |d| d.* = .{ .runs = report.runs, .failure = .{ .injected = null, .err = err, .trace = "" } };
        return error.CheckFailed;
    };
    defer ctx.tearDown();
    const result = ctx.run(io);
    // A planned fault that could not be held for memory was not made: the
    // run proves nothing of it, and passing it would count it covered.
    if (fio.faultsNotMade() != 0) return error.OutOfMemory;
    var injected = if (faulted) |f| f.injected else null;
    if (faulted) |f| {
        if (divergence(f.clean, fio, f.injected.step, &report.excused)) |at| {
            return failWith(gpa, options, fio, f.clean_run, report.*, .{ .injected = injected, .err = error.Nondeterministic, .difference = at, .trace = "" });
        }
        if (!landed(f.clean, fio, f.injected.step)) injected = null;
    }
    ctx.check(judged, result, injected) catch |err| {
        return fail(gpa, options, fio, report.*, .{ .injected = injected, .err = err, .trace = "" });
    };
}

/// Whether the faulted run's fault did something at its step: a cancel
/// under blocked protection did not, and its record is the clean run's.
fn landed(clean: []const Entry, faulted: *FaultIo, step: u64) bool {
    const ours = atStep(clean, step) orelse return true;
    for (faulted.trace().entriesKept() orelse return true) |e| if (e.step == step) return e.whole != ours.whole;
    return true;
}

/// The clean run's entry at `step`, from its entries sorted by step.
fn atStep(by_step: []const Entry, step: u64) ?Entry {
    const at: usize = @intCast(atStepIndex(by_step, step));
    return if (at < by_step.len and by_step[at].step == step) by_step[at] else null;
}

/// The faults to try at `record`'s step, into `buffer`.
fn candidates(ctx: anytype, options: EveryFaultOptions, record: IoTrace.Record, buffer: *[max_faults]IoFault) []const IoFault {
    const call = record.event.call;
    var len: usize = 0;
    if (call == .foreign) {
        const Ctx = @typeInfo(@TypeOf(ctx)).pointer.child;
        if (!@hasDecl(Ctx, "faultsFor")) return &.{};
        for (ctx.faultsFor(record)) |fault| {
            if (len == buffer.len) break;
            if (!fault.fits(.foreign)) continue;
            buffer[len] = fault;
            len += 1;
        }
        return buffer[0..len];
    }
    // A resize or remap through `FaultIo.allocator` is refused already, so
    // failing one would rerun the clean run.
    if (call == .resize or call == .remap) return &.{};
    if (call == .alloc) {
        if (options.alloc) {
            buffer[0] = .{ .fail = error.OutOfMemory };
            return buffer[0..1];
        }
        return &.{};
    }
    for (options.errors) |err| {
        if (len == buffer.len) break;
        if (!io_call.canFail(call, err)) continue;
        buffer[len] = .{ .fail = err };
        len += 1;
    }
    for (options.lost_answers) |err| {
        if (len == buffer.len) break;
        const fault: IoFault = .{ .fail_after = err };
        if (!fault.fits(call)) continue;
        buffer[len] = fault;
        len += 1;
    }
    if (options.cancel and len < buffer.len and io_call.cancelable(call)) {
        buffer[len] = .cancel;
        len += 1;
    }
    if (options.short and io_call.shortable(call)) switch (record.event.outcome) {
        .ok => |moved| if (moved > 0) {
            // No progress, where moving nothing is not the end of the file.
            if (len < buffer.len) none: {
                const fault: IoFault = .{ .short = 0 };
                if (!fault.fits(call)) break :none;
                buffer[len] = fault;
                len += 1;
            }
            if (moved > 1 and len < buffer.len) {
                buffer[len] = .{ .short = @intCast(@min(moved / 2, std.math.maxInt(u32))) };
                len += 1;
            }
        },
        .err => {},
    };
    return buffer[0..len];
}

/// Where a faulted run parted from the clean run before its fault, as the
/// index of its first record that differs, or null when it did not. The
/// fault must have fired at `step`. Up to it the faulted run makes exactly
/// the clean run's calls: a call at every step the clean run made one, the
/// same call with the same arguments. A call that returned before the fault
/// fired returned as it did in the clean run. Only a call still waiting when
/// the fault fired, which the fault may end another way, is excused its
/// outcome, and counted in `excused`. Records are compared by step, not by
/// position: a call returns when it returns, so a fault that ends a waiting
/// call early moves its record, and nothing else.
fn divergence(clean: []const Entry, faulted: *FaultIo, step: u64, excused: *u64) ?u64 {
    const theirs = faulted.trace().entriesKept() orelse return 0;
    const fired = faulted.fired();
    if (fired.len == 0 or fired[0].step != step) return theirs.len;
    // What returned before the fault's own record had returned when it fired.
    const fault_at = for (theirs, 0..) |e, i| {
        if (e.step == step) break i;
    } else theirs.len;
    var made: u64 = 0;
    var waiting: u64 = 0;
    for (theirs, 0..) |e, i| {
        if (e.step >= step) continue;
        const ours = atStep(clean, e.step) orelse return i;
        if (ours.call != e.call) return i;
        if (i < fault_at) {
            if (ours.whole != e.whole) return i;
        } else waiting += 1;
        made += 1;
    }
    // Every call the clean run made before the step, the faulted run made too.
    const before = atStepIndex(clean, step);
    if (made != before) return theirs.len;
    excused.* += waiting;
    return null;
}

/// How many of the clean run's entries come before `step`.
fn atStepIndex(by_step: []const Entry, step: u64) u64 {
    var lo: usize = 0;
    var hi: usize = by_step.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (by_step[mid].step < step) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn fail(gpa: Allocator, options: EveryFaultOptions, fio: *FaultIo, report: EveryFaultReport, failure: EveryFaultReport.Failure) EveryFaultError {
    return failWith(gpa, options, fio, null, report, failure);
}

/// `fail`, and for a `Nondeterministic` run the clean run's records from a
/// little before the first difference to a little past the fault's step,
/// after the faulted run's: the two sides of the difference, where the
/// faulted run's alone named one.
fn failWith(gpa: Allocator, options: EveryFaultOptions, fio: *FaultIo, clean: ?*FaultIo, report: EveryFaultReport, failure: EveryFaultReport.Failure) EveryFaultError {
    const err: EveryFaultError = if (failure.err == error.Nondeterministic) error.Nondeterministic else error.CheckFailed;
    const diagnostics = options.diagnostics orelse return err;
    var text: Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    fio.trace().format(&text.writer) catch return error.OutOfMemory;
    if (clean) |run| if (failure.difference) |at| if (failure.injected) |injected| {
        const theirs = fio.trace().entriesKept() orelse &.{};
        var from: u64 = injected.step;
        for (theirs[@min(at, theirs.len)..]) |e| from = @min(from, e.step);
        from -|= 4;
        const to = injected.step +| 4;
        text.writer.print("the clean run, steps {d} to {d}, as they returned:\n", .{ from, to }) catch return error.OutOfMemory;
        for (run.trace().records()) |r| if (r.step >= from and r.step <= to) {
            text.writer.print("{d:>6} {d:>3} {f}\n", .{ r.step, r.task.raw(), r.event }) catch return error.OutOfMemory;
        };
    };
    var kept = failure;
    kept.trace = text.toOwnedSlice() catch return error.OutOfMemory;
    diagnostics.* = report;
    diagnostics.failure = kept;
    diagnostics.gpa = gpa;
    return err;
}

fn outOfMemory(err: FaultIo.InitError) EveryFaultError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // A one-entry plan built from a call's own fault always applies.
        error.FaultNotInErrorSet, error.FaultNotApplicable => unreachable, // unreachable: candidates checks every fault
    };
}
