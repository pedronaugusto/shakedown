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
//! that makes none for another watchdog time after it was marked is
//! reported again and the process aborted, since nothing else can stop it.
//! The second time counts from the mark, not from the task's last call: a
//! sample taken late (the watchdog's own thread descheduled on a loaded
//! host) leaves the task the whole time to reach its call.
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
    /// When the run was marked stuck.
    marked: ?i64 = null,
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
        w.thread = std.Thread.spawn(spawn, run, .{w}) catch return false;
    }
    watched.next = w.first;
    watched.previous = null;
    if (w.first) |first| first.previous = watched;
    w.first = watched;
    w.wake();
    return true;
}

/// How the thread is started: with the stack std gives a thread, reserved and
/// touched only as used. A small stack saves nothing and is refused or
/// overrun where the system or a sanitizer needs more: glibc takes no stack
/// under 128 KiB on aarch64, and ThreadSanitizer's runtime runs on the
/// thread's own stack (64 KiB crashed aegis's tests under it there).
pub const spawn: std.Thread.SpawnConfig = .{};

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
        // glint-ignore: Z026 -- a wait cut short only samples sooner
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
    switch (verdict(watched, task, watched.calls.load(.monotonic), now)) {
        .running => {},
        .marked => |idle| say("shakedown: task {d} has run {d} ms without an Io call; the run ends as stuck at its next one\n", .{ task.raw(), @divTrunc(idle, std.time.ns_per_ms) }),
        .unstoppable => |idle| {
            say("shakedown: task {d} has made no Io call for {d} ms and cannot be stopped; aborting\n", .{ task.raw(), @divTrunc(idle, std.time.ns_per_ms) });
            std.process.abort();
        },
    }
}

/// What one sample finds: a task that runs as it should, one just marked
/// stuck, or one that made no call in a whole watchdog time after it was
/// marked. Each carries how long the task has gone without a call.
const Verdict = union(enum) { running, marked: i64, unstoppable: i64 };

fn verdict(watched: *Watched, task: ids.TaskId, calls: u64, now: i64) Verdict {
    if (task == ids.outside or calls != watched.seen or watched.since == null) {
        watched.seen = calls;
        watched.since = now;
        watched.marked = null;
        return .running;
    }
    const idle = now -| watched.since.?;
    if (watched.marked) |marked| return if (now -| marked >= watched.limit) .{ .unstoppable = idle } else .running;
    if (idle < watched.limit) return .running;
    watched.marked = now;
    watched.stuck.store(true, .monotonic);
    return .{ .marked = idle };
}

test "a task marked stuck has a whole watchdog time from the mark to reach its call" {
    var running: std.atomic.Value(ids.TaskId) = .init(.fromRaw(1));
    var calls: std.atomic.Value(u64) = .init(0);
    var stuck: std.atomic.Value(bool) = .init(false);
    const ms = std.time.ns_per_ms;
    var watched: Watched = .{ .running = &running, .calls = &calls, .stuck = &stuck, .limit = 50 * ms };
    const task: ids.TaskId = .fromRaw(1);
    try std.testing.expectEqual(Verdict.running, verdict(&watched, task, 0, 0));
    // A late sample marks it at 95 ms; the next, at 101 ms, is not past the grace.
    try std.testing.expectEqual(Verdict{ .marked = 95 * ms }, verdict(&watched, task, 0, 95 * ms));
    try std.testing.expect(stuck.load(.monotonic));
    try std.testing.expectEqual(Verdict.running, verdict(&watched, task, 0, 101 * ms));
    try std.testing.expectEqual(Verdict{ .unstoppable = 145 * ms }, verdict(&watched, task, 0, 145 * ms));
    // A call clears the mark.
    try std.testing.expectEqual(Verdict.running, verdict(&watched, task, 1, 150 * ms));
    try std.testing.expectEqual(Verdict.running, verdict(&watched, task, 1, 199 * ms));
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // glint-ignore: Z026 -- a message stderr cannot take is lost
    stderr.writer.print(fmt, args) catch {};
}
