const std = @import("std");
const bench = @import("bench.zig");

test "bench statistics retain order and use nearest-rank p99" {
    const samples = [_]f64{ 7, 1, 5, 3, 9, 2 };
    const stats = try bench.statistics(std.testing.allocator, &samples);
    try std.testing.expectEqual(@as(f64, 1), stats.best);
    try std.testing.expectEqual(@as(f64, 4), stats.median);
    try std.testing.expectEqual(@as(f64, 9), stats.p99);
    try std.testing.expectEqual(@as(f64, 7), samples[0]);
    try std.testing.expectError(error.InvalidSamples, bench.statistics(std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidSamples, bench.statistics(std.testing.allocator, &.{0}));
    try std.testing.expectError(error.InvalidSamples, bench.statistics(std.testing.allocator, &.{std.math.nan(f64)}));
}

const Clock = @import("Clock.zig");
const corpus = @import("corpus.zig");
const FaultIo = @import("FaultIo.zig");
const Work = struct {
    clock: *Clock,
    calls: usize = 0,
    units: u64 = 0,
    fn run(self: *Work, units: u64) error{}!void {
        self.calls += 1;
        self.units += units;
        self.clock.advance(.fromNanoseconds(@intCast(units * 10)));
    }
};
const rows = [_]bench.Row(Work, error{}){.{ .name = "quoted\"\nrow", .unit = "op", .smoke = 3, .run = Work.run }};
const metadata: bench.Metadata = .{ .commit = "commit\"\n", .zig = "zig", .cpu = "cpu", .os = "os" };

test "bench warms up and batches above clock resolution, retaining JSONL provenance" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: Work = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(error{}, std.testing.allocator, clock.io(), &output.writer, &work, &rows, metadata, .{ .samples = 3, .minimum = .zero });
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    const r = parsed.rows.items[0].value;
    try std.testing.expectEqual(@as(u64, 128), r.batch);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10 }, r.samples);
    try std.testing.expectEqualStrings(rows[0].name, r.row);
    try std.testing.expectEqualStrings(metadata.commit, r.commit);
    try std.testing.expectEqual(@as(usize, 13), work.calls);
    try std.testing.expectEqual(@as(u64, 641), work.units);
}

test "bench smoke runs each selected workload once without a clock or calibration" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .zero });
    var work: Work = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(error{}, std.testing.allocator, clock.io(), &output.writer, &work, &rows, metadata, .{ .smoke = true });
    try std.testing.expectEqual(@as(usize, 1), work.calls);
    try std.testing.expectEqual(@as(u64, 3), work.units);
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    try std.testing.expect(parsed.rows.items[0].value.smoke);
    try std.testing.expectError(error.SmokeRun, bench.compare(std.testing.allocator, parsed.rows.items[0].value, parsed.rows.items[0].value));
    try std.testing.expectError(error.ClockUnavailable, bench.run(error{}, std.testing.allocator, clock.io(), &output.writer, &work, &rows, metadata, .{}));
}

test "bench refuses an unresolved batch and duplicate rows, and filters prefixes" {
    var clock: Clock = .init(std.testing.io, .{});
    var work: Work = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.Unmeasurable, bench.run(error{}, std.testing.allocator, clock.io(), &output.writer, &work, &rows, metadata, .{ .max_batch = 8 }));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try std.testing.expectError(error.DuplicateRow, bench.run(error{}, std.testing.allocator, clock.io(), &output.writer, &work, &.{ rows[0], rows[0] }, metadata, .{}));
    const calls = work.calls;
    try bench.run(error{}, std.testing.allocator, clock.io(), &output.writer, &work, &rows, metadata, .{ .smoke = true, .prefix = "absent" });
    try std.testing.expectEqual(calls, work.calls);
}

fn fixture(samples: []const f64) !bench.Result {
    const stats = try bench.statistics(std.testing.allocator, samples);
    return .{ .row = "row", .unit = "op", .samples = samples, .best = stats.best, .median = stats.median, .p99 = stats.p99, .ops_per_second = 1e9 / stats.median, .commit = "commit", .zig = "zig", .cpu = "cpu", .os = "os", .batch = 1, .clock_resolution_ns = 1 };
}

