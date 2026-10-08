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

/// What `everyFault` tries, and what it keeps when a run fails.
pub const EveryFaultOptions = struct {
    /// Errors tried at every step whose call can return them.
    errors: []const anyerror = &.{ error.InputOutput, error.NoSpaceLeft, error.AccessDenied },
    /// Reads and writes that moved bytes: `short(0)`, and `short(half)`.
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
pub fn everyFault(gpa: Allocator, base: Io, ctx: anytype, options: EveryFaultOptions) EveryFaultError!EveryFaultReport {
    var report: EveryFaultReport = .{};
    const clean = FaultIo.init(gpa, base, .{ .trace = .all, .random_seed = options.random_seed }) catch |err| return outOfMemory(err);
    defer clean.deinit();
    try once(gpa, ctx, clean, options, &report, null);
    report.steps = clean.steps().peek();
    if (report.steps > options.max_steps) return error.TooManySteps;

    const records = clean.trace().records();
    var faults: [max_faults]IoFault = undefined;
    for (records, 0..) |record, index| {
        for (candidates(ctx, options, record, &faults)) |fault| {
            const injected: Injected = .{ .step = record.step, .call = record.event.call, .fault = fault };
            const mode: IoTrace.Mode = if (options.trace == .off) .{ .last = 1 } else options.trace;
            const fio = FaultIo.init(gpa, base, .{
                .trace = mode,
                .random_seed = options.random_seed,
                .plan = &.{.{ .at = .{ .step = record.step }, .fault = fault }},
            }) catch |err| return outOfMemory(err);
            defer fio.deinit();
            try once(gpa, ctx, fio, options, &report, .{ .injected = injected, .clean = clean, .index = index });
        }
    }
    return report;
}

/// The most faults tried at one step.
const max_faults = 32;

/// A faulted run: its fault, and the clean run it must follow up to it.
const Faulted = struct { injected: Injected, clean: *FaultIo, index: usize };

/// One run: set up, run, check, tear down. `check` judges the run before
/// `tearDown` releases what it left, and `tearDown` follows every run whose
/// `setUp` succeeded, the failing ones included.
fn once(gpa: Allocator, ctx: anytype, fio: *FaultIo, options: EveryFaultOptions, report: *EveryFaultReport, faulted: ?Faulted) EveryFaultError!void {
    report.runs += 1;
    ctx.setUp(fio) catch |err| {
        if (options.diagnostics) |d| d.* = .{ .runs = report.runs, .failure = .{ .injected = null, .err = err, .trace = "" } };
        return error.CheckFailed;
    };
    defer ctx.tearDown();
    const result = ctx.run(fio.io());
    var injected = if (faulted) |f| f.injected else null;
    if (faulted) |f| {
        if (divergence(f.clean, fio, f.index, f.injected.step)) |at| {
            return fail(gpa, options, fio, report.*, .{ .injected = injected, .err = error.Nondeterministic, .difference = at, .trace = "" });
        }
        if (!landed(f.clean, fio, f.index)) injected = null;
    }
    ctx.check(fio.io(), result, injected) catch |err| {
        return fail(gpa, options, fio, report.*, .{ .injected = injected, .err = err, .trace = "" });
    };
}

/// Whether the faulted run's fault did something at its step: a cancel
/// under blocked protection did not, and its record is the clean run's.
fn landed(clean: *FaultIo, faulted: *FaultIo, index: usize) bool {
    const theirs = faulted.trace().hashAt(index) orelse return true;
    const ours = clean.trace().hashAt(index) orelse return true;
    return theirs != ours;
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
            fault.check(.foreign) catch continue;
            buffer[len] = fault;
            len += 1;
        }
        return buffer[0..len];
    }
    const allocation = call == .alloc or call == .resize or call == .remap;
    if (allocation) {
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
        fault.check(call) catch continue;
        buffer[len] = fault;
        len += 1;
    }
    if (options.cancel and len < buffer.len and io_call.cancelable(call)) {
        buffer[len] = .cancel;
        len += 1;
    }
    if (options.short and io_call.shortable(call)) switch (record.event.outcome) {
        .ok => |moved| if (moved > 0) {
            if (len < buffer.len) {
                buffer[len] = .{ .short = 0 };
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

/// Where a faulted run parted from the clean run before its fault, or
/// null when it did not: the fault must have fired at `step`, and every
/// record before it must be the clean run's.
fn divergence(clean: *FaultIo, faulted: *FaultIo, index: usize, step: u64) ?u64 {
    const fired = faulted.fired();
    if (fired.len == 0 or fired[0].step != step) return @min(index, faulted.trace().len());
    if (index == 0) return null;
    const theirs = faulted.trace().hashAt(index - 1);
    if (theirs != null and theirs.? == clean.trace().hashAt(index - 1).?) return null;
    // The first record at which the two differ.
    var lo: u64 = 0;
    var hi: u64 = index;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const a = clean.trace().hashAt(mid);
        const b = faulted.trace().hashAt(mid);
        if (b != null and a.? == b.?) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn fail(gpa: Allocator, options: EveryFaultOptions, fio: *FaultIo, report: EveryFaultReport, failure: EveryFaultReport.Failure) EveryFaultError {
    const err: EveryFaultError = if (failure.err == error.Nondeterministic) error.Nondeterministic else error.CheckFailed;
    const diagnostics = options.diagnostics orelse return err;
    var text: Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    fio.trace().format(&text.writer) catch return error.OutOfMemory;
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
