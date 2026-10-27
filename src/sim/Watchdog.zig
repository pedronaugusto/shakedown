//! `Watchdog`: a thread that watches simulations for a task that stopped
//! calling into them.
//!
//! A simulation with a watchdog time starts one of its own on its first
//! run, unless `Sim.Options.watched_by` names one it shares: `check` shares
//! one among its cases, so a case starts no thread. The thread starts with
//! the first simulation watched and stops at `deinit`.
//!
//! Each sample reads a watched simulation's running task, its call count
//! and the thread the task runs on. A task that could run for the
//! simulation's watchdog time without a call is reported and the run marked
//! stuck, which ends it at the task's next call; one that could run another
//! watchdog time after it was marked, still without one, is reported again
//! and the process aborted, since nothing else can stop it.
//!
//! The time a task could run is what its thread had (`os_thread`): its CPU
//! time, and all the time it was blocked in the kernel, where it could not
//! have made a call either. Time it waited for a CPU does not count: on a
//! loaded host a thread can wait a whole watchdog time for one. Where the
//! system says nothing of the thread, real time counts. The second time
//! counts from the mark, not from the task's last call: a sample taken late
//! (the watchdog's own thread descheduled) leaves the task the whole time
//! to reach its call.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const ids = @import("../ids.zig");
const os_thread = @import("os_thread.zig");

const Watchdog = @This();

/// Private: the thread, whether it is to stop and the simulations linked
/// here, behind the lock that guards them and every `Watched` linked.
locked: aegis.BlockingGuarded(Watching) = .init(.{}),
/// Private: bumped to wake the thread, when a simulation comes or goes and
/// when it is to stop.
signal: std.atomic.Value(u32) = .init(0), // aegis: boundary: a futex word, which futexWait waits on as the `u32` itself

/// What the lock guards.
const Watching = struct {
    /// The thread, once started.
    thread: ?std.Thread = null,
    stopping: bool = false,
    first: ?*Watched = null,
};

/// The Io calls a simulation has made: the watchdog's sign of life.
pub const Calls = aegis.units.Count(struct {}, u64);
/// The watchdog's verdict on a simulation, which it reads at its next call.
pub const Stuck = enum(u8) { running, stuck };

/// What the watchdog reads of one simulation, and keeps of it between
/// samples. The simulation owns it, and it links it in with `add`.
pub const Watched = struct {
    /// The running task's id, `outside` when none; the calls made so far;
    /// and the verdict the simulation reads at its next call.
    running: *const aegis.Atomic(ids.TaskId),
    calls: *const aegis.Atomic(Calls),
    stuck: *aegis.Atomic(Stuck),
    /// Time, in nanoseconds, a task may run without a call.
    limit: i64,
    /// The thread the running task runs on, as the simulation names it; null
    /// when it names none, and real time counts.
    runner: ?*const aegis.Atomic(os_thread.Thread) = null,
    /// Private: the watchdog's.
    next: ?*Watched = null,
    previous: ?*Watched = null,
    seen: u64 = 0,
    seen_runner: os_thread.Thread = .none,
    /// When the call count was first seen; null while no task runs.
    since: ?i64 = null,
    /// The runner's last reading, and when it was taken.
    last: ?os_thread.Reading = null,
    read_at: i64 = 0,
    /// How long the task could run since `since`, or since the mark.
    ran: i64 = 0,
    /// When the run was marked stuck.
    marked: ?i64 = null,
};

pub fn init() Watchdog {
    return .{};
}

/// Stops the thread. Every simulation it watched must be torn down first.
pub fn deinit(w: *Watchdog) void {
    const thread = stop: {
        var held = w.locked.acquireUncancelable(real());
        defer held.deinit(real());
        const s = held.value();
        std.debug.assert(s.first == null); // a simulation it watches outlives it
        s.stopping = true;
        break :stop s.thread;
    };
    if (thread) |t| {
        w.wake();
        t.join();
    }
    w.* = undefined;
}