test "bench options come from a program's arguments, as bench-ab passes them" {
    const none = try bench.Options.fromArguments(&.{});
    try std.testing.expect(!none.smoke);
    try std.testing.expectEqualStrings("", none.prefix);
    const smoke = try bench.Options.fromArguments(&.{"--smoke"});
    try std.testing.expect(smoke.smoke);
    const row = try bench.Options.fromArguments(&.{ "--row", "sim/" });
    try std.testing.expectEqualStrings("sim/", row.prefix);
    const bare = try bench.Options.fromArguments(&.{ "--smoke", "net/" });
    try std.testing.expect(bare.smoke);
    try std.testing.expectEqualStrings("net/", bare.prefix);
    try std.testing.expectError(error.InvalidOptions, bench.Options.fromArguments(&.{"--row"}));
    try std.testing.expectError(error.InvalidOptions, bench.Options.fromArguments(&.{"--rows"}));
}

test "bench comparison flags either direction only beyond observed variation" {
    const before = try fixture(&.{ 99, 100, 101 });
    const after = try fixture(&.{ 119, 120, 121 });
    const up = try bench.compare(std.testing.allocator, before, after);
    try std.testing.expectEqual(@as(f64, 20), up.percent);
    try std.testing.expectEqual(@as(f64, 2), up.noise_percent);
    try std.testing.expect(up.beyond_noise);
    const down = try bench.compare(std.testing.allocator, after, before);
    try std.testing.expect(down.percent < 0 and down.beyond_noise);
    const noisy = try fixture(&.{ 90, 101, 150 });
    try std.testing.expect(!(try bench.compare(std.testing.allocator, before, noisy)).beyond_noise);
    var wrong = after;
    wrong.unit = "byte";
    try std.testing.expectError(error.IncompatibleRows, bench.compare(std.testing.allocator, before, wrong));
    wrong = after;
    wrong.os = "another";
    try std.testing.expectError(error.IncompatibleRows, bench.compare(std.testing.allocator, before, wrong));
}

test "bench serialization round trips and rejects inconsistent or duplicate rows" {
    const row = try fixture(&.{ 99, 100, 101 });
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.write(&output.writer, row);
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    try std.testing.expectEqualDeep(row, parsed.rows.items[0].value);
    try bench.write(&output.writer, row);
    try std.testing.expectError(error.DuplicateRow, bench.parse(std.testing.allocator, output.written()));
    var bad = row;
    bad.median = 200;
    var invalid: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid.deinit();
    try bench.write(&invalid.writer, bad);
    try std.testing.expectError(error.InvalidRun, bench.parse(std.testing.allocator, invalid.written()));
    try std.testing.expectError(error.InvalidRun, bench.parse(std.testing.allocator, "{}\n"));
    try std.testing.expectError(error.InvalidRun, bench.parse(std.testing.allocator, "\n"));
}

test "bench p99 is the 99th sorted observation of a hundred" {
    var samples: [100]f64 = undefined;
    for (&samples, 0..) |*s, i| s.* = @floatFromInt(i + 1);
    const stats = try bench.statistics(std.testing.allocator, &samples);
    try std.testing.expectEqual(@as(f64, 50.5), stats.median);
    try std.testing.expectEqual(@as(f64, 99), stats.p99);
}

test "bench a single observation has insufficient noise evidence" {
    const change = try bench.compare(std.testing.allocator, try fixture(&.{100}), try fixture(&.{200}));
    try std.testing.expectEqual(@as(f64, 100), change.percent);
    try std.testing.expect(!change.sufficient_samples and !change.beyond_noise);
}

fn parseAllocationCase(gpa: std.mem.Allocator, jsonl: []const u8) !void {
    var run = try bench.parse(gpa, jsonl);
    defer run.deinit();
}

test "bench parse owns rows through every allocation failure" {
    const row = try fixture(&.{ 1, 2, 3 });
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.write(&output.writer, row);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAllocationCase, .{output.written()});
}

