//! The simulation's core: tasks, the scheduler, virtual time and futexes.
//!
//! One task runs at a time. A task runs until it blocks, yields or ends;
//! then the scheduler picks the next runnable one and switches straight to
//! it, or, when none can run, moves time to the earliest armed timer. When
//! nothing can run and no timer is armed the run is over: finished when
//! every task has ended, deadlocked when some are still waiting. Control
//! then returns to the driver, the thread that called `Sim.run`.
//!
//! Everything the core decides at random it draws from the simulation's
//! source, and only when there is a real choice, so a tape holds only the
//! decisions that could have gone another way. Nothing here allocates once
//! a run's tasks exist: timers, futex waits and run queue slots live in the
//! tasks, and finished tasks are kept, with their stacks, for the next.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const Source = @import("../Source.zig");
const ids = @import("../ids.zig");
const Trace = @import("../trace.zig").Trace;
const IoCall = @import("../io_call.zig").IoCall;
const executor = @import("executor.zig");
const options_mod = @import("options.zig");
const Options = options_mod.Options;
const Event = options_mod.Event;
const Outcome = options_mod.Outcome;
const TaskReport = options_mod.TaskReport;

const Fs = @import("Fs.zig");
const Disk = @import("fs/Model.zig");
const Network = @import("net/Model.zig");
const NodeId = Network.NodeId;
const Processes = @import("programs/Model.zig");
const Process = Processes.Process;
const Core = @This();

/// The first node: the one every simulation has, whose files are `Options.fs`.
pub const first_node: NodeId = .fromRaw(0);

/// An Io namespace: the node a call is made on, and the simulated process
/// making it (null for the test's own, whose working directory, when it
/// changed it, is `cwd`).
pub const Context = struct {
    core: *Core,
    node: NodeId = first_node,
    inherit: bool = false,
    disk: ?Fs = null,
    process: ?*Process = null,
    cwd: ?Io.Dir = null,
};

gpa: Allocator,
options: Options,
source: *Source,
fs: ?Fs = null,
network: Network,
context: Context = undefined,
vtable: *const Io.VTable = undefined,
contexts: std.ArrayList(*Context) = .empty,
/// The namespace of the driver's last call, made outside any task.
active_context: ?*Context = null,
/// The simulated processes and their pipes.
processes: Processes,
/// The fault part's Io, when the simulation plans faults: what a process's
/// own Io routes through.
fault_io: ?Io = null,
/// Memory that lives as long as the simulation: the namespaces of its
/// processes, which a task's last call may name after the process ended.
keep: std.heap.ArenaAllocator,
network_seen: u32 = 0,
kind: executor.Kind,
/// The `Io` handed to tasks the core starts itself (`Sim.at`).
outer: Io = undefined,
trace: Trace(Event),
steps: u64 = 0,

clocks: [3]i64,
/// `.awake` when the simulation began, for `Options.max_time`.
start: i64,
timers: [3]Timers = .{ .{}, .{}, .{} },
timer_seq: u64 = 0,

/// Every task ever made, live or kept for reuse.
tasks: std.ArrayList(*Task) = .empty,
/// Tasks that ended and were released, ready to run another job.
idle: std.ArrayList(*Task) = .empty,
next_id: ids.TaskIssuer = .init(0),
/// Tasks started and not yet ended.
live: u32 = 0,
ready: std.ArrayList(*Task) = .empty,
/// FIFO: where the queue in `ready` starts.
ready_head: usize = 0,
ready_seq: u64 = 0,
current: ?*Task = null,
driver: executor.Context,
buckets: [bucket_count]Bucket = @splat(.{}),

outcome: ?Outcome = null,
mode: Mode = .run,
step_taken: bool = false,
until: i64 = 0,
change_points: [max_depth]u64 = @splat(0),
change_count: u8 = 0,
next_change: u8 = 0,
/// A digest of the choices drawn during the current call.
decision: ?u64 = null,
/// The parked task the driver is asking for its stack.
capturing: ?*Task = null,
reports: std.ArrayList(TaskReport) = .empty,

/// Shared with the watchdog thread: the step count, the running task's id (0
/// when none), and whether the watchdog found the run stuck.
calls: std.atomic.Value(u64) = .init(0),
running: std.atomic.Value(ids.TaskId) = .init(ids.outside),
stuck: std.atomic.Value(bool) = .init(false),

const max_depth = 16;
const bucket_count = 256;

pub const Mode = enum { run, until, step };

pub const Kept = enum(u2) { awake, boot, real };

const Key = struct {
    deadline: i64,
    seq: u64,

    fn order(a: Key, b: Key) std.math.Order {
        return switch (std.math.order(a.deadline, b.deadline)) {
            .eq => std.math.order(a.seq, b.seq),
            else => |o| o,
        };
    }
};

const Timers = std.Treap(Key, Key.order);

const Bucket = struct { head: ?*Task = null, tail: ?*Task = null };

