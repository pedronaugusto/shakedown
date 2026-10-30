//! A manual clock over any base `Io`: time moves only when the test moves it.
//!
//! `now`, `clockResolution` and `sleep` are the clock's, and so are the
//! timed forms of `futexWait` and `batchAwaitConcurrent` and the timeout of
//! `netConnectIp`. Every other slot goes to the base unchanged, so a timer,
//! a retry loop or a deadline under test runs its real code against a time
//! the test chooses.
//!
//! The awake, boot and real clocks are kept apart: `advance` moves all
//! three, `suspendFor` moves boot and real but not awake, as a machine that
//! sleeps does, and `stepReal` moves only real time, backwards too. The CPU
//! clocks stay frozen unless `Options.cpu` hands them to the base.
//!
//! With `Options.advance = .auto`, time moves by itself instead: each timer
//! fires as it is armed, the clocks moving to its deadline, and as far past
//! it as `late` says, as a sleeper that resumes late. That suits code whose
//! own waits are what move its time, with no test thread to move it.
//!
//! The base must keep real time (`std.testing.io`, or a `Threaded` of the
//! test's own): a waiter blocks on the base until a timer fires or its
//! wait is woken. A `Clock` must not move once `io` has been called.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const assert = std.debug.assert;
const Layer = @import("layer.zig").Layer;
const nanoseconds = @import("nanoseconds.zig");

const Clock = @This();

/// Private: the layer and the clock's state.
layer: L,

pub const Options = struct {
    /// `.real` at the start, in Unix time (2026-01-01T00:00:00Z).
    real: Io.Timestamp = .fromNanoseconds(1_767_225_600 * std.time.ns_per_s),
    /// `.awake` and `.boot` at the start, and where frozen CPU clocks stay.
    /// Nonzero, so code that treats 0 as "unset" is caught.
    monotonic: Io.Timestamp = .fromNanoseconds(std.time.ns_per_s),
    resolution: Io.Duration = .fromNanoseconds(1),
    cpu: Cpu = .frozen,
    /// How often, in real time, a timed futex or batch wait looks again at
    /// its timer. A timeout that fires reaches its waiter at most this late;
    /// a wake from the code under test reaches it at once.
    recheck: Io.Duration = .fromMilliseconds(1),
    /// Who moves time.
    advance: Advance = .manual,

    pub const Advance = union(enum) {
        /// The test, with `advance` and its kin; a waiter waits for it.
        manual,
        /// The waiters: each timer fires as it is armed.
        auto: Auto,
    };

    pub const Auto = struct {
        /// How far past its deadline each timer fires: the clocks move to
        /// the deadline and this much further. Zero is on time.
        late: Io.Duration = .zero,
    };

    pub const Cpu = enum {
        /// `cpu_process` and `cpu_thread` read `monotonic` and never move.
        /// A timer on them that is not already due never fires.
        frozen,
        /// The CPU clocks, and every wait on them, are the base's.
        base,
    };
};

pub const AwaitArmedError = error{ Timeout, Canceled };

const L = Layer(State, .{
    .now = now,
    .clockResolution = clockResolution,
    .sleep = sleep,
    .futexWait = futexWait,
    .batchAwaitConcurrent = batchAwaitConcurrent,
    .netConnectIp = netConnectIp,
});

/// The clocks a `Clock` moves, as indices into its state.
const Kept = enum(u2) { awake, boot, real };

/// A reading of one of the kept clocks, which a `Kept` beside it names.
const Reading = nanoseconds.Reading(Clock);
/// How far the kept clocks move, or are from a deadline.
const Span = nanoseconds.Span;
/// Timers armed.
const Armed = aegis.units.Count(Timer, usize);

const still: Span = .fromRaw(0);

const Key = struct {
    deadline: Reading,
    /// Arming order: equal deadlines fire in the order they were armed.
    seq: u64,

    fn order(a: Key, b: Key) std.math.Order {
        return switch (a.deadline.compare(b.deadline)) {
            .eq => std.math.order(a.seq, b.seq),
            else => |o| o,
        };
    }
};