const FailingWork = struct {
    fn run(_: *FailingWork, _: u64) error{WorkloadFailed}!void {
        return error.WorkloadFailed;
    }
};
test "bench callbacks retain finite workload errors in runner composition" {
    const E = error{WorkloadFailed};
    const Callback = @TypeOf(@as(bench.Row(FailingWork, E), undefined).run);
    comptime std.debug.assert(@typeInfo(@typeInfo(@typeInfo(Callback).pointer.child).@"fn".return_type.?).error_union.error_set == E);
    comptime std.debug.assert(bench.RunError(E) != anyerror);
    var work: FailingWork = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const failing_rows = [_]bench.Row(FailingWork, E){.{ .name = "failure", .unit = "op", .run = FailingWork.run }};
    try std.testing.expectError(error.WorkloadFailed, bench.run(E, std.testing.allocator, std.testing.io, &out.writer, &work, &failing_rows, metadata, .{ .smoke = true }));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

const HookError = error{ SetupFailed, StageFailed, WorkloadFailed, SettleFailed, TeardownFailed, OutOfMemory };
/// Every hook records its letter: s setup, g stage, w run, l settle, t teardown.
/// The fixture is a resource that exists between setup and teardown, and a
/// stage is a state that exists between it and its settle.
const HookWork = struct {
    clock: *Clock,
    gpa: std.mem.Allocator = std.testing.allocator,
    resource: ?[]u8 = null,
    events: [256]u8 = undefined,
    event_count: usize = 0,
    setups: usize = 0,
    stages: usize = 0,
    calls: usize = 0,
    settles: usize = 0,
    teardowns: usize = 0,
    units: u64 = 0,
    fast_call: usize = 0,
    fail_setup: usize = 0,
    fail_stage: usize = 0,
    fail_run: usize = 0,
    fail_settle: usize = 0,
    fail_teardown: usize = 0,
    /// Whether a run must find itself staged.
    expect_stage: bool = false,
    staged: bool = false,
    /// What the workload leaves in its fixture across batches: kept by a row
    /// lifetime, gone with a batch lifetime's fixture.
    warmth: u64 = 0,
    /// The units of the batch that is staged.
    staged_units: u64 = 0,

    fn event(self: *HookWork, value: u8) void {
        self.events[self.event_count] = value;
        self.event_count += 1;
    }
    fn setup(self: *HookWork) error{ SetupFailed, OutOfMemory }!void {
        self.event('s');
        self.setups += 1;
        std.debug.assert(self.resource == null);
        const resource = try self.gpa.alloc(u8, 1);
        errdefer self.gpa.free(resource);
        self.clock.advance(.fromNanoseconds(10_000));
        if (self.setups == self.fail_setup) return error.SetupFailed;
        self.resource = resource;
        self.warmth = 0;
    }
    fn stage(self: *HookWork, units: u64) error{StageFailed}!void {
        self.event('g');
        self.stages += 1;
        std.debug.assert(self.resource != null);
        std.debug.assert(!self.staged);
        self.clock.advance(.fromNanoseconds(5_000));
        if (self.stages == self.fail_stage) return error.StageFailed;
        self.staged = true;
        self.staged_units = units;
    }
    fn settle(self: *HookWork, units: u64) error{SettleFailed}!void {
        self.event('l');
        self.settles += 1;
        std.debug.assert(self.staged);
        std.debug.assert(self.staged_units == units);
        self.staged = false;
        self.clock.advance(.fromNanoseconds(7_000));
        if (self.settles == self.fail_settle) return error.SettleFailed;
    }
    fn run(self: *HookWork, units: u64) error{WorkloadFailed}!void {
        self.event('w');
        self.calls += 1;
        self.units += units;
        self.warmth += 1;
        std.debug.assert(self.resource != null);
        if (self.expect_stage) {
            std.debug.assert(self.staged);
            std.debug.assert(self.staged_units == units);
        }
        // safe: the fixture's bounded batches cannot overflow i64.
        self.clock.advance(.fromNanoseconds(if (self.calls == self.fast_call) 0 else @intCast(units * 10)));
        if (self.calls == self.fail_run) return error.WorkloadFailed;
    }
    fn teardown(self: *HookWork) error{TeardownFailed}!void {
        self.event('t');
        self.teardowns += 1;
        self.gpa.free(self.resource.?);
        self.resource = null;
        self.clock.advance(.fromNanoseconds(20_000));
        if (self.teardowns == self.fail_teardown) return error.TeardownFailed;
    }
};
const HookRow = bench.Row(HookWork, HookError);
/// The fixture of every batch, as the tests below count it.
const hook_rows = [_]HookRow{.{ .name = "hooks", .unit = "op", .run = HookWork.run, .fixture = .{ .lifetime = .batch, .setup = HookWork.setup, .teardown = HookWork.teardown } }};
/// The same fixture, built once for the row, and a stage and a settle per batch.
const kept_row: HookRow = .{ .name = "hooks", .unit = "op", .run = HookWork.run, .fixture = .{ .lifetime = .row, .setup = HookWork.setup, .teardown = HookWork.teardown } };
const staged_row: HookRow = .{ .name = "hooks", .unit = "op", .run = HookWork.run, .fixture = kept_row.fixture, .stage = HookWork.stage, .settle = HookWork.settle };

comptime {
    for (.{ @TypeOf(@as(HookRow, undefined).run), HookRow.Hook, std.meta.Child(@TypeOf(@as(HookRow.Fixture, undefined).teardown)), std.meta.Child(@TypeOf(@as(HookRow, undefined).stage)), std.meta.Child(@TypeOf(@as(HookRow, undefined).settle)) }) |Callback| {
        std.debug.assert(@typeInfo(@typeInfo(@typeInfo(Callback).pointer.child).@"fn".return_type.?).error_union.error_set == HookError);
    }
    std.debug.assert(bench.RunError(HookError) == bench.RunError(error{}) || HookError);
    std.debug.assert(bench.RunError(HookError) != anyerror);
}

test "bench hooks exclude setup and teardown from every whole sample batch" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &hook_rows, metadata, .{ .samples = 3, .minimum = .zero });
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    const r = parsed.rows.items[0].value;
    try std.testing.expectEqual(@as(u64, 128), r.batch);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10 }, r.samples);
    try std.testing.expectEqual(@as(usize, 13), work.calls);
    try std.testing.expectEqual(@as(u64, 641), work.units);
    try std.testing.expectEqual(work.calls, work.setups);
    try std.testing.expectEqual(work.calls, work.teardowns);
    try std.testing.expectEqualStrings(corpus.repeat("swt", 13), work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
    // Same calibration, samples, counts and units as the omitted-hook fixture.
    try std.testing.expectEqual(@as(i96, 13 * 30_000 + 641 * 10), std.Io.Timestamp.fromNanoseconds(1_000_000_000).durationTo(.now(clock.io(), .awake)).nanoseconds);
}

