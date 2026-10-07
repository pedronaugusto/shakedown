//! Fuzz corpus entries in `std.testing.Smith`'s input format, built at
//! compile time.
//!
//! Smith reads its input as a sequence of draws: an integer is 8
//! little-endian bytes, an end-of-stream flag is one byte, `bytes` reads as
//! many raw bytes as asked, and a slice is a little-endian `u32` length and
//! then that many bytes. A literal written without the length is read as a
//! length and truncated, a seed that silently tests nothing; these build
//! the bytes from what the draws should be.
const std = @import("std");

/// One entry for `Smith.slice*`: a little-endian `u32` length, then the bytes.
pub fn entry(comptime bytes: []const u8) []const u8 {
    return comptime encode(&.{.{ .slice = bytes }});
}

/// One draw, as Smith reads it.
pub const Item = union(enum) {
    /// `value`, `valueRangeAtMost` and the other integer draws: 8 bytes.
    int: u64,
    /// `eos`: one byte, nonzero for the end.
    eos: bool,
    /// `bytes`: the bytes as they are.
    bytes: []const u8,
    /// `slice`: a `u32` length, then the bytes.
    slice: []const u8,
};

/// Smith's input for `items`, in order.
pub fn encode(comptime items: []const Item) []const u8 {
    comptime {
        var len: usize = 0;
        for (items) |item| len += switch (item) {
            .int => 8,
            .eos => 1,
            .bytes => |b| b.len,
            .slice => |b| 4 + b.len,
        };
        var out: [len]u8 = undefined;
        var at: usize = 0;
        for (items) |item| switch (item) {
            .int => |v| {
                std.mem.writeInt(u64, out[at..][0..8], v, .little);
                at += 8;
            },
            .eos => |end| {
                out[at] = @intFromBool(end);
                at += 1;
            },
            .bytes => |b| {
                @memcpy(out[at..][0..b.len], b);
                at += b.len;
            },
            .slice => |b| {
                std.mem.writeInt(u32, out[at..][0..4], b.len, .little);
                @memcpy(out[at + 4 ..][0..b.len], b);
                at += 4 + b.len;
            },
        };
        const final = out;
        return &final;
    }
}

test "an entry is its length, little-endian, then its bytes" {
    try std.testing.expectEqualSlices(u8, "\x03\x00\x00\x00abc", entry("abc"));
    try std.testing.expectEqualSlices(u8, "\x00\x00\x00\x00", entry(""));
    const long: [300]u8 = @splat('x');
    try std.testing.expectEqualSlices(u8, "\x2c\x01\x00\x00" ++ &long, entry(&long));
}

test "Smith draws back exactly what was encoded" {
    const input = comptime encode(&.{
        .{ .int = 7 },
        .{ .slice = "hello" },
        .{ .eos = false },
        .{ .bytes = "xyz" },
        .{ .int = 0xfedc_ba98_7654_3210 },
        .{ .eos = true },
    });
    var smith: std.testing.Smith = .{ .in = input };
    try std.testing.expectEqual(@as(u64, 7), smith.valueRangeAtMost(u64, 0, 100));
    var buf: [16]u8 = undefined;
    const n = smith.slice(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    try std.testing.expect(!smith.eos());
    var three: [3]u8 = undefined;
    smith.bytes(&three);
    try std.testing.expectEqualStrings("xyz", &three);
    try std.testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), smith.value(u64));
    try std.testing.expect(smith.eos());
    try std.testing.expectEqual(@as(usize, 0), smith.in.?.len);
}
