//! `alloc.Erased` from outside: a block freed erased passes in every build
//! when the bytes reach the allocator, one that is not is described, and a
//! free whose bytes `Allocator.free` hid is counted, never passed.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Erased = shakedown.alloc.Erased;

/// What code that erases its own secrets does: wipe, then hand the block
/// back as it is.
fn wipeAndFree(gpa: std.mem.Allocator, block: []u8) void {
    std.crypto.secureZero(u8, block);
    gpa.rawFree(block, .of(u8), @returnAddress());
}

test "blocks erased before a raw free pass, in every build" {
    var erased: Erased = .init(testing.allocator);
    const gpa = erased.allocator();
    for (0..4) |i| {
        var key = "a key 0".*;
        key[6] += @intCast(i);
        wipeAndFree(gpa, try gpa.dupe(u8, &key));
    }
    try erased.expectErased();
    try testing.expectEqual(@as(usize, 0), erased.unerased());
    try testing.expectEqual(@as(usize, 0), erased.unseen());
}

test "a block freed with a byte left is described, and one never written is told apart" {
    var erased: Erased = .init(testing.allocator);
    const gpa = erased.allocator();
    const block = try gpa.dupe(u8, "token!");
    std.crypto.secureZero(u8, block[0..4]);
    gpa.rawFree(block, .of(u8), @returnAddress());
    try testing.expectEqual(@as(usize, 1), erased.unerased());
    const hit = erased.firstHit().?;
    try testing.expectEqual(@as(usize, 4), hit.offset);
    try testing.expectEqual(@as(u8, 'n'), hit.byte);
    try testing.expectEqual(@as(usize, 6), hit.len);
    try testing.expect(hit.stack_len > 0);
    try testing.expectError(error.TestUnexpectedResult, erased.expectErased());

    var untouched: Erased = .init(testing.allocator);
    const other = untouched.allocator();
    // `Allocator.alloc` fills a block with `undefined` where runtime safety
    // is on; `rawAlloc` hands it over as the allocator made it.
    const never = (other.rawAlloc(8, .of(u8), @returnAddress()) orelse return error.OutOfMemory)[0..8];
    other.rawFree(never, .of(u8), @returnAddress());
    try testing.expectEqual(Erased.fresh, untouched.firstHit().?.byte);
}

test "a free through Allocator.free is unseen where runtime safety hides it" {
    var erased: Erased = .init(testing.allocator);
    const gpa = erased.allocator();
    const block = try gpa.dupe(u8, "secret");
    std.crypto.secureZero(u8, block);
    gpa.free(block);
    if (std.debug.runtime_safety) {
        try testing.expectEqual(@as(usize, 1), erased.unseen());
        try testing.expectError(error.SkipZigTest, erased.expectErased());
    } else try erased.expectErased();
}

test "a block that shrinks is freed whole and checked whole" {
    var erased: Erased = .init(testing.allocator);
    const gpa = erased.allocator();
    const block = try gpa.dupe(u8, "0123456789");
    try testing.expect(!gpa.resize(block, 4));
    try testing.expect(gpa.remap(block, 4) == null);
    gpa.rawFree(block, .of(u8), @returnAddress());
    try testing.expectEqual(@as(usize, 1), erased.unerased());
}