test "bench hook errors preserve originals and release ownership on callback failure" {
    const Phase = struct { smoke: bool, failure: usize };
    for ([_]Phase{ .{ .smoke = true, .failure = 1 }, .{ .smoke = false, .failure = 1 }, .{ .smoke = false, .failure = 2 }, .{ .smoke = false, .failure = 3 } }) |phase| {
        const smoke = phase.smoke;
        const failure = phase.failure;
        for (0..4) |case| {
            var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
            var work: HookWork = .{ .clock = &clock };
            const expected: HookError = switch (case) {
                0 => blk: {
                    work.fail_setup = failure;
                    break :blk error.SetupFailed;
                },
                1, 3 => blk: {
                    work.fail_run = failure;
                    if (case == 3) work.fail_teardown = failure;
                    break :blk error.WorkloadFailed;
                },
                2 => blk: {
                    work.fail_teardown = failure;
                    break :blk error.TeardownFailed;
                },
                else => unreachable,
            };
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();
            try std.testing.expectError(expected, bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &hook_rows, metadata, .{ .smoke = smoke, .warmup = 1, .samples = 1, .minimum = .zero, .resolution_multiple = 1 }));
            try std.testing.expect(work.resource == null);
            try std.testing.expectEqual(@as(usize, 0), output.written().len);
            try std.testing.expectEqual(failure, work.setups);
            try std.testing.expectEqual(failure - @intFromBool(case == 0), work.calls);
            try std.testing.expectEqual(work.calls, work.teardowns);
            for (0..failure - 1) |i| try std.testing.expectEqualStrings("swt", work.events[i * 3 ..][0..3]);
            try std.testing.expectEqualStrings(if (case == 0) "s" else "swt", work.events[(failure - 1) * 3 .. work.event_count]);
        }
    }
}

test "bench hooks release ownership before runner rejects an unresolved batch" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.Unmeasurable, bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &hook_rows, metadata, .{ .max_batch = 8, .minimum = .zero }));
    try std.testing.expectEqualStrings("swtswtswtswtswtswt", work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
}

