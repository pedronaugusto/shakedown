//! Source layers, lowest first. Every production source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/alloc/Counting.zig",
        "src/alloc/LockProbe.zig",
        "src/alloc/NoResize.zig",
        "src/alloc/Quarantine.zig",
        "src/alloc/Unwiped.zig",
        "src/corpus.zig",
        "src/bench.zig",
        "src/ids.zig",
        "src/io_call.zig",
        "src/layer.zig",
        "src/match.zig",
        "src/sim/executor.zig",
        "src/sim/Region.zig",
        "src/sim/Watchdog.zig",
        "src/Source.zig",
        "src/Steps.zig",
    } },
    .{ .name = "vocabulary", .patterns = &.{
        "src/gen.zig",
        "src/plan.zig",
        "src/shrink.zig",
        "src/trace.zig",
    } },
    .{ .name = "disk pages", .patterns = &.{ "src/sim/fs/Image.zig", "src/sim/fs/names.zig" } },
    .{ .name = "disk state", .patterns = &.{"src/sim/fs/state.zig"} },
    .{ .name = "disk model", .patterns = &.{"src/sim/fs/Model.zig"} },
    .{ .name = "disk", .patterns = &.{"src/sim/Fs.zig"} },
    .{ .name = "network model", .patterns = &.{"src/sim/net/Model.zig"} },
    .{ .name = "process parts", .patterns = &.{ "src/sim/programs/Pipes.zig", "src/sim/programs/Heap.zig" } },
    .{ .name = "process model", .patterns = &.{"src/sim/programs/Model.zig"} },
    .{ .name = "simulation parts", .patterns = &.{
        "src/sim/options.zig",
    } },
    .{ .name = "simulation core", .patterns = &.{
        "src/sim/Core.zig",
    } },
    .{ .name = "io layers", .patterns = &.{
        "src/Clock.zig",
        "src/FaultIo.zig",
        "src/sim/calls.zig",
        "src/sim/fs/calls.zig",
        "src/sim/net/calls.zig",
        "src/sim/programs/calls.zig",
        "src/sim/routing.zig",
    } },
    .{ .name = "nodes and topology", .patterns = &.{ "src/sim/Node.zig", "src/sim/Net.zig", "src/sim/Programs.zig" } },
    .{ .name = "simulation", .patterns = &.{
        "src/Sim.zig",
    } },
    .{ .name = "drivers and namespaces", .patterns = &.{
        "src/alloc.zig",
        "src/bench/compare.zig",
        "src/check.zig",
        "src/explore.zig",
        "src/Machine.zig",
        "src/linearizable.zig",
        "src/conformance.zig",
        "src/conformance/files.zig",
        "src/determinism.zig",
        "src/every/fault.zig",
        "src/every.zig",
        "src/every/crash.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/shakedown.zig",
    } },
};

pub const entries: []const []const u8 = &.{"src/bench/compare.zig"};

pub const modules: []const gantry.NamedModule = &.{ .{ .name = "measuring", .path = "src/bench.zig" }, .{ .name = "network_model", .path = "src/sim/net/Model.zig" }, .{ .name = "bench_compare", .path = "src/bench/compare.zig" } };

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "aegis",
        "bench_options",
        "build_options",
        "builtin",
        "shakedown",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
