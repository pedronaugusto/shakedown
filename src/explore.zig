//! `explore`: every run of a property, not a sample of them.
//!
//! `check` draws a property's choices at random; `explore` makes every one
//! of them in turn. It runs the body, then runs it again with the last
//! choice it can still change changed, depth first, until no choice is
//! left untried: a stateless model checker over the property's own tape.
//! A choice with more than `max_branch` alternatives (a latency, a byte of
//! `io.random`, a fault's chance) keeps its simplest value, so the search
//! spans what is small enough to span: schedules, spurious wakes, `async`
//! starting at once or not, a wake landing with a cancel, a property's own
//! small draws.
//!
//! A simulation the body makes with `Case.sim` takes the bounded schedule:
//! at every call a task makes while another can run, the search chooses
//! whether it goes on, at most `preemptions` times a run, and whenever a
//! task waits, which one runs next (Musuvathi and Qadeer's bound, CHESS:
//! most concurrency bugs need two preemptions or fewer).
//!
//! Orders that differ only in the order of steps that cannot affect each
//! other are searched once (dynamic partial-order reduction with sleep sets,
//! Flanagan and Godefroid, POPL 2005, made sound under the preemption bound
//! as Coons, Musuvathi and McKinley do, OOPSLA 2013). Two steps affect each
//! other when they touch one simulated object (a futex, a task, a group, a
//! disk, the network, the pipes, a process) or one memory: what memory
//! tasks share is `memory`'s to say, and by default they all share it, so
//! every order of steps of different tasks is searched.
//!
//! A failing run is shrunk and reported as `check` reports it, with the tape
//! that replays it (`SHAKEDOWN_TAPE`), under this same schedule.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const Tape = Source.Tape;
const checking = @import("check.zig");
const Case = checking.Case;
const Sim = @import("Sim.zig");

pub const ExploreOptions = struct {
    /// Preemptions a run may have.
    preemptions: u8 = 2,
    /// Spurious futex wakes a run may have.
    spurious_wakes: u8 = 0,
    /// What simulated tasks may share; see `Sim.Schedule.Bounded.memory`.
    memory: @FieldType(Sim.Schedule.Bounded, "memory") = .shared,
    /// Whether orders that differ only in independent steps are run once.
    reduction: enum { partial_order, none } = .partial_order,
    /// A choice with more alternatives than this keeps its simplest value.
    max_branch: u32 = 16,
    /// Choices other than schedules a run may make other than the simplest
    /// (0), or null for any number: a delay bound (Emmi, Qadeer and
    /// Rakamaric, POPL 2011), for a body whose small choices go on as long
    /// as they are made (an operation that may complete at any later poll).
    max_deviations: ?u32 = null,
    /// Runs the search may make; past them it ends incomplete.
    max_runs: u64 = 1 << 20,
    /// The most choices one run may draw; a larger one is discarded.
    max_choices: u32 = 1 << 16,
    /// Replays the shrinker may make of a failing run.
    max_shrink_runs: u32 = 5_000,
    /// Filled when a run fails, if given, as `check` fills it.
    diagnostics: ?*checking.CheckReport = null,
};

/// What a search did.
pub const Exploration = struct {
    /// Runs made, redundant ones included.
    runs: u64,
    /// Runs found, once begun, to repeat an order already searched, and
    /// cut short of choices.
    redundant: u64,
    /// Whether every run within the bounds was made: false when `max_runs`
    /// ran out first.
    complete: bool,
    /// Choices of more than `max_branch` alternatives, held at their
    /// simplest value, in the last run.
    held: u64,
};

/// `PropertyFailed`: a run failed (reported). `Nondeterministic`: a run
/// made the same choices as an earlier one and was offered others, so the
/// search cannot trust a tape: the body depends on something besides its
/// source. `InvalidTape`: `SHAKEDOWN_TAPE` is not a tape.
pub const ExploreError = error{ PropertyFailed, OutOfMemory, Nondeterministic, InvalidTape, Unsatisfiable };

