//! Measure the network model separately from scheduling and Io trace costs.
const std = @import("std");
const Io = std.Io;
const Model = @import("network_model");
const bench = @import("measuring");
const Context = struct { model: Model, pair: [2]*Model.Socket, checksum: u64 = 0 };
fn message(ctx: *Context, count: u64) Model.Error!void {
    var bytes: [32]u8 = @splat(42);
    for (0..count) |_| {
        _ = try ctx.model.write(ctx.pair[0], &bytes);
        ctx.model.pump();
        const n = (try ctx.model.read(ctx.pair[1], &bytes)).?;
        ctx.checksum +%= n + bytes[0];
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try bench.Options.fromArguments(args[1..]);
    var ctx: Context = .{ .model = .init(init.gpa, .{}), .pair = undefined };
    defer ctx.model.deinit();
    _ = try ctx.model.addNode(&.{});
    ctx.pair = try ctx.model.pair(0, 0, true);
    var buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(init.io, &buffer);
    const rows = [_]bench.Row(Context, Model.Error){.{ .name = "net/message-32", .unit = "message", .run = message }};
    try bench.run(Model.Error, init.gpa, init.io, &output.interface, &ctx, &rows, .{ .commit = @import("bench_options").commit }, options);
    std.mem.doNotOptimizeAway(ctx.checksum);
}
