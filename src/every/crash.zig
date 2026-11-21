//! Crash before every Io call, and after return; recover every allowed disk image.
const std = @import("std");
const Io = std.Io;
const Sim = @import("../Sim.zig");
const reports = @import("fault.zig");
const Trace = @import("../trace.zig").Trace;
const Untraced = @import("../alloc/Untraced.zig");

pub const EveryCrashOptions = struct {
    sim: Sim.Options = .{},
    /// Bound exploration at each crash point; reaching it is reported explicitly.
    max_states: u32 = 256,
    max_steps: u64 = 100_000,
    /// Filled with the crash point, recovery error and trace on failure.
    diagnostics: ?*reports.EveryFaultReport = null,
    /// The crash points this call explores: one of `count` contiguous
    /// ranges of them, so a long operation's sweep runs as several tests.
    shard: Shard = .{},
    /// Syncs that lie (`Sim.Fs.Faults.sync_lie_per_million`), explored
    /// rather than drawn: at each crash point, besides the images honest
    /// syncs allow, the images left if the last 1 to `lying_syncs` data or
    /// full syncs of node zero's disk before it lied. An honest sync
    /// persists what earlier lies left on the device, so any set of lies
    /// leaves images among those of the run of last syncs that begins at its
    /// earliest lie: these are all the lies that matter at a point whose
    /// earliest is among its last `lying_syncs` syncs. Each is
    /// one more run of the prefix and at most `max_states` more images
    /// there: a point after `m` syncs is run `1 + min(m, lying_syncs)`
    /// times. 0, the default, explores honest syncs only.
    lying_syncs: u8 = 0,

    /// Shard `index` of `count` explores the points from
    /// `points * index / count` up to the next shard's first. A range keeps
    /// together the points that leave the same states, so a state is
    /// recovered by about one shard; a state two ranges both reach is
    /// recovered in each.
    pub const Shard = reports.Shard;
};
pub const Report = reports.EveryFaultReport;
pub const Error = Sim.InitError || error{ OutOfMemory, Nondeterministic, CheckFailed, TooManySteps, FileSystemDisabled };

/// ctx: setUp(ctx, sim), run(ctx, io), recover(ctx, io, gpa),
/// check(ctx, io, gpa), optionally tearDown(ctx). A crash abandons tasks
/// without executing defers; own application heap state in ctx and release
/// it in tearDown. What `run` allocates comes from `sim.allocator()`, taken
/// in setUp.
///
/// Every run's simulation has memory of its own over `gpa`, counted and
/// without a stack trace per allocation (`alloc.Untraced`): the clean run's,
/// and each crash point's, which its recoveries share since a recovery
/// restores the point's storage. `recover` and `check` are handed `gpa`, an
/// allocator of the recovery's own, of the same kind: what they allocate
/// they free. A leak in any of them fails the sweep (`error.CheckFailed`,
/// the report's failure `error.Leaked` at its point), after the leaking run
/// is made again on traced allocators, whose report names each leaked block.
/// Recovery runs on a fresh scheduler with the crashed storage. The returned
/// bounded count makes an incomplete exploration visible to the caller.
/// A state is recovered once: one an earlier crash point left (the same
/// tree, `Sim.Fs.Snapshot.digest`) is counted in `repeated` and not
/// recovered again, since recovery sees nothing but that storage. `recover`
/// and `check` are judged once per distinct state, so they must not count
/// on being called once per crash point. A point whose storage is the
/// previous point's (a call between them that changed nothing on disk or in
/// the journal) leaves the same states, so they are not drawn again: they
/// are counted in `repeated` as drawing them would have counted them.
pub fn everyCrash(gpa: std.mem.Allocator, ctx: anytype, options: EveryCrashOptions) Error!Report {
    return (try sweepAll(gpa, ctx, options, true)).report;
}

/// `everyCrash`, and how many of the runs its points made had the previous
/// point's storage and drew no state; with `skip` false every point draws
/// its states (the tests' reference).
const Swept = struct { report: Report, skipped: u32 };