/// Runs `body` once for every way its choices can go within the bounds.
/// `SHAKEDOWN_TAPE=<tape>` replays one run instead, under the same schedule.
pub fn explore(
    gpa: Allocator,
    ctx: anytype,
    comptime body: fn (@TypeOf(ctx), *Case) anyerror!void,
    options: ExploreOptions,
) ExploreError!Exploration {
    var runner: checking.Runner = try .init(gpa, .{ .max_choices = options.max_choices, .max_shrink_runs = options.max_shrink_runs, .diagnostics = options.diagnostics });
    defer runner.deinit();
    runner.bounded = .{ .preemptions = options.preemptions, .spurious_wakes = options.spurious_wakes, .memory = options.memory };
    const Body = checking.Bound(@TypeOf(ctx), body);
    var bound: Body = .{ .ctx = ctx };
    runner.body = .{ .ctx = &bound, .run = Body.run };

    if (try checking.environment(gpa, "SHAKEDOWN_TAPE")) |text| {
        defer gpa.free(text);
        const choices = Tape.parse(gpa, text) catch |err| return checking.invalid(err);
        defer gpa.free(choices);
        try runner.replayOnly(choices);
        return .{ .runs = 1, .redundant = 0, .complete = false, .held = 0 };
    }

    var search: Search = .init(gpa, options);
    defer search.deinit();
    while (true) {
        search.begin();
        const outcome = try runner.once(.{ .chooser = search.chooser() });
        if (search.oom) return error.OutOfMemory;
        if (search.diverged) return error.Nondeterministic;
        switch (outcome) {
            .fail => |err| return runner.failed(err, .{ .explored = search.runs }),
            .pass, .discard => {},
        }
        try search.end();
        if (!try search.advance()) return search.summary(true);
        if (search.runs >= options.max_runs) return search.summary(false);
    }
}

const Access = struct { object: u64, write: bool };

fn conflict(a: Access, b: Access) bool {
    return a.object == b.object and (a.write or b.write);
}

fn conflicts(a: []const Access, b: []const Access) bool {
    for (a) |x| for (b) |y| if (conflict(x, y)) return true;
    return false;
}

/// A run of a pool: `[start, start + len)`.
const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    fn of(comptime T: type, pool: []const T, r: Range) []const T {
        return pool[r.start..][0..r.len];
    }
};

/// An option of a pick: whether a race says to try it, whether it was
/// tried, and the first step it took from there.
const Option = struct { backtrack: bool = false, done: bool = false, footprint: ?Range = null };

/// An actor asleep: its next step, already searched from an earlier state,
/// and independent of everything run since.
const Sleeper = struct { actor: u32, footprint: Range };

/// How long each pool was once a point last added to it: popping the points
/// past one cuts the pools back to its marks, since a point adds to the
/// pools only while it is the deepest on the path.
const Marks = struct { ids: u32 = 0, options: u32 = 0, sleepers: u32 = 0, prints: u32 = 0 };

/// A choice on the current path, kept across the runs that share it. A
/// pick's actors, options and sleep set live in the search's pools.
const Point = struct {
    kind: enum { data, pick },
    /// The largest choice that will be made here: 0 for a choice held at
    /// its simplest value.
    bound: u64,
    chosen: u64,
    preemptive: bool = false,
    actors: Range = .{},
    options: Range = .{},
    /// The actors asleep when the path reached it.
    asleep: Range = .{},
    marks: Marks = .{},
};

/// One step of one run: an actor's run from a point where it was chosen, or
/// went on, to its next.
const Step = struct {
    actor: u32,
    /// The pick that began it, when one did.
    pre: ?u32,
    /// The latest pick before it began.
    after: ?u32,
    /// Its accesses, `[first, first + len)` of the run's.
    first: u32,
    len: u32 = 0,
    /// The step of the actor that started this one's, for its first step.
    parent: ?u32 = null,
};

