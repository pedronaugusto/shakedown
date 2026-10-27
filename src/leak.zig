//! Timing-leak tests: does how long an operation takes depend on its secret input? Two classes
//! of input, a fixed one and random ones, are measured interleaved in a random order and compared
//! with Welch's t-test, uncropped, cropped at a hundred percentiles and in second order (dudect:
//! Reparaz, Balasch and Verbauwhede, "Dude, is my code constant time?", 2017). A large |t| says
//! the time depends on the class.
//!
//! Run it on the build that ships: a compiler can turn constant-time source into a branch, and
//! only the built code shows it. A run finds a leak with some confidence; it never proves there is
//! none, and what it can see is bounded by its measurements and the clock's resolution (`batch`
//! repeats a call within one measurement to rise above it).
const std = @import("std");
const Io = std.Io;
const nanoseconds = @import("nanoseconds.zig");

/// The class of one measurement's input.
pub const Class = enum(u1) {
    /// The one input the test holds fixed, often a special one (all zeros, a match).
    fixed,
    /// A fresh random input.
    random,
};

pub const Options = struct {
    /// Measurements in all, the classes drawn at random for each: at least `slots + floor`.
    measurements: usize = 1 << 20,
    /// Inputs prepared at a time: each round prepares this many, then measures them in order.
    slots: usize = 1 << 12,
    /// Calls per measurement.
    batch: usize = 1,
    /// |t| above this is a leak. dudect's 4.5 is a leak with high confidence; above 10 it is
    /// certain.
    threshold: f64 = 4.5,
    /// The seed of the class draws, and of the random handed to `prepare`.
    seed: u64 = 0,
};

/// The tests a run makes: uncropped, cropped at each of `crops` percentiles, and second order.
pub const crops = 100;
pub const tests = crops + 2;

/// What a run found.
pub const Report = struct {
    /// The largest |t| among the tests with enough measurements.
    t: f64,
    /// Which test it was: 0 uncropped, 1 to `crops` cropped (more cropped first), `crops + 1`
    /// second order.
    test_index: usize,
    measurements: usize,
    /// Mean nanoseconds per call of each class, uncropped.
    mean: [2]f64,
    /// `t` is above the threshold.
    leak: bool,
};

/// Measurements a test needs, past the first round, before its |t| says anything (dudect's).
pub const floor = 10_000;

pub const RunError = std.mem.Allocator.Error || error{ InvalidOptions, NonMonotonicClock };

/// Measures `context`: `prepare(context, slot, class, random)` sets up slot's input of `class`
/// (untimed), and `call(context, slot)` runs the operation on it, `batch` times per measurement.
/// Inputs a call consumes are prepared again for each round; a call must not depend on earlier
/// calls.
pub fn run(gpa: std.mem.Allocator, io: Io, context: anytype, options: Options) RunError!Report {
    // The first round sets the crop points and is left out; what is left must reach the floor
    // below which a test says nothing.
    if (options.slots < 2 or options.measurements < options.slots + floor or options.batch == 0 or !(options.threshold > 0)) return error.InvalidOptions;
    var prng: std.Random.DefaultPrng = .init(options.seed);
    const random = prng.random();
    const classes = try gpa.alloc(Class, options.slots);
    defer gpa.free(classes);
    const times = try gpa.alloc(f64, options.slots);
    defer gpa.free(times);
    var stats: [tests]Welch = @splat(.{});
    var cuts: [crops]f64 = undefined;
    var done: usize = 0;
    var round: usize = 0;
    while (done < options.measurements) : (round += 1) {
        const count = @min(options.slots, options.measurements - done);
        for (classes[0..count], 0..) |*class, slot| {
            class.* = if (random.boolean()) .random else .fixed;
            context.prepare(slot, class.*, random);
        }
        for (times[0..count], 0..) |*time, slot| {
            const start = Io.Timestamp.now(io, .awake);
            for (0..options.batch) |_| context.call(slot);
            const end = Io.Timestamp.now(io, .awake);
            const spent = nanoseconds.span(start.durationTo(end));
            if (spent.compare(.fromRaw(0)) == .lt) return error.NonMonotonicClock;
            time.* = @as(f64, @floatFromInt(spent.raw())) / @as(f64, @floatFromInt(options.batch));
        }
        // The first round only sets the crop points, from its own spread: measurements while
        // caches and branch predictors warm are left out.
        if (round == 0) {
            const sorted = try gpa.dupe(f64, times[0..count]);
            defer gpa.free(sorted);
            std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
            for (&cuts, 0..) |*cut, i| {
                const fraction = 1 - std.math.pow(f64, 0.5, 10 * @as(f64, @floatFromInt(i + 1)) / crops);
                cut.* = sorted[@min(sorted.len - 1, @as(usize, @intFromFloat(fraction * @as(f64, @floatFromInt(sorted.len)))))];
            }
            done += count;
            continue;
        }
        for (times[0..count], classes[0..count]) |time, class| {
            stats[0].push(time, class);
            for (cuts, 1..) |cut, i| if (time < cut) stats[i].push(time, class);
            // Second order: the squared distance from the class's mean so far.
            if (stats[0].n[@backingInt(class)] > 1) {
                const centered = time - stats[0].mean[@backingInt(class)];
                stats[crops + 1].push(centered * centered, class);
            }
        }
        done += count;
    }
    var report: Report = .{ .t = 0, .test_index = 0, .measurements = done, .mean = stats[0].mean, .leak = false };
    for (&stats, 0..) |*s, i| {
        // dudect's floor: a test with fewer measurements says nothing yet.
        if (s.n[0] + s.n[1] < floor or s.n[0] < 2 or s.n[1] < 2) continue;
        const t = @abs(s.t());
        if (t > report.t) {
            report.t = t;
            report.test_index = i;
        }
    }
    report.leak = report.t > options.threshold;
    return report;
}

/// Welch's t-test over two classes, by Welford's running mean and squared deviation.
const Welch = struct {
    n: [2]f64 = .{ 0, 0 },
    mean: [2]f64 = .{ 0, 0 },
    m2: [2]f64 = .{ 0, 0 },

    fn push(self: *Welch, x: f64, class: Class) void {
        const c = @backingInt(class);
        self.n[c] += 1;
        const delta = x - self.mean[c];
        self.mean[c] += delta / self.n[c];
        self.m2[c] += delta * (x - self.mean[c]);
    }

    fn t(self: *const Welch) f64 {
        const v0 = self.m2[0] / (self.n[0] - 1);
        const v1 = self.m2[1] / (self.n[1] - 1);
        const spread = @sqrt(v0 / self.n[0] + v1 / self.n[1]);
        if (spread == 0) return if (self.mean[0] == self.mean[1]) 0 else std.math.inf(f64);
        return (self.mean[0] - self.mean[1]) / spread;
    }
};
