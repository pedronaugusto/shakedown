//! `expectDeterministic`: one seed must make one run.
//!
//! It runs a body twice, each time on a fresh `Sim` from the same seed, and
//! fails at the first call the two runs made differently, or, given a
//! checksum of the body's state, at the first step after which the states
//! differ, as GGPO's sync test compares frames. The two simulations run one
//! after the other, so each can lay out its memory at the same fixed
//! address (`Sim.allocator`).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sim = @import("Sim.zig");

pub fn DeterminismOptions(comptime Ctx: type) type {
    return struct {
        /// The seed both runs draw from, in place of `sim.seed`.
        seed: u64 = 0,
        /// Everything else about the two simulations.
        sim: Sim.Options = .{},
        /// A digest of the body's state, taken after every step of each
        /// run: the two must agree on every one.
        checksum: ?*const fn (Ctx) u64 = null,
        /// Filled when the runs differ, if given; otherwise the difference
        /// is printed. Free with `DeterminismReport.deinit`.
        diagnostics: ?*DeterminismReport = null,
    };
}

/// Where two runs of one seed parted.
pub const DeterminismReport = struct {
    /// The first record, or step, at which they differ.
    index: u64,
    /// What each run did there.
    text: []u8,
    /// Private: what `text` was allocated with.
    gpa: Allocator,

    pub fn deinit(r: *DeterminismReport) void {
        r.gpa.free(r.text);
        r.* = undefined;
    }
};

/// `Nondeterministic`: the runs differ (reported). The others: a simulation
/// could not be made.
pub const DeterminismError = error{ Nondeterministic, OutOfMemory, ExecutorUnavailable, FaultNotInErrorSet, FaultNotApplicable, SystemResources, InvalidLink, InvalidSchedule };

/// Runs `body(ctx, io)` as the root task of two simulations of
/// `options.seed`, one after the other. The body must start from the same
/// state each time: it sets up what it uses.
pub fn expectDeterministic(
    gpa: Allocator,
    ctx: anytype,
    comptime body: fn (@TypeOf(ctx), Io) anyerror!void,
    options: DeterminismOptions(@TypeOf(ctx)),
) DeterminismError!void {
    var first = try Run.go(gpa, ctx, body, options);
    defer first.deinit(gpa);
    var second = try Run.go(gpa, ctx, body, options);
    defer second.deinit(gpa);
    const index, const text = try first.compare(gpa, &second) orelse return;
    if (options.diagnostics) |d| {
        d.* = .{ .index = index, .text = text, .gpa = gpa };
        return error.Nondeterministic;
    }
    defer gpa.free(text);
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // glint-ignore: Z026 -- a report stderr cannot take is lost; the error still fails the test
    stderr.writer.writeAll(text) catch {};
    return error.Nondeterministic;
}

/// What one run left to compare: its outcome, its records with the hash
/// after each, and its checksums.
const Run = struct {
    outcome: Outcome,
    records: std.ArrayList(Record) = .empty,
    hashes: std.ArrayList(u64) = .empty,
    checksums: std.ArrayList(u64) = .empty,

    const Tag = std.meta.Tag(Sim.Outcome);
    // Capture the result without borrowing a deadlock report from the Sim.
    // Failure belongs to its tag; successful outcomes have no error field.
    const Outcome = union(Tag) {
        finished,
        failed: anyerror,
        deadlock,
        step_limit,
        time_limit,
        stuck,
    };
    const Record = std.meta.Child(@TypeOf(@as(*Sim, undefined).trace().records()));

    fn go(gpa: Allocator, ctx: anytype, comptime body: anytype, options: anytype) DeterminismError!Run {
        var sim_options = options.sim;
        sim_options.seed = options.seed;
        sim_options.source = null;
        sim_options.trace = .all;
        const sim = try Sim.init(gpa, sim_options);
        defer sim.deinit();
        var r: Run = .{ .outcome = undefined };
        errdefer r.deinit(gpa);
        const outcome = if (options.checksum) |sum| stepped: {
            try sim.start(body, .{ ctx, sim.io() });
            while (true) {
                const step = sim.step();
                try r.checksums.append(gpa, sum(ctx));
                if (step) |o| break :stepped o;
            }
        } else sim.run(body, .{ ctx, sim.io() });
        r.outcome = switch (outcome) {
            .failed => |err| .{ .failed = err },
            inline else => |_, tag| @unionInit(Outcome, @tagName(tag), {}),
        };
        const records = sim.trace().records();
        try r.records.appendSlice(gpa, records);
        try r.hashes.ensureTotalCapacityPrecise(gpa, records.len);
        for (0..records.len) |i| r.hashes.appendAssumeCapacity(sim.trace().hashAt(i).?);
        return r;
    }

    fn deinit(r: *Run, gpa: Allocator) void {
        r.records.deinit(gpa);
        r.hashes.deinit(gpa);
        r.checksums.deinit(gpa);
        r.* = undefined;
    }

    /// Where `a` and `b` part, and how, or null when they do not.
    fn compare(a: *const Run, gpa: Allocator, b: *const Run) error{OutOfMemory}!?struct { u64, []u8 } {
        var text: std.Io.Writer.Allocating = .init(gpa);
        errdefer text.deinit();
        const w = &text.writer;
        const index: u64 = if (firstDifference(a.hashes.items, b.hashes.items)) |i| at: {
            w.print("shakedown: two runs of one seed made different calls at record {d}:\n", .{i}) catch return error.OutOfMemory;
            describe(w, "first ", a.records.items, i) catch return error.OutOfMemory;
            describe(w, "second", b.records.items, i) catch return error.OutOfMemory;
            break :at i;
        } else if (std.mem.findDiff(u64, a.checksums.items, b.checksums.items)) |i| at: {
            w.print("shakedown: two runs of one seed made the same calls, but their states differ after step {d}\n", .{i}) catch return error.OutOfMemory;
            break :at i;
        } else if (std.meta.activeTag(a.outcome) != std.meta.activeTag(b.outcome) or (a.outcome == .failed and a.outcome.failed != b.outcome.failed)) at: {
            w.print("shakedown: two runs of one seed ended differently: {t} and {t}\n", .{ a.outcome, b.outcome }) catch return error.OutOfMemory;
            break :at a.records.items.len;
        } else {
            text.deinit();
            return null;
        };
        return .{ index, try text.toOwnedSlice() };
    }

    fn firstDifference(a: []const u64, b: []const u64) ?u64 {
        const shorter = @min(a.len, b.len);
        // Equal up to the first difference, unequal after it: a binary
        // search finds where.
        var lo: usize = 0;
        var hi: usize = shorter;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (a[mid] == b[mid]) lo = mid + 1 else hi = mid;
        }
        if (lo < shorter or a.len != b.len) return lo;
        return null;
    }

    fn describe(w: *std.Io.Writer, which: []const u8, records: []const Record, i: u64) std.Io.Writer.Error!void {
        if (i >= records.len) return w.print("  {s} run: no record, the run had ended\n", .{which});
        const r = records[@intCast(i)];
        try w.print("  {s} run: step {d}, {f}\n", .{ which, r.step, r.event });
    }
};
