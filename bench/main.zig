//! shakedown's own benchmarks: what a layer, a clock or an allocator costs
//! over std's own. `zig build bench` runs them in ReleaseFast and writes one
//! JSON line per row to stdout.
//!
//! Timings are taken by hand, on the shared machine, never in CI, where
//! `zig build test` runs each row once at its smallest (`--smoke`).
//! `zig-out/bench/shakedown-bench <row prefix>` runs the rows whose name
//! starts with the prefix.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const shakedown = @import("shakedown");

const WorkloadError = blk: {
    var E: type = error{};
    for (.{ netRpc, netGossip, fsCycleSim, fsCycleThreaded, fsCrashStates, fsSnapshot, nowThreaded, nowLayer, nowClock, nowFaultIo, checkCancelThreaded, checkCancelFaultIo, preadSim, preadThreaded, preadLayer, preadClock, preadFaultEmpty, preadFaultTrace, preadFaultPlan, allocRaw, allocCounting, allocFailing, allocFaultIo, allocQuarantine, randomThreaded, randomFaultIo, randomFaultSeeded, batchThreaded, batchFaultIo, everyFaultSweep, simNow, simSwitchFibers, simSwitchThreads, simSpawn, simContentionRandom, simContentionPct, simTimers, simNew, simDeterminism, simReplay, checkCases, checkSimCases, checkShrink }) |callback| {
        E = E || @typeInfo(@typeInfo(@TypeOf(callback)).@"fn".return_type.?).error_union.error_set;
    }
    break :blk E;
};
const Row = shakedown.bench.Row(Context, WorkloadError);

const Context = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    file: Io.File,
    sink: u64 = 0,
};

const rows = [_]Row{
    .{ .name = "net/rpc-32", .unit = "roundtrip", .run = netRpc },
    .{ .name = "net/gossip-3", .unit = "round", .run = netGossip },
    .{ .name = "fs_cycle/sim", .unit = "op", .run = fsCycleSim },
    .{ .name = "fs_cycle/threaded", .unit = "op", .run = fsCycleThreaded },
    .{ .name = "fs/crash-states-30", .unit = "op", .run = fsCrashStates },
    .{ .name = "fs/snapshot", .unit = "op", .run = fsSnapshot },
    .{ .name = "now/threaded", .unit = "op", .run = nowThreaded },
    .{ .name = "now/layer", .unit = "op", .run = nowLayer },
    .{ .name = "now/clock", .unit = "op", .run = nowClock },
    .{ .name = "now/faultio", .unit = "op", .run = nowFaultIo },
    .{ .name = "checkcancel/threaded", .unit = "op", .run = checkCancelThreaded },
    .{ .name = "checkcancel/faultio", .unit = "op", .run = checkCancelFaultIo },
    .{ .name = "pread4k/sim", .unit = "op", .run = preadSim },
    .{ .name = "pread4k/threaded", .unit = "op", .run = preadThreaded },
    .{ .name = "pread4k/layer", .unit = "op", .run = preadLayer },
    .{ .name = "pread4k/clock", .unit = "op", .run = preadClock },
    .{ .name = "pread4k/faultio-empty", .unit = "op", .run = preadFaultEmpty },
    .{ .name = "pread4k/faultio-trace", .unit = "op", .run = preadFaultTrace },
    .{ .name = "pread4k/faultio-plan16", .unit = "op", .run = preadFaultPlan },
    .{ .name = "alloc256/raw", .unit = "op", .run = allocRaw },
    .{ .name = "alloc256/counting", .unit = "op", .run = allocCounting },
    .{ .name = "alloc256/failing", .unit = "op", .run = allocFailing },
    .{ .name = "alloc256/faultio", .unit = "op", .run = allocFaultIo },
    .{ .name = "alloc4k/quarantine", .unit = "op", .run = allocQuarantine },
    .{ .name = "random16/threaded", .unit = "op", .run = randomThreaded },
    .{ .name = "random16/faultio", .unit = "op", .run = randomFaultIo },
    .{ .name = "random16/faultio-seeded", .unit = "op", .run = randomFaultSeeded },
    .{ .name = "batch1/threaded", .unit = "op", .run = batchThreaded },
    .{ .name = "batch1/faultio", .unit = "op", .run = batchFaultIo },
    .{ .name = "everyfault/alloc16-random", .unit = "op", .run = everyFaultSweep },
    .{ .name = "sim/now", .unit = "op", .run = simNow },
    .{ .name = "sim/switch-fibers", .unit = "op", .initial = 2, .smoke = 2, .run = simSwitchFibers },
    .{ .name = "sim/switch-threads", .unit = "op", .initial = 2, .smoke = 2, .run = simSwitchThreads },
    .{ .name = "sim/spawn-await", .unit = "op", .run = simSpawn },
    .{ .name = "sim/contention-random", .unit = "op", .initial = 100, .smoke = 100, .run = simContentionRandom },
    .{ .name = "sim/contention-pct", .unit = "op", .initial = 100, .smoke = 100, .run = simContentionPct },
    .{ .name = "sim/timers", .unit = "op", .initial = 1000, .smoke = 1000, .run = simTimers },
    .{ .name = "sim/new", .unit = "op", .run = simNew },
    .{ .name = "sim/determinism", .unit = "op", .run = simDeterminism },
    .{ .name = "sim/replay", .unit = "op", .initial = 100, .smoke = 100, .run = simReplay },
    .{ .name = "check/sum-cases", .unit = "op", .run = checkCases },
    .{ .name = "check/sim-cases", .unit = "op", .run = checkSimCases },
    .{ .name = "check/shrink-distinct", .unit = "op", .run = checkShrink },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const prefix: []const u8 = if (args.len > 1 and !smoke) args[1] else "";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);

    // The file the reads read, in the working directory, gone at the end.
    const cwd = Io.Dir.cwd();
    var scratch = try cwd.createDirPathOpen(io, "shakedown-bench-scratch", .{});
    defer cwd.deleteTree(io, "shakedown-bench-scratch") catch {};
    defer scratch.close(io);
    var page: [4096]u8 = @splat(0x5a);
    try scratch.writeFile(io, .{ .sub_path = "data", .data = &page });
    const file = try scratch.openFile(io, "data", .{});
    defer file.close(io);

    var ctx: Context = .{ .io = io, .gpa = gpa, .dir = scratch, .file = file };
    try shakedown.bench.run(WorkloadError, gpa, io, &stdout.interface, &ctx, &rows, .{ .commit = @import("bench_options").commit }, .{ .smoke = smoke, .prefix = prefix });
    try stdout.interface.flush();
    std.mem.doNotOptimizeAway(ctx.sink);
}

