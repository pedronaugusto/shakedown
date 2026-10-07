//! Source layers, lowest first. Every production source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/alloc/Counting.zig",
        "src/alloc/Quarantine.zig",
        "src/corpus.zig",
        "src/layer.zig",
        "src/Source.zig",
    } },
    .{ .name = "time", .patterns = &.{
        "src/Clock.zig",
    } },
    .{ .name = "namespaces", .patterns = &.{
        "src/alloc.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/shakedown.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
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