/// What a task was asked to do.
pub const Job = union(enum) {
    /// `async` or `concurrent`: its result waits in the frame for `await`.
    future: *const fn (context: *const anyopaque, result: *anyopaque) void,
    /// A group member: released as soon as it returns.
    member: *const fn (context: *const anyopaque) void,
    /// `Sim.run`'s function: its error, if any, ends the run.
    root: *const fn (context: *const anyopaque, result: *anyopaque) void,
    node: *const fn (context: *const anyopaque, result: *anyopaque) void,
    /// `Sim.at`'s function, started when its timer fires.
    at: struct { ctx: *anyopaque, f: *const fn (io: Io, ctx: *anyopaque) void },
    /// A simulated process's `main`: the process ends when it returns.
    program: *Process,
};

pub const State = enum { idle, ready, running, parked, deferred, done, abandoned };

pub const Cancel = enum { none, requested, delivered };

/// Why a parked task runs again.
pub const Wake = enum { none, woken, timeout, canceled, spurious };

pub const Wait = union(enum) {
    none,
    /// A task of `Sim.at`, waiting for its time to start.
    start,
    futex: usize,
    sleep,
    task: *Task,
    group: *Io.Group,
    /// A simulated process, by id, to end.
    process: u32,
};

pub const Task = struct {
    core: *Core,
    id: ids.TaskId = ids.outside,
    node: NodeId = first_node,
    /// The process the task belongs to; null for the test's own.
    process: ?*Process = null,
    /// The namespace of the call the task is making.
    io_context: ?*Context = null,
    state: State = .idle,
    ctx: executor.Context,
    job: Job = undefined,
    /// The job's context bytes and result, at their alignments.
    frame: []align(frame_align) u8 = &.{},
    context_offset: usize = 0,
    result_offset: usize = 0,
    result_len: usize = 0,
    /// The task awaiting or canceling this one.
    awaiter: ?*Task = null,
    group: ?*Io.Group = null,
    cancel: Cancel = .none,
    protection: Io.CancelProtection = .unblocked,
    wait: Wait = .none,
    /// Whether the current wait ends on a cancel.
    cancelable: bool = false,
    wake: Wake = .none,
    futex_prev: ?*Task = null,
    futex_next: ?*Task = null,
    futex_linked: bool = false,
    futex_address: usize = 0,
    timer: Timers.Node = undefined,
    timer_clock: Kept = .awake,
    timer_armed: bool = false,
    seq: u64 = 0,
    priority: u64 = 0,
    spawned_at: usize = 0,
    /// Where the task last called into the simulation.
    call_site: usize = 0,
    report: TaskReport = .{ .id = ids.outside, .spawned_at = 0, .waiting = .none },

    fn contextPointer(t: *Task) *const anyopaque {
        return @ptrCast(t.frame.ptr + t.context_offset); // safe: the frame holds the copied context at this offset
    }

    fn resultPointer(t: *Task) *anyopaque {
        return @ptrCast(t.frame.ptr + t.result_offset); // safe: the frame holds the result at this offset
    }

    pub fn result(t: *Task) []u8 {
        return (t.frame.ptr + t.result_offset)[0..t.result_len];
    }
};

const frame_align = 64;

pub const InitError = error{ OutOfMemory, ExecutorUnavailable, InvalidLink, InvalidSchedule };

pub fn init(gpa: Allocator, options: Options, source: *Source) InitError!Core {
    if (options.net) |net_options| try Network.validate(net_options.default_link);
    switch (options.schedule) {
        .pct => |pct| if (pct.depth < 1 or pct.depth > max_depth or pct.length < 1) return error.InvalidSchedule,
        .fifo, .random => {},
    }
    const kind: executor.Kind = switch (options.executor) {
        .auto => executor.best orelse return error.ExecutorUnavailable,
        .fibers => if (executor.available(.win32)) .win32 else if (executor.available(.fibers)) .fibers else return error.ExecutorUnavailable,
        .threads => if (executor.available(.threads)) .threads else return error.ExecutorUnavailable,
    };
    const monotonic = nanoseconds(options.clock.monotonic.nanoseconds);
    var processes: Processes = try .init(gpa, options.programs);
    errdefer processes.deinit();
    var c: Core = .{
        .gpa = gpa,
        .options = options,
        .processes = processes,
        .keep = .init(gpa),
        .network = .init(gpa, options.net orelse .{}),
        .source = source,
        .kind = kind,
        .trace = .init(gpa, options.trace),
        .clocks = .{ monotonic, monotonic, nanoseconds(options.clock.real.nanoseconds) },
        .start = monotonic,
        .driver = .{ .kind = kind },
    };
    if (options.fs) |fs_options| {
        c.fs = .{ .model = try Disk.init(gpa, source, fs_options) };
    }
    switch (options.schedule) {
        .pct => |pct| {
            c.change_count = pct.depth - 1;
            for (c.change_points[0..c.change_count]) |*point| point.* = 1 + c.draw(pct.length - 1);
            std.mem.sort(u64, c.change_points[0..c.change_count], {}, std.sort.asc(u64));
        },
        .fifo, .random => {},
    }
    return c;
}

