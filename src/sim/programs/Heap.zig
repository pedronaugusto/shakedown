//! A simulated process's general purpose allocator (`std.process.Init.gpa`):
//! it remembers every block it hands out, so what the process leaves behind
//! is given back when the process ends, as an operating system takes back a
//! dead process's memory. A program killed mid-way then leaks nothing into
//! the test's own allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Heap = @This();

const Block = struct { len: usize, alignment: std.mem.Alignment };

child: Allocator,
live: std.AutoHashMapUnmanaged(usize, Block) = .empty,

pub fn init(child: Allocator) Heap {
    return .{ .child = child };
}

/// Gives back every block still live.
pub fn deinit(h: *Heap) void {
    var it = h.live.iterator();
    while (it.next()) |entry| {
        const block = entry.value_ptr.*;
        const memory: [*]u8 = @ptrFromInt(entry.key_ptr.*); // safe: the key is the address this heap handed out
        h.child.rawFree(memory[0..block.len], block.alignment, @returnAddress());
    }
    h.live.deinit(h.child);
    h.* = undefined;
}

/// Blocks still live.
pub fn count(h: *const Heap) usize {
    return h.live.count();
}

pub fn allocator(h: *Heap) Allocator {
    return .{ .ptr = h, .vtable = &vtable };
}

const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

fn of(context: *anyopaque) *Heap {
    return @ptrCast(@alignCast(context)); // safe: every allocator of this vtable is made by `allocator` over a Heap
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
    const h = of(context);
    h.live.ensureUnusedCapacity(h.child, 1) catch return null;
    const memory = h.child.rawAlloc(len, alignment, ret) orelse return null;
    h.live.putAssumeCapacity(@intFromPtr(memory), .{ .len = len, .alignment = alignment }); // safe: the address only keys the block
    return memory;
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
    const h = of(context);
    if (!h.child.rawResize(memory, alignment, new_len, ret)) return false;
    h.live.getPtr(@intFromPtr(memory.ptr)).?.len = new_len; // safe: the address only keys the block
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
    const h = of(context);
    h.live.ensureUnusedCapacity(h.child, 1) catch return null;
    const moved = h.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
    _ = h.live.remove(@intFromPtr(memory.ptr)); // safe: the address only keys the block
    h.live.putAssumeCapacity(@intFromPtr(moved), .{ .len = new_len, .alignment = alignment }); // safe: the address only keys the block
    return moved;
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
    const h = of(context);
    _ = h.live.remove(@intFromPtr(memory.ptr)); // safe: the address only keys the block
    h.child.rawFree(memory, alignment, ret);
}

test "what a process leaves behind is given back when it ends" {
    var h: Heap = .init(std.testing.allocator);
    const gpa = h.allocator();
    const kept = try gpa.alloc(u8, 100);
    const freed = try gpa.alloc(u32, 10);
    gpa.free(freed);
    const grown = try gpa.realloc(kept, 5000);
    _ = try gpa.create(u64);
    try std.testing.expectEqual(@as(usize, 2), h.count());
    _ = grown;
    h.deinit();
}
