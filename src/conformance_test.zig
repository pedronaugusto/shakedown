//! The conformance checks against std's threaded `Io`, an empty `Layer` and
//! an empty `FaultIo` over it, and a `Sim` on every executor and schedule.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const conformance = shakedown.conformance;

fn expectConforming(io: Io) !void {
    var failure: conformance.Failure = undefined;
    conformance.run(testing.allocator, io, .{ .failure = &failure }) catch |err| {
        std.debug.print("conformance: \"{s}\" failed: {t}\n", .{ failure.check, failure.err });
        return err;
    };
}

test "std's threaded Io conforms" {
    try expectConforming(testing.io);
}

test "an empty Layer and an empty FaultIo over it conform" {
    var layer: shakedown.Layer(struct { unused: u8 = 0 }, .{}) = .init(testing.io, .{});
    try expectConforming(layer.io());
    const fio = try shakedown.FaultIo.init(testing.allocator, layer.io(), .{});
    defer fio.deinit();
    try expectConforming(fio.io());
}

fn conformingRoot(io: Io) !void {
    var failure: conformance.Failure = undefined;
    conformance.run(testing.allocator, io, .{ .failure = &failure }) catch |err| {
        std.debug.print("conformance: \"{s}\" failed: {t}\n", .{ failure.check, failure.err });
        return err;
    };
}

test "a Sim conforms, on every executor and schedule, whatever the seed" {
    const schedules = [_]shakedown.Sim.Schedule{ .fifo, .random, .{ .pct = .{} } };
    for ([_]shakedown.Sim.Executor{ .auto, .threads }) |executor| {
        for (schedules) |schedule| {
            for (0..8) |seed| {
                const sim = try shakedown.Sim.init(testing.allocator, .{ .seed = seed, .executor = executor, .schedule = schedule, .yield_per_million = 100_000 });
                defer sim.deinit();
                const outcome = sim.run(conformingRoot, .{sim.io()});
                if (outcome != .finished) {
                    std.debug.print("seed {d}, {t}, {t}: {any}\n", .{ seed, executor, schedule, outcome });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