/// Releases every task, whatever it was doing: a task the run ended
/// with is dropped without unwinding.
pub fn deinit(c: *Core) void {
    for (c.tasks.items) |t| {
        executor.destroy(&t.ctx);
        c.gpa.free(t.frame);
        c.gpa.destroy(t);
    }
    c.processes.deinit();
    c.keep.deinit();
    c.network.deinit();
    for (c.contexts.items) |ctx| {
        if (ctx.disk) |fs_| fs_.model.deinit();
        c.gpa.destroy(ctx);
    }
    c.contexts.deinit(c.gpa);
    c.tasks.deinit(c.gpa);
    c.idle.deinit(c.gpa);
    c.ready.deinit(c.gpa);
    c.reports.deinit(c.gpa);
    c.trace.deinit();
    if (c.fs) |fs| {
        fs.model.deinit();
    }
    c.* = undefined;
}

pub fn of(userdata: ?*anyopaque) *Core {
    const ctx: *Context = @ptrCast(@alignCast(userdata.?)); // safe: each simulation Io owns a stable Context
    const c = ctx.core;
    if (!ctx.inherit) {
        if (c.current) |t| t.io_context = ctx else c.active_context = ctx;
    }
    return c;
}

/// The namespace of the call being made: the running task's, or the
/// driver's.
pub fn currentContext(c: *const Core) ?*Context {
    return if (c.current) |t| t.io_context else c.active_context;
}

pub fn nodeId(c: *const Core) NodeId {
    const ctx = c.currentContext() orelse return first_node;
    return ctx.node;
}

/// The simulated process making the call being made; null for the test's
/// own.
pub fn processOf(c: *const Core) ?*Process {
    const ctx = c.currentContext() orelse return null;
    return ctx.process;
}

/// The working directory a context's calls mean by `Dir.cwd()`; null for
/// its node's root.
pub fn cwdOf(ctx: *const Context) ?Io.Dir {
    if (ctx.process) |p| return p.cwd;
    return ctx.cwd;
}

/// Ends simulated process `p` as `term`: every task it still has but the
/// running one (whose job is ending it) ends where it stands, as a dying
/// process's threads do; what it held is given back, its files and their
/// locks, its sockets and its pipe ends; whoever waits for it is woken.
pub fn endProcess(c: *Core, p: *Process, term: Processes.Term) void {
    if (p.term != null) return;
    p.term = term;
    for (c.tasks.items) |t| if (t.process == p and t != c.current) c.drop(t);
    c.processes.release(p);
    if (c.disk(p.node)) |d| {
        d.model.closeOwned(p.pid);
        c.wakeLocks(d.model);
    }
    c.network.closeOwned(p.pid);
    for (c.tasks.items) |t| if (t.state == .parked and t.wait == .process and t.wait.process == p.pid) c.wake(t, .woken);
    c.wakeIo();
}

/// Ends every simulated process on `node`, as a machine that goes down
/// takes its processes with it.
pub fn endProcessesOn(c: *Core, node: NodeId) void {
    for (c.processes.processes.items) |p| if (p.node == node) c.endProcess(p, Processes.killed());
}

/// The id of the process making the call, as the models record an owner:
/// 0 for the test's own.
pub fn ownerOf(c: *const Core) u32 {
    return if (c.processOf()) |p| p.pid else 0;
}

/// The context of a node made by `Sim.node`: the first is `c.context`.
pub fn contextOf(c: *Core, node: NodeId) *Context {
    return c.contexts.items[Network.followerIndex(node)];
}

pub fn disk(c: *Core, node: NodeId) ?Fs {
    return if (node == first_node) c.fs else c.contextOf(node).disk;
}
pub fn notifyNetwork(c: *Core) void {
    c.network.now = c.clocks[@backingInt(Kept.awake)];
    c.network.pump();
    if (c.network_seen != c.network.change) {
        c.network_seen = c.network.change;
        _ = c.wakeFutex(@intFromPtr(&c.network.change), std.math.maxInt(u32)); // safe: the network epoch has a stable address until Core.deinit
    }
}

// Decisions.

/// A choice in `[0, max]` from the source, folded into this call's digest.
pub fn draw(c: *Core, max: u64) u64 {
    const choice = c.source.below(max);
    c.decision = std.hash.int((c.decision orelse 0) ^ choice);
    return choice;
}

pub fn chance(c: *Core, per_million: u32) bool {
    if (per_million == 0) return false;
    const fired = c.source.chance(per_million);
    c.decision = std.hash.int((c.decision orelse 0) ^ @intFromBool(fired));
    return fired;
}

// Tasks.

/// `SystemResources`: no room for the job's context or result in a frame, or
/// no task id left.
pub const SpawnError = error{ OutOfMemory, SystemResources };

/// How a new task begins.
pub const Start = enum {
    /// Runnable at once.
    ready,
    /// A group member waiting for its group's await.
    deferred,
    /// A task of `Sim.at`, waiting for its time.
    parked,
};