fn sweepAll(gpa: std.mem.Allocator, ctx: anytype, options: EveryCrashOptions, skip: bool) Error!Swept {
    if (options.sim.fs == null) return error.FileSystemDisabled;
    if (options.max_states == 0) return error.CheckFailed;
    if (!options.shard.valid()) return error.CheckFailed;
    var config = options.sim;
    config.max_steps = options.max_steps;
    config.trace = .all;
    // The clean run's memory lasts the sweep: its trace is every point's baseline.
    var memory: Memory = .init(gpa, false);
    const swept = sweepFrom(gpa, memory.allocator(), ctx, options, config, skip);
    const leaks = memory.deinit();
    const done = try swept;
    if (leaks == 0) return done;
    var loud: Memory = .init(gpa, true);
    if (cleanRun(loud.allocator(), ctx, config)) |again| again.deinit() else |err| Untraced.rerunFailed(err);
    _ = loud.deinit();
    return leaked(gpa, options, done.report, null);
}

/// The clean run, on `a`: the simulation it returns holds its trace.
fn cleanRun(a: std.mem.Allocator, ctx: anytype, config: Sim.Options) Error!*Sim {
    const clean = try Sim.init(a, config);
    errdefer clean.deinit();
    try setup(ctx, clean);
    defer teardown(ctx);
    switch (clean.run(Root(@TypeOf(ctx)).run, .{ clean.io(), ctx })) {
        .finished => return clean,
        .step_limit => return error.TooManySteps,
        .failed => |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.CheckFailed,
        else => return error.CheckFailed,
    }
}

/// The sweep after a clean run on `clean_memory`; the points' memory is
/// their own, over `gpa`.
fn sweepFrom(gpa: std.mem.Allocator, clean_memory: std.mem.Allocator, ctx: anytype, options: EveryCrashOptions, config: Sim.Options, skip: bool) Error!Swept {
    const clean = try cleanRun(clean_memory, ctx, config);
    defer clean.deinit();
    // One run of a point per lie count: the honest one, then 1 to `lying_syncs` lies.
    const runs_per_point = @as(usize, options.lying_syncs) + 1;
    const prior = try gpa.alloc(?Sweep.Seen, runs_per_point);
    defer gpa.free(prior);
    const current = try gpa.alloc(?Sweep.Seen, runs_per_point);
    defer gpa.free(current);
    @memset(prior, null);
    var sweep: Sweep = .{ .gpa = gpa, .options = options, .config = config, .baseline = clean.trace().records(), .report = .{ .steps = clean.steps(), .runs = 1 }, .prior = prior, .current = current, .skip = skip };
    defer sweep.recovered.deinit(gpa);
    // The first point is before call 1; the last is after the root returned.
    const points = options.shard.range(sweep.report.steps + 1);
    for (@intCast(points.first)..@intCast(points.end)) |point| {
        @memset(sweep.current, null);
        const syncs = try sweep.point(ctx, point, null, 0);
        for (1..@as(usize, @min(syncs, options.lying_syncs)) + 1) |lies| _ = try sweep.point(ctx, point, @intCast(syncs - lies), lies);
        std.mem.swap([]?Sweep.Seen, &sweep.prior, &sweep.current);
    }
    return .{ .report = sweep.report, .skipped = sweep.skipped };
}

fn Root(comptime Ctx: type) type {
    return struct {
        fn run(io: Io, context: Ctx) !void {
            try context.run(io);
        }
        fn recover(io: Io, context: Ctx, gpa: std.mem.Allocator) !void {
            try context.recover(io, gpa);
            try context.check(io, gpa);
        }
    };
}

/// A run's memory: counted without a stack trace per allocation, or traced
/// when a leak is being named.
const Memory = union(enum) {
    quiet: Untraced,
    loud: std.heap.SafeAllocator,

    fn init(backing: std.mem.Allocator, loud: bool) Memory {
        return if (loud) .{ .loud = Untraced.traced(backing) } else .{ .quiet = .init(backing) };
    }

    /// The allocator. `m` must not move while it is in use.
    fn allocator(m: *Memory) std.mem.Allocator {
        return switch (m.*) {
            .quiet => |*q| q.allocator(),
            .loud => |*l| l.allocator(),
        };
    }

    /// The blocks still live, freed; a traced one logs each with the stack
    /// it was allocated from.
    fn deinit(m: *Memory) usize {
        return switch (m.*) {
            .quiet => |*q| q.deinit(),
            .loud => |*l| l.deinit(),
        };
    }
};