const Timers = std.Treap(Key, Key.order);

/// A timer lives on the stack of the call that armed it. Firing happens
/// under the clock's lock and the waiter takes that lock before it
/// returns, so nothing touches a timer, or the futex word it names, after
/// its waiter has gone.
const Timer = struct {
    /// Private: the timer's place among the armed ones.
    node: Timers.Node = undefined,
    clock: Kept,
    /// Private: 0 while armed, 1 once fired. A sleep waits on it.
    state: std.atomic.Value(u32) = .init(0), // aegis: boundary(A007): a futex word, which the base's futexWait waits on as the `u32` itself
    /// A timed futex wait's word, woken when the timer fires.
    futex: ?*const u32 = null,
    /// Private: how many timers the clock had fired before this one.
    rank: u64 = 0,
};

const State = struct {
    options: Options,
    /// Each kept clock, moved under the lock and read without it.
    clocks: [3]aegis.Atomic(Reading),
    /// The armed timers, behind the lock that guards them.
    locked: aegis.BlockingGuarded(Timing) = .init(.{}),
    count: aegis.Atomic(Armed) = .init(.fromRaw(0)),
    /// Bumped on every arming, so `awaitArmed` can wait on it.
    arming: std.atomic.Value(u32) = .init(0), // aegis: boundary(A007): a futex word, which the base's futexWait waits on as the `u32` itself
};

/// What the clock's lock guards.
const Timing = struct {
    timers: [3]Timers = .{ .{}, .{}, .{} },
    seq: u64 = 0,
    fired: u64 = 0,
};

pub fn init(base: Io, options: Options) Clock {
    switch (options.advance) {
        .manual => {},
        .auto => |auto| assert(spanOf(auto.late).compare(still) != .lt),
    }
    const monotonic = readingOf(options.monotonic);
    return .{ .layer = .init(base, .{
        .options = options,
        .clocks = .{ .init(monotonic), .init(monotonic), .init(readingOf(options.real)) },
    }) };
}

fn acquire(l: *L) @TypeOf(l.state.locked).Guard {
    return l.state.locked.acquireUncancelable(l.base);
}

/// The `Io` to hand the code under test. The clock must not move after this.
pub fn io(c: *Clock) Io {
    return c.layer.io();
}

/// What `which` reads now.
pub fn read(c: *const Clock, which: Io.Clock) Io.Timestamp {
    return readState(&c.layer, which);
}

/// Move awake, boot and real forward by `by`, then fire every timer whose
/// deadline is reached, in (deadline, arming order) order.
pub fn advance(c: *Clock, by: Io.Duration) void {
    const d = spanOf(by);
    assert(d.compare(still) != .lt);
    move(&c.layer, .{ d, d, d });
}

/// Move awake to `awake`, and boot and real by as much. Never backwards.
pub fn advanceTo(c: *Clock, awake: Io.Timestamp) void {
    const by = c.layer.state.clocks[@backingInt(Kept.awake)].load(.acquire).saturatingDurationTo(readingOf(awake));
    assert(by.compare(still) != .lt);
    move(&c.layer, .{ by, by, by });
}

/// Move to the earliest armed deadline and fire what is due there. Returns
/// how far the clocks moved, or null when no timer is armed.
pub fn advanceToNext(c: *Clock) ?Io.Duration {
    const l = &c.layer;
    var held = acquire(l);
    defer held.deinit(l.base);
    const next = earliest(&l.state, held.value()) orelse return null;
    const by = next.remaining;
    moveLocked(l, held.value(), .{ by, by, by });
    return by.toIoDuration();
}

/// The machine sleeps for `d`: boot and real move, awake does not. Timers
/// on boot or real time may fire.
pub fn suspendFor(c: *Clock, d: Io.Duration) void {
    const by = spanOf(d);
    assert(by.compare(still) != .lt);
    move(&c.layer, .{ still, by, by });
}