/// Watches `watched`, starting the thread if there is none yet. Returns
/// false when no thread can be had: the run is then unwatched and
/// otherwise the same. `watched` must not move until `remove`.
pub fn add(w: *Watchdog, watched: *Watched) bool {
    var held = w.locked.acquireUncancelable(real());
    defer held.deinit(real());
    const s = held.value();
    if (s.thread == null) {
        s.thread = std.Thread.spawn(spawn, run, .{w}) catch return false;
    }
    watched.next = s.first;
    watched.previous = null;
    if (s.first) |first| first.previous = watched;
    s.first = watched;
    w.wake();
    return true;
}

/// The thread, once started: for tests that check who watches.
pub fn started(w: *Watchdog) ?std.Thread {
    var held = w.locked.acquireUncancelable(real());
    defer held.deinit(real());
    return held.value().thread;
}

/// How the thread is started: with the stack std gives a thread, reserved and
/// touched only as used. A small stack saves nothing and is refused or
/// overrun where the system or a sanitizer needs more: glibc takes no stack
/// under 128 KiB on aarch64, and ThreadSanitizer's runtime runs on the
/// thread's own stack (64 KiB crashed aegis's tests under it there).
pub const spawn: std.Thread.SpawnConfig = .{};

/// Stops watching `watched`.
pub fn remove(w: *Watchdog, watched: *Watched) void {
    var held = w.locked.acquireUncancelable(real());
    defer held.deinit(real());
    if (watched.previous) |p| p.next = watched.next else held.value().first = watched.next;
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
    var held = w.locked.acquireUncancelable(real());
    defer held.deinit(real());
    const s = held.value();
    if (s.stopping) return null;
    const now = std.math.lossyCast(i64, Io.Timestamp.now(real(), .awake).nanoseconds);
    var slice: ?i64 = null;
    var it = s.first;
    while (it) |watched| : (it = watched.next) {
        look(watched, now);
        const own = @max(@divTrunc(watched.limit, 8), std.time.ns_per_ms);
        slice = if (slice) |least| @min(least, own) else own;
    }
    return .{ .slice = slice };
}

fn look(watched: *Watched, now: i64) void {
    const task = watched.running.load(.monotonic);
    const calls = watched.calls.load(.monotonic).raw();
    const runner: os_thread.Thread = if (watched.runner) |r| r.load(.monotonic) else .none;
    const reading = if (task == ids.outside) null else os_thread.read(runner);
    switch (verdict(watched, task, calls, runner, now, reading)) {
        .running => {},
        .marked => |idle| say("shakedown: task {d} has made no Io call for {d} ms, a watchdog time of it running; the run ends as stuck at its next one\n", .{ task.raw(), @divTrunc(idle, std.time.ns_per_ms) }),
        .unstoppable => |idle| {
            say("shakedown: task {d} has made no Io call for {d} ms and cannot be stopped; aborting\n", .{ task.raw(), @divTrunc(idle, std.time.ns_per_ms) });
            std.process.abort();
        },
    }
}

/// What one sample finds: a task that runs as it should, one just marked
/// stuck, or one that could run a whole watchdog time after it was marked
/// and made no call. Each carries how long, in real time, the task has gone
/// without a call.
const Verdict = union(enum) { running, marked: i64, unstoppable: i64 };

/// `reading` is the runner's, taken now: null when no task runs or the
/// system says nothing of it.
fn verdict(watched: *Watched, task: ids.TaskId, calls: u64, runner: os_thread.Thread, now: i64, reading: ?os_thread.Reading) Verdict {
    if (task == ids.outside) {
        watched.since = null;
        return .running;
    }
    if (calls != watched.seen or runner != watched.seen_runner or watched.since == null) {
        watched.seen = calls;
        watched.seen_runner = runner;
        watched.since = now;
        watched.last = reading;
        watched.read_at = now;
        watched.ran = 0;
        watched.marked = null;
        return .running;
    }
    watched.ran += os_thread.couldRun(watched.last, reading, now -| watched.read_at);
    watched.last = reading;
    watched.read_at = now;
    const idle = now -| watched.since.?;
    if (watched.ran < watched.limit) return .running;
    if (watched.marked != null) return .{ .unstoppable = idle };
    watched.marked = now;
    watched.ran = 0;
    watched.stuck.store(.stuck, .monotonic);
    return .{ .marked = idle };
}

