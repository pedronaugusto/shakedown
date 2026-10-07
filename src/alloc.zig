//! Allocators for tests: one that counts, one that never reuses an address.

/// Counts calls, failures and bytes live, at their peak and in total.
pub const Counting = @import("alloc/Counting.zig");
/// Never hands out an address twice, so a use after free faults.
pub const Quarantine = @import("alloc/Quarantine.zig");
