//! A retry loop with backoff, tested without waiting: the code under test
//! sleeps on a `shakedown.Clock`, and the test moves the clock. Then an
//! allocator that counts, and a `FaultIo` that fails one sync by its path.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- usage`
//! extracts the region between the usage markers into README.md, so the
//! snippet a reader copies is code CI executes.

const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");

/// The code under test: try `attempt` up to `tries` times, sleeping one
/// second, then two, then four between tries.
fn retry(io: Io, tries: u32, attempts: *std.atomic.Value(u32)) error{ GaveUp, Canceled }!void {
    var backoff: Io.Duration = .fromSeconds(1);
    for (0..tries) |_| {
        if (attempts.fetchAdd(1, .acq_rel) + 1 == tries) return;
        try io.sleep(backoff, .awake);
        backoff = .fromNanoseconds(backoff.nanoseconds * 2);
    }
    return error.GaveUp;
}

pub fn main(init: std.process.Init) !void {
    // --- README:usage ---

    var clock: shakedown.Clock = .init(init.io, .{});
    const io = clock.io();
    const start = Io.Timestamp.now(io, .awake);

    var attempts: std.atomic.Value(u32) = .init(0);
    var task = try io.concurrent(retry, .{ io, 3, &attempts });

    // Wait until the task sleeps, then let exactly its backoff pass.
    try clock.awaitArmed(1, .fromSeconds(10));
    clock.advance(.fromSeconds(1));
    try clock.awaitArmed(1, .fromSeconds(10));
    std.debug.assert(clock.advanceToNext().?.nanoseconds == 2 * std.time.ns_per_s);
    try task.await(io);

    std.debug.assert(attempts.load(.acquire) == 3);
    std.debug.assert(start.durationTo(.now(io, .awake)).nanoseconds == 3 * std.time.ns_per_s);

    // An allocator that counts, for a test that bounds what code allocates.
    var counting: shakedown.alloc.Counting = .init(std.heap.page_allocator);
    const gpa = counting.allocator();
    const bytes = try gpa.alloc(u8, 100);
    gpa.free(bytes);
    std.debug.assert(counting.peak_bytes == 100);
    std.debug.assert(counting.live_bytes == 0);

    // Fail the first sync of a file whose path ends in ".lock", and count
    // every call on the way.
    const dir = try Io.Dir.cwd().createDirPathOpen(init.io, ".zig-cache/shakedown-example", .{});
    defer dir.close(init.io);
    const fio = try shakedown.FaultIo.init(init.gpa, init.io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .fileSync, .n = 1, .path = .{ .suffix = ".lock" } } },
        .fault = .{ .fail = error.InputOutput },
    }} });
    defer fio.deinit();
    const lock = try dir.createFile(fio.io(), "HEAD.lock", .{});
    defer lock.close(fio.io());
    if (lock.sync(fio.io())) |_| unreachable else |err| std.debug.assert(err == error.InputOutput);
    std.debug.assert(fio.count(.fileSync) == 1);

    // --- README:usage ---
}