/// A sweep that leaked fails with `error.Leaked` at the leaking point,
/// `null` for the clean run.
fn leaked(gpa: std.mem.Allocator, options: EveryCrashOptions, report: Report, injected: ?reports.Injected) Error {
    const diagnostics = options.diagnostics orelse return error.CheckFailed;
    const trace = gpa.dupe(u8, "a leak: the traced run's report names each leaked block\n") catch return error.OutOfMemory;
    diagnostics.* = report;
    diagnostics.failure = .{ .injected = injected, .err = error.Leaked, .trace = trace };
    diagnostics.gpa = gpa;
    return error.CheckFailed;
}

const Sweep = struct {
    gpa: std.mem.Allocator,
    options: EveryCrashOptions,
    config: Sim.Options,
    baseline: []const Trace(Sim.Event).Record,
    report: Report,
    recovered: std.AutoHashMapUnmanaged(u128, void) = .empty,
    /// What the previous point's run of each lie count left, and this point's.
    prior: []?Seen,
    current: []?Seen,
    /// Runs whose storage was the previous point's, which drew no state.
    skipped: u32 = 0,
    /// Whether such a run draws no state.
    skip: bool,

    /// A run's storage (`Model.stateDigest`), how many states it drew, and
    /// whether it reached `max_states`.
    const Seen = struct { storage: u128, states: u32, bounded: bool };

    /// Runs the operation to `point` and recovers each image its disk may
    /// crash to, its syncs from `lie_from` on lying, the point's run `slot`
    /// (its lie count). Returns how many data or full syncs the prefix made.
    /// The point's simulations, and each recovery's `recover` and `check`,
    /// have memory of their own; a leak in any runs the point again traced,
    /// every state recovered, and fails it.
    fn point(sweep: *Sweep, ctx: anytype, at: usize, lie_from: ?u32, slot: usize) Error!u32 {
        var memory: Memory = .init(sweep.gpa, false);
        var leaks: usize = 0;
        const ran = sweep.pointOn(ctx, at, lie_from, slot, memory.allocator(), false, &leaks);
        leaks += memory.deinit();
        const syncs = try ran;
        if (leaks == 0) return syncs;
        var loud: Memory = .init(sweep.gpa, true);
        var again: usize = 0;
        if (sweep.pointOn(ctx, at, lie_from, slot, loud.allocator(), true, &again)) |_| {} else |err| Untraced.rerunFailed(err);
        _ = loud.deinit();
        return leaked(sweep.gpa, sweep.options, sweep.report, sweep.injectedAt(at));
    }

    /// The crash before the call at step `at + 1`, or none after the root returned.
    fn injectedAt(sweep: *const Sweep, at: usize) ?reports.Injected {
        return if (at < sweep.baseline.len) .{ .step = at + 1, .call = sweep.baseline[at].event.call, .fault = .crash } else null;
    }

    /// `point` on `a`, adding the recoveries' leaks to `leaks`. `loud`, to
    /// name a leak: every state is recovered, none skipped as seen before,
    /// on traced allocators.
    fn pointOn(sweep: *Sweep, ctx: anytype, at: usize, lie_from: ?u32, slot: usize, a: std.mem.Allocator, loud: bool, leaks: *usize) Error!u32 {
        var config = sweep.config;
        config.max_steps = at;
        const stopped = try Sim.init(a, config);
        defer stopped.deinit();
        stopped.fs().model.lie_from = lie_from;
        try setup(ctx, stopped);
        defer teardown(ctx);
        const outcome = stopped.run(Root(@TypeOf(ctx)).run, .{ stopped.io(), ctx });
        if (outcome != .step_limit and outcome != .finished) return error.CheckFailed;
        const prefix = stopped.trace().records();
        if (prefix.len > sweep.baseline.len) return error.Nondeterministic;
        for (prefix, sweep.baseline[0..prefix.len]) |actual, expected| {
            if (!std.meta.eql(actual.event, expected.event)) return error.Nondeterministic;
        }
        // The point's states share the files none of them changed.
        var images: Sim.Fs.ImageDigests = .init(a);
        defer images.deinit();
        const storage = try stopped.fs().model.stateDigest(&images);
        const syncs = stopped.fs().model.syncs;
        // The previous point's storage: the same crash states, each recovered
        // or found repeated there, so each is a repeat here.
        if (sweep.skip and !loud) if (sweep.prior[slot]) |seen| if (seen.storage == storage) {
            sweep.report.repeated += seen.states;
            if (seen.bounded) sweep.report.bounded += 1;
            sweep.current[slot] = seen;
            sweep.skipped += 1;
            return syncs;
        };
        var states = try stopped.fs().crashStates(sweep.options.max_states +| 1);
        defer states.deinit();
        var count: u32 = 0;
        var bounded = false;
        while (try states.next()) |snap| {
            defer snap.deinit();
            if (count == sweep.options.max_states) {
                sweep.report.bounded += 1;
                bounded = true;
                break;
            }
            count += 1;
            const digest = try snap.digest(&images);
            if (!loud and (try sweep.recovered.getOrPut(sweep.gpa, digest)).found_existing) {
                sweep.report.repeated += 1;
                continue;
            }
            var recovery_options = sweep.options.sim;
            recovery_options.faults = &.{};
            const recovery = try Sim.init(a, recovery_options);
            defer recovery.deinit();
            recovery.fs().restore(snap);
            var own: Memory = .init(sweep.gpa, loud);
            const recovered = recovery.run(Root(@TypeOf(ctx)).recover, .{ recovery.io(), ctx, own.allocator() });
            leaks.* += own.deinit();
            sweep.report.runs += 1;
            if (recovered != .finished) {
                const err = if (recovered == .failed) recovered.failed else error.CheckFailed;
                return fail(sweep.gpa, sweep.options, recovery, sweep.report, sweep.injectedAt(at), err);
            }
        }
        sweep.current[slot] = .{ .storage = storage, .states = count, .bounded = bounded };
        return syncs;
    }
};
fn setup(ctx: anytype, sim: *Sim) Error!void {
    ctx.setUp(sim) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.CheckFailed;
    };
}
fn teardown(ctx: anytype) void {
    if (@hasDecl(@typeInfo(@TypeOf(ctx)).pointer.child, "tearDown")) ctx.tearDown();
}

