//! Test inputs: fuzz corpus entries in `std.testing.Smith`'s input format,
//! built at compile time or from a recorded tape, text repeated to a
//! length, and `rows`, which runs a check on each line of a vector file.
//!
//! Smith reads its input as a sequence of draws: an integer is 8
//! little-endian bytes, an end-of-stream flag is one byte, `bytes` reads as
//! many raw bytes as asked, and a slice is a little-endian `u32` length and
//! then that many bytes. A literal written without the length is read as a
//! length and truncated, a seed that silently tests nothing; these build
//! the bytes from what the draws should be.
const std = @import("std");
const Untraced = @import("alloc/Untraced.zig");

/// Runs `row(ctx, gpa, line)` on each line of `text` that is not empty: a
/// vector file, each line a case. Each row has an allocator of its own,
/// counted and without a stack trace per allocation (`alloc.Untraced.run`):
/// a row that leaks fails, and runs again traced to name the leak. The first
/// row that fails stops the run, and its error is returned after a warning
/// that names its line number and text. Lines end at `\n`; a `\r` before it
/// is part of the line.
pub fn rows(gpa: std.mem.Allocator, text: []const u8, ctx: anytype, comptime row: fn (@TypeOf(ctx), std.mem.Allocator, []const u8) anyerror!void) anyerror!void {
    const Row = struct {
        ctx: @TypeOf(ctx),
        line: []const u8,
        fn run(r: *const @This(), a: std.mem.Allocator) anyerror!void {
            return row(r.ctx, a, r.line);
        }
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (line.len == 0) continue;
        const each: Row = .{ .ctx = ctx, .line = line };
        Untraced.run(gpa, &each, Row.run) catch |err| {
            std.log.scoped(.shakedown).warn("corpus row {d} failed with {t}: {s}", .{ number, err, line });
            return err;
        };
    }
}

/// One entry for `Smith.slice*`: a little-endian `u32` length, then the bytes.
pub fn entry(comptime bytes: []const u8) []const u8 {
    return comptime prefixed(bytes);
}

/// `entry` of each of `list`, in order: a corpus for `std.testing.fuzz`'s
/// `.corpus`, written as the bytes each entry should hold.
pub fn entries(comptime list: []const []const u8) []const []const u8 {
    return comptime blk: {
        // Three backward branches an entry, the loop and two calls, and
        // one to spare: `prefixed` itself has no loop.
        @setEvalBranchQuota(1000 + 4 * list.len);
        var out: [list.len][]const u8 = undefined;
        for (list, &out) |bytes, *e| e.* = prefixed(bytes);
        const final = out;
        break :blk &final;
    };
}

/// `bytes` behind their length as a little-endian `u32`, with no loop.
fn prefixed(comptime bytes: []const u8) *const [4 + bytes.len]u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes[0..bytes.len].*;
        return &out;
    }
}

/// `text` written `times` times: `repeat("ab", 3)` is `"ababab"`, the
/// array product Zig 0.17 no longer has. Like a string literal, the result
/// is static and ends in a 0 sentinel, so it outlives any call and coerces
/// to `[]const u8` and `[:0]const u8`.
///
/// The copies are one `@splat`, not a loop, so any count stays inside the
/// default eval branch quota and costs compile time in proportion to the
/// bytes made. It is `inline` so that its result is known at compile time
/// wherever it is called, and joins other text with `++`.
pub inline fn repeat(comptime text: []const u8, comptime times: usize) *const [text.len * times:0]u8 {
    comptime {
        const copies: [times][text.len]u8 = @splat(text[0..text.len].*);
        const flat: [text.len * times]u8 = @bitCast(copies);
        const terminated = flat ++ [_]u8{0};
        const final: [text.len * times:0]u8 = terminated[0 .. text.len * times :0].*;
        return &final;
    }
}

/// A recorded tape's choices as Smith input: each choice is an integer
/// draw, 8 little-endian bytes, so a source reading it under the fuzzer
/// draws the same choices the tape holds. Owned by the caller.
pub fn fromTape(gpa: std.mem.Allocator, choices: []const u64) error{OutOfMemory}![]u8 {
    const out = try gpa.alloc(u8, choices.len * 8);
    for (choices, 0..) |choice, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], choice, .little);
    return out;
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
    try std.testing.expectEqualSlices(u8, comptime encode(&.{.{ .slice = "abc" }}), entry("abc"));
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

