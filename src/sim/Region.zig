//! The simulation's allocator: the same allocations and frees, in the same
//! order, give the same addresses in every run.
//!
//! It hands out memory from one region of address space reserved at a
//! fixed address where the system allows it, so code that keys a hash map
//! by pointer, or prints a pointer, behaves the same in two runs of one
//! seed. Blocks up to 64 KiB come in power-of-two classes, each with a
//! free list, reused last-in first-out; larger blocks are page runs that
//! are never reused, their pages given back on free. Memory is committed a
//! megabyte at a time as the region fills.
//!
//! Not thread-safe: a simulation runs one task at a time.
const builtin = @import("builtin");
const std = @import("std");
const Alignment = std.mem.Alignment;
const windows = std.os.windows;

const Region = @This();

/// Private: the reservation.
base: usize,
len: usize,
/// Private: whether the region landed at the fixed address.
fixed: bool,
/// Private: bytes from `base` handed out so far, and committed so far.
used: usize = 0,
committed: usize = 0,
/// Private: freed blocks of each class.
free_lists: [classes]?*Free = @splat(null),

const Free = struct { next: ?*Free };

const min_shift = 4;
const max_shift = 16;
const classes = max_shift - min_shift + 1;
const commit_step = 1 << 20;

/// Where the region is asked for: high in the address space of 64-bit
/// systems, far from heaps and from where the system places mappings.
const hint: usize = if (@sizeOf(usize) == 8) 0x2000_0000_0000 else 0;

/// Address space reserved: only what is touched is ever committed.
const reserve: usize = if (@sizeOf(usize) == 8) 64 << 30 else 256 << 20;

pub const supported = builtin.os.tag == .windows or switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => true,
    .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .haiku => true,
    else => false,
};

pub const InitError = error{ OutOfMemory, Unsupported };

pub fn init() InitError!Region {
    if (!supported) return error.Unsupported;
    if (reserveAt(hint)) |base| return .{ .base = base, .len = reserve, .fixed = base == hint };
    const base = reserveAt(0) orelse return error.OutOfMemory;
    return .{ .base = base, .len = reserve, .fixed = false };
}

pub fn deinit(r: *Region) void {
    release(r.base, r.len);
    r.* = undefined;
}

/// Whether the region is at the fixed address, so its addresses repeat
/// across runs. It is not when the address was taken, by another
/// simulation alive at the same time, say.
pub fn atFixedAddress(r: *const Region) bool {
    return r.fixed;
}

pub fn allocator(r: *Region) std.mem.Allocator {
    return .{ .ptr = r, .vtable = &vtable };
}

const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

fn of(ptr: *anyopaque) *Region {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with a *Region
}

/// The class of a block: its size rounded up to a power of two, at least
/// its alignment; null for a large block.
fn classOf(len: usize, alignment: Alignment) ?u5 {
    const size = @max(len, alignment.toByteUnits(), @as(usize, 1) << min_shift);
    if (size > @as(usize, 1) << max_shift) return null;
    const shift = std.math.log2_int_ceil(usize, size);
    return @intCast(shift - min_shift);
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const r = of(ptr);
    if (classOf(len, alignment)) |class| {
        if (r.free_lists[class]) |block| {
            r.free_lists[class] = block.next;
            return @ptrCast(block); // safe: a freed block of this class, handed out again
        }
        const size = @as(usize, 1) << @intCast(@as(u6, class) + min_shift);
        return r.bump(size, .fromByteUnits(size));
    }
    const page = std.heap.pageSize();
    const size = std.mem.alignForward(usize, len, page);
    return r.bump(size, alignment.max(.fromByteUnits(page)));
}

fn bump(r: *Region, size: usize, alignment: Alignment) ?[*]u8 {
    const start = alignment.forward(r.base + r.used) - r.base;
    const end = std.math.add(usize, start, size) catch return null;
    if (end > r.len) return null;
    if (end > r.committed) {
        const target = @min(std.mem.alignForward(usize, end, commit_step), r.len);
        if (!commit(r.base + r.committed, target - r.committed)) return null;
        r.committed = target;
    }
    r.used = end;
    return @ptrFromInt(r.base + start);
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const old = classOf(memory.len, alignment);
    const new = classOf(new_len, alignment);
    if (old) |class| return new != null and new.? == class;
    if (new != null) return false;
    // A large block shrinks in place; it cannot grow.
    const page = std.heap.pageSize();
    return std.mem.alignForward(usize, new_len, page) <= std.mem.alignForward(usize, memory.len, page);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ptr, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const r = of(ptr);
    if (classOf(memory.len, alignment)) |class| {
        if (std.debug.runtime_safety) @memset(memory, undefined);
        const block: *Free = @ptrCast(@alignCast(memory.ptr)); // safe: every class is at least 16 bytes, aligned to its size
        block.next = r.free_lists[class];
        r.free_lists[class] = block;
        return;
    }
    const page = std.heap.pageSize();
    decommit(@intFromPtr(memory.ptr), std.mem.alignForward(usize, memory.len, page)); // safe: a large block is a page run of the region
}

