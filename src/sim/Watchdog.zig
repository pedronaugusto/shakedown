//! `Watchdog`: a thread that watches simulations for a task that stopped
//! calling into them.
//!
//! A simulation with a watchdog time starts one of its own on its first
//! run, unless `Sim.Options.watched_by` names one it shares: `check` shares
//! one among its cases, so a case starts no thread. The thread starts with
//! the first simulation watched and stops at `deinit`.
//!
//! Each sample reads a watched simulation's running task and call count. A
//! task that makes no call for the simulation's watchdog time is reported
//! and the run marked stuck, which ends it at the task's next call; one
//! that never makes one is reported again and the process aborted, since
//! nothing else can stop it.
const std = @import("std");
const Io = std.Io;
const ids = @import("../ids.zig");

const Watchdog = @This();

/// Private: the thread, once started.
thread: ?std.Thread = null,
/// Private: bumped to wake the thread, when a simulation comes or goes and
/// when it is to stop.
signal: std.atomic.Value(u32) = .init(0),
/// Private: under the mutex, as is every `Watched` linked here.
stopping: bool = false,
mutex: Io.Mutex = .init,
first: ?*Watched = null,

/// What the watchdog reads of one simulation, and keeps of it between
/// samples. The simulation owns it, and it links it in with `add`.
pub const Watched = struct {
    /// The running task's id, `outside` when none; the calls made so far;
    /// and the verdict the simulation reads at its next call.
    running: *const std.atomic.Value(ids.TaskId),
    calls: *const std.atomic.Value(u64),
    stuck: *std.atomic.Value(bool),
    /// Real time, in nanoseconds, a task may run without a call.
    limit: i64,
    /// Private: the watchdog's.
    next: ?*Watched = null,
    previous: ?*Watched = null,
    seen: u64 = 0,
    since: ?i64 = null,
};

pub fn init() Watchdog {
    return .{};
}

/// Stops the thread. Every simulation it watched must be torn down first.
pub fn deinit(w: *Watchdog) void {
    std.debug.assert(w.first == null); // a simulation it watches outlives it
    if (w.thread) |thread| {
        w.mutex.lockUncancelable(real());
        w.stopping = true;
        w.mutex.unlock(real());
        w.wake();
        thread.join();
    }
    w.* = undefined;
}

/// Watches `watched`, starting the thread if there is none yet. Returns
/// false when no thread can be had: the run is then unwatched and
/// otherwise the same. `watched` must not move until `remove`.
pub fn add(w: *Watchdog, watched: *Watched) bool {
    w.mutex.lockUncancelable(real());
    defer w.mutex.unlock(real());
    if (w.thread == null) {
        // ziglint-ignore: Z026 without its thread the watchdog is off; the run itself is unchanged
        w.thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, run, .{w}) catch return false;
    }
    watched.next = w.first;
    watched.previous = null;
    if (w.first) |first| first.previous = watched;
    w.first = watched;
    w.wake();
    return true;
}

/// Stops watching `watched`.
pub fn remove(w: *Watchdog, watched: *Watched) void {
    w.mutex.lockUncancelable(real());
    defer w.mutex.unlock(real());
    if (watched.previous) |p| p.next = watched.next else w.first = watched.next;
    if (watched.next) |n| n.previous = watched.previous;
    watched.next = null;
    watched.previous = null;
}

/// The real system, whatever the simulations simulate.
fn real() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn wake(w: *Watchdog) void {
    _ = w.signal.fetchAdd(1, .release);
    real().futexWake(u32, &w.signal.raw, 1);
}

fn run(w: *Watchdog) void {
    while (true) {
        const seen = w.signal.load(.acquire);
        const next = w.sample() orelse return;
        const timeout: Io.Timeout = if (next.slice) |ns| .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } } else .none;
        // ziglint-ignore: Z026 a wait cut short only samples sooner
        real().futexWaitTimeout(u32, &w.signal.raw, seen, timeout) catch {};
    }
}

/// How long until the next sample; null while nothing is watched.
const Next = struct { slice: ?i64 };

/// Samples every simulation watched. Null once the watchdog is stopping.
fn sample(w: *Watchdog) ?Next {
    w.mutex.lockUncancelable(real());
    defer w.mutex.unlock(real());
    if (w.stopping) return null;
    const now = std.math.lossyCast(i64, Io.Timestamp.now(real(), .awake).nanoseconds);
    var slice: ?i64 = null;
    var it = w.first;
    while (it) |watched| : (it = watched.next) {
        look(watched, now);
        const own = @max(@divTrunc(watched.limit, 8), std.time.ns_per_ms);
        slice = if (slice) |least| @min(least, own) else own;
    }
    return .{ .slice = slice };
}

fn look(watched: *Watched, now: i64) void {
    const task = watched.running.load(.monotonic);
    const calls = watched.calls.load(.monotonic);
    if (task == ids.outside or calls != watched.seen or watched.since == null) {
        watched.seen = calls;
        watched.since = now;
        return;
    }
    const idle = now -| watched.since.?;
    if (idle >= watched.limit and !watched.stuck.load(.monotonic)) {
        watched.stuck.store(true, .monotonic);
        say("shakedown: task {d} has run {d} ms without an Io call; the run ends as stuck at its next one\n", .{ task.raw(), @divTrunc(idle, std.time.ns_per_ms) });
    }
    if (idle >= 2 *| watched.limit) {
        say("shakedown: task {d} has made no Io call for {d} ms and cannot be stopped; aborting\n", .{ task.raw(), @divTrunc(idle, std.time.ns_per_ms) });
        std.process.abort();
    }
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // ziglint-ignore: Z026 a message stderr cannot take is lost
    stderr.writer.print(fmt, args) catch {};
}