test "bench hooks preserve alternating base candidate sample acquisition order" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var works = [_]HookWork{ .{ .clock = &clock }, .{ .clock = &clock } };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    for (0..7) |pair| {
        const first = pair % 2;
        for ([_]usize{ first, 1 - first }) |side| {
            const before = works[side].event_count;
            const other_calls = works[1 - side].calls;
            var provenance = metadata;
            provenance.commit = if (side == 0) "base" else "candidate";
            try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &works[side], &hook_rows, provenance, .{ .samples = 1, .warmup = 1, .minimum = .zero, .resolution_multiple = 1 });
            try std.testing.expectEqualStrings("swtswtswt", works[side].events[before..works[side].event_count]);
            try std.testing.expectEqual(other_calls, works[1 - side].calls);
        }
    }
    // Each invocation emits immediately; no regrouping by base/candidate.
    var lines = std.mem.tokenizeScalar(u8, output.written(), '\n');
    for (0..7) |pair| {
        for ([_]usize{ pair % 2, 1 - pair % 2 }) |side| {
            var parsed = try bench.parse(std.testing.allocator, lines.next().?);
            defer parsed.deinit();
            const r = parsed.rows.items[0].value;
            try std.testing.expectEqualStrings(if (side == 0) "base" else "candidate", r.commit);
            try std.testing.expectEqualSlices(f64, &.{10}, r.samples);
        }
    }
    try std.testing.expect(lines.next() == null);
    for (works) |work| try std.testing.expect(work.resource == null);
}

fn hookAllocationCase(gpa: std.mem.Allocator) !void {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .gpa = gpa };
    defer std.debug.assert(work.resource == null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, gpa, clock.io(), &output.writer, &work, &hook_rows, metadata, .{ .samples = 1, .warmup = 1, .minimum = .zero, .resolution_multiple = 1 });
}

test "bench hooks and runner release owned allocations on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, hookAllocationCase, .{});
}

test "bench a fixture can go without teardown, and stages without a fixture" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .zero });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var row = hook_rows[0];
    row.fixture.?.teardown = null;
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{row}, metadata, .{ .smoke = true });
    try std.testing.expectEqualStrings("sw", work.events[0..work.event_count]);
    // Without teardown the driver owns the successful setup's resource.
    defer if (work.resource) |resource| work.gpa.free(resource);
    // A stage and a settle need no fixture: the resource is the one the first
    // run left.
    row.fixture = null;
    row.stage = HookWork.stage;
    row.settle = HookWork.settle;
    work.expect_stage = true;
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{row}, metadata, .{ .smoke = true });
    try std.testing.expectEqualStrings("swgwl", work.events[0..work.event_count]);
}

test "bench hooks release resources before writer failure" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, bench.run(HookError, std.testing.allocator, clock.io(), &output, &work, &hook_rows, metadata, .{ .samples = 1, .warmup = 1, .minimum = .zero, .resolution_multiple = 1 }));
    try std.testing.expectEqualStrings("swtswtswt", work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
}

test "bench hooks also surround discarded samples without changing calibration" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .fast_call = 3 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &hook_rows, metadata, .{ .samples = 3, .warmup = 1, .minimum = .zero, .resolution_multiple = 1 });
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed.rows.items[0].value.batch);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10 }, parsed.rows.items[0].value.samples);
    try std.testing.expectEqual(@as(u64, 11), work.units);
    try std.testing.expectEqualStrings(corpus.repeat("swt", 7), work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
}

const FailingSample = struct {
    calls: usize = 0,
    fn run(self: *FailingSample, _: u64) error{WorkloadFailed}!void {
        self.calls += 1;
        if (self.calls == 2) return error.WorkloadFailed;
    }
};

test "bench failed timed callbacks preserve the original clock read count" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    const fio = try FaultIo.init(std.testing.allocator, clock.io(), .{});
    defer fio.deinit();
    var work: FailingSample = .{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const failing_rows = [_]bench.Row(FailingSample, error{WorkloadFailed}){.{ .name = "failure", .unit = "op", .run = FailingSample.run }};
    try std.testing.expectError(error.WorkloadFailed, bench.run(error{WorkloadFailed}, std.testing.allocator, fio.io(), &output.writer, &work, &failing_rows, metadata, .{ .warmup = 1, .samples = 1, .minimum = .zero }));
    try std.testing.expectEqual(@as(u64, 1), fio.count(.now));
    try std.testing.expectEqual(@as(usize, 2), work.calls);
}