const Fixture = struct {
    running: aegis.Atomic(ids.TaskId) = .init(.fromRaw(1)),
    calls: aegis.Atomic(Calls) = .init(.fromRaw(0)),
    stuck: aegis.Atomic(Stuck) = .init(.running),
    runner: aegis.Atomic(os_thread.Thread) = .init(@fromBackingInt(7)),
    watched: Watched = undefined,

    const ms = std.time.ns_per_ms;
    const task: ids.TaskId = .fromRaw(1);
    const thread: os_thread.Thread = @fromBackingInt(@intCast(7));

    fn init(f: *Fixture) void {
        f.watched = .{ .running = &f.running, .calls = &f.calls, .stuck = &f.stuck, .runner = &f.runner, .limit = 50 * ms };
    }

    /// The verdict at `now` ms of a task that made `calls` calls, its
    /// thread having had `cpu` ms of CPU, blocked or not.
    fn at(f: *Fixture, calls: u64, now: i64, cpu: i64, blocked: bool) Verdict {
        return verdict(&f.watched, task, calls, thread, now * ms, .{ .cpu = cpu * ms, .blocked = blocked });
    }
};

test "a task marked stuck has a whole watchdog time from the mark to reach its call" {
    var f: Fixture = .{};
    f.init();
    const ms = Fixture.ms;
    try std.testing.expectEqual(Verdict.running, f.at(0, 0, 0, false));
    // A late sample marks it at 95 ms; the next, at 101 ms, is not past the grace.
    try std.testing.expectEqual(Verdict{ .marked = 95 * ms }, f.at(0, 95, 95, false));
    try std.testing.expect(f.stuck.load(.monotonic) == .stuck);
    try std.testing.expectEqual(Verdict.running, f.at(0, 101, 101, false));
    try std.testing.expectEqual(Verdict{ .unstoppable = 145 * ms }, f.at(0, 145, 145, false));
    // A call clears the mark.
    try std.testing.expectEqual(Verdict.running, f.at(1, 150, 150, false));
    try std.testing.expectEqual(Verdict.running, f.at(1, 199, 199, false));
}

test "a task whose thread waits for a CPU is not charged the wait" {
    var f: Fixture = .{};
    f.init();
    const ms = Fixture.ms;
    try std.testing.expectEqual(Verdict.running, f.at(0, 0, 0, false));
    try std.testing.expectEqual(Verdict{ .marked = 60 * ms }, f.at(0, 60, 60, false));
    // Off the CPU for most of 140 ms after the mark: it had 2 ms of them.
    try std.testing.expectEqual(Verdict.running, f.at(0, 200, 62, false));
    try std.testing.expectEqual(Verdict.running, f.at(0, 300, 100, false));
    try std.testing.expectEqual(Verdict{ .unstoppable = 320 * ms }, f.at(0, 320, 112, false));
}

test "a task blocked in the kernel is charged all the time it is blocked" {
    var f: Fixture = .{};
    f.init();
    const ms = Fixture.ms;
    try std.testing.expectEqual(Verdict.running, f.at(0, 0, 0, true));
    try std.testing.expectEqual(Verdict.running, f.at(0, 30, 0, true));
    try std.testing.expectEqual(Verdict{ .marked = 60 * ms }, f.at(0, 60, 0, true));
    try std.testing.expectEqual(Verdict{ .unstoppable = 110 * ms }, f.at(0, 110, 0, true));
}

test "a task on another thread starts its time again" {
    var f: Fixture = .{};
    f.init();
    try std.testing.expectEqual(Verdict.running, f.at(0, 0, 0, false));
    try std.testing.expectEqual(Verdict.running, f.at(0, 40, 40, false));
    try std.testing.expectEqual(Verdict.running, verdict(&f.watched, Fixture.task, 0, @fromBackingInt(@intCast(8)), 45 * Fixture.ms, .{ .cpu = 0, .blocked = false }));
    try std.testing.expectEqual(Verdict.running, verdict(&f.watched, Fixture.task, 0, @fromBackingInt(@intCast(8)), 90 * Fixture.ms, .{ .cpu = 45 * Fixture.ms, .blocked = false }));
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // glint-ignore: Z026 -- a message stderr cannot take is lost
    stderr.writer.print(fmt, args) catch {};
}
