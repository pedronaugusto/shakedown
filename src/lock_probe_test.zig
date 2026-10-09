//! `alloc.LockProbe` from outside: calls made with the lock held are
//! counted and the first is kept, whatever kind of lock it is, and every
//! call still reaches the child.
const std = @import("std");
const testing = std.testing;
const aegis = @import("aegis");
const shakedown = @import("shakedown.zig");
const LockProbe = shakedown.alloc.LockProbe;

test "calls with the flag set are counted, the rest only pass through" {
    var flag: std.atomic.Value(bool) = .init(false);
    var probe: LockProbe = .init(testing.allocator, .flag(&flag));
    const gpa = probe.allocator();
    const free_block = try gpa.alloc(u8, 16);
    gpa.free(free_block);
    try testing.expectEqual(@as(usize, 2), probe.calls());
    try testing.expectEqual(@as(usize, 0), probe.underLock());
    try probe.expectNone();
    flag.store(true, .release);
    const held_block = try gpa.alloc(u8, 24);
    flag.store(false, .release);
    gpa.free(held_block);
    try testing.expectEqual(@as(usize, 4), probe.calls());
    try testing.expectEqual(@as(usize, 1), probe.underLock());
    const first = probe.firstOffender().?;
    try testing.expectEqual(LockProbe.Call.alloc, first.call);
    try testing.expectEqual(@as(usize, 24), first.len);
    try testing.expect(first.stack_len > 0);
    try testing.expectError(error.TestUnexpectedResult, probe.expectNone());
}

test "the first offender is kept, whatever the call" {
    var flag: std.atomic.Value(bool) = .init(true);
    var probe: LockProbe = .init(testing.allocator, .flag(&flag));
    const gpa = probe.allocator();
    var block = try gpa.alloc(u8, 8);
    block = try gpa.realloc(block, 4096);
    gpa.free(block);
    try testing.expect(probe.underLock() >= 2);
    try testing.expectEqual(LockProbe.Call.alloc, probe.firstOffender().?.call);
    try testing.expectEqual(probe.calls(), probe.underLock());
}

test "a probe that saw no call fails: the code never reached it" {
    var flag: std.atomic.Value(bool) = .init(false);
    var probe: LockProbe = .init(testing.allocator, .flag(&flag));
    try testing.expectError(error.TestUnexpectedResult, probe.expectNone());
}

test "an Io.Mutex is held between lock and unlock" {
    var mutex: std.Io.Mutex = .init;
    var probe: LockProbe = .init(testing.allocator, .mutex(&mutex));
    const gpa = probe.allocator();
    gpa.free(try gpa.alloc(u8, 1));
    try testing.expectEqual(@as(usize, 0), probe.underLock());
    try mutex.lock(testing.io);
    gpa.free(try gpa.alloc(u8, 1));
    mutex.unlock(testing.io);
    gpa.free(try gpa.alloc(u8, 1));
    try testing.expectEqual(@as(usize, 2), probe.underLock());
    try testing.expectEqual(@as(usize, 6), probe.calls());
}

test "a std.atomic.Mutex is held between tryLock and unlock" {
    var mutex: std.atomic.Mutex = .unlocked;
    var probe: LockProbe = .init(testing.allocator, .spinMutex(&mutex));
    const gpa = probe.allocator();
    try testing.expect(mutex.tryLock());
    gpa.free(try gpa.alloc(u8, 1));
    mutex.unlock();
    gpa.free(try gpa.alloc(u8, 1));
    try testing.expectEqual(@as(usize, 2), probe.underLock());
}

test "the lock of an aegis.Guarded is the flag" {
    var guarded: aegis.Guarded(u32) = .init(0);
    var probe: LockProbe = .init(testing.allocator, .flag(&guarded.lock));
    const gpa = probe.allocator();
    {
        var held = guarded.acquire();
        defer held.deinit();
        held.value().* += 1;
        gpa.free(try gpa.alloc(u8, 1));
    }
    gpa.free(try gpa.alloc(u8, 1));
    try testing.expectEqual(@as(usize, 2), probe.underLock());
    try testing.expectEqual(@as(usize, 4), probe.calls());
}

test "data written through the probe is the child's" {
    var flag: std.atomic.Value(bool) = .init(false);
    var probe: LockProbe = .init(testing.allocator, .flag(&flag));
    const gpa = probe.allocator();
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    for (0..1000) |i| try list.append(gpa, @intCast(i));
    for (list.items, 0..) |value, i| try testing.expectEqual(@as(u32, @intCast(i)), value);
    try testing.expect(probe.calls() > 0);
}

test "calls from several threads are counted while the main thread holds the flag" {
    var flag: std.atomic.Value(bool) = .init(true);
    var probe: LockProbe = .init(testing.allocator, .flag(&flag));
    const gpa = probe.allocator();
    const Worker = struct {
        fn run(a: std.mem.Allocator) void {
            for (0..100) |_| a.free(a.alloc(u8, 8) catch return);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{gpa});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 800), probe.calls());
    try testing.expectEqual(@as(usize, 800), probe.underLock());
}