/// A task for `job`, its context copied in and room made for its result.
pub fn spawn(
    c: *Core,
    job: Job,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    start: Start,
) SpawnError!*Task {
    const t = c.idle.pop() orelse try c.newTask();
    errdefer c.idle.appendAssumeCapacity(t);
    try c.layOut(t, context.len, context_alignment, result_len, result_alignment);
    // Issued last, so a spawn that fails leaves the issuer where it was.
    const id = c.next_id.next() catch return error.SystemResources;
    @memcpy((t.frame.ptr + t.context_offset)[0..context.len], context);
    t.* = .{
        .core = c,
        .ctx = t.ctx,
        .frame = t.frame,
        .context_offset = t.context_offset,
        .result_offset = t.result_offset,
        .result_len = result_len,
        .id = id,
        .node = c.nodeId(),
        .process = c.processOf(),
        .io_context = c.currentContext(),
        .job = job,
    };
    c.live += 1;
    switch (c.options.schedule) {
        .pct => |pct| t.priority = pct.depth + c.draw(1 << 20),
        .fifo, .random => {},
    }
    switch (start) {
        .ready => c.makeReady(t),
        .deferred => t.state = .deferred,
        .parked => {
            t.state = .parked;
            t.wait = .start;
        },
    }
    return t;
}

fn newTask(c: *Core) SpawnError!*Task {
    try c.tasks.ensureUnusedCapacity(c.gpa, 1);
    try c.idle.ensureTotalCapacity(c.gpa, c.tasks.items.len + 1);
    try c.ready.ensureTotalCapacity(c.gpa, c.tasks.items.len + 1);
    const t = try c.gpa.create(Task);
    errdefer c.gpa.destroy(t);
    const stack_size = c.options.stack_size.raw();
    t.* = .{ .core = c, .ctx = try executor.create(c.kind, taskMain, t, stack_size) };
    errdefer executor.destroy(&t.ctx);
    try executor.start(&t.ctx, taskMain, t, stack_size);
    c.tasks.appendAssumeCapacity(t);
    return t;
}

/// Places the context and the result in the task's frame, growing it when
/// the job needs more than it held.
fn layOut(c: *Core, t: *Task, context_len: usize, context_alignment: std.mem.Alignment, result_len: usize, result_alignment: std.mem.Alignment) SpawnError!void {
    // A job whose types want more than a frame gives is the caller's, not a
    // bug here: `async` runs it at once, `concurrent` is unavailable.
    if (context_alignment.toByteUnits() > frame_align or result_alignment.toByteUnits() > frame_align) return error.SystemResources;
    const result_offset = result_alignment.forward(context_len);
    const need = @max(result_offset + result_len, 1);
    if (t.frame.len < need) {
        const grown = try c.gpa.alignedAlloc(u8, .fromByteUnits(frame_align), std.math.ceilPowerOfTwoAssert(usize, @max(need, 64)));
        c.gpa.free(t.frame);
        t.frame = grown;
    }
    t.context_offset = 0;
    t.result_offset = result_offset;
}

/// Puts an ended task back for reuse.
pub fn release(c: *Core, t: *Task) void {
    // A second release would queue the task twice, and two jobs would then
    // share its frame and stack.
    aegis.assert.pre(t.state == .running or t.state == .done, "a task is released once, after it ended");
    t.state = .idle;
    c.idle.appendAssumeCapacity(t);
}

/// What every task context runs: a job, then the switch away; a task
/// reused for another job comes back here.
fn taskMain(arg: *anyopaque) callconv(.c) noreturn {
    const t: *Task = @ptrCast(@alignCast(arg)); // safe: every context is made with its task as the argument
    if (t.core.kind == .threads) running_core = t.core;
    while (true) {
        switch (t.job) {
            .future => |f| f(t.contextPointer(), t.resultPointer()),
            .member => |f| f(t.contextPointer()),
            .root, .node => |f| f(t.contextPointer(), t.resultPointer()),
            .at => |a| a.f(t.core.outer, a.ctx),
            .program => |p| {
                const code = Processes.run(p);
                t.core.endProcess(p, .{ .exited = code });
            },
        }
        t.core.finish(t);
    }
}

/// The simulation running on this thread, for the panic handler.
pub threadlocal var running_core: ?*Core = null;

fn finish(c: *Core, t: *Task) void {
    if (t.timer_armed) c.disarm(t);
    c.live -= 1;
    switch (t.job) {
        .future => {
            t.state = .done;
            if (t.awaiter) |a| c.wake(a, .woken);
        },
        .member => {
            const g = t.group.?;
            g.state -= 1;
            if (g.state == 0) if (groupAwaiter(g)) |a| c.wake(a, .woken);
            c.release(t);
        },
        .root => {
            const err: *const ?anyerror = @ptrCast(@alignCast(t.resultPointer())); // safe: a root's result is its error, written by its start function
            if (err.*) |e| c.outcome = .{ .failed = e };
            c.release(t);
        },
        .node => {
            const err: *const ?anyerror = @ptrCast(@alignCast(t.resultPointer())); // safe: node callback writes an optional error
            if (err.*) |e| if (e != error.Canceled or t.cancel != .delivered) {
                c.outcome = .{ .failed = e };
            };
            c.release(t);
        },
        .at, .program => c.release(t),
    }
    c.dispatch(&t.ctx);
}

/// The token of a group with members and no awaiter: the group itself.
/// While a task awaits the group, the token is that task.
pub fn groupMarker(g: *Io.Group) *anyopaque {
    return @ptrCast(g); // safe: only compared, never dereferenced as anything else
}

/// The task awaiting `g`, if one is.
pub fn groupAwaiter(g: *Io.Group) ?*Task {
    const token = g.token.raw orelse return null;
    if (token == groupMarker(g)) return null;
    return @ptrCast(@alignCast(token)); // safe: a token other than the marker is the awaiting task
}

