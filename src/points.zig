//! The driver of aegis's fault points (`aegis.points`): the places a package marks in its own
//! code where a test may make it misbehave, decided per case from the case's source, as
//! FoundationDB's BUGGIFY decides its sites.
//!
//! A run names the point sets it exercises (`CheckOptions.points`, each `aegis.points.list(E)`);
//! a point of no named set stays inert. The first time a case meets a named point, it draws
//! whether the point is armed in this case; once armed, each time it is met it draws whether it
//! fires. Both are chances on the case's tape, 0 the simplest, so a failing case shrinks to the
//! points and the firings its failure needs, and replays them.
//!
//! The driver is installed around each case (`Runner.once`) and answers only on the case's own
//! thread or in a running task of a simulation: a draw from any other thread would race on the
//! source and break the case's determinism, so there every point is inert. It is not installed
//! under `explore`, whose chooser would multiply every point's draws.
const std = @import("std");
const aegis = @import("aegis");
const Source = @import("Source.zig");
const Sim = @import("Sim.zig");
const Core = @import("sim/Core.zig");

pub const Point = aegis.points.Point;

/// The chance in a million that a case arms a point it meets, and that an armed point fires
/// each time it is met: FoundationDB's 25% and 25%.
pub const arm_per_million = 250_000;
pub const fire_per_million = 250_000;

/// What a run saw of one named point.
pub const Count = struct {
    point: Point,
    /// Times a case met it where the driver answers.
    evaluated: u64 = 0,
    /// Cases that armed it.
    armed: u64 = 0,
    /// Times it fired: a fault taken, a value shortened, a task yielded, a state reached.
    fired: u64 = 0,
    /// Passing cases in which it fired.
    fired_passing: u64 = 0,
};

