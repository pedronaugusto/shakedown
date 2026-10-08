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

    // Available to build tools without fetching preflight or building tests.
    _ = b.addExecutable(.{
        .name = "shakedown-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/compare.zig"),
            .imports = &.{.{ .name = "measuring", .module = b.createModule(.{ .root_source_file = b.path("src/bench.zig"), .target = target, .optimize = optimize }) }},
            .target = target,
            .optimize = optimize,
        }),
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

    // The 32-bit draw regression compiles enabled portable APIs without a
    // hosted Io. Both targets exercise pointer-sized indexing independently.
    const source32_step = b.step("check-source32", "Compile portable draws for wasm32 and x86 Linux");
    for ([_][]const u8{ "wasm32-freestanding", "x86-linux-musl" }) |triple| {
        const cross_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("invalid target"));
        const cross_module = b.createModule(.{ .root_source_file = b.path("src/shakedown.zig"), .target = cross_target, .optimize = optimize });
        const fixture = b.addObject(.{
            .name = "source32",
            .root_module = b.createModule(.{
                .root_source_file = b.path("ci/source32.zig"),
                .target = cross_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "shakedown", .module = cross_module }},
            }),
        });
        source32_step.dependOn(&fixture.step);
    }
    check_step.dependOn(source32_step);
    test_step.dependOn(source32_step);
    const source32_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/source32.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    const source32_test_step = b.step("test-source32", "Run the portable draw regression");
    source32_test_step.dependOn(&b.addRunArtifact(source32_tests).step);
    test_step.dependOn(source32_test_step);
    check_step.dependOn(&source32_tests.step);

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
                .programs = &.{
                    .{ .name = "shakedown-bench", .source = "bench/main.zig" },
                    .{ .name = "shakedown-bench-compare", .source = "bench/compare.zig", .timed = false },
                },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        const tooling = b.dependencyLazy("preflight", .{}) catch return;
        const host = b.graph.host;
        const gantry = tooling.builder.dependencyLazy("gantry", .{ .target = host, .optimize = .safe }) catch return;
        const plan_tool = b.addExecutable(.{ .name = "shakedown-ci-plan", .root_module = b.createModule(.{
            .root_source_file = tooling.path("src/main.zig"),
            .target = host,
            .optimize = .safe,
            .imports = &.{.{ .name = "gantry", .module = gantry.module("gantry") }},
        }) });
        const planner = b.addRunArtifact(plan_tool);
        planner.addArg("plan");
        planner.addPassthruArgs();
        planner.setCwd(b.path("."));
        b.step("plan", "Generate the hosted CI matrices").dependOn(&planner.step);
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
    const provenance = b.addOptions();
    const revision = std.mem.trim(u8, b.run(&.{ "git", "rev-parse", "HEAD" }), "\r\n");
    const dirty = b.run(&.{ "git", "status", "--porcelain", "--untracked-files=normal" }).len != 0;
    provenance.addOption([]const u8, "commit", if (dirty) b.fmt("{s}-dirty", .{revision}) else revision);
    const compare_driver = b.createModule(.{ .root_source_file = b.path("src/bench/compare.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "measuring", .module = b.createModule(.{ .root_source_file = b.path("src/bench.zig"), .target = target, .optimize = optimize }) }} });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "shakedown", .module = module },
        .{ .name = "bench_options", .module = provenance.createModule() },
        .{ .name = "bench_compare", .module = compare_driver },
    }) catch @panic("OOM");
}
