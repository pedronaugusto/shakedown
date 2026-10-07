//! `alloc.NoResize` from outside: growth moves, and the allocation count a
//! failure check depends on repeats run to run.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const NoResize = shakedown.alloc.NoResize;

test "a block grows by moving, every time" {
    var no_resize: NoResize = .init(testing.allocator);
    const gpa = no_resize.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendNTimes(gpa, 'x', 16);
    try testing.expect(!gpa.resize(list.allocatedSlice(), 64));
    try testing.expect(gpa.remap(list.allocatedSlice(), 64) == null);
    try list.appendNTimes(gpa, 'y', 64);
    try testing.expectEqual(80, list.items.len);
}

test "every growth is one allocation, the same in every run" {
    var counts: [3]u64 = undefined;
    for (&counts) |*count| {
        var counting: shakedown.alloc.Counting = .init(testing.allocator);
        var no_resize: NoResize = .init(counting.allocator());
        try grow(no_resize.allocator());
        count.* = counting.allocations;
        try testing.expectEqual(@as(u64, 0), counting.resizes + counting.remaps);
    }
    try testing.expectEqual(counts[0], counts[1]);
    try testing.expectEqual(counts[0], counts[2]);
    // And the check that depends on it passes.
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), grow, .{});
}

fn grow(gpa: std.mem.Allocator) !void {
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(gpa);
    for (0..4096) |i| try list.append(gpa, i);
}
