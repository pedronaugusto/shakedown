const std = @import("std");

/// What a project that depends on shakedown builds: the module, and the two
/// programs build tools take from it, the benchmark comparison and the
/// fuzzer. The tests, programs, example and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig over `std` and aegis, whose runtime is `std` only:
    // nothing to link and no build options, so nothing a consumer has to
    // match. It is a test dependency: a package imports it from its test
    // modules and never from production code.
    //=====================================================================

    // aegis's types are in shakedown's API (task ids, byte counts, limits),
    // so a build links one aegis: shakedown's own by default, or, with
    // `.aegis = .consumer`, the consumer's, bound with `useAegis`, and
    // shakedown's is then never fetched.
    const aegis_from = b.option(enum { own, consumer }, "aegis", "Which aegis shakedown imports: its own pin, or the consumer's, bound with useAegis (default own)") orelse .own;
    const module = b.addModule("shakedown", .{
        .root_source_file = b.path("src/shakedown.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (aegis_from == .own) {
        // The module is declared either way, so a consumer can ask for it while aegis is fetched.
        if (b.lazyDependency("aegis", .{ .target = target, .optimize = optimize })) |aegis| module.addImport("aegis", aegis.module("aegis"));
    }

    // Available to build tools without building tests.
    const comparison = b.addExecutable(.{
        .name = "shakedown-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/compare.zig"),
            .imports = &.{.{ .name = "measuring", .module = b.createModule(.{ .root_source_file = b.path("src/bench.zig"), .target = target, .optimize = optimize }) }},
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(comparison);

    // Continuous fuzzing of a package's properties, off the landing path.
    const fuzzer = b.addExecutable(.{
        .name = "shakedown-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz/main.zig"),
            .imports = &.{.{ .name = "fuzz_findings", .module = b.createModule(.{ .root_source_file = b.path("src/fuzz.zig"), .target = target, .optimize = optimize }) }},
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(fuzzer);
}

/// shakedown's development: its tests, fault programs, example, consumer
/// checks and benchmarks, under preflight's gate. Run through bay, which gives
/// `tools` and holds shakedown as a dependency of this build.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The clock's no-lost-wake stress test: how many real threads sit in
    // timed waits, and how many steps the clock moves under them.
    const stress_threads = b.option(u32, "stress-threads", "Threads in the clock stress test (default 1000)") orelse 1000;
    const stress_rounds = b.option(u32, "stress-rounds", "Clock steps in the clock stress test (default 10000)") orelse 10_000;
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("shakedown");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });

    //=====================================================================
    // Tests
    //=====================================================================

    const test_options = b.addOptions();
    test_options.addOption(u32, "stress_threads", stress_threads);
    test_options.addOption(u32, "stress_rounds", stress_rounds);
    const tests = b.addTest(.{
        .name = "shakedown-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", test_options);
    tests.root_module.addImport("aegis", aegis_dependency.module("aegis"));

    const test_step = b.step("test", "Run the tests, the fault programs and the example");
    const unit_run = b.addRunArtifact(tests);
    test_step.dependOn(&unit_run.step);
    // The suite alone: what the fuzzer runs (`bay unit --fuzz`), every
    // binary of it having properties.
    b.step("unit", "Run the shakedown suite alone, without the programs and the example").dependOn(&unit_run.step);

    // A build-time API contract: an isolated consumer requests the comparator
    // artifact, using only a path dependency and with package fetching off.
    const empty_packages = b.addWriteFiles();
    _ = empty_packages.add("README", "No packages.\n");
    _ = empty_packages.addCopyDirectory(aegis_dependency.path(""), aegis_dependency.builder.pkg_hash, .{});
    const comparison_consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file", "ci/bench-consumer/build.zig", "--system" });
    comparison_consumer.addDirectoryArg2(empty_packages.getDirectory(), .{});
    comparison_consumer.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", ".zig-cache/bench-consumer-global");
    comparison_consumer.setCwd(p.path("."));
    comparison_consumer.has_side_effects = true;
    b.step("check-bench-consumer", "Smoke-run the comparator as an isolated dependency artifact").dependOn(&comparison_consumer.step);

    // Real crash replay (Linux, root, by hand before a cut; never in CI):
    // what a real file system recovers to under dm-log-writes, against what
    // `Sim.Fs` reaches.
    const crash_replay = b.addExecutable(.{
        .name = "shakedown-crash-replay",
        .root_module = b.createModule(.{
            .root_source_file = p.path("crashreplay/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    b.step("crash-replay", "Build the real crash replay (Linux, run as root by hand)").dependOn(&b.addInstallArtifact(crash_replay, .{}).step);
    const crash_replay_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = p.path("crashreplay/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "shakedown", .module = module }},
    }) });

    // A consumer that brings its own aegis binds shakedown to it: one aegis
    // links, and shakedown's own pin is not asked for.
    const aegis_consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file", "ci/aegis-consumer/build.zig", "--system" });
    aegis_consumer.addDirectoryArg2(empty_packages.getDirectory(), .{});
    aegis_consumer.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", ".zig-cache/aegis-consumer-global");
    aegis_consumer.setCwd(p.path("."));
    aegis_consumer.has_side_effects = true;
    b.step("check-aegis-consumer", "Build a consumer that binds shakedown to its own aegis").dependOn(&aegis_consumer.step);

    const check_step = b.step("check", "Compile the tests, programs and example without running them");
    check_step.dependOn(&tests.step);
    // The replay's own parts are tested and compiled with the rest; the
    // replay itself runs only by hand.
    check_step.dependOn(&crash_replay.step);
    test_step.dependOn(&b.addRunArtifact(crash_replay_tests).step);

    // The 32-bit draw regression compiles enabled portable APIs without a
    // hosted Io. Both targets exercise pointer-sized indexing independently.
    const source32_step = b.step("check-source32", "Compile portable draws for wasm32 and x86 Linux");
    for ([_][]const u8{ "wasm32-freestanding", "x86-linux-musl" }) |triple| {
        const cross_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("invalid target"));
        const cross_aegis = p.dependency("aegis", .{ .target = cross_target, .optimize = optimize }).module("aegis");
        const cross_module = b.createModule(.{ .root_source_file = p.path("src/shakedown.zig"), .target = cross_target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = cross_aegis }} });
        const fixture = b.addObject(.{
            .name = "source32",
            .root_module = b.createModule(.{
                .root_source_file = p.path("ci/source32.zig"),
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
            .root_source_file = p.path("ci/source32.zig"),
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
            .root_source_file = p.path("src/testing/quarantine_fault.zig"),
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
            .root_source_file = p.path("src/testing/stack_fault.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(stack_fault).step);
    check_step.dependOn(&stack_fault.step);

    //=====================================================================
    // Example: built AND run against the module a consumer gets.
    // examples/usage.zig is also README.md's Usage block (bay docs --
    // usage), so the snippet a reader copies is code CI executes.
    //=====================================================================

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/usage.zig"),
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
    // The gate. preflight is a dev dependency: a project depending on
    // shakedown never sees it. Its benchmarks measure through shakedown,
    // which this build holds as the package itself.
    //=====================================================================

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // `bay bench` runs them in ReleaseFast, by hand; never timed in CI,
        // where `bay test` runs each once.
        .bench = .{
            .programs = &.{
                .{ .name = "shakedown-bench", .source = "bench/main.zig" },
                .{ .name = "shakedown-net-bench", .source = "bench/net.zig" },
                .{ .name = "shakedown-model-bench", .source = "bench/b6.zig" },
                .{ .name = "shakedown-bench-compare", .source = "bench/compare.zig", .timed = false },
            },
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on shakedown by path, with only the packages
    // shakedown needs: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "shakedown", .program = p.path("ci/consumer.zig"), .packages = &.{aegis_dependency} });
}

/// shakedown in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would time
/// the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).builder;
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const module = b.createModule(.{ .root_source_file = p.path("src/shakedown.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
    // Git state is a build input, not a cached configuration-time observation.
    const revision = b.addSystemCommand(&.{ "git", "rev-parse", "HEAD" });
    revision.setCwd(p.path("."));
    revision.has_side_effects = true;
    const status = b.addSystemCommand(&.{ "git", "status", "--porcelain", "--untracked-files=normal" });
    status.setCwd(p.path("."));
    status.has_side_effects = true;
    const provenance = b.addWriteFiles();
    // Every benchmark requests these files. Identical cached output paths can
    // be rewritten while a sibling compiler reads them; give each writer its
    // own temporary directory, with Git state still observed on every build.
    provenance.mode = .tmp;
    _ = provenance.addCopyFile(revision.captureStdOut(.{}), "revision.txt");
    _ = provenance.addCopyFile(status.captureStdOut(.{}), "status.txt");
    const options = provenance.add("options.zig", "const std = @import(\"std\");\n" ++
        "pub const commit = std.mem.trim(u8, @embedFile(\"revision.txt\"), \"\\r\\n\") ++ (if (@embedFile(\"status.txt\").len != 0) \"-dirty\" else \"\");\n");
    const provenance_module = b.createModule(.{ .root_source_file = options, .target = target, .optimize = optimize });
    const compare_driver = b.createModule(.{ .root_source_file = p.path("src/bench/compare.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "measuring", .module = b.createModule(.{ .root_source_file = p.path("src/bench.zig"), .target = target, .optimize = optimize }) }} });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "shakedown", .module = module },
        .{ .name = "bench_options", .module = provenance_module },
        .{ .name = "network_model", .module = b.createModule(.{ .root_source_file = p.path("src/sim/net/Model.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} }) },
        .{ .name = "measuring", .module = b.createModule(.{ .root_source_file = p.path("src/bench.zig"), .target = target, .optimize = optimize }) },
        .{ .name = "bench_compare", .module = compare_driver },
    }) catch @panic("OOM");
}

/// Binds a fetched shakedown to the consumer's aegis, so its build links one
/// aegis and shakedown's ids and byte counts are the consumer's own types.
/// Fetch shakedown with `.aegis = .consumer`, so its own pin is not fetched:
///
///     const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
///     @import("shakedown").useAegis(shakedown, aegis.module("aegis"));
///
/// With bay, a package does this in `dev`, where shakedown is `tools.shakedown`.
pub fn useAegis(shakedown: *std.Build.Dependency, aegis: *std.Build.Module) void {
    shakedown.module("shakedown").addImport("aegis", aegis);
}
