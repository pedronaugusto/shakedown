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

    const check_step = b.step("check", "Compile the tests, programs, example and benchmarks without running them");
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

    //=====================================================================
    // Benchmarks: run by hand with `zig build bench`, compiled by CI and never
    // timed there. Results are JSON lines under zig-out/bench/.
    //=====================================================================

    const bench = b.addExecutable(.{
        .name = "shakedown-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .fast else optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.setCwd(b.path("."));
    bench_run.addPassthruArgs();
    b.step("bench", "Run the benchmarks (by hand; never timed in CI)").dependOn(&bench_run.step);
    check_step.dependOn(&bench.step);

    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // CI wiring, only in shakedown's own tree. preflight is lazy and only the
    // root build asks for it, so a project depending on shakedown neither
    // needs nor fetches it.
    //=====================================================================

    if (b.dep_prefix.len == 0) if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // A project that depends on shakedown by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "shakedown", .program = b.path("ci/consumer.zig") });
    };
}
