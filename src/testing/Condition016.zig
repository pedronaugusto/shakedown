//! `std.Io.Condition` as Zig 0.16.0 shipped it (lib/std/Io.zig, MIT), kept
//! as a test fixture: a bug a simulation must find. When a wait is canceled
//! as a signal lands, it consumes the signal and returns without
//! `error.Canceled`, so the cancel is acknowledged and lost. Zig 0.17's
//! condition reports the cancel and hands the signal on.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Condition016 = @This();

state: std.atomic.Value(State),
/// Incremented whenever the condition is signaled
epoch: std.atomic.Value(u32),

const State = packed struct(u32) {
    waiters: u16,
    signals: u16,
};

pub const init: Condition016 = .{
    .state = .init(.{ .waiters = 0, .signals = 0 }),
    .epoch = .init(0),
};

pub fn wait(cond: *Condition016, io: Io, mutex: *Io.Mutex) Io.Cancelable!void {
    var epoch = cond.epoch.load(.acquire);
    {
        const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
        assert(prev_state.waiters < std.math.maxInt(u16));
    }
    mutex.unlock(io);
    defer mutex.lockUncancelable(io);
    while (true) {
        const result = io.futexWait(u32, &cond.epoch.raw, epoch);
        epoch = cond.epoch.load(.acquire);
        // Even on error, try to consume a pending signal first: the bug.
        {
            var prev_state = cond.state.load(.monotonic);
            while (prev_state.signals > 0) {
                prev_state = cond.state.cmpxchgWeak(prev_state, .{
                    .waiters = prev_state.waiters - 1,
                    .signals = prev_state.signals - 1,
                }, .acquire, .monotonic) orelse return;
            }
        }
        result catch |err| {
            const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            assert(prev_state.waiters > 0);
            return err;
        };
    }
}

pub fn broadcast(cond: *Condition016, io: Io) void {
    var prev_state = cond.state.load(.monotonic);
    while (prev_state.waiters > prev_state.signals) {
        prev_state = cond.state.cmpxchgWeak(prev_state, .{
            .waiters = prev_state.waiters,
            .signals = prev_state.waiters,
        }, .release, .monotonic) orelse {
            _ = cond.epoch.fetchAdd(1, .release);
            io.futexWake(u32, &cond.epoch.raw, prev_state.waiters - prev_state.signals);
            return;
        };
    }
}
