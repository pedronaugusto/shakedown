//! Measuring for test and benchmark programs. Samples are nanoseconds per unit,
//! kept in acquisition order. The clock must be real and monotonic, independently
//! of any clock the workload simulates. No timings are correctness gates.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Provenance supplied by the build or driver. CPU names the selected target
/// CPU model; drivers may supply the physical CPU name instead.
pub const Metadata = struct {
    commit: []const u8,
    zig: []const u8 = builtin.zig_version_string,
    cpu: []const u8 = @tagName(builtin.cpu.arch) ++ "/" ++ builtin.cpu.model.name,
    os: []const u8 = @tagName(builtin.os.tag),
};

/// A JSONL row. Every sample and statistic is ns/unit; throughput is units/s.
pub const Result = struct {
    row: []const u8,
    unit: []const u8,
    samples: []const f64,
    best: f64,
    median: f64,
    p99: f64,
    ops_per_second: f64,
    commit: []const u8,
    zig: []const u8,
    cpu: []const u8,
    os: []const u8,
    /// Workload units in each timed sample. Zero in a smoke row.
    batch: u64,
    clock_resolution_ns: u64,
    smoke: bool = false,
};

/// Summary of positive finite samples; p99 uses nearest rank, median averages
/// the two central samples for an even count.
pub const Statistics = struct { best: f64, median: f64, p99: f64, radius: f64 };
pub const StatisticsError = error{ OutOfMemory, InvalidSamples };
pub fn statistics(gpa: std.mem.Allocator, samples: []const f64) StatisticsError!Statistics {
    if (samples.len == 0) return error.InvalidSamples;
    for (samples) |s| if (!std.math.isFinite(s) or s <= 0 or !std.math.isFinite(1e9 / s)) return error.InvalidSamples;
    const sorted = try gpa.dupe(f64, samples);
    defer gpa.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const middle = sorted.len / 2;
    const median = if (sorted.len % 2 == 0) sorted[middle - 1] / 2 + sorted[middle] / 2 else sorted[middle];
    // ceil(0.99*n)-1, without multiplying n and overflowing.
    const rank = sorted.len - sorted.len / 100 - 1;
    return .{ .best = sorted[0], .median = median, .p99 = sorted[rank], .radius = @max(median - sorted[0], sorted[sorted.len - 1] - median) };
}

/// A named workload. `run` must do exactly `units` units, retain observable
/// results. Optional hooks surround each whole batch (including warmup,
/// calibration and smoke), outside timing, and share the declared error set.
/// Setup owns partial-acquisition cleanup on failure; teardown runs only after
/// successful or omitted setup, even on workload failure. Teardown must release
/// its resources before returning an error. The workload error takes precedence
/// if both workload and teardown fail. Without hooks, run leaves context reusable.
pub fn Row(comptime Context: type, comptime WorkloadError: type) type {
    return struct {
        name: []const u8,
        unit: []const u8,
        initial: u64 = 1,
        smoke: u64 = 1,
        run: *const fn (*Context, u64) WorkloadError!void,
        setup: ?*const fn (*Context) WorkloadError!void = null,
        teardown: ?*const fn (*Context) WorkloadError!void = null,
    };
}

