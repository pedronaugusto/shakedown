//! The step counter of one run. Every plan and trace that shares a `Steps`
//! numbers its calls from it, so calls made through `FaultIo`, a seam's
//! own calls and anything else that takes a step interleave into one
//! sequence: step `i` names one call, whoever made it.
//!
//! Steps are numbered from 0. Taking one is a single atomic add, so tasks
//! on a threaded base may share a counter; the order they take steps in is
//! then the order the base ran them in.
const std = @import("std");

const Steps = @This();

/// Private: the next step.
next: std.atomic.Value(u64) = .init(0),

pub fn init() Steps {
    return .{};
}

/// Takes the next step and returns its number.
pub fn take(s: *Steps) u64 {
    return s.next.fetchAdd(1, .monotonic);
}

/// How many steps have been taken: the number the next one gets.
pub fn peek(s: *const Steps) u64 {
    return s.next.load(.monotonic);
}

/// Starts again from step 0.
pub fn reset(s: *Steps) void {
    s.next.store(0, .monotonic);
}

test "steps count from zero, and peeking takes none" {
    var s: Steps = .init();
    try std.testing.expectEqual(@as(u64, 0), s.peek());
    try std.testing.expectEqual(@as(u64, 0), s.take());
    try std.testing.expectEqual(@as(u64, 1), s.take());
    try std.testing.expectEqual(@as(u64, 2), s.peek());
    s.reset();
    try std.testing.expectEqual(@as(u64, 0), s.take());
}
