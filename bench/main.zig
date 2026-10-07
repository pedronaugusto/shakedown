//! shakedown's own benchmarks: what a layer, a clock or an allocator costs
//! over std's own. `zig build bench` runs them in ReleaseFast and writes one
//! JSON line per row to stdout and to zig-out/bench/results.jsonl.
//!
//! Timings are taken by hand, on an idle machine, never in CI; CI only
//! compiles this. `zig build bench -- <row prefix>` runs the rows whose name
//! starts with the prefix.
const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");

/// Each row is timed this many times; the median is reported.
const repeats = 7;

const Row = struct {
    name: []const u8,
    /// Operations per timed run.
    ops: u64,
    run: *const fn (ctx: *Context, ops: u64) anyerror!void,
};

const Context = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    file: Io.File,
    sink: u64 = 0,
};

const rows = [_]Row{
    .{ .name = "now/threaded", .ops = 10_000_000, .run = nowThreaded },
    .{ .name = "now/layer", .ops = 10_000_000, .run = nowLayer },
    .{ .name = "now/clock", .ops = 10_000_000, .run = nowClock },
    .{ .name = "pread4k/threaded", .ops = 1_000_000, .run = preadThreaded },
    .{ .name = "pread4k/layer", .ops = 1_000_000, .run = preadLayer },
    .{ .name = "pread4k/clock", .ops = 1_000_000, .run = preadClock },
    .{ .name = "pread4k/faultio-empty", .ops = 1_000_000, .run = preadFaultEmpty },
    .{ .name = "pread4k/faultio-trace", .ops = 1_000_000, .run = preadFaultTrace },
    .{ .name = "pread4k/faultio-plan16", .ops = 1_000_000, .run = preadFaultPlan },
    .{ .name = "alloc256/raw", .ops = 10_000_000, .run = allocRaw },
    .{ .name = "alloc256/counting", .ops = 10_000_000, .run = allocCounting },
    .{ .name = "alloc256/failing", .ops = 10_000_000, .run = allocFailing },
    .{ .name = "alloc256/faultio", .ops = 10_000_000, .run = allocFaultIo },
    .{ .name = "alloc4k/quarantine", .ops = 100_000, .run = allocQuarantine },
    .{ .name = "random16/threaded", .ops = 1_000_000, .run = randomThreaded },
    .{ .name = "random16/faultio", .ops = 1_000_000, .run = randomFaultIo },
    .{ .name = "random16/faultio-seeded", .ops = 1_000_000, .run = randomFaultSeeded },
    .{ .name = "everyfault/alloc16-random", .ops = 2_000, .run = everyFaultSweep },
    .{ .name = "sim/now", .ops = 10_000_000, .run = simNow },
    .{ .name = "sim/switch-fibers", .ops = 1_000_000, .run = simSwitchFibers },
    .{ .name = "sim/switch-threads", .ops = 20_000, .run = simSwitchThreads },
    .{ .name = "sim/spawn-await", .ops = 1_000_000, .run = simSpawn },
    .{ .name = "sim/contention-random", .ops = 100_000, .run = simContentionRandom },
    .{ .name = "sim/contention-pct", .ops = 100_000, .run = simContentionPct },
    .{ .name = "sim/timers", .ops = 100_000, .run = simTimers },
    .{ .name = "sim/new", .ops = 10_000, .run = simNew },
    .{ .name = "sim/replay", .ops = 100_000, .run = simReplay },
    .{ .name = "check/sum-cases", .ops = 25_600, .run = checkCases },
    .{ .name = "check/shrink-distinct", .ops = 20, .run = checkShrink },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const prefix: []const u8 = if (args.len > 1) args[1] else "";

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out/bench");
    var out_file = try cwd.createFile(io, "zig-out/bench/results.jsonl", .{});
    defer out_file.close(io);
    var out_buffer: [4096]u8 = undefined;
    var out = out_file.writer(io, &out_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);

    var scratch = try cwd.createDirPathOpen(io, "zig-out/bench/scratch", .{});
    defer scratch.close(io);
    var page: [4096]u8 = @splat(0x5a);
    try scratch.writeFile(io, .{ .sub_path = "data", .data = &page });
    const file = try scratch.openFile(io, "data", .{});
    defer file.close(io);

    var ctx: Context = .{ .io = io, .gpa = gpa, .dir = scratch, .file = file };
    for (rows) |row| {
        if (!std.mem.startsWith(u8, row.name, prefix)) continue;
        var samples: [repeats]u64 = undefined;
        for (&samples) |*sample| {
            const start = Io.Timestamp.now(io, .awake);
            try row.run(&ctx, row.ops);
            sample.* = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        const median = samples[repeats / 2];
        const per_op = @as(f64, @floatFromInt(median)) / @as(f64, @floatFromInt(row.ops));
        const fmt = "{{\"row\":\"{s}\",\"ops\":{d},\"median_ns\":{d},\"min_ns\":{d},\"ns_per_op\":{d:.2}}}\n";
        const values = .{ row.name, row.ops, median, samples[0], per_op };
        try out.interface.print(fmt, values);
        try stdout.interface.print(fmt, values);
        try stdout.interface.flush();
    }
    try out.interface.flush();
    std.mem.doNotOptimizeAway(ctx.sink);
}

// Time.

fn nowLoop(ctx: *Context, io: Io, ops: u64) void {
    var sum: i96 = 0;
    for (0..ops) |_| sum +%= Io.Timestamp.now(io, .awake).nanoseconds;
    ctx.sink +%= @truncate(@as(u96, @bitCast(sum)));
}

fn nowThreaded(ctx: *Context, ops: u64) anyerror!void {
    nowLoop(ctx, ctx.io, ops);
}

const Empty = shakedown.Layer(struct { unused: u8 = 0 }, .{});

fn nowLayer(ctx: *Context, ops: u64) anyerror!void {
    var layer: Empty = .init(ctx.io, .{});
    nowLoop(ctx, layer.io(), ops);
}

fn nowClock(ctx: *Context, ops: u64) anyerror!void {
    var clock: shakedown.Clock = .init(ctx.io, .{});
    nowLoop(ctx, clock.io(), ops);
}

// Reads.

fn preadLoop(ctx: *Context, io: Io, ops: u64) !void {
    var buffer: [4096]u8 = undefined;
    for (0..ops) |_| {
        const n = try ctx.file.readPositional(io, &.{&buffer}, 0);
        ctx.sink +%= n;
    }
}

fn preadThreaded(ctx: *Context, ops: u64) anyerror!void {
    try preadLoop(ctx, ctx.io, ops);
}

fn preadLayer(ctx: *Context, ops: u64) anyerror!void {
    var layer: Empty = .init(ctx.io, .{});
    try preadLoop(ctx, layer.io(), ops);
}

fn preadClock(ctx: *Context, ops: u64) anyerror!void {
    var clock: shakedown.Clock = .init(ctx.io, .{});
    try preadLoop(ctx, clock.io(), ops);
}

fn preadFault(ctx: *Context, ops: u64, options: shakedown.FaultIo.Options) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, options);
    defer fio.deinit();
    try preadLoop(ctx, fio.io(), ops);
}