// Time.

fn nowLoop(ctx: *Context, io: Io, ops: u64) void {
    var sum: i96 = 0;
    for (0..ops) |_| {
        const timestamp = Io.Timestamp.now(io, .awake).nanoseconds;
        std.mem.doNotOptimizeAway(timestamp);
        sum +%= timestamp;
    }
    ctx.sink +%= @truncate(@as(u96, @bitCast(sum)));
}

fn nowThreaded(ctx: *Context, ops: u64) !void {
    nowLoop(ctx, ctx.io, ops);
}

const Empty = shakedown.Layer(struct { unused: u8 = 0 }, .{});

fn nowLayer(ctx: *Context, ops: u64) !void {
    var layer: Empty = .init(ctx.io, .{});
    nowLoop(ctx, layer.io(), ops);
}

fn nowClock(ctx: *Context, ops: u64) !void {
    var clock: shakedown.Clock = .init(ctx.io, .{});
    nowLoop(ctx, clock.io(), ops);
}

fn nowFaultIo(ctx: *Context, ops: u64) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    nowLoop(ctx, fio.io(), ops);
}

// Cancelation points: the cheapest call that can be canceled.

fn checkCancelLoop(io: Io, ops: u64) !void {
    for (0..ops) |_| try io.checkCancel();
}

fn checkCancelThreaded(ctx: *Context, ops: u64) !void {
    try checkCancelLoop(ctx.io, ops);
}

fn checkCancelFaultIo(ctx: *Context, ops: u64) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    try checkCancelLoop(fio.io(), ops);
}

// Reads.

fn preadLoop(ctx: *Context, io: Io, ops: u64) !void {
    var buffer: [4096]u8 = undefined;
    for (0..ops) |_| {
        const n = try ctx.file.readPositional(io, &.{&buffer}, 0);
        ctx.sink +%= n;
    }
}

fn preadThreaded(ctx: *Context, ops: u64) !void {
    try preadLoop(ctx, ctx.io, ops);
}

fn preadLayer(ctx: *Context, ops: u64) !void {
    var layer: Empty = .init(ctx.io, .{});
    try preadLoop(ctx, layer.io(), ops);
}

