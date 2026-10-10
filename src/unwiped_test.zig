//! `alloc.Unwiped` from outside: a block freed with a needle in it is
//! counted and described, a wiped one is not, and a build that hides the
//! bytes from the allocator says so instead of passing.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Unwiped = shakedown.alloc.Unwiped;

/// A free that reaches the allocator with the block as the program left it,
/// in every build: `Allocator.free` fills the block with `undefined` first
/// where runtime safety is on.
fn freeAsLeft(gpa: std.mem.Allocator, block: []u8) void {
    gpa.rawFree(block, .of(u8), @returnAddress());
}

test "a block freed with a needle in it is noticed, and a wiped one is not" {
    var unwiped: Unwiped = .init(testing.allocator, &.{"secret"});
    const gpa = unwiped.allocator();
    const wiped = try gpa.dupe(u8, "a secret");
    std.crypto.secureZero(u8, wiped);
    freeAsLeft(gpa, wiped);
    try testing.expectEqual(@as(usize, 0), unwiped.found());
    try testing.expectEqual(@as(?Unwiped.Hit, null), unwiped.firstHit());
    const left = try gpa.dupe(u8, "a secret");
    freeAsLeft(gpa, left);
    try testing.expectEqual(@as(usize, 1), unwiped.found());
    const hit = unwiped.firstHit().?;
    try testing.expectEqual(@as(usize, 0), hit.needle);
    try testing.expectEqual(@as(usize, 2), hit.offset);
    try testing.expectEqual(@as(usize, 8), hit.len);
    try testing.expect(hit.stack_len > 0);
}

test "each of several needles is found, and the first block is the one kept" {
    var unwiped: Unwiped = .init(testing.allocator, &.{ "alpha", "bravo", "charlie" });
    const gpa = unwiped.allocator();
    for ([_][]const u8{ "xx charlie", "bravo", "none of them" }) |text| {
        freeAsLeft(gpa, try gpa.dupe(u8, text));
    }
    try testing.expectEqual(@as(usize, 2), unwiped.found());
    const first = unwiped.firstHit().?;
    try testing.expectEqual(@as(usize, 2), first.needle);
    try testing.expectEqual(@as(usize, 3), first.offset);
}

test "a shrink or a growth moves the block, so the old contents are seen" {
    var unwiped: Unwiped = .init(testing.allocator, &.{"token"});
    const gpa = unwiped.allocator();
    var block = try gpa.alloc(u8, 16);
    @memset(block, 0);
    @memcpy(block[0..5], "token");
    try testing.expect(!gpa.resize(block, 8));
    try testing.expect(gpa.remap(block, 8) == null);
    // `Allocator.realloc` copies and frees, filling the old block first
    // where runtime safety is on.
    block = try gpa.realloc(block, 8);
    defer gpa.free(block);
    try testing.expectEqualStrings("token", block[0..5]);
    if (Unwiped.sees) try testing.expectEqual(@as(usize, 1), unwiped.found());
}

test "a free through Allocator.free is seen only where the allocator is shown the bytes" {
    var unwiped: Unwiped = .init(testing.allocator, &.{"password"});
    const gpa = unwiped.allocator();
    gpa.free(try gpa.dupe(u8, "the password"));
    if (Unwiped.sees) {
        try testing.expectEqual(@as(usize, 1), unwiped.found());
        try testing.expectError(error.TestUnexpectedResult, unwiped.expectNone());
    } else {
        try testing.expectEqual(@as(usize, 0), unwiped.found());
        try testing.expectError(error.SkipZigTest, unwiped.expectNone());
    }
}

test "expectNone passes for memory that was wiped before it was freed" {
    var unwiped: Unwiped = .init(testing.allocator, &.{"password"});
    const gpa = unwiped.allocator();
    const block = try gpa.dupe(u8, "the password");
    std.crypto.secureZero(u8, block);
    gpa.free(block);
    unwiped.expectNone() catch |err| switch (err) {
        error.SkipZigTest => try testing.expect(!Unwiped.sees),
        error.TestUnexpectedResult => return err,
    };
}

test "blocks freed on several threads are all counted" {
    var unwiped: Unwiped = .init(testing.allocator, &.{"needle"});
    const gpa = unwiped.allocator();
    const Worker = struct {
        fn run(a: std.mem.Allocator) void {
            for (0..200) |_| {
                const block = a.dupe(u8, "a needle") catch return;
                freeAsLeft(a, block);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{gpa});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 800), unwiped.found());
}

test "a free through rawFree is seen in every build, and an unseen one is counted" {
    var unwiped: Unwiped = .init(testing.allocator, &.{"password"});
    const gpa = unwiped.allocator();
    const wiped = try gpa.dupe(u8, "the password");
    std.crypto.secureZero(u8, wiped);
    freeAsLeft(gpa, wiped);
    try unwiped.expectNone();
    gpa.free(try gpa.dupe(u8, "the password"));
    try testing.expectEqual(@as(usize, if (Unwiped.sees) 0 else 1), unwiped.unseen());
}