/// The timing policy. Resolution error is at most 1/resolution_multiple of
/// each retained sample. Batching is bounded; an unmeasurable row is an error.
pub const Options = struct {
    smoke: bool = false,
    prefix: []const u8 = "",
    samples: usize = 31,
    warmup: usize = 2,
    minimum: Io.Duration = .fromMilliseconds(1),
    resolution_multiple: u32 = 1000,
    max_batch: u64 = 1 << 40,

    /// The options a benchmark program's arguments ask for, without its
    /// own name: `--smoke` runs each row once, untimed; `--row PREFIX`, or a
    /// bare PREFIX, runs the rows whose names start with it, as preflight's
    /// `bench-ab` passes it.
    pub fn fromArguments(arguments: []const []const u8) error{InvalidOptions}!Options {
        var options: Options = .{};
        var i: usize = 0;
        while (i < arguments.len) : (i += 1) {
            const argument = arguments[i];
            if (std.mem.eql(u8, argument, "--smoke")) {
                options.smoke = true;
            } else if (std.mem.eql(u8, argument, "--row")) {
                i += 1;
                if (i == arguments.len) return error.InvalidOptions;
                options.prefix = arguments[i];
            } else if (std.mem.startsWith(u8, argument, "--")) {
                return error.InvalidOptions;
            } else {
                options.prefix = argument;
            }
        }
        return options;
    }
};
/// Runner failures composed with the workload's declared error set.
pub fn RunError(comptime WorkloadError: type) type {
    return WorkloadError || StatisticsError || Io.Writer.Error || Io.Clock.ResolutionError || error{
        InvalidOptions,
        DuplicateRow,
        ClockUnavailable,
        Unmeasurable,
        NonMonotonicClock,
    };
}
pub fn run(comptime WorkloadError: type, gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, context: anytype, rows: []const Row(std.meta.Child(@TypeOf(context)), WorkloadError), metadata: Metadata, options: Options) RunError(WorkloadError)!void {
    if (metadata.commit.len == 0 or metadata.zig.len == 0 or metadata.cpu.len == 0 or metadata.os.len == 0 or options.samples == 0 or options.warmup == 0 or options.resolution_multiple == 0 or options.minimum.nanoseconds < 0) return error.InvalidOptions;
    for (rows, 0..) |row, i| {
        if (row.name.len == 0 or row.unit.len == 0 or row.initial == 0 or row.smoke == 0 or row.initial > options.max_batch) return error.InvalidOptions;
        for (rows[0..i]) |previous| if (std.mem.eql(u8, previous.name, row.name)) return error.DuplicateRow;
    }
    if (options.smoke) {
        for (rows) |row| {
            if (!std.mem.startsWith(u8, row.name, options.prefix)) continue;
            _ = try invoke(WorkloadError, false, io, context, row, row.smoke);
            try write(writer, .{ .row = row.name, .unit = row.unit, .samples = &.{}, .best = 0, .median = 0, .p99 = 0, .ops_per_second = 0, .commit = metadata.commit, .zig = metadata.zig, .cpu = metadata.cpu, .os = metadata.os, .batch = 0, .clock_resolution_ns = 0, .smoke = true });
        }
        return;
    }
    const resolution = (try Io.Clock.awake.resolution(io)).nanoseconds;
    if (resolution <= 0 or resolution > std.math.maxInt(u64)) return error.ClockUnavailable;
    const target = @max(options.minimum.nanoseconds, std.math.mul(i96, resolution, options.resolution_multiple) catch return error.InvalidOptions);
    const samples = try gpa.alloc(f64, options.samples);
    defer gpa.free(samples);
    for (rows) |row| {
        if (!std.mem.startsWith(u8, row.name, options.prefix)) continue;
        var batch = row.initial;
        for (0..options.warmup) |_| _ = try invoke(WorkloadError, false, io, context, row, batch);
        // Calibration is discarded, as is an entire sample set if its fastest
        // batch reveals that calibration was distorted by a cold cache.
        while (true) {
            const elapsed = try invoke(WorkloadError, true, io, context, row, batch);
            if (elapsed < target) {
                batch = try larger(batch, options.max_batch);
                continue;
            }
            var resolved = true;
            for (samples) |*sample| {
                const ns = try invoke(WorkloadError, true, io, context, row, batch);
                if (ns < target) {
                    resolved = false;
                    break;
                }
                sample.* = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(batch));
            }
            if (!resolved) {
                batch = try larger(batch, options.max_batch);
                continue;
            }
            const stats = try statistics(gpa, samples);
            try write(writer, .{ .row = row.name, .unit = row.unit, .samples = samples, .best = stats.best, .median = stats.median, .p99 = stats.p99, .ops_per_second = 1e9 / stats.median, .commit = metadata.commit, .zig = metadata.zig, .cpu = metadata.cpu, .os = metadata.os, .batch = batch, .clock_resolution_ns = @intCast(resolution) });
            try writer.flush();
            break;
        }
    }
}
fn larger(batch: u64, limit: u64) error{Unmeasurable}!u64 {
    if (batch >= limit) return error.Unmeasurable;
    return batch + @min(batch, limit - batch);
}
fn invoke(comptime WorkloadError: type, comptime timed: bool, io: Io, context: anytype, row: Row(std.meta.Child(@TypeOf(context)), WorkloadError), batch: u64) RunError(WorkloadError)!i96 {
    if (row.setup) |setup| try setup(context);
    const start = if (timed) Io.Timestamp.now(io, .awake) else Io.Timestamp.fromNanoseconds(0);
    row.run(context, batch) catch |err| {
        // Cleanup is attempted exactly once. Preserve the original workload
        // error if cleanup also fails; teardown owns release on either outcome.
        if (row.teardown) |teardown| teardown(context) catch return err;
        return err;
    };
    const elapsed = if (timed) start.durationTo(.now(io, .awake)).nanoseconds else 0;
    if (row.teardown) |teardown| try teardown(context);
    if (elapsed < 0) return error.NonMonotonicClock;
    return elapsed;
}
pub const WriteError = Io.Writer.Error;
/// Writes one complete JSON line, escaping workload names and provenance.
pub fn write(writer: *Io.Writer, result: Result) WriteError!void {
    try std.json.Stringify.value(result, .{}, writer);
    try writer.writeByte('\n');
}

