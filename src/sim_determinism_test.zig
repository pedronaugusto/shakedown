//! One seed, one run: the conformance workload's trace hash repeats for
//! every seed, is the same on fibers and on threads, and is fixed, so a
//! change to what a simulation decides, or in what order, fails here and is
//! made on purpose.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const Sim = shakedown.Sim;

fn workload(io: std.Io) !void {
    try shakedown.conformance.run(testing.allocator, io, .{});
}

fn traceHash(seed: u64, executor: Sim.Executor) !u64 {
    const sim = try Sim.init(testing.allocator, .{ .seed = seed, .executor = executor, .yield_per_million = 50_000 });
    defer sim.deinit();
    try testing.expectEqual(Sim.Outcome.finished, sim.run(workload, .{sim.io()}));
    return sim.trace().hash();
}

/// The digest of the first thousand seeds' trace hashes, in order. It
/// changes only when a simulation's decisions or their order change.
// B4 extends the fixture with files, hard links and mmap, including input digests.
// B5 adds the node namespace to each record; scheduler choices are unchanged.
// A listing resumes by cookie, so one that removes what it listed skips nothing.
const golden: u64 = 0x1aba0c62c00a5093;

test "a thousand seeds of the conformance workload repeat their runs, and the runs are fixed" {
    var digest: u64 = 0;
    for (0..1000) |seed| {
        const hash = try traceHash(seed, .auto);
        try testing.expectEqual(hash, try traceHash(seed, .auto));
        digest = std.hash.int(digest ^ hash);
    }
    try testing.expectEqual(golden, digest);
}

test "fibers and threads make the same run of a seed" {
    for (0..20) |seed| try testing.expectEqual(try traceHash(seed, .auto), try traceHash(seed, .threads));
}
