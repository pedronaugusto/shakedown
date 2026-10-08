//! Compile the portable draw APIs without a hosted Io or test runner.
const std = @import("std");
const shakedown = @import("shakedown");

// Exporting the runtime entry forces analysis and code generation in an object
// build; merely importing the module would leave these lazy APIs unchecked.
export fn source32() u64 {
    var storage: [32768]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    var source = shakedown.Source.initRecording(arena.allocator(), .{ .prng = 0 }, .{ .max_choices = 256 }) catch return 0;
    defer source.deinit();
    const hash = draws(&source);
    if (hash == 0 or source.overrun()) return 0;
    var replay = shakedown.Source.init(arena.allocator(), .{ .replay = source.tape().choices }) catch return 0;
    defer replay.deinit();
    return if (draws(&replay) == hash) hash else 0;
}

fn draws(source: *shakedown.Source) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    const bounds = [_]u64{ 0, 1, 255, 256, 65535, 65536, 0xffffffff, 0x100000000, std.math.maxInt(u64) };
    for (bounds) |bound| {
        for (0..8) |_| {
            const draw = source.integer(bound);
            if (draw > bound) return 0;
            hash = (hash ^ draw) *% 0x100000001b3;
        }
    }
    hash ^= shakedown.gen.int(source, u64);
    hash ^= @truncate(shakedown.gen.int(source, u128));
    hash ^= @bitCast(shakedown.gen.intRange(source, i64, std.math.minInt(i64), std.math.maxInt(i64)));
    const Kind = enum { first, second, third };
    hash ^= @backingInt(shakedown.gen.enumValue(source, Kind));
    hash ^= shakedown.gen.oneOf(source, u64, &.{ 7, 11, 19 });
    hash ^= shakedown.gen.weighted(source, &.{ 1, 3, 7 });
    hash ^= @as(u64, @bitCast(shakedown.gen.float(source, f64)));
    return hash;
}

test "portable seeded draws preserve their golden result and replay" {
    try std.testing.expectEqual(@as(u64, 14487966971076840345), source32());
}