/// A wall-clock step, as NTP or an operator makes it, backwards too. Only
/// `.real` changes; a forward step fires the real-time timers it reaches.
pub fn stepReal(c: *Clock, to: Io.Timestamp) void {
    const l = &c.layer;
    var held = acquire(l);
    defer held.deinit(l.base);
    const from = l.state.clocks[@backingInt(Kept.real)].load(.acquire);
    moveLocked(l, held.value(), .{ still, still, from.saturatingDurationTo(readingOf(to)) });
}

/// How many timers are armed: sleeps and timed waits not yet fired,
/// returned or canceled.
pub fn armed(c: *const Clock) usize {
    return c.layer.state.count.load(.acquire).raw();
}

/// The armed deadline the clocks reach first, on its own clock.
pub fn nextDeadline(c: *Clock) ?Io.Clock.Timestamp {
    const l = &c.layer;
    var held = acquire(l);
    defer held.deinit(l.base);
    const next = earliest(&l.state, held.value()) orelse return null;
    return .{ .raw = next.node.key.deadline.toTimestamp(), .clock = clockOf(next.clock) };
}

/// Block, in real time on the base, until at least `n` timers are armed:
/// the barrier a test takes before `advance` when the waiter runs on
/// another task. `timeout` is read on the base, never on this clock, so a
/// deadline can be shared with the test's other waits; `.none` waits for
/// as long as it takes.
pub fn awaitArmed(c: *Clock, n: usize, timeout: Io.Timeout) AwaitArmedError!void {
    const s = &c.layer.state;
    const base = c.layer.base;
    const deadline = timeout.toDeadline(base);
    while (true) {
        const seen = s.arming.load(.acquire);
        if (s.count.load(.acquire).compare(.fromRaw(n)) != .lt) return;
        switch (deadline) {
            .deadline => |at| if (at.compare(.lte, .now(base, at.clock))) return error.Timeout,
            .none, .duration => {},
        }
        try base.futexWaitTimeout(u32, &s.arming.raw, seen, deadline);
    }
}

// The overrides.

fn now(userdata: ?*anyopaque, which: Io.Clock) Io.Timestamp {
    return readState(L.of(userdata), which);
}

fn clockResolution(userdata: ?*anyopaque, which: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    const l = L.of(userdata);
    if (keptOf(which) == null and l.state.options.cpu == .base) {
        return l.base.vtable.clockResolution(l.base.userdata, which);
    }
    return l.state.options.resolution;
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const l = L.of(userdata);
    switch (when(l, timeout)) {
        .base => return l.base.vtable.sleep(l.base.userdata, timeout),
        .never => return l.base.vtable.sleep(l.base.userdata, .none),
        .due => return l.base.checkCancel(),
        .at => |at| {
            var timer: Timer = .{ .clock = at.clock };
            if (!arm(l, &timer, at.deadline)) return l.base.checkCancel();
            defer disarm(l, &timer);
            while (timer.state.load(.acquire) == 0) try l.base.futexWait(u32, &timer.state.raw, 0);
        },
    }
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const l = L.of(userdata);
    switch (when(l, timeout)) {
        .base => return l.base.vtable.futexWait(l.base.userdata, ptr, expected, timeout),
        .never => return l.base.vtable.futexWait(l.base.userdata, ptr, expected, .none),
        // Due already: no wait, but a cancel aimed at the waiter is still its answer,
        // as the base's own wait would give it.
        .due => return l.base.checkCancel(),
        .at => |at| {
            var timer: Timer = .{ .clock = at.clock, .futex = ptr };
            if (!arm(l, &timer, at.deadline)) return l.base.checkCancel();
            defer disarm(l, &timer);
            const slice = recheck(l);
            // A wake that leaves the word at `expected` is taken for a
            // spurious one and waited through; returning would read as a
            // timeout to a caller such as `Event.waitTimeout`.
            while (timer.state.load(.acquire) == 0 and @atomicLoad(u32, ptr, .acquire) == expected) { // aegis: boundary(A007): the futex word is std's, a `*const u32` the vtable hands in
                try l.base.vtable.futexWait(l.base.userdata, ptr, expected, slice);
            }
        },
    }
}

fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    const l = L.of(userdata);
    const at = switch (when(l, timeout)) {
        .base => return l.base.vtable.batchAwaitConcurrent(l.base.userdata, batch, timeout),
        .never => return l.base.vtable.batchAwaitConcurrent(l.base.userdata, batch, .none),
        .due => return l.base.vtable.batchAwaitConcurrent(l.base.userdata, batch, zero),
        .at => |at| at,
    };
    var timer: Timer = .{ .clock = at.clock };
    if (!arm(l, &timer, at.deadline)) return l.base.vtable.batchAwaitConcurrent(l.base.userdata, batch, zero);
    defer disarm(l, &timer);
    const slice = recheck(l);
    while (true) {
        // A timer that has fired gets one last look, which waits for nothing.
        const fired = timer.state.load(.acquire) != 0;
        return l.base.vtable.batchAwaitConcurrent(l.base.userdata, batch, if (fired) zero else slice) catch |err| switch (err) {
            error.Timeout => if (fired or timer.state.load(.acquire) != 0) error.Timeout else continue,
            else => err,
        };
    }
}

/// A connect's timeout is handed to the base as the controlled time left,
/// counted in real time: enough for a loopback connect, which is what a
/// test makes.
fn netConnectIp(
    userdata: ?*anyopaque,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ConnectOptions,
) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const l = L.of(userdata);
    var forwarded = options;
    forwarded.timeout = switch (when(l, options.timeout)) {
        .base => options.timeout,
        .never => .none,
        .due => zero,
        .at => |at| left: {
            const left = l.state.clocks[@backingInt(at.clock)].load(.acquire).saturatingDurationTo(at.deadline);
            const ahead = if (left.compare(still) == .lt) still else left;
            break :left .{ .duration = .{ .raw = ahead.toIoDuration(), .clock = .awake } };
        },
    };
    return l.base.vtable.netConnectIp(l.base.userdata, address, forwarded);
}

// Timers.

const zero: Io.Timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } };

const When = union(enum) {
    /// A CPU clock the base keeps, or no timeout: the base's to wait.
    base,
    /// A frozen CPU clock that will not reach the deadline.
    never,
    /// The deadline is already reached.
    due,
    at: struct { clock: Kept, deadline: Reading },
};

/// Where a timeout ends: a span from the clock's reading, or a reading.
const End = union(enum) {
    after: Span,
    at: Reading,

    fn from(e: End, current: Reading) Reading {
        return switch (e) {
            .after => |span| current.saturatingAdd(span),
            .at => |deadline| deadline,
        };
    }
};

fn when(l: *L, timeout: Io.Timeout) When {
    const which, const end: End = switch (timeout) {
        .none => return .base,
        .duration => |d| .{ d.clock, .{ .after = spanOf(d.raw) } },
        .deadline => |d| .{ d.clock, .{ .at = readingOf(d.raw) } },
    };
    const kept = keptOf(which) orelse {
        if (l.state.options.cpu == .base) return .base;
        const frozen = readingOf(l.state.options.monotonic);
        return if (end.from(frozen).compare(frozen) != .gt) .due else .never;
    };
    return .{ .at = .{ .clock = kept, .deadline = end.from(l.state.clocks[@backingInt(kept)].load(.acquire)) } };
}

fn recheck(l: *L) Io.Timeout {
    return .{ .duration = .{ .raw = l.state.options.recheck, .clock = .awake } };
}