fn fail(gpa: std.mem.Allocator, options: EveryCrashOptions, sim: *Sim, report: Report, injected: ?reports.Injected, err: anyerror) Error {
    const diagnostics = options.diagnostics orelse return error.CheckFailed;
    var writer: Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    sim.trace().format(&writer.writer) catch return error.OutOfMemory;
    const trace = writer.toOwnedSlice() catch return error.OutOfMemory;
    diagnostics.* = report;
    diagnostics.failure = .{ .injected = injected, .err = err, .trace = trace };
    diagnostics.gpa = gpa;
    return error.CheckFailed;
}

const testing = std.testing;

/// A durable replace with calls between its steps that touch no file: each
/// point after one of them has the storage of the point before it.
const Quiet = struct {
    recovered: u64 = 0,
    pub fn setUp(_: *Quiet, sim: *Sim) !void {
        try sim.fs().write("dest", "old");
    }
    pub fn run(_: *Quiet, io: Io) !void {
        const cwd = Io.Dir.cwd();
        const file = try cwd.createFile(io, "temp", .{});
        defer file.close(io);
        try file.writePositionalAll(io, "new", 0);
        for (0..4) |_| _ = Io.Clock.Timestamp.now(io, .awake);
        try file.sync(io);
        for (0..4) |_| _ = Io.Clock.Timestamp.now(io, .awake);
        try cwd.rename("temp", cwd, "dest", io);
    }
    pub fn recover(ctx: *Quiet, _: Io, _: std.mem.Allocator) !void {
        ctx.recovered += 1;
    }
    /// Every state passes: what is compared is the sweep's report, and a lying sync may leave
    /// either file's bytes behind.
    pub fn check(_: *Quiet, _: Io, _: std.mem.Allocator) !void {}
};

test "a crash point whose storage is the previous point's draws no state, and the report is the one drawing them gives" {
    for ([_]u8{ 0, 2 }) |lying_syncs| {
        const options: EveryCrashOptions = .{ .sim = .{ .watchdog = null }, .max_states = 64, .lying_syncs = lying_syncs };
        var drawing: Quiet = .{};
        const reference = try sweepAll(testing.allocator, &drawing, options, false);
        try testing.expectEqual(@as(u32, 0), reference.skipped);
        var skipping: Quiet = .{};
        const swept = try sweepAll(testing.allocator, &skipping, options, true);
        // The clock reads change nothing stored: at least each one's point after the first of a run of them.
        try testing.expect(swept.skipped >= 6);
        try testing.expectEqual(reference.report, swept.report);
        try testing.expectEqual(drawing.recovered, skipping.recovered);
    }
}
