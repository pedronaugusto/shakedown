//! An allocator that counts the calls made while a lock is held.
//!
//! A section that must be bounded, because another thread waits on its
//! lock, must not allocate: an allocation can take the system's own locks
//! and as long as it likes. Give the probe the lock, run the code, and read
//! how many of its allocator calls found the lock held. `Counting` counts
//! and fails calls but cannot look at anything else when one is made; the
//! probe asks `Held` at every call and keeps the first offender with its
//! frames.
//!
//! The lock is read, never taken, and a lock does not say who holds it: the
//! probe reports a call made while *anyone* held the lock. That is the
//! question for a lock the code under test takes itself, with the test on
//! one thread, and for any lock where no allocation at all is the contract.
//! Calls pass through to the child unchanged.
//!
//! Thread-safe.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const LockProbe = @This();

/// Private: where the memory comes from and goes back to.
child: Allocator,
/// Private: what says whether the lock is held.
held: Held,
/// Private: every call, and those made with the lock held.
total: std.atomic.Value(usize) = .init(0),
locked: std.atomic.Value(usize) = .init(0),
/// Private: the first call made with the lock held.
first: aegis.Guarded(?Offender) = .init(null),

/// How the probe reads a lock: a context and a question about it.
pub const Held = struct {
    context: *const anyopaque,
    isHeld: *const fn (context: *const anyopaque) bool,

    /// A spin lock that is one atomic flag, true while held, as the lock of
    /// an `aegis.Guarded` is.
    pub fn flag(lock: *const std.atomic.Value(bool)) Held {
        return .{
            .context = lock,
            .isHeld = struct {
                fn is(context: *const anyopaque) bool {
                    const l: *const std.atomic.Value(bool) = @ptrCast(@alignCast(context)); // safe: made from a flag in `flag`
                    return l.load(.acquire);
                }
            }.is,
        };
    }

    /// The lock of an `aegis.Guarded`, read without taking it. `Guarded` has
    /// no call that asks whether it is held, and this is the one place a
    /// probe reaches for its flag, so a test does not.
    pub fn guarded(owner: anytype) Held {
        // glint-ignore: A001 -- safe-type-internals: docs/design.md#aegis-types-and-the-raw-sites; the flag is read, never written, and Guarded offers no call that asks
        return flag(&owner.lock);
    }

    /// A `std.Io.Mutex`.
    pub fn mutex(lock: *const std.Io.Mutex) Held {
        return .{
            .context = lock,
            .isHeld = struct {
                fn is(context: *const anyopaque) bool {
                    const l: *const std.Io.Mutex = @ptrCast(@alignCast(context)); // safe: made from a mutex in `mutex`
                    return l.state.load(.acquire) != .unlocked;
                }
            }.is,
        };
    }

    /// A `std.atomic.Mutex`.
    pub fn spinMutex(lock: *const std.atomic.Mutex) Held {
        return .{
            .context = lock,
            .isHeld = struct {
                fn is(context: *const anyopaque) bool {
                    const l: *const std.atomic.Mutex = @ptrCast(@alignCast(context)); // safe: made from a spin mutex in `spinMutex`
                    return @atomicLoad(std.atomic.Mutex, l, .acquire) == .locked;
                }
            }.is,
        };
    }
};

/// A call made with the lock held.
pub const Offender = struct {
    call: Call,
    /// The length asked for, or the block's length for a free.
    len: usize,
    /// The frames of the call, innermost first.
    stack: [16]usize = @splat(0),
    stack_len: u8 = 0,

    /// The call as a line and its frames.
    pub fn format(o: Offender, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{t} of {d} bytes\n", .{ o.call, o.len });
        if (o.stack_len == 0) return;
        var copy = o.stack;
        try w.print("called at:\n{f}", .{std.debug.FormatStackTrace{ .stack_trace = .{ .return_addresses = copy[0..o.stack_len], .skipped = .unknown } }});
    }
};

pub const Call = enum { alloc, resize, remap, free };

pub fn init(child: Allocator, held: Held) LockProbe {
    return .{ .child = child, .held = held };
}

/// The allocator. `p` must not move while it is in use.
pub fn allocator(p: *LockProbe) Allocator {
    return .{ .ptr = p, .vtable = &vtable };
}

/// Every call made through the allocator.
pub fn calls(p: *const LockProbe) usize {
    return p.total.load(.acquire);
}

/// The calls made with the lock held.
pub fn underLock(p: *const LockProbe) usize {
    return p.locked.load(.acquire);
}

/// The first call made with the lock held.
pub fn firstOffender(p: *LockProbe) ?Offender {
    var held = p.first.acquire();
    defer held.deinit();
    return held.value().*;
}

/// Passes when no call found the lock held, and fails when none was made at
/// all: a probe the code never reached proves nothing.
pub fn expectNone(p: *LockProbe) error{TestUnexpectedResult}!void {
    if (p.calls() == 0) {
        say("the probe saw no allocator call at all\n", .{});
        return error.TestUnexpectedResult;
    }
    const n = p.underLock();
    if (n == 0) return;
    const first = p.firstOffender().?; // a count above zero is published after the first offender
    say("{d} of {d} allocator calls found the lock held; the first was {f}", .{ n, p.calls(), first });
    return error.TestUnexpectedResult;
}

/// The failure goes to stderr as `std.testing` puts its own there.
fn say(comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // ziglint-ignore: Z026 a message stderr cannot take is lost
    stderr.writer.print(fmt, args) catch {};
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn of(ptr: *anyopaque) *LockProbe {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with a *LockProbe
}

fn note(p: *LockProbe, call: Call, len: usize, ret_addr: usize) void {
    _ = p.total.fetchAdd(1, .monotonic);
    if (!p.held.isHeld(p.held.context)) return;
    var offender: Offender = .{ .call = call, .len = len };
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = ret_addr }, &offender.stack);
    offender.stack_len = @intCast(trace.return_addresses.len); // safe: at most the 16 frames of `stack`
    {
        var held = p.first.acquire();
        defer held.deinit();
        if (held.value().* == null) held.value().* = offender;
    }
    // After the offender is kept, so a reader that sees the count finds it.
    _ = p.locked.fetchAdd(1, .release);
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    of(ptr).note(.alloc, len, ret_addr);
    return of(ptr).child.rawAlloc(len, alignment, ret_addr);
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    of(ptr).note(.resize, new_len, ret_addr);
    return of(ptr).child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    of(ptr).note(.remap, new_len, ret_addr);
    return of(ptr).child.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    of(ptr).note(.free, memory.len, ret_addr);
    of(ptr).child.rawFree(memory, alignment, ret_addr);
}
