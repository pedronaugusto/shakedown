//! An allocator that checks every block is erased, every byte zero, by the
//! time it is freed: what a program that holds keys, tokens or passwords
//! promises of each of them.
//!
//! Every byte counts, those the program never wrote too: each block is
//! handed out filled with a nonzero pattern (`Allocator.alloc` fills it with
//! `undefined` instead where runtime safety is on), so a byte never written
//! is not taken for one erased. Resizes and remaps are
//! refused, so a block that shrinks or moves is freed whole and checked whole.
//!
//! It sees a block as the free hands it over. `Allocator.free` fills a block
//! with `undefined` first wherever runtime safety is on (Debug, ReleaseSafe),
//! so there a free through it shows nothing of what the program left; such a
//! block is counted as unseen, and `expectErased` skips rather than pass on
//! it. A free through `rawFree`, as code that erases its secrets itself makes
//! it, is seen in every build, and so is every free in ReleaseFast and
//! ReleaseSmall.
//!
//! Thread-safe.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Erased = @This();

/// What a fresh block holds until the program writes it.
pub const fresh: u8 = 0xd7;

/// Private: where the memory comes from and goes back to.
child: Allocator,
/// Private: blocks freed with a nonzero byte, and blocks freed unseen.
unerased_count: std.atomic.Value(usize) = .init(0),
unseen_count: std.atomic.Value(usize) = .init(0),
/// Private: the first block freed with a nonzero byte.
first: aegis.Guarded(?Hit) = .init(null),

/// A block freed before it was erased.
pub const Hit = struct {
    /// Where its first nonzero byte was, and what it held.
    offset: usize,
    byte: u8,
    /// The block's length.
    len: usize,
    /// The frames of the free, innermost first.
    stack: [16]usize = @splat(0),
    stack_len: u8 = 0,

    pub fn format(h: Hit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("byte 0x{x:0>2} at offset {d} of a {d}-byte block", .{ h.byte, h.offset, h.len });
        if (h.byte == fresh) try w.writeAll(", as it was handed out: never written");
        try w.writeByte('\n');
        if (h.stack_len == 0) return;
        var copy = h.stack;
        try w.print("freed at:\n{f}", .{std.debug.FormatStackTrace{ .stack_trace = .{ .return_addresses = copy[0..h.stack_len], .skipped = .unknown } }});
    }
};

pub fn init(child: Allocator) Erased {
    return .{ .child = child };
}

/// The allocator. `e` must not move while it is in use.
pub fn allocator(e: *Erased) Allocator {
    return .{ .ptr = e, .vtable = &vtable };
}

/// Blocks freed with a byte that is not zero.
pub fn unerased(e: *const Erased) usize {
    return e.unerased_count.load(.acquire);
}

/// Blocks `Allocator.free` overwrote before this allocator could look.
pub fn unseen(e: *const Erased) usize {
    return e.unseen_count.load(.acquire);
}

/// The first block freed before it was erased.
pub fn firstHit(e: *Erased) ?Hit {
    var held = e.first.acquire();
    defer held.deinit();
    return held.value().*;
}

pub const ExpectError = error{ SkipZigTest, TestUnexpectedResult };

/// Fails when a block was freed before it was erased; skips when a block
/// went unseen, since a pass would then prove nothing of it; passes
/// otherwise, in every build.
pub fn expectErased(e: *Erased) ExpectError!void {
    const n = e.unerased();
    if (n > 0) {
        const hit = e.firstHit().?; // a count above zero is published after the first hit
        say("{d} block(s) freed before they were erased; the first held {f}", .{ n, hit });
        return error.TestUnexpectedResult;
    }
    if (e.unseen() > 0) return error.SkipZigTest;
}

/// Whether a block in hand is what `Allocator.free` leaves where runtime
/// safety is on: every byte `undefined`'s fill.
pub fn overwritten(block: []const u8) bool {
    if (!std.debug.runtime_safety or block.len == 0) return false;
    for (block) |b| if (b != 0xaa) return false;
    return true;
}

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

fn of(ptr: *anyopaque) *Erased {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with an *Erased
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const memory = of(ptr).child.rawAlloc(len, alignment, ret_addr) orelse return null;
    @memset(memory[0..len], fresh);
    return memory;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const e = of(ptr);
    if (overwritten(memory)) {
        _ = e.unseen_count.fetchAdd(1, .release);
    } else if (std.mem.findNone(u8, memory, &.{0})) |offset| {
        var hit: Hit = .{ .offset = offset, .byte = memory[offset], .len = memory.len };
        const trace = std.debug.captureCurrentStackTrace(.{ .first_address = ret_addr }, &hit.stack);
        hit.stack_len = @intCast(trace.return_addresses.len); // safe: at most the 16 frames of `stack`
        {
            var held = e.first.acquire();
            defer held.deinit();
            if (held.value().* == null) held.value().* = hit;
        }
        // After the hit is kept, so a reader that sees the count finds it.
        _ = e.unerased_count.fetchAdd(1, .release);
    }
    e.child.rawFree(memory, alignment, ret_addr);
}