fn preadFaultEmpty(ctx: *Context, ops: u64) anyerror!void {
    try preadFault(ctx, ops, .{ .track_paths = false });
}

fn preadFaultTrace(ctx: *Context, ops: u64) anyerror!void {
    try preadFault(ctx, ops, .{ .track_paths = false, .trace = .all });
}

fn preadFaultPlan(ctx: *Context, ops: u64) anyerror!void {
    // Sixteen entries that never fire: each waits for a call no read makes.
    var entries: [16]shakedown.IoPlan.Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{
        .at = .{ .nth = .{ .call = .dirDeleteFile, .n = @intCast(i + 1) } },
        .fault = .{ .fail = error.AccessDenied },
    };
    try preadFault(ctx, ops, .{ .track_paths = false, .plan = &entries });
}

// Allocation.

fn allocLoop(ctx: *Context, gpa: std.mem.Allocator, ops: u64, len: usize) !void {
    for (0..ops) |_| {
        const block = try gpa.alloc(u8, len);
        ctx.sink +%= @intFromPtr(block.ptr); // safe: an address folded into the sink, never used again
        gpa.free(block);
    }
}

fn allocRaw(ctx: *Context, ops: u64) anyerror!void {
    try allocLoop(ctx, std.heap.smp_allocator, ops, 256);
}

fn allocCounting(ctx: *Context, ops: u64) anyerror!void {
    var counting: shakedown.alloc.Counting = .init(std.heap.smp_allocator);
    try allocLoop(ctx, counting.allocator(), ops, 256);
}

fn allocFailing(ctx: *Context, ops: u64) anyerror!void {
    var failing: std.testing.FailingAllocator = .init(std.heap.smp_allocator, .{});
    try allocLoop(ctx, failing.allocator(), ops, 256);
}

fn allocFaultIo(ctx: *Context, ops: u64) anyerror!void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    try allocLoop(ctx, try fio.allocator(std.heap.smp_allocator), ops, 256);
}

fn allocQuarantine(ctx: *Context, ops: u64) anyerror!void {
    var quarantine: shakedown.alloc.Quarantine = .init(.{});
    defer quarantine.deinit();
    try allocLoop(ctx, quarantine.allocator(), ops, 4096);
}

// Randomness.