// Scheduling.

pub fn makeReady(c: *Core, t: *Task) void {
    t.state = .ready;
    c.ready_seq += 1;
    t.seq = c.ready_seq;
    switch (c.options.schedule) {
        .fifo => {
            if (c.ready.items.len == c.ready.capacity) {
                // Compact the queue to the front: it never holds more than
                // the tasks there are, and room for all of them was taken.
                const queued = c.ready.items[c.ready_head..];
                @memmove(c.ready.items[0..queued.len], queued);
                c.ready.items.len = queued.len;
                c.ready_head = 0;
            }
            c.ready.appendAssumeCapacity(t);
        },
        .random => c.ready.appendAssumeCapacity(t),
        .pct => {
            c.ready.appendAssumeCapacity(t);
            siftUp(c.ready.items, c.ready.items.len - 1);
        },
    }
}

fn readyCount(c: *const Core) usize {
    return c.ready.items.len - c.ready_head;
}

/// The next task to run, drawn among the ready ones per the schedule.
fn pickReady(c: *Core) ?*Task {
    const n = c.readyCount();
    if (n == 0) return null;
    switch (c.options.schedule) {
        .fifo => {
            const t = c.ready.items[c.ready_head];
            c.ready_head += 1;
            if (c.ready_head == c.ready.items.len) {
                c.ready.items.len = 0;
                c.ready_head = 0;
            }
            return t;
        },
        .random => {
            const index = if (n == 1) 0 else c.draw(n - 1);
            return c.ready.swapRemove(@intCast(index));
        },
        .pct => {
            const items = c.ready.items;
            const top = items[0];
            items[0] = items[items.len - 1];
            c.ready.items.len -= 1;
            if (c.ready.items.len > 0) siftDown(c.ready.items, 0);
            return top;
        },
    }
}

fn higher(a: *const Task, b: *const Task) bool {
    if (a.priority != b.priority) return a.priority > b.priority;
    return a.seq < b.seq;
}

fn siftUp(items: []*Task, start: usize) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!higher(items[i], items[parent])) return;
        std.mem.swap(*Task, &items[i], &items[parent]);
        i = parent;
    }
}

fn siftDown(items: []*Task, start: usize) void {
    var i = start;
    while (true) {
        var best = i;
        for ([_]usize{ 2 * i + 1, 2 * i + 2 }) |child| {
            if (child < items.len and higher(items[child], items[best])) best = child;
        }
        if (best == i) return;
        std.mem.swap(*Task, &items[i], &items[best]);
        i = best;
    }
}

/// Whether a ready task outranks `t` under PCT.
fn outranked(c: *const Core, t: *const Task) bool {
    return c.readyCount() > 0 and higher(c.ready.items[0], t);
}

/// Hands control from `from` to the next task, or to the driver when the
/// run pauses or ends.
pub fn dispatch(c: *Core, from: *executor.Context) void {
    const to: *executor.Context = if (c.next()) |n| to: {
        c.current = n;
        n.state = .running;
        c.running.store(n.id, .monotonic);
        break :to &n.ctx;
    } else to: {
        c.current = null;
        c.running.store(ids.outside, .monotonic);
        break :to &c.driver;
    };
    if (to != from) executor.switchTo(from, to);
}

/// The next task, after moving time as far as it takes to have one; null
/// when control goes back to the driver.
fn next(c: *Core) ?*Task {
    while (true) {
        if (c.outcome != null) return null;
        if (c.mode == .step and c.step_taken) return null;
        c.notifyNetwork();
        if (c.pickReady()) |t| {
            c.step_taken = true;
            return t;
        }
        if (c.live == 0) {
            if (c.mode == .until) c.moveTo(c.until);
            c.outcome = .finished;
            return null;
        }
        const remaining: ?i64 = blk: {
            const timer = c.earliest();
            const network = c.network.nextDeadline();
            const network_remaining: ?i64 = if (network) |at| @max(0, at -| c.clocks[@backingInt(Kept.awake)]) else null;
            if (timer) |e| break :blk if (network_remaining) |n| @min(e.remaining, n) else e.remaining;
            break :blk network_remaining;
        };
        if (remaining) |by| {
            const at = c.clocks[@backingInt(Kept.awake)] +| by;
            if (c.mode == .until and at > c.until) {
                c.moveTo(c.until);
                return null;
            }
            if (at -| c.start > nanoseconds(c.options.max_time.nanoseconds)) {
                c.outcome = .time_limit;
                return null;
            }
            c.advance(by);
            if (c.mode == .step) {
                c.step_taken = true;
                return null;
            }
            continue;
        }
        if (c.mode == .until) {
            c.moveTo(c.until);
            return null;
        }
        c.outcome = .{ .deadlock = &.{} };
        return null;
    }
}

