//! `Sim`: one simulated `Io` that owns time, tasks, randomness and storage.
//!
//! Code written against `std.Io` runs on it unchanged. Its tasks run one at
//! a time, switching only at `Io` calls, and every choice between legal
//! behaviours is drawn from one seeded source: which ready task runs next,
//! whether `async` starts a task or runs at once, a spurious futex wake, a
//! wake and a cancel landing together. Time moves only when every task is
//! waiting, straight to the next timer, so an hour of timeouts takes no
//! real time, and one seed reproduces a whole run. With `Options.faults`,
//! a `FaultIo` is the simulation's outermost part, drawing from the same
//! source, so a schedule and its faults shrink together.
//!
//! What it cannot reach is what does not go through `Io`: `std.Thread`,
//! spin loops on atomics, raw system calls, and data races between `Io`
//! calls, which are ThreadSanitizer's. Files, directories and explicit mmap
//! read/write synchronization use its disk model. TCP, UDP, Unix sockets and
//! DNS use its network model. `std.process` spawns the programs registered
//! on `programs()` as simulated processes, with pipes for their streams.
//!
//! A `Sim` must not move; `init` allocates it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const FaultIo = @import("FaultIo.zig");
const Trace = @import("trace.zig").Trace;
const Core = @import("sim/Core.zig");
const ids = @import("ids.zig");
const calls = @import("sim/calls.zig");
const Region = @import("sim/Region.zig");
const Disk = @import("sim/fs/Model.zig");
const options_mod = @import("sim/options.zig");

const Routing = @import("sim/routing.zig").Routing;
const Sim = @This();

pub const Fs = @import("sim/Fs.zig");
pub const Node = @import("sim/Node.zig");
pub const Net = @import("sim/Net.zig");
pub const Programs = @import("sim/Programs.zig");
pub const Options = options_mod.Options;
pub const Executor = options_mod.Executor;
pub const Schedule = options_mod.Schedule;
pub const AsyncStart = options_mod.AsyncStart;
pub const Outcome = options_mod.Outcome;
pub const TaskReport = options_mod.TaskReport;
/// One call, as the run's trace records it.
pub const Event = options_mod.Event;
/// A node of the simulated network, as a trace and a report name it.
pub const NodeId = @import("sim/net/Model.zig").NodeId;
/// A thread that watches simulations, shared through `Options.watched_by`.
pub const Watchdog = @import("sim/Watchdog.zig");

/// Private: the allocator the simulation was made with.
gpa: Allocator,
/// Private: tasks, time, futexes.
core: Core,
nodes: std.ArrayList(*Node) = .empty,
network: Net = undefined,
registry: Programs = undefined,
fault_context: Core.Context = undefined,
fault_outer: ?Routing = null,
/// Private: the source when the options name none.
own_source: Source,
/// Private: the fault part, when the options plan faults.
fio: ?*FaultIo = null,
/// Private: the memory `allocator` hands out, once asked for.
region: ?Region = null,
/// Private: the watchdog of its own, used unless `Options.watched_by`
/// names a shared one; the one watching it, once a run has begun; and
/// what that one reads.
own_watchdog: Watchdog = .{},
watched_by: ?*Watchdog = null,
watch: Watchdog.Watched = undefined,

pub const InitError = error{ OutOfMemory, ExecutorUnavailable, FaultNotInErrorSet, FaultNotApplicable, InvalidLink, InvalidSchedule };