test "bench hooks keep clock reads outside warmup smoke and cleanup" {
    for ([_]bool{ true, false }) |smoke| {
        for ([_]usize{ 0, 2 }) |fail_run| {
            var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
            const fio = try FaultIo.init(std.testing.allocator, clock.io(), .{});
            defer fio.deinit();
            var work: HookWork = .{ .clock = &clock, .fail_run = fail_run };
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();
            const outcome = bench.run(HookError, std.testing.allocator, fio.io(), &output.writer, &work, &hook_rows, metadata, .{ .smoke = smoke, .warmup = 1, .samples = 1, .minimum = .zero, .resolution_multiple = 1 });
            if (!smoke and fail_run != 0) {
                try std.testing.expectError(error.WorkloadFailed, outcome);
            } else {
                try outcome;
            }
            try std.testing.expectEqual(@as(u64, if (smoke) 0 else if (fail_run != 0) 1 else 4), fio.count(.now));
            try std.testing.expectEqual(work.calls, work.teardowns);
            try std.testing.expect(work.resource == null);
        }
    }
}

const sampling: bench.Options = .{ .samples = 3, .minimum = .zero };
/// The nanoseconds a run of the hook fixture leaves on the clock: every hook of
/// a batch has its cost, and only the run's is timed.
fn elapsed(clock: *Clock) i96 {
    return std.Io.Timestamp.fromNanoseconds(1_000_000_000).durationTo(.now(clock.io(), .awake)).nanoseconds;
}

test "bench keeps a row's fixture across warmup, calibration and every sample" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{kept_row}, metadata, sampling);
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    const r = parsed.rows.items[0].value;
    // The same calibration and samples as a fixture of every batch.
    try std.testing.expectEqual(@as(u64, 128), r.batch);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10 }, r.samples);
    try std.testing.expectEqual(@as(usize, 13), work.calls);
    try std.testing.expectEqual(@as(usize, 1), work.setups);
    try std.testing.expectEqual(@as(usize, 1), work.teardowns);
    // What a batch left in the fixture is there for the next.
    try std.testing.expectEqual(@as(u64, 13), work.warmth);
    try std.testing.expectEqualStrings("s" ++ corpus.repeat("w", 13) ++ "t", work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
    try std.testing.expectEqual(@as(i96, 30_000 + 641 * 10), elapsed(&clock));
}

test "bench builds a batch's fixture for that batch alone" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &hook_rows, metadata, sampling);
    // The last batch's fixture met one run, none of the 12 before it.
    try std.testing.expectEqual(@as(u64, 1), work.warmth);
    try std.testing.expectEqual(@as(usize, 13), work.setups);
}

test "bench stages and settles every batch outside the clock" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .expect_stage = true };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{staged_row}, metadata, sampling);
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    const r = parsed.rows.items[0].value;
    try std.testing.expectEqual(@as(u64, 128), r.batch);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10 }, r.samples);
    try std.testing.expectEqualStrings("s" ++ corpus.repeat("gwl", 13) ++ "t", work.events[0..work.event_count]);
    try std.testing.expectEqual(@as(i96, 30_000 + 13 * 12_000 + 641 * 10), elapsed(&clock));
}

test "bench smoke stages and settles once around the one run of a kept fixture" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .zero });
    var work: HookWork = .{ .clock = &clock, .expect_stage = true };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{staged_row}, metadata, .{ .smoke = true });
    try std.testing.expectEqualStrings("sgwlt", work.events[0..work.event_count]);
    work.expect_stage = false;
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{kept_row}, metadata, .{ .smoke = true });
    try std.testing.expectEqualStrings("sgwltswt", work.events[0..work.event_count]);
}

test "bench rows keep their fixtures one after the other" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var second = kept_row;
    second.name = "second";
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{ kept_row, second }, metadata, sampling);
    try std.testing.expectEqualStrings("s" ++ corpus.repeat("w", 13) ++ "t" ++ "s" ++ corpus.repeat("w", 13) ++ "t", work.events[0..work.event_count]);
    // The second row did not meet what the first left.
    try std.testing.expectEqual(@as(u64, 13), work.warmth);
}

