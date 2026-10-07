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
    _ = @import("layer_test.zig");
    _ = @import("clock_test.zig");
    _ = @import("quarantine_test.zig");
}
