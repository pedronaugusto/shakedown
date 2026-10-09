//! Allocators for tests: one that counts, one that never reuses an address,
//! one that never resizes in place, one that sees frees of unwiped memory
//! and one that sees calls made under a lock.

/// Counts calls, failures and bytes live, at their peak and in total.
pub const Counting = @import("alloc/Counting.zig");
/// Never hands out an address twice, so a use after free faults.
pub const Quarantine = @import("alloc/Quarantine.zig");
/// Refuses every resize and remap, so allocation counts repeat run to run.
pub const NoResize = @import("alloc/NoResize.zig");
/// Notes blocks freed while they still hold bytes that must not outlive
/// their owner: a key, a token, a password.
pub const Unwiped = @import("alloc/Unwiped.zig");
/// Counts the calls made while a lock is held.
pub const LockProbe = @import("alloc/LockProbe.zig");