/// The driver and the run's counts.
pub const Points = struct {
    gpa: std.mem.Allocator,
    counts: []Count,
    /// Each point's name as `Reach` labels are matched: `Set.tag`.
    labels: [][]const u8,
    /// The current case: per point, whether it was met, armed and fired.
    case: []CaseState,
    driver: aegis.points.Driver,
    /// The current case's source, thread and simulations, while it runs.
    source: ?*Source = null,
    thread: std.Thread.Id = undefined,
    sims: ?*const std.ArrayList(*Sim) = null,

    const CaseState = struct { met: bool = false, armed: bool = false, fired: bool = false };

    const vtable: aegis.points.Driver.VTable = .{ .fault = fault, .shorten = shorten, .yield = yield, .reached = reached };

    pub fn init(gpa: std.mem.Allocator, sets: []const []const Point) std.mem.Allocator.Error!Points {
        var total: usize = 0;
        for (sets) |set| total += set.len;
        const counts = try gpa.alloc(Count, total);
        errdefer gpa.free(counts);
        const labels = try gpa.alloc([]const u8, total);
        errdefer gpa.free(labels);
        const case = try gpa.alloc(CaseState, total);
        errdefer gpa.free(case);
        var made: usize = 0;
        errdefer for (labels[0..made]) |label| gpa.free(label);
        for (sets) |set| for (set) |point| {
            counts[made] = .{ .point = point };
            labels[made] = try std.fmt.allocPrint(gpa, "{f}", .{point});
            made += 1;
        };
        @memset(case, .{});
        return .{ .gpa = gpa, .counts = counts, .labels = labels, .case = case, .driver = undefined };
    }

    pub fn deinit(p: *Points) void {
        for (p.labels) |label| p.gpa.free(label);
        p.gpa.free(p.labels);
        p.gpa.free(p.counts);
        p.gpa.free(p.case);
        p.* = undefined;
    }

    /// Installs the driver for a case drawing from `source`, run on this thread, its
    /// simulations those `sims` holds as it goes. A second driver at once is two runners at
    /// once: a bug.
    pub fn start(p: *Points, source: *Source, sims: *const std.ArrayList(*Sim)) void {
        @memset(p.case, .{});
        p.source = source;
        p.thread = std.Thread.getCurrentId();
        p.sims = sims;
        p.driver = .{ .context = p, .vtable = &vtable };
        aegis.points.install(&p.driver) catch aegis.assert.never("one fault point driver at a time: two runners at once");
    }

    /// Removes the driver; `passed` says whether the case passed, for the counts.
    pub fn end(p: *Points, passed: bool) void {
        aegis.points.uninstall(&p.driver);
        p.source = null;
        for (p.case, p.counts) |state, *count| {
            if (state.armed) count.armed += 1;
            if (passed and state.fired) count.fired_passing += 1;
        }
    }

    /// The labels of the points the case fired, for `Reach`.
    pub fn firedLabels(p: *const Points, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        for (p.case, p.labels) |state, label| if (state.fired) try out.append(gpa, label);
    }

    /// Whether every named point fired in some passing case.
    pub fn allFired(p: *const Points) bool {
        for (p.counts) |count| if (count.fired_passing == 0) return false;
        return true;
    }

    /// The counts, one row per point, for a report.
    pub fn print(p: *const Points, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("  point: evaluated, cases armed, fired, passing cases it fired in\n");
        for (p.counts, p.labels) |count, label| {
            try w.print("    {s}: {d}, {d}, {d}, {d}{s}\n", .{ label, count.evaluated, count.armed, count.fired, count.fired_passing, if (count.fired_passing == 0) "  <- never fired in a passing case" else "" });
        }
    }

    fn of(context: *anyopaque) *Points {
        return @ptrCast(@alignCast(context)); // safe: every driver of this vtable is made over a Points by `start`
    }

    /// The point's index, where the driver answers here and the run names it.
    fn answer(p: *Points, point: Point) ?usize {
        if (p.source == null or !p.here()) return null;
        for (p.counts, 0..) |count, i| {
            if (std.mem.eql(u8, count.point.name, point.name) and std.mem.eql(u8, count.point.set, point.set)) {
                p.counts[i].evaluated += 1;
                return i;
            }
        }
        return null;
    }

    /// The case's own thread outside its simulations, or a running task of one of them.
    fn here(p: *const Points) bool {
        if (Core.running_core) |core| {
            if (core.current == null) return false;
            for (p.sims.?.items) |s| if (&s.core == core) return true;
            return false;
        }
        return std.Thread.getCurrentId() == p.thread;
    }

    /// Whether point `i` is armed in this case, drawn the first time the case meets it.
    fn armed(p: *Points, i: usize) bool {
        const state = &p.case[i];
        if (!state.met) {
            state.met = true;
            state.armed = p.source.?.chance(arm_per_million);
        }
        return state.armed;
    }

    fn fired(p: *Points, i: usize) void {
        p.case[i].fired = true;
        p.counts[i].fired += 1;
    }

    fn fault(context: *anyopaque, point: Point) bool {
        const p = of(context);
        const i = p.answer(point) orelse return false;
        if (!p.armed(i) or !p.source.?.chance(fire_per_million)) return false;
        p.fired(i);
        return true;
    }

    /// `n` less a drawn amount, where armed: 0 drawn, the simplest, is `n` itself.
    fn shorten(context: *anyopaque, point: Point, n: usize) usize {
        const p = of(context);
        const i = p.answer(point) orelse return n;
        if (!p.armed(i)) return n;
        const less: usize = @intCast(p.source.?.below(n - 1)); // safe: below(n - 1) is under n, a usize
        if (less != 0) p.fired(i);
        return n - less;
    }

    fn yield(context: *anyopaque, point: Point) void {
        const p = of(context);
        const i = p.answer(point) orelse return;
        const core = Core.running_core orelse return;
        const task = core.current orelse return;
        if (!p.armed(i) or !p.source.?.chance(fire_per_million)) return;
        p.fired(i);
        core.yield(task);
    }

    fn reached(context: *anyopaque, point: Point) void {
        const p = of(context);
        const i = p.answer(point) orelse return;
        p.fired(i);
    }
};