pub fn init(gpa: Allocator, options: Options) InitError!*Sim {
    const s = try gpa.create(Sim);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .core = undefined, .own_source = try .init(gpa, .{ .prng = options.seed }) };
    errdefer s.own_source.deinit();
    const drawn_from = options.source orelse &s.own_source;
    s.core = try .init(gpa, options, drawn_from);
    errdefer s.core.deinit();
    s.core.context = .{ .core = &s.core };
    s.core.vtable = &calls.vtable;
    s.core.network.drawn_by = &s.core;
    s.core.network.draw_fn = struct {
        fn draw(p: *anyopaque, max: u64) u64 {
            const c: *Core = @ptrCast(@alignCast(p)); // safe: installed with this Core as drawn_by
            return c.draw(max);
        }
    }.draw;
    _ = try s.core.network.addNode(&.{});
    s.network = .{ .core = &s.core };
    s.registry = .{ .core = &s.core };
    if (s.core.fs) |*fs_| {
        fs_.clock = &s.core.clocks[@backingInt(Core.Kept.real)];
        fs_.stepper = .{ .core = &s.core, .flush = Core.flushStep };
    }
    if (options.faults.len > 0) {
        s.fault_context = .{ .core = &s.core, .inherit = true };
        const base: Io = .{ .userdata = &s.fault_context, .vtable = &calls.vtable };
        const fio = try FaultIo.init(gpa, base, .{ .source = drawn_from });
        errdefer fio.deinit();
        fio.tasks.on_crash = if (options.fs != null) crashOf else null;
        try fio.setPlan(options.faults);
        // A cancel the fault part lands is held for the simulation's task.
        fio.tasks.id = taskOf;
        fio.tasks.blocked = blockedOf;
        s.fio = fio;
        s.core.fault_io = fio.io();
        s.fault_outer = .init(fio.io(), .{ .context = &s.core.context });
    }
    s.core.outer = s.io();
    return s;
}

fn crashOf(base: Io) void {
    const c = Core.of(base.userdata);
    const node_id = c.nodeId();
    c.endProcessesOn(node_id);
    if (node_id != Core.first_node) {
        c.network.kill(node_id);
        for (c.tasks.items) |task| if (task.node == node_id) c.requestCancel(task);
        if (c.contextOf(node_id).disk) |*disk| disk.crash(.random) catch |err| {
            if (c.current) |task| c.abandon(task, .{ .failed = err });
        };
        c.notifyNetwork();
        return;
    }
    c.fs.?.crash(.random) catch |err| {
        if (c.current) |t| c.abandon(t, .{ .failed = err });
        return;
    };
    if (c.current) |t| c.abandon(t, .finished);
}

/// `FaultIo`'s key for the calling task is its own `u64`, 0 for none, over
/// any base `Io`: this simulation's key is the task's id.
fn taskOf(base: Io) u64 {
    const c = Core.of(base.userdata);
    return if (c.current) |t| t.id.raw() else ids.outside.raw();
}

fn blockedOf(base: Io) bool {
    const c = Core.of(base.userdata);
    return if (c.current) |t| t.protection == .blocked else false;
}

/// Ends the simulation. Tasks still waiting are dropped where they stand,
/// their `defer`s not run.
pub fn deinit(s: *Sim) void {
    if (s.watched_by) |w| w.remove(&s.watch);
    s.own_watchdog.deinit();
    for (s.nodes.items) |n| {
        s.gpa.free(n.name);
        s.gpa.destroy(n);
    }
    s.nodes.deinit(s.gpa);
    s.core.deinit();
    if (s.fio) |f| f.deinit();
    if (s.region) |*r| r.deinit();
    s.own_source.deinit();
    s.gpa.destroy(s);
}

/// The `Io` to hand the code under test.
pub fn io(s: *Sim) Io {
    if (s.fault_outer) |*outer| return outer.io();
    return s.coreIo();
}

fn coreIo(s: *Sim) Io {
    return .{ .userdata = &s.core.context, .vtable = &calls.vtable };
}

/// Runs `f(args)` as the root task until the run ends: every task ended,
/// the root failed, a deadlock, a limit, or a stuck task. A simulation
/// runs one root; later calls return the first outcome.
pub fn run(s: *Sim, comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) Outcome {
    if (s.core.outcome) |o| return o;
    s.startAt(f, args, @returnAddress()) catch |err| return .{ .failed = err };
    return s.drive(.run, 0).?;
}

