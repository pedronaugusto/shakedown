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
