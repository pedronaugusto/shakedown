//! An allocator that refuses every resize and remap, so each growth is a
//! fresh allocation and a copy.
//!
//! `std.testing.checkAllAllocationFailures` counts a first run's
//! allocations, then fails each in turn. Whether a growth is a resize in
//! place or one more allocation depends on where the child's free space
//! lies, which `std.testing.allocator` does not keep the same from run to
//! run; the count then moves between runs. Over `NoResize` every growth is
//! an allocation in every run. Frees and the child's leak check pass
//! through unchanged.
const std = @import("std");
const Alignment = std.mem.Alignment;

const NoResize = @This();

child: std.mem.Allocator,

pub fn init(child: std.mem.Allocator) NoResize {
    return .{ .child = child };
}

/// The allocator. `n` must not move while it is in use.
pub fn allocator(n: *NoResize) std.mem.Allocator {
    return .{ .ptr = n, .vtable = &vtable };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = free,
};

fn of(ptr: *anyopaque) *NoResize {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with a *NoResize
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    return of(ptr).child.rawAlloc(len, alignment, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    of(ptr).child.rawFree(memory, alignment, ret_addr);
}