test "entries is an entry of each, in order, for a corpus of any length" {
    const corpus = entries(&.{ "abc", "", "\x00\xff" });
    try std.testing.expectEqual(@as(usize, 3), corpus.len);
    try std.testing.expectEqualSlices(u8, entry("abc"), corpus[0]);
    try std.testing.expectEqualSlices(u8, entry(""), corpus[1]);
    try std.testing.expectEqualSlices(u8, entry("\x00\xff"), corpus[2]);
    try std.testing.expectEqual(@as(usize, 0), entries(&.{}).len);

    const list: [5000][]const u8 = @splat("x");
    const many = entries(&list);
    try std.testing.expectEqual(@as(usize, 5000), many.len);
    for (many) |e| try std.testing.expectEqualSlices(u8, "\x01\x00\x00\x00x", e);
}

/// `repeat` through a function that is not inline, for the tests: the
/// result must outlive the call.
fn repeated() [:0]const u8 {
    return repeat("ab", 3);
}

test "repeat writes text a number of times, static and 0-terminated like a literal" {
    try std.testing.expectEqualStrings("ababab", repeat("ab", 3));
    // Known at compile time, so it joins other text with `++`.
    const joined = repeat("a", 3) ++ "b";
    try std.testing.expectEqualStrings("aaab", joined);
    try std.testing.expectEqual(@as(usize, 0), repeat("", 5).len);
    try std.testing.expectEqual(@as(usize, 0), repeat("xyz", 0).len);
    try std.testing.expectEqualStrings("x", repeat("x", 1));

    const terminated: [:0]const u8 = repeat("ab", 2);
    try std.testing.expectEqual(@as(u8, 0), terminated[terminated.len]);
    const first = repeated();
    const second = repeated();
    try std.testing.expectEqualStrings("ababab", first);
    try std.testing.expectEqual(first.ptr, second.ptr);
}

test "repeat makes any count inside the default eval branch quota" {
    // A copy per loop iteration would need a quota in the hundreds of thousands.
    const big = repeat("ab", 1 << 16);
    try std.testing.expectEqual(@as(usize, 1 << 17), big.len);
    try std.testing.expectEqual(@as(usize, 1 << 16), std.mem.count(u8, big, "ab"));
    try std.testing.expectEqual(@as(u8, 0), big[big.len]);
}

/// Each row's text and whether it leaked, for the tests of `rows`.
const Seen = struct {
    lines: [8][]const u8 = undefined,
    count: usize = 0,
    /// The line, by its text, that leaks a block the first time it runs.
    leaky: []const u8 = "",
    leaked: bool = false,

    fn row(s: *Seen, gpa: std.mem.Allocator, line: []const u8) anyerror!void {
        s.lines[s.count] = line;
        s.count += 1;
        const copy = try gpa.dupe(u8, line);
        if (std.mem.eql(u8, line, s.leaky) and !s.leaked) {
            s.leaked = true;
            return;
        }
        gpa.free(copy);
        if (std.mem.eql(u8, line, "bad")) return error.BadRow;
    }
};

test "rows runs each line that is not empty, in order, with an allocator of its own" {
    var seen: Seen = .{};
    try rows(std.testing.allocator, "a\n\nb c\nd\n", &seen, Seen.row);
    try std.testing.expectEqual(@as(usize, 3), seen.count);
    try std.testing.expectEqualStrings("a", seen.lines[0]);
    try std.testing.expectEqualStrings("b c", seen.lines[1]);
    try std.testing.expectEqualStrings("d", seen.lines[2]);
}

test "rows stops at the first row that fails and returns its error" {
    var seen: Seen = .{};
    try std.testing.expectError(error.BadRow, rows(std.testing.allocator, "a\nbad\nc", &seen, Seen.row));
    try std.testing.expectEqual(@as(usize, 2), seen.count);
}

test "a row that leaks fails with error.Leaked, run again traced" {
    // It leaks only the first time, so the traced run logs no leak here.
    var seen: Seen = .{ .leaky = "b" };
    try std.testing.expectError(error.Leaked, rows(std.testing.allocator, "a\nb\nc", &seen, Seen.row));
    try std.testing.expectEqual(@as(usize, 3), seen.count);
    try std.testing.expectEqualStrings("b", seen.lines[1]);
    try std.testing.expectEqualStrings("b", seen.lines[2]);
}
