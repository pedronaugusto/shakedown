//! The test root: every unit test, and the tests that drive the package
//! from outside.
test {
    _ = @import("fs_test.zig");
    _ = @import("net_test.zig");
    _ = @import("shakedown.zig");
    _ = @import("layer.zig");
    _ = @import("Clock.zig");
    _ = @import("alloc/Counting.zig");
    _ = @import("alloc/Quarantine.zig");
    _ = @import("alloc/NoResize.zig");
    _ = @import("corpus.zig");
    _ = @import("Source.zig");
    _ = @import("Steps.zig");
    _ = @import("match.zig");
    _ = @import("plan.zig");
    _ = @import("trace.zig");
    _ = @import("io_call.zig");
    _ = @import("FaultIo.zig");
    _ = @import("every/fault.zig");
    _ = @import("every.zig");
    _ = @import("gen.zig");
    _ = @import("shrink.zig");
    _ = @import("check.zig");
    _ = @import("Sim.zig");
    _ = @import("sim/Core.zig");
    _ = @import("sim/Region.zig");
    _ = @import("sim/executor.zig");
    _ = @import("conformance.zig");
    _ = @import("determinism.zig");
    _ = @import("layer_test.zig");
    _ = @import("clock_test.zig");
    _ = @import("quarantine_test.zig");
    _ = @import("no_resize_test.zig");
    _ = @import("fault_test.zig");
    _ = @import("every_fault_test.zig");
    _ = @import("check_test.zig");
    _ = @import("shrink_challenge_test.zig");
    _ = @import("sim_test.zig");
    _ = @import("sim_bugs_test.zig");
    _ = @import("sim_determinism_test.zig");
    _ = @import("conformance_test.zig");
}

test {
    _ = @import("bench_test.zig");
}
