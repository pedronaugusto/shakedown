//! An allocator that notes when memory still holding some bytes is freed:
//! a key, a token or a password a program left behind for the next
//! allocation to find.
//!
//! Give it the bytes that must not outlive their owner. Every free scans the
//! block for them before the block goes back to the child, and counts the
//! blocks that held one. Resizes and remaps are refused, so a block that
//! shrinks or moves is freed with the contents it had, and the part a
//! shrink would have dropped is seen too.
//!
//! It sees a free only as the allocator receives it, and `Allocator.free`
//! fills a block with `undefined` first wherever runtime safety is on
//! (Debug and ReleaseSafe): there the bytes never reach this allocator,
//! whatever the program did. `sees` says which builds can tell, and
//! `expectNone` skips the test in the others rather than pass it. Run such
//! tests in ReleaseFast or ReleaseSmall.
//!
//! Thread-safe.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Unwiped = @This();

/// Whether a free shows this allocator what the block held: not where
/// `Allocator.free` overwrites it first.
pub const sees = !std.debug.runtime_safety;

/// Private: where the memory comes from and goes back to.
child: Allocator,
/// The bytes that must not be found in freed memory. Borrowed, and not empty
/// each: an empty needle is in every block.
needles: []const []const u8,
/// Private: blocks freed with a needle in them.
count: std.atomic.Value(usize) = .init(0),
/// Private: the first of those.
first: aegis.Guarded(?Hit) = .init(null),

/// A block freed with a needle in it.
pub const Hit = struct {
    /// Which of the needles, by position.
    needle: usize,
    /// Where in the block it was found.
    offset: usize,
    /// The block's length.
    len: usize,
    /// The frames of the free, innermost first.
    stack: [16]usize = @splat(0),
    stack_len: u8 = 0,

    /// The hit as a line and the frames of the free.
    pub fn format(h: Hit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("needle {d} at offset {d} of a {d}-byte block\n", .{ h.needle, h.offset, h.len });
        if (h.stack_len == 0) return;
        var copy = h.stack;
        try w.print("freed at:\n{f}", .{std.debug.FormatStackTrace{ .stack_trace = .{ .return_addresses = copy[0..h.stack_len], .skipped = .unknown } }});
    }
};

pub fn init(child: Allocator, needles: []const []const u8) Unwiped {
    for (needles) |needle| aegis.assert.pre(needle.len > 0, "an Unwiped needle is not empty");
    return .{ .child = child, .needles = needles };
}

/// The allocator. `u` must not move while it is in use.
pub fn allocator(u: *Unwiped) Allocator {
    return .{ .ptr = u, .vtable = &vtable };
}

/// How many blocks were freed with a needle in them.
pub fn found(u: *const Unwiped) usize {
    return u.count.load(.acquire);
}

/// The first block freed with a needle in it.
pub fn firstHit(u: *Unwiped) ?Hit {
    var held = u.first.acquire();
    defer held.deinit();
    return held.value().*;
}

/// What `expectNone` reports besides a pass.
pub const ExpectError = error{ SkipZigTest, TestUnexpectedResult };

/// Passes when no freed block held a needle. Where `sees` is false it skips
/// the test instead, since a pass there would prove nothing.
pub fn expectNone(u: *Unwiped) ExpectError!void {
    if (!sees) return error.SkipZigTest;
    const n = u.found();
    if (n == 0) return;
    const hit = u.firstHit().?; // a count above zero is published after the first hit
    say("{d} block(s) freed with unwiped contents; the first held {f}", .{ n, hit });
    return error.TestUnexpectedResult;
}

/// The failure goes to stderr as `std.testing` puts its own there.
fn say(comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // glint-ignore: Z026 -- a message stderr cannot take is lost
    stderr.writer.print(fmt, args) catch {};
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = Allocator.noResize,
    .remap = Allocator.noRemap,
    .free = free,
};

fn of(ptr: *anyopaque) *Unwiped {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with an *Unwiped
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    return of(ptr).child.rawAlloc(len, alignment, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const u = of(ptr);
    for (u.needles, 0..) |needle, which| {
        const offset = std.mem.find(u8, memory, needle) orelse continue;
        u.note(.{ .needle = which, .offset = offset, .len = memory.len }, ret_addr);
        break;
    }
    u.child.rawFree(memory, alignment, ret_addr);
}

fn note(u: *Unwiped, found_hit: Hit, ret_addr: usize) void {
    var hit = found_hit;
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = ret_addr }, &hit.stack);
    hit.stack_len = @intCast(trace.return_addresses.len); // safe: at most the 16 frames of `stack`
    {
        var held = u.first.acquire();
        defer held.deinit();
        if (held.value().* == null) held.value().* = hit;
    }
    // After the hit is kept, so a reader that sees the count finds it.
    _ = u.count.fetchAdd(1, .release);
}