/// Parks the running task on `wait` until something wakes it.
pub fn block(c: *Core, t: *Task, wait: Wait, cancelable: bool) Wake {
    t.wait = wait;
    t.cancelable = cancelable and t.protection == .unblocked;
    t.wake = .none;
    t.state = .parked;
    // The choices drawn while others ran were theirs: this call keeps its own.
    const mine = c.decision;
    c.dispatch(&t.ctx);
    while (c.capturing == t) {
        c.capture(t);
        c.capturing = null;
        executor.switchTo(&t.ctx, &c.driver);
    }
    if (t.timer_armed) c.disarm(t);
    if (t.futex_linked) c.unlink(t);
    t.wait = .none;
    c.decision = mine;
    if (t.wake == .canceled) t.cancel = .delivered;
    return t.wake;
}

pub fn wake(c: *Core, t: *Task, reason: Wake) void {
    if (t.state != .parked or t.wake != .none or t.wait == .start) return;
    t.wake = reason;
    c.makeReady(t);
}

/// Lets other ready tasks run before `t` goes on.
pub fn yield(c: *Core, t: *Task) void {
    const mine = c.decision;
    c.makeReady(t);
    c.dispatch(&t.ctx);
    c.decision = mine;
}

/// Ends the run as `outcome` from inside `t`, which never runs again.
pub fn abandon(c: *Core, t: *Task, outcome: Outcome) noreturn {
    c.outcome = outcome;
    t.state = .abandoned;
    c.live -= 1;
    c.current = null;
    c.running.store(ids.outside, .monotonic);
    executor.switchTo(&t.ctx, &c.driver);
    @panic("shakedown: an abandoned task was resumed");
}

/// Ends a task that is not running where it stands, as a dying process's
/// threads end: it never runs again and nothing of it unwinds. A task that
/// had ended and was not yet awaited is put back for reuse.
pub fn drop(c: *Core, t: *Task) void {
    aegis.assert.pre(t != c.current, "a task drops others, never itself");
    switch (t.state) {
        .idle, .abandoned => return,
        .done => return c.release(t),
        .running => unreachable, // unreachable: only the current task runs
        .ready => c.unready(t),
        .parked => {
            if (t.timer_armed) c.disarm(t);
            if (t.futex_linked) c.unlink(t);
        },
        .deferred => {},
    }
    t.state = .abandoned;
    c.live -= 1;
}

/// Ends the running task where it stands, the run going on without it:
/// a task whose process replaced its image. It never runs again.
pub fn retire(c: *Core, t: *Task) noreturn {
    aegis.assert.pre(t == c.current, "a task retires itself");
    if (t.timer_armed) c.disarm(t);
    t.state = .abandoned;
    c.live -= 1;
    c.dispatch(&t.ctx);
    @panic("shakedown: a retired task was resumed");
}

/// Takes a ready task out of the run queue.
fn unready(c: *Core, t: *Task) void {
    const items = c.ready.items;
    const at = std.mem.findScalarPos(*Task, items, c.ready_head, t) orelse return;
    switch (c.options.schedule) {
        .fifo, .random => _ = c.ready.orderedRemove(at),
        .pct => {
            items[at] = items[items.len - 1];
            c.ready.items.len -= 1;
            if (at < c.ready.items.len) {
                siftDown(c.ready.items, at);
                siftUp(c.ready.items, at);
            }
        },
    }
    if (c.ready_head == c.ready.items.len) {
        c.ready.items.len = 0;
        c.ready_head = 0;
    }
}

/// Wakes every task waiting for a simulated stream to become ready: a
/// socket's or a pipe's.
pub fn wakeIo(c: *Core) void {
    _ = c.wakeFutex(@intFromPtr(&c.network.change), std.math.maxInt(u32)); // safe: the network epoch has a stable address until Core.deinit
}

/// Wakes every task waiting for a lock on `disk`.
pub fn wakeLocks(c: *Core, model: *Disk) void {
    model.lock_epoch +%= 1;
    _ = c.wakeFutex(@intFromPtr(&model.lock_epoch), std.math.maxInt(u32)); // safe: the epoch has a stable address while the disk lives
}

/// Delivers a cancel to `t`'s next cancelation point, or now if it waits
/// at one.
pub fn requestCancel(c: *Core, t: *Task) void {
    switch (t.state) {
        .idle, .done, .abandoned => return,
        .ready, .running, .parked, .deferred => {},
    }
    if (t.cancel == .none) t.cancel = .requested;
    if (t.state == .deferred) c.makeReady(t);
    if (t.state == .parked and t.cancelable and t.cancel == .requested) c.wake(t, .canceled);
}

/// At a cancelation point: whether a cancel lands here, delivering it.
pub fn cancelPoint(t: *Task) bool {
    if (t.cancel != .requested or t.protection == .blocked) return false;
    t.cancel = .delivered;
    return true;
}

// Driving.

/// Runs until the run pauses (`.until`, `.step`) or ends; returns the
/// outcome once it has ended.
pub fn drive(c: *Core, mode: Mode, until: i64) executor.CreateError!?Outcome {
    if (c.outcome) |o| return o;
    c.mode = mode;
    c.until = until;
    c.step_taken = false;
    c.driver = try executor.initDriver(c.kind);
    defer executor.finishDriver(&c.driver);
    const previous = running_core;
    running_core = c;
    defer running_core = previous;
    c.dispatch(&c.driver);
    if (c.outcome) |o| if (o == .deadlock) {
        c.outcome = .{ .deadlock = c.gatherReports() };
    };
    return c.outcome;
}

