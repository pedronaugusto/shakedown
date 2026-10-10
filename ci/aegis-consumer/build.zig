//! A consumer that brings its own aegis and binds shakedown to it, as a
//! package with aegis in its own graph does, so its tests link one aegis.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = .Debug }).module("aegis");
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = .Debug, .aegis = .consumer });
    @import("shakedown").useAegis(shakedown, aegis);
    const exe = b.addExecutable(.{ .name = "aegis-consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("../consumer.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{ .{ .name = "shakedown", .module = shakedown.module("shakedown") }, .{ .name = "aegis", .module = aegis } },
    }) });
    b.default_step.dependOn(&b.addRunArtifact(exe).step);
}