fn randomLoop(ctx: *Context, io: Io, ops: u64) void {
    var buffer: [16]u8 = undefined;
    for (0..ops) |_| {
        io.random(&buffer);
        ctx.sink +%= std.mem.readInt(u64, buffer[0..8], .little);
    }
}

fn randomThreaded(ctx: *Context, ops: u64) anyerror!void {
    randomLoop(ctx, ctx.io, ops);
}

fn randomFaultIo(ctx: *Context, ops: u64) anyerror!void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    randomLoop(ctx, fio.io(), ops);
}

fn randomFaultSeeded(ctx: *Context, ops: u64) anyerror!void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false, .random_seed = 1 });
    defer fio.deinit();
    randomLoop(ctx, fio.io(), ops);
}

// everyFault.

/// Sixteen allocations, each with a draw from `io.random`: one clean run
/// and sixteen faulted ones a sweep.
const Sweep = struct {
    gpa: std.mem.Allocator = undefined,
    sink: u64 = 0,

    pub fn setUp(s: *Sweep, fio: *shakedown.FaultIo) !void {
        s.gpa = try fio.allocator(std.heap.smp_allocator);
    }

    pub fn run(s: *Sweep, io: Io) !void {
        for (0..16) |_| {
            const block = try s.gpa.alloc(u8, 64);
            defer s.gpa.free(block);
            io.random(block[0..8]);
            s.sink +%= block[0];
        }
    }

    pub fn check(s: *Sweep, io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = s;
        _ = io;
        if (injected == null) try result;
    }

    pub fn tearDown(s: *Sweep) void {
        _ = s;
    }
};

fn everyFaultSweep(ctx: *Context, ops: u64) anyerror!void {
    var sweep: Sweep = .{};
    for (0..ops) |_| {
        const report = try shakedown.everyFault(ctx.gpa, ctx.io, &sweep, .{});
        ctx.sink +%= report.runs;
    }
    ctx.sink +%= sweep.sink;
}

// Simulation. Every row runs inside one `Sim`; ops counts calls, switches,
// tasks, lock round trips or timer firings.

fn simRun(ctx: *Context, options: shakedown.Sim.Options, comptime f: anytype, args: anytype) !void {
    const sim = try shakedown.Sim.init(ctx.gpa, options);
    defer sim.deinit();
    switch (sim.run(f, args ++ .{sim.io()})) {
        .finished => {},
        else => return error.BenchFailed,
    }
    ctx.sink +%= sim.steps();
}

const quiet: shakedown.Sim.Options = .{ .schedule = .fifo, .spurious_wake_per_million = 0, .watchdog = null };

fn nowCalls(ops: u64, io: Io) void {
    var sum: i96 = 0;
    for (0..ops) |_| sum +%= Io.Timestamp.now(io, .awake).nanoseconds;
    std.mem.doNotOptimizeAway(sum);
}

fn simNow(ctx: *Context, ops: u64) anyerror!void {
    try simRun(ctx, quiet, nowCalls, .{ops});
}

/// Two tasks hand a turn back and forth: ops switches.
fn pingPong(ops: u64, io: Io) !void {
    const Side = struct {
        fn run(mine: *std.atomic.Value(u32), theirs: *std.atomic.Value(u32), rounds: u64, inner: Io) Io.Cancelable!void {
            for (0..rounds) |_| {
                while (mine.load(.acquire) == 0) try inner.futexWait(u32, &mine.raw, 0);
                mine.store(0, .release);
                theirs.store(1, .release);
                inner.futexWake(u32, &theirs.raw, 1);
            }
        }
    };
    var a: std.atomic.Value(u32) = .init(1);
    var b: std.atomic.Value(u32) = .init(0);
    var other = try io.concurrent(Side.run, .{ &b, &a, ops / 2, io });
    try Side.run(&a, &b, ops / 2, io);
    try other.await(io);
}

fn simSwitchFibers(ctx: *Context, ops: u64) anyerror!void {
    try simRun(ctx, quiet, pingPong, .{ops});
}

fn simSwitchThreads(ctx: *Context, ops: u64) anyerror!void {
    var options = quiet;
    options.executor = .threads;
    try simRun(ctx, options, pingPong, .{ops});
}

fn square(x: u64) u64 {
    return x *% x;
}

/// Start a task and await it, ops times: tasks come from the pool.
fn spawnAwait(ops: u64, io: Io) !void {
    var sum: u64 = 0;
    for (0..ops) |i| {
        var task = try io.concurrent(square, .{i});
        sum +%= task.await(io);
    }
    std.mem.doNotOptimizeAway(sum);
}

fn simSpawn(ctx: *Context, ops: u64) anyerror!void {
    try simRun(ctx, quiet, spawnAwait, .{ops});
}

