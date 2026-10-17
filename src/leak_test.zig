const std = @import("std");
const leak = @import("leak.zig");

/// Compares slot inputs with a secret of 256 bytes, early-exit or whole.
const Compare = struct {
    secret: [256]u8 = @splat(0x5a),
    inputs: [1 << 10][256]u8 = undefined,
    whole: bool,
    /// Both classes get the fixed input: the classes differ in name only.
    same: bool = false,
    sink: u32 = 0,

    pub fn prepare(self: *Compare, slot: usize, class: leak.Class, random: std.Random) void {
        switch (if (self.same) .fixed else class) {
            // The fixed class matches: an early exit reads every byte.
            .fixed => self.inputs[slot] = self.secret,
            .random => random.bytes(&self.inputs[slot]),
        }
    }

    pub fn call(self: *Compare, slot: usize) void {
        const a: *const volatile [256]u8 = &self.inputs[slot];
        const b: *const volatile [256]u8 = &self.secret;
        if (self.whole) {
            var difference: u8 = 0;
            for (0..256) |i| difference |= a[i] ^ b[i];
            self.sink +%= difference;
        } else {
            for (0..256) |i| if (a[i] != b[i]) {
                self.sink +%= 1;
                return;
            };
        }
    }
};

const options: leak.Options = .{ .measurements = 1 << 16, .slots = 1 << 10, .batch = 16, .threshold = 10, .seed = 7 };

test "leak: an early-exit comparison is found" {
    var compare: Compare = .{ .whole = false };
    const report = try leak.run(std.testing.allocator, std.testing.io, &compare, options);
    try std.testing.expect(report.leak);
    // The match reads every byte: the fixed class is the slower.
    try std.testing.expect(report.mean[0] > report.mean[1]);
}

test "leak: classes that differ in name only are not told apart" {
    // The same operation on the same input under both labels. (A comparison of every byte over
    // matching and random inputs is not this: the hardware may time the two apart, as Apple's
    // data-memory prefetcher reads memory contents, and that is what the test is for.)
    var compare: Compare = .{ .whole = true, .same = true };
    const report = try leak.run(std.testing.allocator, std.testing.io, &compare, options);
    try std.testing.expect(!report.leak);
    try std.testing.expectEqual(options.measurements, report.measurements);
}

test "leak: options that cannot measure are refused" {
    var compare: Compare = .{ .whole = true };
    try std.testing.expectError(error.InvalidOptions, leak.run(std.testing.allocator, std.testing.io, &compare, .{ .measurements = 10, .slots = 8 }));
    try std.testing.expectError(error.InvalidOptions, leak.run(std.testing.allocator, std.testing.io, &compare, .{ .slots = 1 }));
    try std.testing.expectError(error.InvalidOptions, leak.run(std.testing.allocator, std.testing.io, &compare, .{ .batch = 0 }));
}