fn preadClock(ctx: *Context, ops: u64) !void {
    var clock: shakedown.Clock = .init(ctx.io, .{});
    try preadLoop(ctx, clock.io(), ops);
}

fn preadFault(ctx: *Context, ops: u64, options: shakedown.FaultIo.Options) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, options);
    defer fio.deinit();
    try preadLoop(ctx, fio.io(), ops);
}

fn preadFaultEmpty(ctx: *Context, ops: u64) !void {
    try preadFault(ctx, ops, .{ .track_paths = false });
}

fn preadFaultTrace(ctx: *Context, ops: u64) !void {
    try preadFault(ctx, ops, .{ .track_paths = false, .trace = .all });
}

fn preadFaultPlan(ctx: *Context, ops: u64) !void {
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

fn allocRaw(ctx: *Context, ops: u64) !void {
    try allocLoop(ctx, std.heap.smp_allocator, ops, 256);
}

fn allocCounting(ctx: *Context, ops: u64) !void {
    var counting: shakedown.alloc.Counting = .init(std.heap.smp_allocator);
    try allocLoop(ctx, counting.allocator(), ops, 256);
}

fn allocFailing(ctx: *Context, ops: u64) !void {
    var failing: std.testing.FailingAllocator = .init(std.heap.smp_allocator, .{});
    try allocLoop(ctx, failing.allocator(), ops, 256);
}

fn allocFaultIo(ctx: *Context, ops: u64) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    try allocLoop(ctx, try fio.allocator(std.heap.smp_allocator), ops, 256);
}

fn allocQuarantine(ctx: *Context, ops: u64) !void {
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

fn randomThreaded(ctx: *Context, ops: u64) !void {
    randomLoop(ctx, ctx.io, ops);
}

fn randomFaultIo(ctx: *Context, ops: u64) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    randomLoop(ctx, fio.io(), ops);
}

fn randomFaultSeeded(ctx: *Context, ops: u64) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false, .random_seed = 1 });
    defer fio.deinit();
    randomLoop(ctx, fio.io(), ops);
}

// Batches.

/// A batch of one read of the page, awaited, taken and canceled: what a
/// pump's wait costs.
fn batchLoop(ctx: *Context, io: Io, ops: u64) !void {
    var buffer: [4096]u8 = undefined;
    var storage: [1]Io.Operation.Storage = undefined;
    for (0..ops) |_| {
        var batch: Io.Batch = .init(&storage);
        defer batch.cancel(io);
        batch.addAt(0, .{ .file_read_streaming = .{ .file = ctx.file, .data = &.{&buffer} } });
        try batch.awaitAsync(io);
        const done = batch.next() orelse return error.BenchFailed;
        ctx.sink +%= done.result.file_read_streaming catch 0;
    }
}

fn batchThreaded(ctx: *Context, ops: u64) !void {
    try batchLoop(ctx, ctx.io, ops);
}