/// Two runs compared using observed sample variation, not a hypothesis test.
/// Noise is the sum of their largest deviations from the median. A flag says
/// the median change exceeds that conservative observed band, never pass/fail.
pub const Change = struct { row: []const u8, unit: []const u8, percent: f64, noise_percent: f64, sufficient_samples: bool, beyond_noise: bool };
pub const CompareError = StatisticsError || error{ IncompatibleRows, SmokeRun };
pub fn compare(gpa: std.mem.Allocator, before: Result, after: Result) CompareError!Change {
    if (!std.mem.eql(u8, before.row, after.row) or !std.mem.eql(u8, before.unit, after.unit) or !std.mem.eql(u8, before.cpu, after.cpu) or !std.mem.eql(u8, before.os, after.os)) return error.IncompatibleRows;
    if (before.smoke or after.smoke) return error.SmokeRun;
    const a = try statistics(gpa, before.samples);
    const b = try statistics(gpa, after.samples);
    const delta = b.median - a.median;
    const noise = a.radius + b.radius;
    const percent = delta / a.median * 100;
    const noise_percent = noise / a.median * 100;
    if (!std.math.isFinite(percent) or !std.math.isFinite(noise_percent)) return error.InvalidSamples;
    const enough = before.samples.len >= 3 and after.samples.len >= 3;
    return .{ .row = before.row, .unit = before.unit, .percent = percent, .noise_percent = noise_percent, .sufficient_samples = enough, .beyond_noise = enough and @abs(delta) > noise };
}

/// An owned, validated run; strings and samples borrow the JSON parse trees.
pub const Run = struct {
    gpa: std.mem.Allocator,
    rows: std.ArrayList(std.json.Parsed(Result)) = .empty,
    pub fn deinit(self: *Run) void {
        for (self.rows.items) |*row| row.deinit();
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }
};
pub const ParseError = error{ OutOfMemory, InvalidRun, DuplicateRow };
/// Parses JSONL with bounded input supplied by the driver. Declared statistics
/// must agree exactly with the samples; malformed or duplicate rows fail.
pub fn parse(gpa: std.mem.Allocator, jsonl: []const u8) ParseError!Run {
    var result: Run = .{ .gpa = gpa };
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(Result, gpa, line, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidRun,
        };
        errdefer parsed.deinit();
        const r = parsed.value;
        if (r.row.len == 0 or r.unit.len == 0 or r.commit.len == 0 or r.cpu.len == 0 or r.os.len == 0 or r.zig.len == 0) return error.InvalidRun;
        if (r.smoke) {
            if (r.samples.len != 0 or r.batch != 0 or r.best != 0 or r.median != 0 or r.p99 != 0 or r.ops_per_second != 0 or r.clock_resolution_ns != 0) return error.InvalidRun;
        } else {
            const stats = statistics(gpa, r.samples) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidRun,
            };
            if (r.batch == 0 or r.clock_resolution_ns == 0 or r.best != stats.best or r.median != stats.median or r.p99 != stats.p99 or r.ops_per_second != 1e9 / stats.median) return error.InvalidRun;
        }
        for (result.rows.items) |row| if (std.mem.eql(u8, row.value.row, r.row)) return error.DuplicateRow;
        try result.rows.append(gpa, parsed);
    }
    if (result.rows.items.len == 0) return error.InvalidRun;
    return result;
}