/// Arms `timer` unless its deadline is already reached; returns whether it
/// did. Under `.auto` the clocks then move until it fires.
fn arm(l: *L, timer: *Timer, deadline: Reading) bool {
    const s = &l.state;
    var held = acquire(l);
    defer held.deinit(l.base);
    const t = held.value();
    const kept = @backingInt(timer.clock);
    const current = s.clocks[kept].load(.acquire);
    if (deadline.compare(current) != .gt) return false;
    t.seq += 1;
    var entry = t.timers[kept].getEntryFor(.{ .deadline = deadline, .seq = t.seq });
    entry.set(&timer.node);
    _ = s.count.fetchAddWrapping(.fromRaw(1), .release);
    _ = s.arming.fetchAdd(1, .release);
    l.base.futexWake(u32, &s.arming.raw, std.math.maxInt(u32));
    switch (s.options.advance) {
        .manual => {},
        .auto => |auto| {
            const by = current.saturatingDurationTo(deadline).saturatingAdd(spanOf(auto.late));
            moveLocked(l, t, .{ by, by, by });
        },
    }
    return true;
}

/// Takes the timer out unless it fired. Either way, once this returns the
/// clock is done with it.
fn disarm(l: *L, timer: *Timer) void {
    var held = acquire(l);
    defer held.deinit(l.base);
    if (timer.state.load(.acquire) != 0) return;
    var entry = held.value().timers[@backingInt(timer.clock)].getEntryForExisting(&timer.node);
    entry.set(null);
    _ = l.state.count.fetchSubWrapping(.fromRaw(1), .release);
}

fn move(l: *L, by: [3]Span) void {
    var held = acquire(l);
    defer held.deinit(l.base);
    moveLocked(l, held.value(), by);
}

/// Moves each kept clock by its amount, then fires what became due: the
/// timer the clocks reached first goes first, equal ones in arming order.
fn moveLocked(l: *L, t: *Timing, by: [3]Span) void {
    var before: [3]Reading = undefined;
    var after: [3]Reading = undefined;
    for (&l.state.clocks, &before, &after, by) |*clock, *b, *a, d| {
        b.* = clock.load(.acquire);
        a.* = b.saturatingAdd(d);
        clock.store(a.*, .release);
    }
    while (true) {
        var first: ?Pick = null;
        for (&t.timers, 0..) |*timers, i| {
            const node = timers.getMin() orelse continue;
            if (node.key.deadline.compare(after[i]) == .gt) continue;
            const pick: Pick = .{ .clock = @fromBackingInt(@intCast(i)), .node = node, .remaining = before[i].saturatingDurationTo(node.key.deadline) };
            if (first == null or pick.before(first.?)) first = pick;
        }
        fire(l, t, first orelse return);
    }
}

const Pick = struct {
    clock: Kept,
    node: *Timers.Node,
    /// How far the clocks had to move to reach it.
    remaining: Span,

    fn before(a: Pick, b: Pick) bool {
        return switch (a.remaining.compare(b.remaining)) {
            .lt => true,
            .gt => false,
            .eq => a.node.key.seq < b.node.key.seq,
        };
    }
};

/// The armed timer the clocks reach first.
fn earliest(s: *State, t: *Timing) ?Pick {
    var first: ?Pick = null;
    for (&t.timers, 0..) |*timers, i| {
        const node = timers.getMin() orelse continue;
        const pick: Pick = .{
            .clock = @fromBackingInt(@intCast(i)),
            .node = node,
            .remaining = s.clocks[i].load(.acquire).saturatingDurationTo(node.key.deadline),
        };
        if (first == null or pick.before(first.?)) first = pick;
    }
    return first;
}

