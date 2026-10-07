//! The test root: every unit test, and the tests that drive the package
//! from outside.
test {
    _ = @import("shakedown.zig");
    _ = @import("layer.zig");
    _ = @import("Clock.zig");
    _ = @import("alloc/Counting.zig");
    _ = @import("alloc/Quarantine.zig");
    _ = @import("corpus.zig");
    _ = @import("Source.zig");
    _ = @import("Steps.zig");
    _ = @import("match.zig");
    _ = @import("plan.zig");
    _ = @import("trace.zig");
    _ = @import("io_call.zig");
    _ = @import("FaultIo.zig");
    _ = @import("sweep.zig");
    _ = @import("layer_test.zig");
    _ = @import("clock_test.zig");
    _ = @import("quarantine_test.zig");
    _ = @import("fault_test.zig");
    _ = @import("sweep_test.zig");
}
