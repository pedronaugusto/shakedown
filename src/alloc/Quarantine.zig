//! An allocator that never hands out an address twice, so a use after
//! free faults at once instead of landing in whatever was allocated next.
//!
//! Every allocation is a mapping of its own. A free gives the pages back to
//! the system and leaves their addresses reserved with no access: on POSIX,
//! `madvise` then `mprotect(PROT_NONE)`; on Windows, a decommit that keeps
//! the reservation. With `guard = .after` an inaccessible page follows each
//! block, which ends at that page, so an overflow by one byte faults too.
//!
//! Only address space is spent, never resident memory, and each call is a
//! system call: this is for soak runs and test suites, not for timing.
//! Resizes are refused unless the length stays the same, so a grown block
//! is a new one and the old one is quarantined. Elsewhere than POSIX and
//! Windows the blocks come from `std.heap.page_allocator` and nothing is
//! quarantined.
//!
//! Thread-safe.
const builtin = @import("builtin");
const std = @import("std");
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const windows = std.os.windows;

const Quarantine = @This();

/// Private: what the quarantine was asked for.
options: Options,
/// Private: guards `mappings`, `freed` and `quarantined`.
mutex: std.atomic.Mutex = .unlocked,
/// Private: every reservation still held, by base address, with its length.
mappings: std.AutoHashMapUnmanaged(usize, usize) = .empty,
/// Private: freed reservations, oldest first, from `freed_head` on.
freed: std.ArrayList(Range) = .empty,
freed_head: usize = 0,
/// Private: bytes reserved by freed blocks.
quarantined: usize = 0,

pub const Options = struct {
    /// `.after`: each block ends at a page end and the page after it is
    /// inaccessible, so a one-byte overflow faults.
    guard: Guard = .none,
    /// Address space freed blocks may hold before the oldest are given back
    /// to the system, which may then hand them out again. Null keeps every
    /// address forever, which a 64-bit address space affords.
    reuse_after: ?usize = null,

    pub const Guard = enum { none, after };
};

const Range = struct { base: usize, len: usize };

/// Whether this target quarantines; elsewhere blocks are plain pages.
pub const supported = builtin.os.tag == .windows or have_mprotect;
const have_mprotect = switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => true,
    .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .haiku => true,
    else => false,
};

pub fn init(options: Options) Quarantine {
    return .{ .options = options };
}

/// The allocator. `q` must not move while it is in use.
pub fn allocator(q: *Quarantine) std.mem.Allocator {
    return .{ .ptr = q, .vtable = &vtable };
}

/// Gives back every reservation, freed or not.
pub fn deinit(q: *Quarantine) void {
    var it = q.mappings.iterator();
    while (it.next()) |entry| release(.{ .base = entry.key_ptr.*, .len = entry.value_ptr.* });
    q.mappings.deinit(bookkeeping);
    q.freed.deinit(bookkeeping);
    q.* = undefined;
}

/// The quarantine's own tables come straight from the system, so a test
/// that counts or fails allocations never sees them.
const bookkeeping = std.heap.page_allocator;

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn of(ptr: *anyopaque) *Quarantine {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with a *Quarantine
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const q = of(ptr);
    if (!supported) return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
    const page = std.heap.pageSize();
    const data = std.mem.alignForward(usize, @max(len, 1), page);
    const guard: usize = if (q.options.guard == .after) page else 0;
    const span = std.math.add(usize, data, guard) catch return null;
    const base = std.heap.PageAllocator.map(span, .fromByteUnits(@max(alignment.toByteUnits(), page))) orelse return null;
    const at = @intFromPtr(base); // safe: an address, kept as a number for page arithmetic
    if (guard != 0 and !close(at + data, guard)) {
        release(.{ .base = at, .len = span });
        return null;
    }
    lock(q);
    defer q.mutex.unlock();
    q.mappings.put(bookkeeping, at, span) catch {
        release(.{ .base = at, .len = span });
        return null;
    };
    // With a guard the block ends where the guard begins.
    const start = if (guard == 0) at else alignment.backward(at + data - @max(len, 1));
    assert(start >= at);
    return @ptrFromInt(start);
}

/// In place, a shrink would leave the tail open and a growth could move
/// it: a range handed out stays this block's until it is freed.
fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    return new_len == memory.len;
}

fn remap(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) ?[*]u8 {
    return if (new_len == memory.len) memory.ptr else null;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const q = of(ptr);
    if (!supported) return std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    const page = std.heap.pageSize();
    const base = std.mem.alignBackward(usize, @intFromPtr(memory.ptr), page); // safe: an address, kept as a number for page arithmetic
    lock(q);
    defer q.mutex.unlock();
    const span = q.mappings.get(base) orelse unreachable; // unreachable: a free of a block this allocator never gave out
    const guard: usize = if (q.options.guard == .after) page else 0;
    if (!decommit(base, span - guard)) {
        // The pages could not be closed, so they cannot be kept: give the
        // range back rather than leave it open and reserved.
        release(.{ .base = base, .len = span });
        _ = q.mappings.remove(base);
        return;
    }
    const limit = q.options.reuse_after orelse return;
    q.freed.append(bookkeeping, .{ .base = base, .len = span }) catch return;
    q.quarantined += span;
    while (q.quarantined > limit and q.freed_head < q.freed.items.len) {
        const oldest = q.freed.items[q.freed_head];
        q.freed_head += 1;
        q.quarantined -= oldest.len;
        release(oldest);
        _ = q.mappings.remove(oldest.base);
    }
    if (q.freed_head == q.freed.items.len) {
        q.freed.clearRetainingCapacity();
        q.freed_head = 0;
    }
}

fn lock(q: *Quarantine) void {
    while (!q.mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Makes `[at, at + len)` inaccessible, keeping it reserved and resident.
fn close(at: usize, len: usize) bool {
    if (builtin.os.tag == .windows) {
        var address: ?windows.PVOID = @ptrFromInt(at);
        var size: windows.SIZE_T = len;
        var old: windows.PAGE = undefined;
        return windows.ntdll.NtProtectVirtualMemory(windows.GetCurrentProcess(), &address, &size, .{ .NOACCESS = true }, &old) == .SUCCESS;
    }
    const start: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(at); // safe: `at` is a page boundary inside a mapping this allocator made
    return std.posix.errno(std.posix.system.mprotect(start, len, std.mem.zeroes(std.posix.PROT))) == .SUCCESS;
}

/// Gives `[at, at + len)` back to the system and leaves it inaccessible
/// and reserved, so no later mapping lands there.
fn decommit(at: usize, len: usize) bool {
    if (builtin.os.tag == .windows) {
        var address: ?windows.PVOID = @ptrFromInt(at);
        var size: windows.SIZE_T = len;
        return windows.ntdll.NtFreeVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&address), &size, .{ .DECOMMIT = true }) == .SUCCESS; // safe: the binding takes the base address as `*?*anyopaque`
    }
    const start: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(at); // safe: `at` is a page boundary inside a mapping this allocator made
    const advice = if (builtin.os.tag.isDarwin()) std.posix.MADV.FREE_REUSABLE else std.posix.MADV.DONTNEED;
    // ziglint-ignore: Z026 pages not given back stay resident; the range is still closed below
    std.posix.madvise(start, len, advice) catch {};
    return close(at, len);
}

fn release(range: Range) void {
    const start: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(range.base); // safe: every range here is a whole mapping this allocator made, page-aligned
    std.heap.PageAllocator.unmap(start[0..range.len]);
}
