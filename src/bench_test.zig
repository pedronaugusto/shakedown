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

const HookError = error{ SetupFailed, WorkloadFailed, TeardownFailed, OutOfMemory };
const HookWork = struct {
    clock: *Clock,
    gpa: std.mem.Allocator = std.testing.allocator,
    resource: ?[]u8 = null,
    events: [128]u8 = undefined,
    event_count: usize = 0,
    setups: usize = 0,
    calls: usize = 0,
    teardowns: usize = 0,
    units: u64 = 0,
    fast_call: usize = 0,
    fail_setup: usize = 0,
    fail_run: usize = 0,
    fail_teardown: usize = 0,

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
    }
    fn run(self: *HookWork, units: u64) error{WorkloadFailed}!void {
        self.event('w');
        self.calls += 1;
        self.units += units;
        std.debug.assert(self.resource != null);
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
const hook_rows = [_]bench.Row(HookWork, HookError){.{ .name = "hooks", .unit = "op", .run = HookWork.run, .setup = HookWork.setup, .teardown = HookWork.teardown }};

comptime {
    const R = bench.Row(HookWork, HookError);
    for (.{ @TypeOf(@as(R, undefined).run), std.meta.Child(@TypeOf(@as(R, undefined).setup)), std.meta.Child(@TypeOf(@as(R, undefined).teardown)) }) |Callback| {
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

test "bench hooks can each be omitted independently" {
    var clock: Clock = .init(std.testing.io, .{ .resolution = .zero });
    var work: HookWork = .{ .clock = &clock };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var row = hook_rows[0];
    row.teardown = null;
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{row}, metadata, .{ .smoke = true });
    try std.testing.expectEqualStrings("sw", work.events[0..work.event_count]);
    // Without teardown the driver owns the successful setup's resource.
    defer if (work.resource) |resource| work.gpa.free(resource);
    row.setup = null;
    row.teardown = HookWork.teardown;
    try bench.run(HookError, std.testing.allocator, clock.io(), &output.writer, &work, &.{row}, metadata, .{ .smoke = true });
    try std.testing.expectEqualStrings("swwt", work.events[0..work.event_count]);
    try std.testing.expect(work.resource == null);
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