const Search = struct {
    gpa: Allocator,
    options: ExploreOptions,
    path: std.ArrayList(Point) = .empty,
    // The path's pools.
    ids: std.ArrayList(u32) = .empty,
    picks: std.ArrayList(Option) = .empty,
    sleepers: std.ArrayList(Sleeper) = .empty,
    prints: std.ArrayList(Access) = .empty,
    /// The first steps options took, recorded after deeper points were
    /// made: not on the stack the other pools keep, so compacted instead
    /// when what the path still holds is a small part of it.
    footprints: std.ArrayList(Access) = .empty,
    /// Where the next run changes the path: its choices before this point
    /// are the last run's.
    branch: ?usize = null,
    // The run under way.
    depth: usize = 0,
    steps: std.ArrayList(Step) = .empty,
    accesses: std.ArrayList(Access) = .empty,
    /// The step under way, the pick whose chosen actor begins the next, and
    /// the latest pick.
    current: ?u32 = null,
    pending: ?u32 = null,
    last_pick: ?u32 = null,
    /// Whose first step happens after which step.
    parents: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The sleep set as the run goes, its footprints in `asleep_prints`.
    asleep: std.ArrayList(Sleeper) = .empty,
    asleep_prints: std.ArrayList(Access) = .empty,
    // The race analysis's room, kept between runs.
    actor_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    clocks: std.ArrayList(u32) = .empty,
    before: std.ArrayList(u32) = .empty,
    last: std.ArrayList(?u32) = .empty,
    objects: std.AutoHashMapUnmanaged(u64, Accessed) = .empty,
    reads: std.ArrayList(Read) = .empty,
    redundant_run: bool = false,
    diverged: bool = false,
    oom: bool = false,
    held: u64 = 0,
    runs: u64 = 0,
    redundant: u64 = 0,

    /// An object's last write, and the reads since, newest first.
    const Accessed = struct { write: ?u32 = null, reads: ?u32 = null };
    const Read = struct { step: u32, next: ?u32 };

    fn init(gpa: Allocator, options: ExploreOptions) Search {
        return .{ .gpa = gpa, .options = options };
    }

    fn deinit(s: *Search) void {
        s.path.deinit(s.gpa);
        s.ids.deinit(s.gpa);
        s.picks.deinit(s.gpa);
        s.sleepers.deinit(s.gpa);
        s.prints.deinit(s.gpa);
        s.footprints.deinit(s.gpa);
        s.steps.deinit(s.gpa);
        s.accesses.deinit(s.gpa);
        s.parents.deinit(s.gpa);
        s.asleep.deinit(s.gpa);
        s.asleep_prints.deinit(s.gpa);
        s.actor_index.deinit(s.gpa);
        s.clocks.deinit(s.gpa);
        s.before.deinit(s.gpa);
        s.last.deinit(s.gpa);
        s.objects.deinit(s.gpa);
        s.reads.deinit(s.gpa);
    }

    fn summary(s: *const Search, complete: bool) Exploration {
        return .{ .runs = s.runs, .redundant = s.redundant, .complete = complete, .held = s.held };
    }

    fn chooser(s: *Search) Source.Chooser {
        return .{ .ctx = s, .vtable = &vtable };
    }

    const vtable: Source.Chooser.VTable = .{ .choose = choose, .pick = pick, .step = step, .touch = touch, .spawned = spawned };

    fn of(ctx: *anyopaque) *Search {
        return @ptrCast(@alignCast(ctx)); // safe: every chooser of this vtable is made by `chooser` over a Search
    }

    fn marks(s: *const Search) Marks {
        return .{ .ids = @intCast(s.ids.items.len), .options = @intCast(s.picks.items.len), .sleepers = @intCast(s.sleepers.items.len), .prints = @intCast(s.prints.items.len) };
    }

    fn actorsOf(s: *const Search, p: *const Point) []const u32 {
        return Range.of(u32, s.ids.items, p.actors);
    }

    fn optionsOf(s: *Search, p: *const Point) []Option {
        return s.picks.items[p.options.start..][0..p.options.len];
    }

    fn begin(s: *Search) void {
        s.runs += 1;
        s.depth = 0;
        s.steps.clearRetainingCapacity();
        s.accesses.clearRetainingCapacity();
        s.parents.clearRetainingCapacity();
        s.asleep.clearRetainingCapacity();
        s.asleep_prints.clearRetainingCapacity();
        s.current = null;
        s.pending = null;
        s.last_pick = null;
        s.redundant_run = false;
        s.held = 0;
    }

    /// Whether the run has passed the point where it leaves the last one.
    fn fresh(s: *const Search) bool {
        const b = s.branch orelse return true;
        return s.depth > b;
    }

    fn choose(ctx: *anyopaque, max: u64) u64 {
        const s = of(ctx);
        if (s.depth < s.path.items.len) {
            const p = &s.path.items[s.depth];
            s.depth += 1;
            if (p.kind != .data or (p.bound != 0 and p.bound != max) or p.chosen > max) s.diverged = true;
            if (p.bound == 0 and max > s.options.max_branch) s.held += 1;
            return @min(p.chosen, max);
        }
        const held = max > s.options.max_branch or s.redundant_run;
        if (max > s.options.max_branch) s.held += 1;
        s.path.append(s.gpa, .{ .kind = .data, .bound = if (held) 0 else max, .chosen = 0, .marks = s.marks() }) catch {
            s.oom = true;
            return 0;
        };
        s.depth += 1;
        return 0;
    }

    fn pick(ctx: *anyopaque, actors: []const u32, preemptive: bool) u64 {
        const s = of(ctx);
        if (s.depth < s.path.items.len) {
            const at = s.depth;
            const p = &s.path.items[at];
            s.depth += 1;
            if (p.kind != .pick or p.preemptive != preemptive or !std.mem.eql(u32, s.actorsOf(p), actors)) {
                s.diverged = true;
                return 0;
            }
            if (s.branch == at) s.wake(p) catch {
                s.oom = true;
            };
            s.pending = @intCast(at);
            s.last_pick = @intCast(at);
            return p.chosen;
        }
        return s.newPick(actors, preemptive) catch {
            s.oom = true;
            return 0;
        };
    }

    /// The sleep set where the path branches at `p`: what was asleep when it
    /// was reached, and every option tried there before.
    fn wake(s: *Search, p: *const Point) Allocator.Error!void {
        s.asleep.clearRetainingCapacity();
        s.asleep_prints.clearRetainingCapacity();
        for (Range.of(Sleeper, s.sleepers.items, p.asleep)) |a| try s.sleep(a.actor, Range.of(Access, s.prints.items, a.footprint));
        if (s.options.reduction == .none) return;
        const actors = s.actorsOf(p);
        for (s.optionsOf(p), 0..) |o, i| {
            if (!o.done or i == p.chosen) continue;
            if (o.footprint) |f| try s.sleep(actors[i], Range.of(Access, s.footprints.items, f));
        }
    }

    fn sleep(s: *Search, actor: u32, footprint: []const Access) Allocator.Error!void {
        const start: u32 = @intCast(s.asleep_prints.items.len);
        try s.asleep_prints.appendSlice(s.gpa, footprint);
        try s.asleep.append(s.gpa, .{ .actor = actor, .footprint = .{ .start = start, .len = @intCast(footprint.len) } });
    }

    fn isAsleep(s: *const Search, actor: u32) bool {
        for (s.asleep.items) |a| if (a.actor == actor) return true;
        return false;
    }

    fn newPick(s: *Search, actors: []const u32, preemptive: bool) Allocator.Error!u64 {
        try s.path.ensureUnusedCapacity(s.gpa, 1);
        try s.ids.ensureUnusedCapacity(s.gpa, actors.len);
        try s.picks.ensureUnusedCapacity(s.gpa, actors.len);
        try s.sleepers.ensureUnusedCapacity(s.gpa, s.asleep.items.len);
        var footprints: usize = 0;
        for (s.asleep.items) |a| footprints += a.footprint.len;
        try s.prints.ensureUnusedCapacity(s.gpa, footprints);
        var p: Point = .{ .kind = .pick, .bound = actors.len - 1, .chosen = 0, .preemptive = preemptive };
        p.actors = .{ .start = @intCast(s.ids.items.len), .len = @intCast(actors.len) };
        s.ids.appendSliceAssumeCapacity(actors);
        p.options = .{ .start = @intCast(s.picks.items.len), .len = @intCast(actors.len) };
        s.picks.appendNTimesAssumeCapacity(.{}, actors.len);
        p.asleep = .{ .start = @intCast(s.sleepers.items.len), .len = @intCast(s.asleep.items.len) };
        for (s.asleep.items) |a| {
            const start: u32 = @intCast(s.prints.items.len);
            s.prints.appendSliceAssumeCapacity(Range.of(Access, s.asleep_prints.items, a.footprint));
            s.sleepers.appendAssumeCapacity(.{ .actor = a.actor, .footprint = .{ .start = start, .len = a.footprint.len } });
        }
        // The first awake option, the running actor first: no preemption
        // spent where none is needed.
        var chosen: ?usize = null;
        for (actors, 0..) |a, i| if (!s.isAsleep(a)) {
            chosen = i;
            break;
        };
        if (chosen == null) s.redundant_run = true;
        p.chosen = chosen orelse 0;
        const options = s.optionsOf(&p);
        for (options, 0..) |*o, i| {
            // A redundant run tries nothing more below it; without reduction
            // every option is to be tried.
            o.done = s.redundant_run or i == p.chosen;
            o.backtrack = !s.redundant_run and (s.options.reduction == .none or i == p.chosen);
        }
        p.marks = s.marks();
        s.path.appendAssumeCapacity(p);
        const at = s.depth;
        s.depth += 1;
        s.pending = @intCast(at);
        s.last_pick = @intCast(at);
        return p.chosen;
    }

    fn step(ctx: *anyopaque, actor: u32) void {
        const s = of(ctx);
        var pre: ?u32 = null;
        if (s.pending) |at| {
            const p = &s.path.items[at];
            if (s.actorsOf(p)[@intCast(p.chosen)] == actor) pre = at;
            s.pending = null;
        }
        if (s.fresh() and pre == null and s.isAsleep(actor)) s.redundant_run = true;
        const index: u32 = @intCast(s.steps.items.len);
        var parent: ?u32 = null;
        if (s.parents.fetchRemove(actor)) |kv| parent = kv.value;
        s.steps.append(s.gpa, .{ .actor = actor, .pre = pre, .after = s.last_pick, .first = @intCast(s.accesses.items.len), .parent = parent }) catch {
            s.oom = true;
            return;
        };
        s.current = index;
    }

    fn touch(ctx: *anyopaque, actor: u32, object: u64, write: bool) void {
        const s = of(ctx);
        const index = s.current orelse return;
        const st = &s.steps.items[index];
        if (st.actor != actor) return;
        const access: Access = .{ .object = object, .write = write };
        s.accesses.append(s.gpa, access) catch {
            s.oom = true;
            return;
        };
        st.len += 1;
        if (!s.fresh()) return;
        // A sleeping actor whose step this one affects wakes. Its footprint
        // stays in `asleep_prints` until the run's sleep set is next reset.
        var i: usize = 0;
        while (i < s.asleep.items.len) {
            const a = s.asleep.items[i];
            var hit = false;
            for (Range.of(Access, s.asleep_prints.items, a.footprint)) |f| if (conflict(f, access)) {
                hit = true;
                break;
            };
            if (hit) {
                _ = s.asleep.swapRemove(i);
            } else i += 1;
        }
    }

    fn spawned(ctx: *anyopaque, parent: u32, child: u32) void {
        const s = of(ctx);
        _ = parent;
        const index = s.current orelse return;
        s.parents.put(s.gpa, child, index) catch {
            s.oom = true;
        };
    }

    fn accessesOf(s: *const Search, st: Step) []const Access {
        return s.accesses.items[st.first..][0..st.len];
    }

    /// After a run: what each option tried took as its first step, and the
    /// races that say which other options must be tried.
    fn end(s: *Search) Allocator.Error!void {
        if (s.redundant_run) s.redundant += 1;
        // Points the run left behind it, once it turned redundant, are of no
        // use: nothing below them is new.
        for (s.steps.items) |st| {
            const at = st.pre orelse continue;
            if (s.branch) |b| if (at < b) continue;
            const p = &s.path.items[at];
            const o = &s.optionsOf(p)[@intCast(p.chosen)];
            if (o.footprint != null) continue;
            const start: u32 = @intCast(s.footprints.items.len);
            try s.footprints.appendSlice(s.gpa, s.accessesOf(st));
            o.footprint = .{ .start = start, .len = st.len };
        }
        switch (s.options.reduction) {
            .none => {},
            .partial_order => try s.races(),
        }
    }

    /// Flanagan and Godefroid's backtracking: for each step, the latest
    /// earlier step of another actor it depends on and does not already
    /// follow; the state before that step must also try this step's actor.
    /// Each object remembers its last write and the reads since, so a step
    /// looks only at the steps it can depend on directly; the rest it
    /// follows through them.
    fn races(s: *Search) Allocator.Error!void {
        const n = s.steps.items.len;
        if (n == 0) return;
        const index = &s.actor_index;
        index.clearRetainingCapacity();
        for (s.steps.items) |st| {
            const gop = try index.getOrPut(s.gpa, st.actor);
            if (!gop.found_existing) gop.value_ptr.* = index.count() - 1;
        }
        const width: usize = index.count();
        // Clock vectors: step j knows, of each actor, one past the latest of
        // its steps that happens before j (0 for none).
        try s.clocks.resize(s.gpa, n * width);
        const clocks = s.clocks.items;
        @memset(clocks, 0);
        try s.before.resize(s.gpa, width);
        const before = s.before.items;
        try s.last.resize(s.gpa, width);
        const last = s.last.items;
        @memset(last, null);
        const objects = &s.objects;
        objects.clearRetainingCapacity();
        s.reads.clearRetainingCapacity();
        for (s.steps.items, 0..) |st, j| {
            const me = index.get(st.actor).?;
            const clock = clocks[j * width ..][0..width];
            if (last[me]) |prev| join(clock, clocks[prev * width ..][0..width]);
            if (st.parent) |parent| join(clock, clocks[parent * width ..][0..width]);
            @memcpy(before, clock);
            var raced: ?u32 = null;
            for (s.accessesOf(st)) |access| {
                const o = objects.getPtr(access.object) orelse continue;
                if (o.write) |w| s.dependOn(w, st.actor, before, clock, width, clocks, index, &raced);
                if (access.write) {
                    var r = o.reads;
                    while (r) |at| : (r = s.reads.items[at].next) s.dependOn(s.reads.items[at].step, st.actor, before, clock, width, clocks, index, &raced);
                }
            }
            clock[me] = @intCast(j + 1);
            last[me] = @intCast(j);
            for (s.accessesOf(st)) |access| {
                const gop = try objects.getOrPut(s.gpa, access.object);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                if (access.write) {
                    gop.value_ptr.* = .{ .write = @intCast(j) };
                } else {
                    try s.reads.append(s.gpa, .{ .step = @intCast(j), .next = gop.value_ptr.reads });
                    gop.value_ptr.reads = @intCast(s.reads.items.len - 1);
                }
            }
            if (raced) |r| try s.backtrackFor(s.steps.items[r], st.actor);
        }
    }

    /// Step `i` is one this step depends on: a race when another actor took
    /// it and this actor did not already follow it; this step follows it
    /// from here.
    fn dependOn(s: *const Search, i: u32, actor: u32, before: []const u32, clock: []u32, width: usize, clocks: []const u32, index: *const std.AutoHashMapUnmanaged(u32, u32), raced: *?u32) void {
        const other = s.steps.items[i];
        if (other.actor == actor) return;
        const them = index.get(other.actor).?;
        if (before[them] <= i and (raced.* == null or raced.*.? < i)) raced.* = i;
        join(clock, clocks[@as(usize, i) * width ..][0..width]);
    }

    /// The state before step `racing` must also try `actor`, or, where
    /// `actor` cannot run, everything that can. Where that state offered no
    /// choice (the bound was spent, or it alone could run), and where trying
    /// `actor` there would spend a preemption, `actor` is tried at the last
    /// choice before it that can run it without one, so the bound cannot
    /// hide the other order (Coons, Musuvathi and McKinley).
    fn backtrackFor(s: *Search, racing: Step, actor: u32) Allocator.Error!void {
        if (racing.pre) |at| {
            const p = &s.path.items[at];
            const i = std.mem.findScalar(u32, s.actorsOf(p), actor) orelse {
                for (s.optionsOf(p)) |*o| o.backtrack = true;
                return;
            };
            s.optionsOf(p)[i].backtrack = true;
            if (p.preemptive and i != 0) s.backtrackFree(at, actor);
            return;
        }
        const latest = racing.after orelse return;
        var k: usize = latest + 1;
        while (k > 0) {
            k -= 1;
            const q = &s.path.items[k];
            if (q.kind != .pick) continue;
            const i = std.mem.findScalar(u32, s.actorsOf(q), actor) orelse continue;
            s.optionsOf(q)[i].backtrack = true;
            if (q.preemptive and i != 0) s.backtrackFree(k, actor);
            return;
        }
    }

    /// Tries `actor` at the last choice before `at` that runs it without a
    /// preemption.
    fn backtrackFree(s: *Search, at: usize, actor: u32) void {
        var k = at;
        while (k > 0) {
            k -= 1;
            const q = &s.path.items[k];
            if (q.kind != .pick or q.preemptive) continue;
            if (std.mem.findScalar(u32, s.actorsOf(q), actor)) |i| {
                s.optionsOf(q)[i].backtrack = true;
                return;
            }
        }
    }

    /// The next run's path: the deepest choice with an option left, changed
    /// to it; false when there is none.
    fn advance(s: *Search) Allocator.Error!bool {
        while (s.path.items.len > 0) {
            const at = s.path.items.len - 1;
            const p = &s.path.items[at];
            switch (p.kind) {
                .data => if (p.chosen < p.bound and (p.chosen > 0 or s.mayDeviate(at))) {
                    p.chosen += 1;
                    s.branch = at;
                    return true;
                },
                .pick => {
                    const actors = s.actorsOf(p);
                    for (s.optionsOf(p), 0..) |*o, i| {
                        if (!o.backtrack or o.done) continue;
                        o.done = true;
                        if (s.asleepAt(p, actors[i])) continue;
                        p.chosen = i;
                        s.branch = at;
                        return true;
                    }
                },
            }
            _ = s.path.pop();
            const m = if (s.path.items.len > 0) s.path.items[s.path.items.len - 1].marks else Marks{};
            s.ids.shrinkRetainingCapacity(m.ids);
            s.picks.shrinkRetainingCapacity(m.options);
            s.sleepers.shrinkRetainingCapacity(m.sleepers);
            s.prints.shrinkRetainingCapacity(m.prints);
            try s.compact();
        }
        return false;
    }

    /// Copies the footprints the path still holds to the front of their
    /// pool, once they are a quarter of it or less.
    fn compact(s: *Search) Allocator.Error!void {
        var live: usize = 0;
        for (s.picks.items) |o| if (o.footprint) |f| {
            live += f.len;
        };
        if (s.footprints.items.len < 4096 or live * 4 > s.footprints.items.len) return;
        var kept: std.ArrayList(Access) = try .initCapacity(s.gpa, live);
        for (s.picks.items) |*o| if (o.footprint) |*f| {
            const start: u32 = @intCast(kept.items.len);
            kept.appendSliceAssumeCapacity(Range.of(Access, s.footprints.items, f.*));
            f.start = start;
        };
        s.footprints.deinit(s.gpa);
        s.footprints = kept;
    }

    /// Whether a run may deviate at data point `at`, given the choices
    /// before it.
    fn mayDeviate(s: *const Search, at: usize) bool {
        const most = s.options.max_deviations orelse return true;
        var made: u32 = 0;
        for (s.path.items[0..at]) |q| {
            if (q.kind == .data and q.chosen != 0) made += 1;
        }
        return made < most;
    }

    fn asleepAt(s: *const Search, p: *const Point, actor: u32) bool {
        for (Range.of(Sleeper, s.sleepers.items, p.asleep)) |a| if (a.actor == actor) return true;
        return false;
    }
};

fn join(into: []u32, from: []const u32) void {
    for (into, from) |*a, b| a.* = @max(a.*, b);
}
