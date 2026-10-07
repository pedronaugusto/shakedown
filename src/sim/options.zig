//! What a simulation is made with, and what a run ends in.
const std = @import("std");
const Io = std.Io;
const Source = @import("../Source.zig");
const io_call = @import("../io_call.zig");
const IoCall = io_call.IoCall;
const Plan = @import("../plan.zig").Plan;
const Trace = @import("../trace.zig").Trace;
const Watchdog = @import("Watchdog.zig");

pub const Executor = enum {
    /// The fastest this target has: Win32 fibers on Windows, fibers on
    /// x86_64 and aarch64 elsewhere, threads otherwise.
    auto,
    fibers,
    threads,
};

/// Which runnable task runs next. Every choice is a draw from the source,
/// made only when two or more tasks can run.
pub const Schedule = union(enum) {
    /// The one that became runnable first. Draws nothing.
    fifo,
    /// Any of them, uniformly.
    random,
    /// Probabilistic concurrency testing: random priorities, the highest
    /// running, and `depth - 1` points, drawn in the first `length` steps,
    /// where the running task drops below every other. Finds a bug of depth
    /// d in one run of about n^(d-1) (Burckhardt et al., ASPLOS 2010).
    pct: struct { depth: u8 = 3, length: u64 = 10_000 },
};

/// What `async` and `Group.async` do, among what std allows.
pub const AsyncStart = enum {
    /// Draw, per call: run the function at once, or start a task.
    any,
    /// Run the function at once, before `async` returns.
    eager,
    /// Start a task.
    concurrent,
    /// `Group.async` waits until the group is awaited or canceled, as its
    /// documentation allows; `async` runs the function at once. Finds code
    /// that waits on a group's output before awaiting the group. std's
    /// `Select` promises its functions start, so this deadlocks it.
    deferred,
};

pub const Options = struct {
    /// The seed of the simulation's own source, unless `source` is given.
    seed: u64 = 0,
    /// Draw every decision from this source instead: a `Case` passes its own,
    /// so the run shrinks with the case.
    source: ?*Source = null,
    executor: Executor = .auto,
    /// Usable stack per task, with an inaccessible guard page below it.
    stack_size: usize = 256 * 1024,
    schedule: Schedule = .random,
    /// Strict by default: a test that assumes an order std does not promise
    /// fails, and that is fixed in the test or the code, not here.
    async_start: AsyncStart = .any,
    /// How often a futex wait returns early with no wake, as std allows.
    spurious_wake_per_million: u32 = 10_000,
    /// How often a call that does not block lets another task run first.
    yield_per_million: u32 = 0,
    /// A run that makes more `Io` calls than this ends as `step_limit`.
    max_steps: u64 = 50_000_000,
    /// A run whose time would pass this ends as `time_limit`.
    max_time: Io.Duration = .fromSeconds(30 * 24 * 3600),
    /// Real time a task may run without an `Io` call before the run is
    /// stuck; null turns the watchdog off. See `Outcome.stuck`.
    watchdog: ?Io.Duration = .fromSeconds(10),
    /// A watchdog shared with other simulations, which must outlive this
    /// one; null starts one of the simulation's own on its first run.
    watched_by: ?*Watchdog = null,
    /// The clocks' starting instants and resolution.
    clock: Clock = .{},
    /// What the run's trace keeps. Its hash covers every call in any mode.
    trace: Trace(Event).Mode = .{ .window = 256 },
    /// Faults for every call, as `FaultIo` injects them: the outermost part
    /// of the simulation, drawing chances from its source.
    faults: []const Plan(IoCall, io_call.IoFault).Entry = &.{},

    pub const Clock = struct {
        /// `.real` at the start, in Unix time (2026-01-01T00:00:00Z).
        real: Io.Timestamp = .fromNanoseconds(1_767_225_600 * std.time.ns_per_s),
        /// `.awake` and `.boot` at the start; the CPU clocks stay here.
        monotonic: Io.Timestamp = .fromNanoseconds(std.time.ns_per_s),
        resolution: Io.Duration = .fromNanoseconds(1),
    };
};

/// One call into the simulation, as its trace records it.
pub const Event = struct {
    call: IoCall,
    /// The task that made it; 0 for calls from outside any task.
    task: u32,
    /// A digest of the choices drawn during the call, if any were.
    decision: ?u64 = null,
    /// A digest of what the call returned.
    outcome: u64 = 0,

    pub fn format(e: Event, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{t} task {d} -> {x}", .{ e.call, e.task, e.outcome });
        if (e.decision) |d| try w.print(" [drew {x}]", .{d});
    }
};

/// A task the run ended with: where it came from and what it waited on.
pub const TaskReport = struct {
    id: u32,
    /// The return address of the call that started it.
    spawned_at: usize,
    waiting: Waiting,
    /// The task's frames, innermost first, from the call it made into the
    /// simulation outward.
    stack: [16]usize = @splat(0),
    len: u8 = 0,

    pub const Waiting = union(enum) {
        /// A futex wait on this address: a mutex, condition, event, queue.
        futex: usize,
        /// A sleep until this instant, or for ever.
        sleep: ?Io.Clock.Timestamp,
        /// An `await` or `cancel` of task n.
        task: u32,
        /// A group's `await` or `cancel`.
        group,
        /// A group member that was never started: its group was never
        /// awaited or canceled.
        unstarted,
        /// Running, or ready to run.
        none,
    };

    /// The report with its frames resolved to source lines.
    pub fn format(r: TaskReport, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("task {d}, started at 0x{x}, ", .{ r.id, r.spawned_at });
        switch (r.waiting) {
            .futex => |address| try w.print("waiting on the futex at 0x{x}", .{address}),
            .sleep => |until| if (until) |at| {
                try w.print("sleeping until {d} ns on {t}", .{ at.raw.nanoseconds, at.clock });
            } else try w.writeAll("sleeping for ever"),
            .task => |id| try w.print("waiting for task {d}", .{id}),
            .group => try w.writeAll("waiting for its group"),
            .unstarted => try w.writeAll("never started: its group was never awaited"),
            .none => try w.writeAll("running"),
        }
        if (r.len == 0) return w.writeByte('\n');
        var copy = r.stack;
        try w.print("{f}", .{std.debug.FormatStackTrace{ .stack_trace = .{ .return_addresses = copy[0..r.len], .skipped = .unknown } }});
    }
};

/// How a run ended.
pub const Outcome = union(enum) {
    /// Every task ended, the root without an error.
    finished,
    /// The root returned this error.
    failed: anyerror,
    /// Every task is waiting and no timer is armed. Valid until the
    /// simulation is torn down.
    deadlock: []const TaskReport,
    /// The run made `Options.max_steps` calls.
    step_limit,
    /// The run's time would pass `Options.max_time`.
    time_limit,
    /// The watchdog found this task running for `Options.watchdog` of real
    /// time without an `Io` call, and it then made one. A task that never
    /// makes one again cannot be stopped: after twice the watchdog's time
    /// the process is aborted, with the report printed first.
    stuck: TaskReport,
};
