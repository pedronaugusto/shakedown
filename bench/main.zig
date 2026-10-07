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
    .{ .name = "alloc256/raw", .ops = 10_000_000, .run = allocRaw },
    .{ .name = "alloc256/counting", .ops = 10_000_000, .run = allocCounting },
    .{ .name = "alloc256/failing", .ops = 10_000_000, .run = allocFailing },
    .{ .name = "alloc4k/quarantine", .ops = 100_000, .run = allocQuarantine },
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

fn allocQuarantine(ctx: *Context, ops: u64) anyerror!void {
    var quarantine: shakedown.alloc.Quarantine = .init(.{});
    defer quarantine.deinit();
    try allocLoop(ctx, quarantine.allocator(), ops, 4096);
}