test "bench hooks of a kept fixture and a stage own their failures in turn" {
    // The batch that fails, among the warmup (1) and the calibration (2, 3).
    inline for (.{ 1, 2, 3 }) |k| {
        const before = "s" ++ corpus.repeat("gwl", k - 1);
        inline for (.{
            .{ "stage", error.StageFailed, "gt" },
            .{ "run", error.WorkloadFailed, "gwlt" },
            .{ "settle", error.SettleFailed, "gwlt" },
            // The first failure is the one returned, and the rest still ran.
            .{ "run and settle", error.WorkloadFailed, "gwlt" },
            .{ "settle and teardown", error.SettleFailed, "gwlt" },
        }) |c| {
            var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
            var work: HookWork = .{ .clock = &clock, .expect_stage = true };
            if (comptime std.mem.find(u8, c[0], "stage") != null) work.fail_stage = k;
            if (comptime std.mem.find(u8, c[0], "run") != null) work.fail_run = k;
            if (comptime std.mem.find(u8, c[0], "settle") != null) work.fail_settle = k;
            if (comptime std.mem.find(u8, c[0], "teardown") != null) work.fail_teardown = 1;
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();
            try std.testing.expectError(c[1], bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{staged_row}, metadata, .{ .warmup = 1, .samples = 1, .minimum = .zero, .resolution_multiple = 1 }));
            try std.testing.expectEqualStrings(before ++ c[2], work.events[0..work.event_count]);
            try std.testing.expectEqual(@as(usize, 0), output.written().len);
            try std.testing.expect(work.resource == null);
            try std.testing.expect(!work.staged);
            try std.testing.expectEqual(@as(usize, 1), work.teardowns);
        }
    }
}

test "bench setup of a kept fixture owns its failure, and its teardown can fail alone" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .fail_setup = 1 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.SetupFailed, bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{staged_row}, metadata, sampling));
    try std.testing.expectEqualStrings("s", work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
    // A teardown that fails after the row was measured leaves no row.
    work = .{ .clock = &clock, .fail_teardown = 1 };
    try std.testing.expectError(error.TeardownFailed, bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{kept_row}, metadata, sampling));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try std.testing.expect(work.resource == null);
    try std.testing.expectEqual(@as(u8, 't'), work.events[work.event_count - 1]);
}

test "bench releases a kept fixture before it rejects an unresolved batch" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.Unmeasurable, bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{kept_row}, metadata, .{ .max_batch = 8, .minimum = .zero }));
    try std.testing.expectEqualStrings("s" ++ corpus.repeat("w", 6) ++ "t", work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
}

test "bench holds a row that cannot grow to one batch and the clock's resolution" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .expect_stage = true };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var row = staged_row;
    row.grow = false;
    row.initial = 4;
    // `minimum` is what growth aims at: a sample of four units is read as it is.
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{row}, metadata, .{ .samples = 3, .warmup = 1, .minimum = .fromSeconds(1), .resolution_multiple = 40 });
    var parsed = try bench.parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 4), parsed.rows.items[0].value.batch);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10 }, parsed.rows.items[0].value.samples);
    // The warmup and the samples; there is no calibration to grow by.
    try std.testing.expectEqual(@as(usize, 4), work.calls);
    try std.testing.expectEqual(@as(u64, 16), work.units);
    try std.testing.expectEqualStrings("s" ++ corpus.repeat("gwl", 4) ++ "t", work.events[0..work.event_count]);
}

test "bench refuses a sample of a row that cannot grow when it is too short to read" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .expect_stage = true };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var row = staged_row;
    row.grow = false;
    // 4 units are 40 ns: under 50 resolutions.
    try std.testing.expectError(error.Unmeasurable, bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{row}, metadata, .{ .samples = 3, .warmup = 1, .minimum = .zero, .resolution_multiple = 50 }));
    try std.testing.expectEqualStrings("s" ++ corpus.repeat("gwl", 2) ++ "t", work.events[0..work.event_count]);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try std.testing.expect(work.resource == null);
}

fn stagedAllocationCase(gpa: std.mem.Allocator) !void {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .fromNanoseconds(1) });
    var work: HookWork = .{ .clock = &clock, .gpa = gpa, .expect_stage = true };
    defer std.debug.assert(work.resource == null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bench.run(HookError, gpa, clock.io(), &output.writer, &work, &.{staged_row}, metadata, .{ .samples = 1, .warmup = 1, .minimum = .zero, .resolution_multiple = 1 });
}

test "bench stages and a kept fixture release owned allocations on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagedAllocationCase, .{});
}