/// The reports of every task still waiting, each with its stack, which the
/// task captures itself when the driver switches to it.
fn gatherReports(c: *Core) []const TaskReport {
    c.reports.clearRetainingCapacity();
    c.reports.ensureTotalCapacity(c.gpa, c.live) catch return &.{};
    for (c.tasks.items) |t| {
        switch (t.state) {
            .parked => if (t.wait == .start) {
                c.reports.appendAssumeCapacity(.{ .id = t.id, .node = t.node, .spawned_at = t.spawned_at, .waiting = .unstarted });
            } else {
                c.capturing = t;
                executor.switchTo(&c.driver, &t.ctx);
                c.reports.appendAssumeCapacity(t.report);
            },
            .deferred => c.reports.appendAssumeCapacity(.{ .id = t.id, .node = t.node, .spawned_at = t.spawned_at, .waiting = .unstarted }),
            .idle, .ready, .running, .done, .abandoned => {},
        }
    }
    return c.reports.items;
}

/// The report of a task, its stack captured where it stands: called on the
/// task's own stack.
pub fn capture(c: *Core, t: *Task) void {
    _ = c;
    t.report = .{ .id = t.id, .node = t.node, .spawned_at = t.spawned_at, .waiting = switch (t.wait) {
        .none => .none,
        .start => .unstarted,
        .futex => |address| .{ .futex = address },
        .sleep => .{ .sleep = if (t.timer_armed) .{ .raw = .fromNanoseconds(t.timer.key.deadline), .clock = clockOf(t.timer_clock) } else null },
        .task => |other| .{ .task = other.id },
        .group => .group,
        .process => |pid| .{ .process = pid },
    } };
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = if (t.call_site != 0) t.call_site else null }, &t.report.stack);
    t.report.len = @intCast(trace.return_addresses.len);
}

// Time.

pub fn now(c: *const Core, which: Io.Clock) Io.Timestamp {
    const kept = keptOf(which) orelse return c.options.clock.monotonic;
    return .fromNanoseconds(c.clocks[@backingInt(kept)]);
}

/// When a timeout ends: never, already, or at an instant on a kept clock.
pub const Deadline = union(enum) { never, due, at: struct { clock: Kept, ns: i64 } };

pub fn deadline(c: *const Core, timeout: Io.Timeout) Deadline {
    const which, const raw, const relative = switch (timeout) {
        .none => return .never,
        .duration => |d| .{ d.clock, nanoseconds(d.raw.nanoseconds), true },
        .deadline => |d| .{ d.clock, nanoseconds(d.raw.nanoseconds), false },
    };
    const kept = keptOf(which) orelse {
        // The CPU clocks are frozen: a deadline not already reached never is.
        const frozen = nanoseconds(c.options.clock.monotonic.nanoseconds);
        return if ((if (relative) frozen +| raw else raw) <= frozen) .due else .never;
    };
    const current = c.clocks[@backingInt(kept)];
    const at = if (relative) current +| raw else raw;
    return if (at <= current) .due else .{ .at = .{ .clock = kept, .ns = at } };
}

pub fn arm(c: *Core, t: *Task, clock: Kept, at: i64) void {
    c.timer_seq += 1;
    t.timer_clock = clock;
    var entry = c.timers[@backingInt(clock)].getEntryFor(.{ .deadline = at, .seq = c.timer_seq });
    entry.set(&t.timer);
    t.timer_armed = true;
}

pub fn disarm(c: *Core, t: *Task) void {
    var entry = c.timers[@backingInt(t.timer_clock)].getEntryForExisting(&t.timer);
    entry.set(null);
    t.timer_armed = false;
}

const Earliest = struct { t: *Task, remaining: i64 };

/// The armed timer the clocks reach first, and how far they must move.
fn earliest(c: *Core) ?Earliest {
    var first: ?Earliest = null;
    var first_seq: u64 = 0;
    for (&c.timers, 0..) |*timers, i| {
        const node = timers.getMin() orelse continue;
        const remaining = node.key.deadline -| c.clocks[i];
        if (first == null or remaining < first.?.remaining or (remaining == first.?.remaining and node.key.seq < first_seq)) {
            first = .{ .t = @alignCast(@fieldParentPtr("timer", node)), .remaining = remaining }; // safe: every timer node is the `timer` of a task
            first_seq = node.key.seq;
        }
    }
    return first;
}

/// Moves every clock by `by` and wakes each timer reached, in the order
/// the clocks reach them.
fn advance(c: *Core, by: i64) void {
    for (&c.clocks) |*clock| clock.* +|= by;
    while (c.earliest()) |e| {
        if (e.remaining > 0) break;
        c.disarm(e.t);
        if (e.t.state != .parked) continue;
        if (e.t.wait == .start) {
            // A task of `Sim.at`, due: it starts now.
            e.t.wait = .none;
            c.makeReady(e.t);
        } else c.wake(e.t, .timeout);
    }
    c.notifyNetwork();
}

fn moveTo(c: *Core, awake: i64) void {
    const by = awake -| c.clocks[@backingInt(Kept.awake)];
    if (by > 0) c.advance(by);
}