fn batchFaultIo(ctx: *Context, ops: u64) !void {
    const fio = try shakedown.FaultIo.init(ctx.gpa, ctx.io, .{ .track_paths = false });
    defer fio.deinit();
    try batchLoop(ctx, fio.io(), ops);
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

fn everyFaultSweep(ctx: *Context, ops: u64) !void {
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
    for (0..ops) |_| {
        const timestamp = Io.Timestamp.now(io, .awake).nanoseconds;
        std.mem.doNotOptimizeAway(timestamp);
        sum +%= timestamp;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn simNow(ctx: *Context, ops: u64) !void {
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

fn simSwitchFibers(ctx: *Context, ops: u64) !void {
    try simRun(ctx, quiet, pingPong, .{ops});
}

fn simSwitchThreads(ctx: *Context, ops: u64) !void {
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

fn simSpawn(ctx: *Context, ops: u64) !void {
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

fn simContentionRandom(ctx: *Context, ops: u64) !void {
    try simRun(ctx, .{ .watchdog = null }, contend, .{ops});
}

fn simContentionPct(ctx: *Context, ops: u64) !void {
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

fn simTimers(ctx: *Context, ops: u64) !void {
    try simRun(ctx, quiet, sleepers, .{ops});
}

fn nothing(_: Io) void {}

/// A simulation made, run on one task and torn down, ops times: what each
/// case of a property over a simulation pays before its body.
fn simNew(ctx: *Context, ops: u64) !void {
    for (0..ops) |_| try simRun(ctx, quiet, nothing, .{});
}

/// The contention workload recorded on a tape, then replayed from it.
fn simReplay(ctx: *Context, ops: u64) !void {
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

fn checkCases(ctx: *Context, ops: u64) !void {
    try shakedown.check(ctx.gpa, {}, sumCommutes, .{ .cases = @intCast(ops), .seed = 1 });
}

/// A simulation per case, as a property over a schedule makes, its root
/// doing nothing: what each case pays for its simulation and its watchdog.
fn emptySim(_: void, c: *shakedown.Case) !void {
    const sim = try c.sim(.{ .schedule = .fifo });
    if (sim.run(nothing, .{sim.io()}) != .finished) return error.BenchFailed;
}

fn checkSimCases(ctx: *Context, ops: u64) !void {
    try shakedown.check(ctx.gpa, {}, emptySim, .{ .cases = @intCast(ops), .seed = 1 });
}

fn distinctBelowThree(_: void, c: *shakedown.Case) !void {
    const list = try shakedown.gen.slice(c.source, i64, intElement, c.gpa, .{});
    for (list, 0..) |a, i| for (list[i + 1 ..]) |b| if (a != b) for (list) |third| {
        if (third != a and third != b) return error.ThreeDistinct;
    };
}

/// A failing property found and shrunk to [0, 1, -1], ops times.
fn checkShrink(ctx: *Context, ops: u64) !void {
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

fn fsCycleRoot(io: Io, sim: *shakedown.Sim, ops: u64) !void {
    const cwd = Io.Dir.cwd();
    const page: [4096]u8 = @splat(0x5a);
    for (0..ops) |_| {
        const file = try cwd.createFile(io, "temp", .{});
        try file.writePositionalAll(io, &page, 0);
        try file.sync(io);
        try cwd.rename("temp", cwd, "saved", io);
        try sim.fs().flushDir(cwd.handle, .full);
        file.close(io);
    }
}
fn fsCycleSim(ctx: *Context, ops: u64) !void {
    const sim = try shakedown.Sim.init(ctx.gpa, .{ .watchdog = null, .trace = .off });
    defer sim.deinit();
    if (sim.run(fsCycleRoot, .{ sim.io(), sim, ops }) != .finished) return error.SimulationFailed;
    ctx.sink +%= sim.steps();
}
fn fsCycleThreaded(ctx: *Context, ops: u64) !void {
    const page: [4096]u8 = @splat(0x5a);
    for (0..ops) |_| {
        const file = try ctx.dir.createFile(ctx.io, "temp", .{});
        try file.writePositionalAll(ctx.io, &page, 0);
        try file.sync(ctx.io);
        try ctx.dir.rename("temp", ctx.dir, "saved", ctx.io);
        file.close(ctx.io);
        // std has no portable directory sync. A read-only directory file
        // descriptor is syncable on POSIX; Windows requires airlock's seam.
        if (builtin.os.tag != .windows) {
            const dir_file = try ctx.dir.openFile(ctx.io, ".", .{});
            defer dir_file.close(ctx.io);
            try dir_file.sync(ctx.io);
        }
    }
}
fn fsCrashStates(ctx: *Context, ops: u64) !void {
    const sim = try shakedown.Sim.init(ctx.gpa, .{ .watchdog = null, .trace = .off, .fs = .{ .sector = 1 } });
    defer sim.deinit();
    const fs = sim.fs();
    const zeros: [30]u8 = @splat(0);
    try fs.write("data", &zeros);
    const Work = struct {
        fn run(io: Io) !void {
            const file = try Io.Dir.cwd().openFile(io, "data", .{ .mode = .read_write });
            defer file.close(io);
            for (0..30) |i| try file.writePositionalAll(io, &.{1}, i);
        }
    };
    if (sim.run(Work.run, .{sim.io()}) != .finished) return error.SimulationFailed;
    for (0..ops) |_| {
        var states = try fs.crashStates(256);
        defer states.deinit();
        while (try states.next()) |snap| {
            snap.deinit();
            ctx.sink +%= 1;
        }
    }
}
fn fsSnapshot(ctx: *Context, ops: u64) !void {
    const sim = try shakedown.Sim.init(ctx.gpa, .{ .watchdog = null, .trace = .off });
    defer sim.deinit();
    for (0..ops) |_| {
        const snap = try sim.fs().snapshot();
        std.mem.doNotOptimizeAway(snap.root);
        snap.deinit();
    }
}

fn preadSim(ctx: *Context, ops: u64) !void {
    const sim = try shakedown.Sim.init(ctx.gpa, .{ .watchdog = null, .trace = .off });
    defer sim.deinit();
    const page: [4096]u8 = @splat(0x5a);
    try sim.fs().write("data", &page);
    const Work = struct {
        fn run(io: Io, count: u64, sink: *u64) !void {
            const file = try Io.Dir.cwd().openFile(io, "data", .{});
            defer file.close(io);
            var buffer: [4096]u8 = undefined;
            for (0..count) |_| {
                if (try file.readPositionalAll(io, &buffer, 0) != buffer.len) return error.ShortRead;
                sink.* +%= buffer[0];
            }
        }
    };
    if (sim.run(Work.run, .{ sim.io(), ops, &ctx.sink }) != .finished) return error.SimulationFailed;
}

fn simDeterminism(ctx: *Context, ops: u64) !void {
    const Work = struct {
        fn run(_: void, io: Io) !void {
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    };
    for (0..ops) |_| try shakedown.expectDeterministic(ctx.gpa, {}, Work.run, .{ .sim = .{ .watchdog = null } });
}

fn netRpc(ctx: *Context, ops: u64) !void {
    const Work = struct {
        fn run(count: u64, sink: *u64, io: Io) !void {
            const pair = try Io.net.Socket.createPair(io, .{});
            defer pair[0].close(io);
            defer pair[1].close(io);
            var bytes: [32]u8 = @splat(42);
            var vectors = [_][]u8{&bytes};
            for (0..count) |_| {
                _ = try (try io.operate(.{ .net_write = .{ .socket_handle = pair[0].handle, .header = &bytes, .data = &.{} } })).net_write;
                const received = try (try io.operate(.{ .net_read = .{ .socket_handle = pair[1].handle, .data = &vectors } })).net_read;
                _ = try (try io.operate(.{ .net_write = .{ .socket_handle = pair[1].handle, .header = bytes[0..received.data_len], .data = &.{} } })).net_write;
                const reply = try (try io.operate(.{ .net_read = .{ .socket_handle = pair[0].handle, .data = &vectors } })).net_read;
                sink.* +%= reply.data_len + bytes[0];
            }
        }
    };
    try simRun(ctx, .{ .schedule = .fifo, .trace = .off, .watchdog = null }, Work.run, .{ ops, &ctx.sink });
}
fn netGossip(ctx: *Context, ops: u64) !void {
    const sim = try shakedown.Sim.init(ctx.gpa, .{ .schedule = .fifo, .trace = .off, .watchdog = null });
    defer sim.deinit();
    var nodes: [3]*shakedown.Sim.Node = undefined;
    var addresses: [3]Io.net.IpAddress = undefined;
    for (&nodes, &addresses, 0..) |*node, *address, i| {
        address.* = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, @intCast(i + 20) }, .port = 1234 } };
        node.* = try sim.node("gossip", .{ .addresses = &.{address.*} });
    }
    const Work = struct {
        fn run(peers: [3]*shakedown.Sim.Node, addr: [3]Io.net.IpAddress, count: u64, sink: *u64) !void {
            var sockets: [3]Io.net.Socket = undefined;
            for (&sockets, peers, addr) |*socket, node, address| socket.* = try address.bind(node.io(), .{ .mode = .dgram });
            defer for (sockets, peers) |socket, node| socket.close(node.io());
            var bytes: [32]u8 = @splat(42);
            var messages = [_]Io.net.IncomingMessage{.init};
            for (0..count) |_| {
                for (sockets, peers, 0..) |socket, node, i| try socket.send(node.io(), &addr[(i + 1) % 3], &bytes);
                for (sockets, peers) |socket, node| {
                    const err, const n = (try node.io().operate(.{ .net_receive = .{ .socket_handle = socket.handle, .message_buffer = &messages, .data_buffer = &bytes, .flags = .{} } })).net_receive;
                    if (err) |e| return e;
                    sink.* +%= n + bytes[0];
                }
            }
        }
    };
    const outcome = sim.run(Work.run, .{ nodes, addresses, ops, &ctx.sink });
    if (outcome == .failed) return outcome.failed;
    if (outcome != .finished) return error.SimulationFailed;
}
