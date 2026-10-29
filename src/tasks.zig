//! Tasks a test started, reaped on its way out.
const std = @import("std");

/// Cancels the task behind `future` and reads what it returned. Being cancelled is the reaping
/// itself; any other failure is a second one, printed beside the test's own rather than dropped.
pub fn reap(comptime T: type, io: std.Io, future: *std.Io.Future(T)) void {
    if (future.cancel(io)) |_| {} else |err| {
        if (@as(anyerror, err) != error.Canceled) std.debug.print("a reaped task failed too: {s}\n", .{@errorName(err)});
    }
}

/// What `function` returns: the `T` of the future `io.concurrent(function, ...)` gives.
pub fn Result(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

fn waitForCancel(io: std.Io, reached: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    reached.store(true, .release);
    try io.sleep(.fromSeconds(60), .awake);
}

test "a reaped task is cancelled and its cancel is its end" {
    const io = std.testing.io;
    var reached: std.atomic.Value(bool) = .init(false);
    var future: std.Io.Future(Result(waitForCancel)) = io.concurrent(waitForCancel, .{ io, &reached }) catch return error.SkipZigTest;
    while (!reached.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    reap(Result(waitForCancel), io, &future);
    try std.testing.expect(reached.load(.acquire));
}
