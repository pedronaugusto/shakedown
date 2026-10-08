//! Crash before every Io call, and after return; recover every allowed disk image.
const std = @import("std");
const Io = std.Io;
const Sim = @import("../Sim.zig");
const reports = @import("fault.zig");

pub const CrashEveryFaultOptions = struct {
    sim: Sim.Options = .{},
    /// Bound exploration at each crash point; reaching it is reported explicitly.
    max_states: u32 = 256,
    max_steps: u64 = 100_000,
    /// Filled with the crash point, recovery error and trace on failure.
    diagnostics: ?*reports.EveryFaultReport = null,
};
pub const Report = reports.EveryFaultReport;
pub const Error = Sim.InitError || error{ OutOfMemory, Nondeterministic, CheckFailed, TooManySteps, FileSystemDisabled };

/// ctx: setUp(ctx, sim), run(ctx, io), recover(ctx, io), check(ctx, io),
/// optionally tearDown(ctx). A crash abandons tasks without executing defers;
/// own application heap state in ctx and release it in tearDown.
/// Recovery runs on a fresh scheduler with the crashed storage. The returned
/// bounded count makes an incomplete exploration visible to the caller.
pub fn everyCrash(gpa: std.mem.Allocator, ctx: anytype, options: CrashEveryFaultOptions) Error!Report {
    if (options.sim.fs == null) return error.FileSystemDisabled;
    if (options.max_states == 0) return error.CheckFailed;
    var config = options.sim;
    config.max_steps = options.max_steps;
    config.trace = .all;
    const clean = try Sim.init(gpa, config);
    defer clean.deinit();
    const Root = struct {
        fn run(io: Io, context: @TypeOf(ctx)) !void {
            try context.run(io);
        }
        fn recover(io: Io, context: @TypeOf(ctx)) !void {
            try context.recover(io);
            try context.check(io);
        }
    };
    {
        try setup(ctx, clean);
        defer teardown(ctx);
        switch (clean.run(Root.run, .{ clean.io(), ctx })) {
            .finished => {},
            .step_limit => return error.TooManySteps,
            .failed => |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.CheckFailed,
            else => return error.CheckFailed,
        }
    }
    var report: Report = .{ .steps = clean.steps(), .runs = 1 };
    const baseline = clean.trace().records();
    // The first point is before call 1; the last is after the root returned.
    for (0..@intCast(report.steps + 1)) |point| {
        config.max_steps = point;
        const stopped = try Sim.init(gpa, config);
        defer stopped.deinit();
        try setup(ctx, stopped);
        defer teardown(ctx);
        const outcome = stopped.run(Root.run, .{ stopped.io(), ctx });
        if (outcome != .step_limit and outcome != .finished) return error.CheckFailed;
        const prefix = stopped.trace().records();
        if (prefix.len > baseline.len) return error.Nondeterministic;
        for (prefix, baseline[0..prefix.len]) |actual, expected| {
            if (!std.meta.eql(actual.event, expected.event)) return error.Nondeterministic;
        }
        var states = try stopped.fs().crashStates(options.max_states +| 1);
        defer states.deinit();
        var count: u32 = 0;
        while (try states.next()) |snap| {
            defer snap.deinit();
            if (count == options.max_states) {
                report.bounded += 1;
                break;
            }
            count += 1;
            var recovery_options = options.sim;
            recovery_options.faults = &.{};
            const recovery = try Sim.init(gpa, recovery_options);
            defer recovery.deinit();
            recovery.fs().restore(snap);
            const recovered = recovery.run(Root.recover, .{ recovery.io(), ctx });
            report.runs += 1;
            if (recovered != .finished) {
                const err = if (recovered == .failed) recovered.failed else error.CheckFailed;
                const injected: ?reports.Injected = if (point < baseline.len) .{ .step = point + 1, .call = baseline[point].event.call, .fault = .crash } else null;
                return fail(gpa, options, recovery, report, injected, err);
            }
        }
    }
    return report;
}
fn setup(ctx: anytype, sim: *Sim) Error!void {
    ctx.setUp(sim) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.CheckFailed;
    };
}
fn teardown(ctx: anytype) void {
    if (@hasDecl(@typeInfo(@TypeOf(ctx)).pointer.child, "tearDown")) ctx.tearDown();
}

fn fail(gpa: std.mem.Allocator, options: CrashEveryFaultOptions, sim: *Sim, report: Report, injected: ?reports.Injected, err: anyerror) Error {
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