/// Starts `f(args)` as the root task without running it: `step`,
/// `runFor` and `runUntil` then drive it. Its error, if it returns one,
/// ends the run as `failed`.
pub fn start(s: *Sim, comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) Core.SpawnError!void {
    return s.startAt(f, args, @returnAddress());
}

fn startAt(s: *Sim, comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f)), spawned_at: usize) Core.SpawnError!void {
    const Args = @TypeOf(args);
    const Start = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const a: *const Args = @ptrCast(@alignCast(context)); // safe: the core copied the arguments here
            const err: *?anyerror = @ptrCast(@alignCast(result)); // safe: the root's result slot is sized and aligned for it
            err.* = errorOf(@call(.auto, f, a.*));
        }
    };
    const root = try s.core.spawn(.{ .root = Start.start }, std.mem.asBytes(&args), .of(Args), @sizeOf(?anyerror), .of(?anyerror), .ready);
    root.spawned_at = spawned_at;
}

fn errorOf(value: anytype) ?anyerror {
    return switch (@typeInfo(@TypeOf(value))) {
        .error_union => if (value) |_| null else |err| err,
        .error_set => value,
        else => null,
    };
}

/// Frame stepping: runs until `.awake` has moved by `d`. Null while tasks
/// are still alive: waiting is not a deadlock while the test may still wake
/// them. The outcome once every task has ended or a limit is reached.
pub fn runFor(s: *Sim, d: Io.Duration) ?Outcome {
    const now_ns = s.core.clocks[@backingInt(Core.Kept.awake)];
    return s.drive(.until, now_ns +| Core.nanoseconds(d.nanoseconds));
}

/// `runFor` up to an instant on `.awake`.
pub fn runUntil(s: *Sim, t: Io.Timestamp) ?Outcome {
    return s.drive(.until, Core.nanoseconds(t.nanoseconds));
}

/// One scheduling step: the next ready task runs to its next blocking call,
/// or time moves to the next timer. Null until the run ends; a deadlock
/// ends it, since no step can be taken.
pub fn step(s: *Sim) ?Outcome {
    return s.drive(.step, 0);
}

fn drive(s: *Sim, mode: Core.Mode, until: i64) ?Outcome {
    if (s.watched_by == null) if (s.core.options.watchdog) |limit| {
        const w = s.core.options.watched_by orelse &s.own_watchdog;
        s.watch = .{ .running = &s.core.running, .calls = &s.core.calls, .stuck = &s.core.stuck, .limit = Core.nanoseconds(limit.nanoseconds) };
        if (w.add(&s.watch)) s.watched_by = w;
    };
    return s.core.drive(mode, until) catch |err| .{ .failed = err };
}

/// Calls `f(io, ctx)` on a task of its own once `.awake` reaches `t`: input
/// replay, an event at a set time.
pub fn at(s: *Sim, t: Io.Timestamp, ctx: *anyopaque, f: *const fn (io: Io, ctx: *anyopaque) void) error{ OutOfMemory, SystemResources }!void {
    const when = Core.nanoseconds(t.nanoseconds);
    const task = try s.core.spawn(.{ .at = .{ .ctx = ctx, .f = f } }, &.{}, .@"1", 0, .@"1", .parked);
    task.spawned_at = @returnAddress();
    if (when <= s.core.clocks[@backingInt(Core.Kept.awake)]) {
        task.wait = .none;
        s.core.makeReady(task);
    } else s.core.arm(task, .awake, when);
}

/// What `which` reads now.
pub fn now(s: *const Sim, which: Io.Clock) Io.Timestamp {
    return s.core.now(which);
}

/// The source every decision of the run comes from.
pub fn source(s: *Sim) *Source {
    return s.core.source;
}

/// The run's trace: one record per call, hashed whatever it keeps.
pub fn trace(s: *Sim) *Trace(Event) {
    return &s.core.trace;
}

/// The fault part, when `Options.faults` planned any.
pub fn faults(s: *Sim) ?*FaultIo {
    return s.fio;
}

