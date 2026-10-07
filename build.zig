const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, `std` only: nothing to link and no build options,
    // so nothing a consumer has to match. It is a test dependency: a package
    // imports it from its test modules and never from production code.
    //=====================================================================

    const module = b.addModule("shakedown", .{
        .root_source_file = b.path("src/shakedown.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Everything below is this repository's own: a project depending on
    // shakedown builds the module and nothing else, and fetches nothing for
    // it.
    if (b.dep_prefix.len != 0) return;

    //=====================================================================
    // Tests
    //=====================================================================

    // The clock's no-lost-wake stress test: how many real threads sit in
    // timed waits, and how many steps the clock moves under them.
    const stress_threads = b.option(u32, "stress-threads", "Threads in the clock stress test (default 1000)") orelse 1000;
    const stress_rounds = b.option(u32, "stress-rounds", "Clock steps in the clock stress test (default 10000)") orelse 10_000;
    const test_options = b.addOptions();
    test_options.addOption(u32, "stress_threads", stress_threads);
    test_options.addOption(u32, "stress_rounds", stress_rounds);

    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{
        .name = "shakedown-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", test_options);

    const test_step = b.step("test", "Run the tests, the fault programs and the example");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const check_step = b.step("check", "Compile the tests, programs and example without running them");
    check_step.dependOn(&tests.step);

    // A use after free and a one-byte overflow on a quarantine must kill the
    // process, so they run in a child: the program spawns itself once per
    // case and passes only when every child died of its access.
    const fault = b.addExecutable(.{
        .name = "quarantine-fault",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/quarantine_fault.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fault).step);
    check_step.dependOn(&fault.step);

    // A simulation's task that overflows its stack must die on the guard
    // page below it, in a child as above.
    const stack_fault = b.addExecutable(.{
        .name = "stack-fault",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/stack_fault.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(stack_fault).step);
    check_step.dependOn(&stack_fault.step);

    //=====================================================================
    // Example: built AND run against the module a consumer gets.
    // examples/usage.zig is also README.md's Usage block (zig build docs --
    // usage), so the snippet a reader copies is code CI executes.
    //=====================================================================

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    const examples_step = b.step("examples", "Build and run the usage example");
    examples_step.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples_step);
    check_step.dependOn(&example.step);

    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // CI wiring. preflight is lazy and only the root build asks for it, so a
    // project depending on shakedown neither needs nor fetches it.
    //=====================================================================

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            // `zig build bench` runs them in ReleaseFast, by hand; never
            // timed in CI, where `zig build test` runs each once.
            .bench = .{
                .programs = &.{.{ .name = "shakedown-bench", .source = "bench/main.zig" }},
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on shakedown by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "shakedown", .program = b.path("ci/consumer.zig") });
    }
}

/// shakedown in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would time
/// the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const module = b.createModule(.{ .root_source_file = b.path("src/shakedown.zig"), .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "shakedown", .module = module }}) catch @panic("OOM");
}
