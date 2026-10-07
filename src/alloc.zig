//! Allocators for tests: one that counts, one that never reuses an address,
//! and one that never resizes in place.

/// Counts calls, failures and bytes live, at their peak and in total.
pub const Counting = @import("alloc/Counting.zig");
/// Never hands out an address twice, so a use after free faults.
pub const Quarantine = @import("alloc/Quarantine.zig");
/// Refuses every resize and remap, so allocation counts repeat run to run.
pub const NoResize = @import("alloc/NoResize.zig");