/// An allocator that lays memory out the same way in every run of a seed,
/// from a region at a fixed address where the system allows one: code that
/// keys a map by pointer then repeats. Not thread-safe, which a simulation
/// does not need. Where no region can be had, the simulation's own
/// allocator.
pub fn allocator(s: *Sim) Allocator {
    if (s.region == null) s.region = Region.init() catch return s.gpa;
    return s.region.?.allocator();
}

/// Calls made so far.
/// Node zero's simulated disk. Requires Options.fs != null.
pub fn fs(s: *Sim) *Fs {
    return &s.core.fs.?;
}

/// The simulated disk `io` works on, when `io` is a simulation's
/// (`Sim.io`, `Node.io`, a simulated process's): its node's disk, or null
/// when that node has none. Null for any other `Io`. A seam whose raw calls
/// go past the `Io` asks it, to make them on the simulation instead.
pub fn fsOf(any: Io) ?*Fs {
    const ctx: *Core.Context = if (any.vtable == &calls.vtable)
        @ptrCast(@alignCast(any.userdata.?)) // safe: a simulation's own vtable is handed out with a Context as userdata
    else if (any.vtable == &Routing.vtable)
        Routing.of(any.userdata).state.context
    else
        return null;
    return ctx.core.diskOf(ctx.node);
}

pub fn steps(s: *const Sim) u64 {
    return s.core.steps;
}

// Panics.

/// A panic handler that says, before std's, which simulation the panicking
/// task ran in: its seed, its tape when it records one, and its last calls.
/// Install it in the test's root: `pub const panic = shakedown.panic;`.
pub const panic = std.debug.FullPanic(panicked);

fn panicked(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (Core.running_core) |c| {
        Core.running_core = null;
        const s: *Sim = @fieldParentPtr("core", c);
        s.describe();
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn describe(s: *Sim) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    const w = stderr.writer;
    w.print("shakedown: a task panicked in a simulation at step {d}", .{s.core.steps}) catch return;
    if (s.core.options.source == null) w.print(", seed 0x{x}", .{s.core.options.seed}) catch return;
    const t = s.core.source.tape();
    if (t.choices.len > 0) w.print("; tape {f}", .{t}) catch return;
    w.writeAll("\nlast calls:\n") catch return;
    s.core.trace.format(w) catch return;
}

/// The owned deterministic network. Disabled network slots fail explicitly.
pub fn net(s: *Sim) *Net {
    return &s.network;
}

/// The programs `std.process` spawns in this simulation.
pub fn programs(s: *Sim) *Programs {
    return &s.registry;
}
/// Create an isolated node before or during a run. Addresses default to 10.x.x.x.
pub fn node(s: *Sim, name: []const u8, options: Node.Options) error{OutOfMemory}!*Node {
    try s.nodes.ensureUnusedCapacity(s.gpa, 1);
    try s.core.contexts.ensureUnusedCapacity(s.gpa, 1);
    const ctx = try s.gpa.create(Core.Context);
    errdefer s.gpa.destroy(ctx);
    ctx.* = .{ .core = &s.core };
    if (options.fs) |o| ctx.disk = .{ .model = try Disk.init(s.gpa, s.core.source, o), .clock = &s.core.clocks[@backingInt(Core.Kept.real)], .stepper = .{ .core = &s.core, .flush = Core.flushStep } };
    errdefer if (ctx.disk) |disk| disk.model.deinit();
    const n = try s.gpa.create(Node);
    errdefer s.gpa.destroy(n);
    const owned_name = try s.gpa.dupe(u8, name);
    errdefer s.gpa.free(owned_name);
    ctx.node = try s.core.network.addNode(options.addresses);
    n.* = .{ .context = ctx, .name = owned_name };
    if (s.fio) |fio| n.outer = .init(fio.io(), .{ .context = ctx });
    s.core.contexts.appendAssumeCapacity(ctx);
    s.nodes.appendAssumeCapacity(n);
    return n;
}