// The system.

fn reserveAt(at: usize) ?usize {
    if (builtin.os.tag == .windows) {
        var address: ?windows.PVOID = if (at == 0) null else @ptrFromInt(at);
        var size: windows.SIZE_T = reserve;
        const status = windows.ntdll.NtAllocateVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&address), 0, &size, .{ .RESERVE = true }, .{ .NOACCESS = true }); // safe: the binding takes the base address as `*?*anyopaque`
        if (status != .SUCCESS) return null;
        return @intFromPtr(address.?); // safe: the reserved base, kept as a number for offsets
    }
    const flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = @hasField(std.posix.MAP, "NORESERVE") };
    const mapped = std.posix.mmap(if (at == 0) null else @ptrFromInt(at), reserve, .{}, flags, -1, 0) catch return null;
    return @intFromPtr(mapped.ptr); // safe: the reserved base, kept as a number for offsets
}

fn commit(at: usize, len: usize) bool {
    if (builtin.os.tag == .windows) {
        var address: ?windows.PVOID = @ptrFromInt(at);
        var size: windows.SIZE_T = len;
        return windows.ntdll.NtAllocateVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&address), 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true }) == .SUCCESS; // safe: the binding takes the base address as `*?*anyopaque`
    }
    const start: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(at); // safe: commits start at the region's base or a commit step past it, page-aligned
    return std.posix.errno(std.posix.system.mprotect(start, len, .{ .READ = true, .WRITE = true })) == .SUCCESS;
}

/// Gives the pages of a freed large block back; the addresses stay the
/// region's, never handed out again.
fn decommit(at: usize, len: usize) void {
    if (builtin.os.tag == .windows) {
        var address: ?windows.PVOID = @ptrFromInt(at);
        var size: windows.SIZE_T = len;
        _ = windows.ntdll.NtFreeVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&address), &size, .{ .DECOMMIT = true }); // safe: the binding takes the base address as `*?*anyopaque`
        return;
    }
    const start: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(at); // safe: a large block starts on a page
    const advice = if (builtin.target.os.tag.isDarwin()) std.posix.MADV.FREE_REUSABLE else std.posix.MADV.DONTNEED;
    // ziglint-ignore: Z026 pages not given back stay resident until the region goes
    std.posix.madvise(start, len, advice) catch {};
}

fn release(at: usize, len: usize) void {
    if (builtin.os.tag == .windows) {
        var address: ?windows.PVOID = @ptrFromInt(at);
        var size: windows.SIZE_T = 0;
        _ = windows.ntdll.NtFreeVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&address), &size, .{ .RELEASE = true }); // safe: the binding takes the base address as `*?*anyopaque`
        return;
    }
    const start: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(at); // safe: the region's base, page-aligned
    std.posix.munmap(start[0..len]);
}

test "the same allocations give the same addresses in a fresh region" {
    var firsts: [2][8]usize = undefined;
    for (&firsts) |*run| {
        var r: Region = try .init();
        defer r.deinit();
        const gpa = r.allocator();
        var blocks: [8][]u8 = undefined;
        for (&blocks, 0..) |*b, i| b.* = try gpa.alloc(u8, 10 + i * 4000);
        gpa.free(blocks[3]);
        const again = try gpa.alloc(u8, 10 + 3 * 4000);
        try std.testing.expectEqual(blocks[3].ptr, again.ptr);
        for (run, blocks) |*a, b| a.* = @intFromPtr(b.ptr);
        try std.testing.expect(r.atFixedAddress());
    }
    try std.testing.expectEqualSlices(usize, &firsts[0], &firsts[1]);
}

test "classes, alignment, resizes and large blocks" {
    var r: Region = try .init();
    defer r.deinit();
    const gpa = r.allocator();
    const aligned = try gpa.alignedAlloc(u8, .@"64", 3);
    defer gpa.free(aligned);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));
    var small = try gpa.alloc(u8, 20);
    try std.testing.expect(gpa.resize(small, 32));
    try std.testing.expect(!gpa.resize(small, 33));
    small = small.ptr[0..32];
    gpa.free(small);
    const large = try gpa.alloc(u8, 1 << 20);
    @memset(large, 7);
    try std.testing.expect(gpa.resize(large, 1000 * 1000));
    try std.testing.expect(!gpa.resize(large, 2 << 20));
    gpa.free(large);
    const next = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(next);
    try std.testing.expect(next.ptr != large.ptr);
}