fn keptOf(which: Io.Clock) ?Kept {
    return switch (which) {
        .awake => .awake,
        .boot => .boot,
        .real => .real,
        .cpu_process, .cpu_thread => null,
    };
}

fn clockOf(kept: Kept) Io.Clock {
    return switch (kept) {
        .awake => .awake,
        .boot => .boot,
        .real => .real,
    };
}

pub fn nanoseconds(n: i96) i64 {
    return std.math.lossyCast(i64, n);
}

// Futexes.

fn bucketOf(c: *Core, address: usize) *Bucket {
    const mixed = @as(u64, address >> 2) *% 0x9e37_79b9_7f4a_7c15;
    return &c.buckets[@intCast(mixed >> (64 - 8))];
}

/// Queues `t` on `address`, after every task already waiting there.
pub fn link(c: *Core, t: *Task, address: usize) void {
    const b = c.bucketOf(address);
    t.futex_prev = b.tail;
    t.futex_next = null;
    if (b.tail) |tail| tail.futex_next = t else b.head = t;
    b.tail = t;
    t.futex_linked = true;
    t.futex_address = address;
}

pub fn unlink(c: *Core, t: *Task) void {
    const b = c.bucketOf(t.futex_address);
    if (t.futex_prev) |p| p.futex_next = t.futex_next else b.head = t.futex_next;
    if (t.futex_next) |n| n.futex_prev = t.futex_prev else b.tail = t.futex_prev;
    t.futex_prev = null;
    t.futex_next = null;
    t.futex_linked = false;
}

/// Wakes up to `max` tasks waiting on `address`, first come first woken.
pub fn wakeFutex(c: *Core, address: usize, max: u32) u32 {
    var woken: u32 = 0;
    var it = c.bucketOf(address).head;
    while (it) |t| {
        if (woken == max) break;
        it = t.futex_next;
        if (t.futex_address != address) continue;
        c.unlink(t);
        c.wake(t, .woken);
        woken += 1;
    }
    return woken;
}

// Steps.

/// A call in progress: who made it, and its step.
pub const Call = struct { task: ?*Task, step: u64, node: NodeId };

/// The start of every call: a step, the watchdog's count, and the step
/// limit and the watchdog's verdict; under PCT, a change point; and, for a
/// call that does not block, a chance to let another task run first.
pub fn enter(c: *Core, call_site: usize, yields: bool) Call {
    c.steps += 1;
    // One writer at a time, the running task: a store, not an increment.
    c.calls.store(c.steps, .monotonic);
    c.decision = null;
    const step = c.steps;
    const node = c.nodeId();
    const limit: aegis.bounded.Limit(u64) = .init(c.options.max_steps);
    const t = c.current orelse {
        limit.check(c.steps) catch if (c.outcome == null) {
            c.outcome = .step_limit;
        };
        return .{ .task = null, .step = step, .node = node };
    };
    t.call_site = call_site;
    limit.check(c.steps) catch c.abandon(t, .step_limit);
    if (c.stuck.load(.monotonic)) {
        c.capture(t);
        c.abandon(t, .{ .stuck = t.report });
    }
    if (c.next_change < c.change_count and c.steps >= c.change_points[c.next_change]) {
        // A PCT change point: the running task drops below every other.
        t.priority = c.change_count - c.next_change;
        c.next_change += 1;
        if (c.outranked(t)) c.yield(t);
    } else if (yields and c.chance(c.options.yield_per_million)) {
        c.yield(t);
    }
    return .{ .task = t, .step = step, .node = node };
}

/// The end of a call: its record in the trace.
pub fn record(c: *Core, call: IoCall, entered: Call, outcome: u64) void {
    const id = if (entered.task) |t| t.id else ids.outside;
    const event: Event = .{ .call = call, .task = id, .node = entered.node, .decision = c.decision, .outcome = outcome };
    const at: Io.Timestamp = .fromNanoseconds(c.clocks[@backingInt(Kept.awake)]);
    // glint-ignore: Z026 -- a record that cannot be kept is dropped; the hash still counts it
    c.trace.append(.{ .step = entered.step, .task = id, .at = at, .event = event }) catch {};
}

test "task ids run out as an error that leaves the issuer where it was" {
    const gpa = std.testing.allocator;
    var source: Source = try .init(gpa, .{ .prng = 0 });
    defer source.deinit();
    var c: Core = try .init(gpa, .{ .fs = null, .net = null }, &source);
    defer c.deinit();
    const job: Job = .{ .future = struct {
        fn run(_: *const anyopaque, _: *anyopaque) void {}
    }.run };
    c.next_id = .init(std.math.maxInt(u32) - 1);
    const last = try c.spawn(job, &.{}, .@"1", 0, .@"1", .parked);
    try std.testing.expectEqual(ids.TaskId.fromRaw(std.math.maxInt(u32)), last.id);
    try std.testing.expectError(error.SystemResources, c.spawn(job, &.{}, .@"1", 0, .@"1", .parked));
    try std.testing.expectError(error.SystemResources, c.spawn(job, &.{}, .@"1", 0, .@"1", .parked));
    try std.testing.expectEqual(@as(u32, 1), c.live);
    try std.testing.expect(c.next_id == ids.TaskIssuer.init(std.math.maxInt(u32)));
}