fn fire(l: *L, t: *Timing, pick: Pick) void {
    const timer: *Timer = @fieldParentPtr("node", pick.node);
    var entry = t.timers[@backingInt(pick.clock)].getEntryForExisting(pick.node);
    entry.set(null);
    _ = l.state.count.fetchSubWrapping(.fromRaw(1), .release);
    timer.rank = t.fired;
    t.fired += 1;
    timer.state.store(1, .release);
    if (timer.futex) |word| {
        l.base.vtable.futexWake(l.base.userdata, word, std.math.maxInt(u32));
    } else {
        l.base.futexWake(u32, &timer.state.raw, 1);
    }
}

fn readState(l: *const L, which: Io.Clock) Io.Timestamp {
    if (keptOf(which)) |kept| return l.state.clocks[@backingInt(kept)].load(.acquire).toTimestamp();
    return switch (l.state.options.cpu) {
        .frozen => l.state.options.monotonic,
        .base => l.base.vtable.now(l.base.userdata, which),
    };
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

fn readingOf(t: Io.Timestamp) Reading {
    return nanoseconds.reading(Clock, t);
}

const spanOf = nanoseconds.span;

test "a fired timer is out of the set, and an expired one is never armed" {
    var clock: Clock = .init(std.testing.io, .{});
    const l = &clock.layer;
    var t: Timer = .{ .clock = .awake };
    const start = l.state.clocks[0].load(.acquire);
    try std.testing.expect(!arm(l, &t, start));
    try std.testing.expect(arm(l, &t, start.saturatingAdd(.fromRaw(5))));
    try std.testing.expectEqual(@as(usize, 1), clock.armed());
    clock.advance(.fromNanoseconds(4));
    try std.testing.expectEqual(@as(u32, 0), t.state.load(.acquire));
    clock.advance(.fromNanoseconds(1));
    try std.testing.expectEqual(@as(u32, 1), t.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), clock.armed());
    disarm(l, &t);
    try std.testing.expectEqual(@as(usize, 0), clock.armed());
}

test "timers fire in the order the clocks reach them, ties in arming order" {
    var clock: Clock = .init(std.testing.io, .{});
    const l = &clock.layer;
    // No thread waits on these timers, so the order read back is the
    // clock's own, free of scheduling.
    var timers: [6]Timer = undefined;
    const awake = l.state.clocks[@backingInt(Kept.awake)].load(.acquire);
    const real = l.state.clocks[@backingInt(Kept.real)].load(.acquire);
    const plan = [_]struct { clock: Kept, deadline: Reading }{
        .{ .clock = .awake, .deadline = awake.saturatingAdd(.fromRaw(30)) },
        .{ .clock = .real, .deadline = real.saturatingAdd(.fromRaw(10)) },
        .{ .clock = .awake, .deadline = awake.saturatingAdd(.fromRaw(10)) }, // ties with 1, armed after it
        .{ .clock = .boot, .deadline = awake.saturatingAdd(.fromRaw(20)) },
        .{ .clock = .awake, .deadline = awake.saturatingAdd(.fromRaw(50)) }, // not reached
        .{ .clock = .real, .deadline = real.saturatingAdd(.fromRaw(30)) }, // ties with 0, armed after it
    };
    for (&timers, plan) |*t, p| {
        t.* = .{ .clock = p.clock };
        try std.testing.expect(arm(l, t, p.deadline));
    }
    try std.testing.expectEqual(@as(usize, 6), clock.armed());
    try std.testing.expectEqual(Io.Clock.real, clock.nextDeadline().?.clock);
    clock.advance(.fromNanoseconds(30));
    try std.testing.expectEqual(@as(usize, 1), clock.armed());
    const order = [_]usize{ 1, 2, 3, 0, 5 };
    for (order, 0..) |index, rank| {
        try std.testing.expectEqual(@as(u32, 1), timers[index].state.load(.acquire));
        try std.testing.expectEqual(@as(u64, rank), timers[index].rank);
    }
    try std.testing.expectEqual(@as(?Io.Duration, .fromNanoseconds(20)), clock.advanceToNext());
    try std.testing.expectEqual(@as(?Io.Duration, null), clock.advanceToNext());
}
