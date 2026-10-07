//! `alloc.Quarantine` from outside: freed memory is closed and its
//! addresses are never handed out again.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Quarantine = @import("shakedown.zig").alloc.Quarantine;

/// Whether the byte at `address` can be read, asked of the kernel so that
/// asking never faults: on POSIX a write from it into a pipe fails with
/// EFAULT, on Windows `VirtualQuery` names its state and protection.
fn readable(address: usize) !bool {
    if (builtin.os.tag == .windows) return windowsReadable(address);
    const fds = try std.Io.Threaded.pipe2(.{});
    defer for (fds) |fd| {
        _ = std.posix.system.close(fd);
    };
    // safe: the kernel checks the address; it is never dereferenced here
    const from: [*]const u8 = @ptrFromInt(address);
    return switch (std.posix.errno(std.posix.system.write(fds[1], from, 1))) {
        .SUCCESS => true,
        .FAULT => false,
        else => |e| std.posix.unexpectedErrno(e),
    };
}

const MemoryBasicInformation = extern struct {
    base_address: ?*anyopaque,
    allocation_base: ?*anyopaque,
    allocation_protect: u32,
    partition_id: u16,
    region_size: usize,
    state: u32,
    protect: u32,
    type: u32,
};
extern "kernel32" fn VirtualQuery(address: ?*const anyopaque, info: *MemoryBasicInformation, length: usize) callconv(.winapi) usize;

fn windowsReadable(address: usize) !bool {
    var info: MemoryBasicInformation = undefined;
    // safe: the kernel looks the address up; it is never dereferenced here
    const at: ?*const anyopaque = @ptrFromInt(address);
    if (VirtualQuery(at, &info, @sizeOf(MemoryBasicInformation)) == 0) return error.Unexpected;
    const mem_commit = 0x1000;
    const page_noaccess = 0x01;
    const page_guard = 0x100;
    return info.state == mem_commit and info.protect & (page_noaccess | page_guard) == 0;
}

test "freed memory is closed, and live memory is not" {
    if (!Quarantine.supported) return error.SkipZigTest;
    var q: Quarantine = .init(.{});
    defer q.deinit();
    const gpa = q.allocator();
    const kept = try gpa.alloc(u8, 3 * std.heap.pageSize());
    defer gpa.free(kept);
    const gone = try gpa.alloc(u8, 100);
    @memset(gone, 0xaa);
    const at = @intFromPtr(gone.ptr);
    try testing.expect(try readable(at));
    gpa.free(gone);
    try testing.expect(!try readable(at));
    try testing.expect(!try readable(at + 99));
    try testing.expect(try readable(@intFromPtr(kept.ptr) + kept.len - 1));
}

test "no address is handed out twice" {
    if (!Quarantine.supported) return error.SkipZigTest;
    var q: Quarantine = .init(.{});
    defer q.deinit();
    const gpa = q.allocator();
    var freed: std.ArrayList([2]usize) = .empty;
    defer freed.deinit(testing.allocator);
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (0..300) |_| {
        const len = random.intRangeAtMost(usize, 1, 3 * std.heap.pageSize());
        const block = try gpa.alloc(u8, len);
        const from = @intFromPtr(block.ptr);
        for (freed.items) |range| try testing.expect(from + len <= range[0] or from >= range[1]);
        @memset(block, 1);
        try freed.append(testing.allocator, .{ from, from + len });
        gpa.free(block);
    }
}

test "a guarded block ends at an inaccessible page" {
    if (!Quarantine.supported) return error.SkipZigTest;
    var q: Quarantine = .init(.{ .guard = .after });
    defer q.deinit();
    const gpa = q.allocator();
    for ([_]usize{ 1, 24, std.heap.pageSize(), std.heap.pageSize() + 8 }) |len| {
        const block = try gpa.alignedAlloc(u8, .@"8", len);
        defer gpa.free(block);
        const end = @intFromPtr(block.ptr) + block.len;
        // The block ends within its alignment of the guard page.
        const guard = std.mem.alignForward(usize, end, std.heap.pageSize());
        try testing.expect(guard - end < 8);
        block[block.len - 1] = 7;
        try testing.expect(try readable(end - 1));
        try testing.expect(!try readable(guard));
    }
}

test "a resize keeps its length or is refused, so a growth moves" {
    var q: Quarantine = .init(.{});
    defer q.deinit();
    const gpa = q.allocator();
    var block = try gpa.alloc(u8, 64);
    try testing.expect(gpa.resize(block, 64));
    try testing.expect(!gpa.resize(block, 65));
    try testing.expect(!gpa.resize(block, 32));
    const before = block.ptr;
    @memset(block, 3);
    block = try gpa.realloc(block, 4096 * 4);
    defer gpa.free(block);
    try testing.expect(block.ptr != before);
    try testing.expect(std.mem.allEqual(u8, block[0..64], 3));
    if (Quarantine.supported) try testing.expect(!try readable(@intFromPtr(before)));
}

test "reuse_after gives the oldest freed ranges back past its limit" {
    if (!Quarantine.supported) return error.SkipZigTest;
    const page = std.heap.pageSize();
    var q: Quarantine = .init(.{ .reuse_after = 2 * page });
    defer q.deinit();
    const gpa = q.allocator();
    var blocks: [4][]u8 = undefined;
    for (&blocks) |*b| b.* = try gpa.alloc(u8, page);
    for (blocks) |b| gpa.free(b);
    // Two pages stay quarantined, the two oldest went back.
    try testing.expectEqual(@as(usize, 2 * page), q.quarantined);
    try testing.expectEqual(@as(u32, 2), q.mappings.count());
    try testing.expect(q.mappings.contains(@intFromPtr(blocks[2].ptr)));
    try testing.expect(q.mappings.contains(@intFromPtr(blocks[3].ptr)));
}

test "a safe allocator over a quarantine finds no leak and reuses nothing" {
    var q: Quarantine = .init(.{});
    defer q.deinit();
    var safe: std.heap.SafeAllocator = .init(q.allocator(), .{});
    const gpa = safe.allocator();
    var list: std.ArrayList(u64) = .empty;
    for (0..10_000) |i| try list.append(gpa, i);
    var map: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    for (list.items) |i| try map.put(gpa, i, i * i);
    try testing.expectEqual(@as(u64, 81), map.get(9).?);
    map.deinit(gpa);
    list.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), safe.deinit());
}