/// A hundred tasks share one mutex, each taking it ops / 100 times and
/// sleeping a nanosecond inside, so every hold is contended.
fn contend(ops: u64, io: Io) !void {
    const Shared = struct {
        mutex: Io.Mutex = .init,
        count: u64 = 0,

        fn add(s: *@This(), times: u64, inner: Io) Io.Cancelable!void {
            for (0..times) |_| {
                try s.mutex.lock(inner);
                defer s.mutex.unlock(inner);
                try inner.sleep(.fromNanoseconds(1), .awake);
                s.count += 1;
            }
        }
    };
    var shared: Shared = .{};
    var group: Io.Group = .init;
    for (0..100) |_| try group.concurrent(io, Shared.add, .{ &shared, ops / 100, io });
    try group.await(io);
    if (shared.count != ops / 100 * 100) return error.BenchFailed;
}

fn simContentionRandom(ctx: *Context, ops: u64) anyerror!void {
    try simRun(ctx, .{ .watchdog = null }, contend, .{ops});
}

fn simContentionPct(ctx: *Context, ops: u64) anyerror!void {
    try simRun(ctx, .{ .schedule = .{ .pct = .{} }, .watchdog = null }, contend, .{ops});
}

/// A thousand tasks sleeping up to an hour of virtual time, each ops /
/// 1000 times.
fn sleepers(ops: u64, io: Io) !void {
    const Sleeper = struct {
        fn run(seed: u64, times: u64, inner: Io) Io.Cancelable!void {
            var prng: std.Random.DefaultPrng = .init(seed);
            for (0..times) |_| try inner.sleep(.fromMilliseconds(prng.random().intRangeAtMost(i64, 1, 3_600_000)), .awake);
        }
    };
    var group: Io.Group = .init;
    for (0..1000) |i| try group.concurrent(io, Sleeper.run, .{ i, ops / 1000, io });
    try group.await(io);
}

fn simTimers(ctx: *Context, ops: u64) anyerror!void {
    try simRun(ctx, quiet, sleepers, .{ops});
}

fn nothing(_: Io) void {}

/// A simulation made, run on one task and torn down, ops times: what each
/// case of a property over a simulation pays before its body.
fn simNew(ctx: *Context, ops: u64) anyerror!void {
    for (0..ops) |_| try simRun(ctx, quiet, nothing, .{});
}

/// The contention workload recorded on a tape, then replayed from it.
fn simReplay(ctx: *Context, ops: u64) anyerror!void {
    var recording: shakedown.Source = try .initRecording(ctx.gpa, .{ .prng = 7 }, .{ .max_choices = 1 << 24 });
    defer recording.deinit();
    try simRun(ctx, .{ .source = &recording, .watchdog = null }, contend, .{ops});
    var replay: shakedown.Source = try .init(ctx.gpa, .{ .replay = recording.tape().choices });
    defer replay.deinit();
    try simRun(ctx, .{ .source = &replay, .watchdog = null }, contend, .{ops});
}

// Properties.

fn intElement(s: *shakedown.Source) i64 {
    return shakedown.gen.int(s, i64);
}

/// The sum of a list does not depend on its order.
fn sumCommutes(_: void, c: *shakedown.Case) !void {
    const list = try shakedown.gen.slice(c.source, i64, intElement, c.gpa, .{});
    var forward: i64 = 0;
    for (list) |x| forward +%= x;
    var backward: i64 = 0;
    var i = list.len;
    while (i > 0) {
        i -= 1;
        backward +%= list[i];
    }
    if (forward != backward) return error.BenchFailed;
}

fn checkCases(ctx: *Context, ops: u64) anyerror!void {
    try shakedown.check(ctx.gpa, {}, sumCommutes, .{ .cases = @intCast(ops), .seed = 1 });
}

fn distinctBelowThree(_: void, c: *shakedown.Case) !void {
    const list = try shakedown.gen.slice(c.source, i64, intElement, c.gpa, .{});
    for (list, 0..) |a, i| for (list[i + 1 ..]) |b| if (a != b) for (list) |third| {
        if (third != a and third != b) return error.ThreeDistinct;
    };
}

/// A failing property found and shrunk to [0, 1, -1], ops times.
fn checkShrink(ctx: *Context, ops: u64) anyerror!void {
    for (0..ops) |seed| {
        var report: shakedown.CheckReport = undefined;
        shakedown.check(ctx.gpa, {}, distinctBelowThree, .{ .seed = seed, .diagnostics = &report }) catch |err| switch (err) {
            error.PropertyFailed => {
                ctx.sink +%= report.shrink_runs;
                report.deinit();
                continue;
            },
            else => return err,
        };
        return error.BenchFailed;
    }
}
