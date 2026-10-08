const std = @import("std");
pub fn build(b: *std.Build) void {
    const dep = b.dependency("shakedown", .{ .target = b.graph.host, .optimize = std.lang.Optimize.fast });
    const run = b.addRunArtifact(dep.artifact("shakedown-bench-compare"));
    run.addArg("--smoke");
    run.expectStdOutEqual("{\"row\":\"fixture/quoted\\\"row\",\"unit\":\"op\",\"percent\":25,\"noise_percent\":0,\"sufficient_samples\":true,\"beyond_noise\":true}\n");
    b.default_step.dependOn(&run.step);
}
