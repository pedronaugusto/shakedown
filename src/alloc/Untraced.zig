//! A leak-counting allocator that takes no stack trace per allocation.
//!
//! `std.testing.allocator` unwinds a stack trace for every allocation, so a
//! leak names where its block was made. In a Debug build that unwinding can
//! be most of a test's time: a test that makes many small allocations then
//! runs close to its test runner's time bound, and a loaded machine runs it
//! out. `Untraced` is a `std.heap.SafeAllocator` like the testing one, with
//! the same checks of leaks, double frees and corrupted blocks, and no
//! traces. `run` hands one to a body, and on a leak runs the body again on a
//! traced allocator, whose report names each leaked block's allocation.
const std = @import("std");

const Untraced = @This();

safe: std.heap.SafeAllocator,

/// Takes its memory from `backing`, which must be thread-safe for this
/// allocator to be: `std.testing.allocator` is.
pub fn init(backing: std.mem.Allocator) Untraced {
    return .{ .safe = .init(backing, .{ .stack_trace_frames = 0 }) };
}

/// The allocator. `u` must not move while it is in use.
pub fn allocator(u: *Untraced) std.mem.Allocator {
    return u.safe.allocator();
}

/// Frees what is still live and gives back the backing memory. Returns how
/// many blocks were still live: the leaks. Logs nothing.
pub fn deinit(u: *Untraced) usize {
    return u.safe.deinitLog(false);
}

/// A traced allocator: `std.testing.allocator`'s, over `backing`. Its
/// `deinit` logs each leaked block with the stack it was allocated from.
pub fn traced(backing: std.mem.Allocator) std.heap.SafeAllocator {
    return .init(backing, .{});
}

/// Runs `body` with an `Untraced` allocator over `backing`. An error from
/// `body` is returned as it is. A body that returns and leaks runs again,
/// on a traced allocator whose report names each leaked allocation, and
/// `error.Leaked` is returned. The body must do the same work when it runs
/// again: what it leaks the second time is what the report names.
pub fn run(backing: std.mem.Allocator, ctx: anytype, comptime body: fn (@TypeOf(ctx), std.mem.Allocator) anyerror!void) anyerror!void {
    var quiet: Untraced = .init(backing);
    const result = body(ctx, quiet.allocator());
    const leaks = quiet.deinit();
    try result;
    if (leaks == 0) return;
    var loud = traced(backing);
    const again = body(ctx, loud.allocator());
    _ = loud.deinit();
    again catch |err| rerunFailed(err);
    return error.Leaked;
}

/// The leak is the failure either way: a traced run made to name it that
/// fails another way is said, since its report may then name nothing.
pub fn rerunFailed(err: anyerror) void {
    std.log.scoped(.shakedown).warn("the traced run made to name a leak failed with {t}", .{err});
}

const testing = std.testing;

const Body = struct {
    calls: u32 = 0,
    /// Leaks a block on the calls up to this one.
    leak_until: u32 = 0,
    fail: bool = false,

    fn run(b: *Body, gpa: std.mem.Allocator) anyerror!void {
        b.calls += 1;
        const block = try gpa.alloc(u8, 16);
        if (b.calls > b.leak_until) gpa.free(block);
        if (b.fail) return error.Failed;
    }
};

test "a body that frees what it allocates runs once" {
    var body: Body = .{};
    try run(testing.allocator, &body, Body.run);
    try testing.expectEqual(@as(u32, 1), body.calls);
}

test "a leak fails the body and runs it again, traced" {
    // It leaks only the first time, so the traced run logs no leak here.
    var body: Body = .{ .leak_until = 1 };
    try testing.expectError(error.Leaked, run(testing.allocator, &body, Body.run));
    try testing.expectEqual(@as(u32, 2), body.calls);
}

test "a body's error is returned as it is, its leaks freed and not run again" {
    var body: Body = .{ .leak_until = 1, .fail = true };
    try testing.expectError(error.Failed, run(testing.allocator, &body, Body.run));
    try testing.expectEqual(@as(u32, 1), body.calls);
}

test "deinit counts the blocks still live and frees them" {
    var u: Untraced = .init(testing.allocator);
    const gpa = u.allocator();
    _ = try gpa.alloc(u8, 10);
    const kept = try gpa.create(u64);
    _ = kept;
    const freed = try gpa.alloc(u8, 3);
    gpa.free(freed);
    try testing.expectEqual(@as(usize, 2), u.deinit());
}
