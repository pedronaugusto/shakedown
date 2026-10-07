//! An allocator that counts what passes through it to a child allocator:
//! calls, failures, and the bytes live, at their peak and in total.
//!
//! The counts are plain fields, read directly; they are not atomic, so a
//! `Counting` serves one thread, or a child that is already serialised by
//! its caller.
const std = @import("std");
const Alignment = std.mem.Alignment;

const Counting = @This();

child: std.mem.Allocator,
/// Successful `alloc` calls.
allocations: u64 = 0,
frees: u64 = 0,
/// Successful in-place resizes.
resizes: u64 = 0,
/// Successful remaps, moved or not.
remaps: u64 = 0,
/// Calls the child refused: allocations, resizes and remaps.
failed: u64 = 0,
live_bytes: usize = 0,
peak_bytes: usize = 0,
/// Bytes handed out over the whole run, counting each growth once.
total_bytes: u64 = 0,

pub fn init(child: std.mem.Allocator) Counting {
    return .{ .child = child };
}

/// The counting allocator. `c` must not move while it is in use.
pub fn allocator(c: *Counting) std.mem.Allocator {
    return .{ .ptr = c, .vtable = &vtable };
}

/// Starts a new peak from what is live now.
pub fn resetPeak(c: *Counting) void {
    c.peak_bytes = c.live_bytes;
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn of(ptr: *anyopaque) *Counting {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with a *Counting
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const c = of(ptr);
    const memory = c.child.rawAlloc(len, alignment, ret_addr) orelse {
        c.failed += 1;
        return null;
    };
    c.allocations += 1;
    c.grow(0, len);
    return memory;
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const c = of(ptr);
    if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) {
        c.failed += 1;
        return false;
    }
    c.resizes += 1;
    c.grow(memory.len, new_len);
    return true;
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const c = of(ptr);
    const moved = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
        c.failed += 1;
        return null;
    };
    c.remaps += 1;
    c.grow(memory.len, new_len);
    return moved;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const c = of(ptr);
    c.child.rawFree(memory, alignment, ret_addr);
    c.frees += 1;
    c.live_bytes -= memory.len;
}

fn grow(c: *Counting, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) {
        c.live_bytes += new_len - old_len;
        c.total_bytes += new_len - old_len;
    } else {
        c.live_bytes -= old_len - new_len;
    }
    c.peak_bytes = @max(c.peak_bytes, c.live_bytes);
}

test "counts follow allocation, growth, shrinking and freeing" {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var counting: Counting = .init(fixed.allocator());
    const gpa = counting.allocator();
    var bytes = try gpa.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), counting.live_bytes);
    const other = try gpa.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 150), counting.peak_bytes);
    gpa.free(other);
    try std.testing.expectEqual(@as(usize, 100), counting.live_bytes);
    try std.testing.expectEqual(@as(usize, 150), counting.peak_bytes);
    counting.resetPeak();
    try std.testing.expectEqual(@as(usize, 100), counting.peak_bytes);

    bytes = try gpa.realloc(bytes, 400);
    try std.testing.expectEqual(@as(usize, 400), counting.live_bytes);
    try std.testing.expectEqual(@as(usize, 400), counting.peak_bytes);
    bytes = try gpa.realloc(bytes, 10);
    try std.testing.expectEqual(@as(usize, 10), counting.live_bytes);
    try std.testing.expectEqual(@as(usize, 400), counting.peak_bytes);
    gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 0), counting.live_bytes);
    try std.testing.expectEqual(@as(u64, 2), counting.allocations);
    try std.testing.expectEqual(@as(u64, 2), counting.frees);
    // 100 + 50 + 300 grown; shrinking adds nothing.
    try std.testing.expectEqual(@as(u64, 450), counting.total_bytes);
    // The fixed buffer grows and shrinks its last allocation in place.
    try std.testing.expectEqual(@as(u64, 2), counting.remaps);
    try std.testing.expectEqual(@as(u64, 0), counting.failed);
}

test "a refusal is counted and changes nothing else" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var counting: Counting = .init(failing.allocator());
    const gpa = counting.allocator();
    const first = try gpa.alloc(u8, 8);
    defer gpa.free(first);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 8));
    try std.testing.expectEqual(@as(u64, 1), counting.failed);
    try std.testing.expectEqual(@as(u64, 1), counting.allocations);
    try std.testing.expectEqual(@as(usize, 8), counting.live_bytes);
    try std.testing.expectEqual(@as(u64, 8), counting.total_bytes);
}
