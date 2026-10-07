//! Generators: values drawn from a `Source`.
//!
//! Every generator is laid out so that smaller choices make simpler values:
//! a choice of 0 gives 0, `false`, the first enum field, the shrink target
//! of a range, the empty list. Shrinking a tape toward zeros and shorter
//! therefore shrinks the values drawn from it, with no shrinker per type.
//! Each call is one span on a recording source, so a whole value can be
//! deleted, zeroed or reordered at once.
//!
//! A number is one choice (two for the widest integers), drawn with
//! `Source.integer`: about one in five is an edge (0, ±1, the type's
//! extremes, powers of two and their neighbours; for floats also ±0,
//! infinities, NaN and the subnormals), the rest spread over magnitudes,
//! small as often as large. The lean is only in the drawing, so an edge
//! shrinks toward its neighbours like any value.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");

/// Any value of `T`, shrinking toward 0, the positive side first.
/// Integers up to 128 bits.
pub fn int(s: *Source, comptime T: type) T {
    const info = @typeInfo(T).int;
    if (info.bits == 0) return 0;
    const U = Unsigned(info.bits);
    const mark = s.begin();
    defer s.end(mark);
    const raw: U = if (info.bits <= 64) @intCast(s.integer(std.math.maxInt(U))) else wide: {
        const high = s.integer(std.math.maxInt(Unsigned(info.bits - 64)));
        break :wide (@as(U, @intCast(high)) << 64) | s.integer(std.math.maxInt(u64));
    };
    if (info.signedness == .unsigned) return raw;
    return signed(T, raw);
}

fn Unsigned(comptime bits: u16) type {
    return @Int(.unsigned, bits);
}

/// 0, 1, -1, 2, -2, ...: a smaller choice is a smaller magnitude, the
/// positive one first. The one value left over, the largest, is the type's
/// minimum.
fn signed(comptime T: type, raw: Unsigned(@typeInfo(T).int.bits)) T {
    if (raw == std.math.maxInt(@TypeOf(raw))) return std.math.minInt(T);
    if (raw % 2 == 1) return @intCast((raw >> 1) + 1);
    return -@as(T, @intCast(raw >> 1));
}

/// A value in `[min, max]`, shrinking toward 0 when the range holds it and
/// toward the end nearer 0 otherwise, alternating above and below. Both
/// ends are among its edges. Integers up to 64 bits.
pub fn intRange(s: *Source, comptime T: type, min: T, max: T) T {
    comptime std.debug.assert(@typeInfo(T).int.bits <= 64);
    std.debug.assert(min <= max);
    if (min == max) return min;
    const mark = s.begin();
    defer s.end(mark);
    const towards: T = if (min <= 0 and 0 <= max) 0 else if (min > 0) min else max;
    const up: u64 = @intCast(@as(i128, max) - towards);
    const down: u64 = @intCast(@as(i128, towards) - min);
    return fromOffset(T, towards, up, down, s.integer(up + down));
}

/// The `offset`-th value from `towards`, alternating above and below while
/// both sides have room, then running out along the longer side.
fn fromOffset(comptime T: type, towards: T, up: u64, down: u64, offset: u64) T {
    const both: u128 = @min(up, down);
    const at: i128 = towards;
    if (offset <= 2 * both) {
        if (offset == 0) return towards;
        const step: i128 = @intCast((offset + 1) / 2);
        return @intCast(if (offset % 2 == 1) at + step else at - step);
    }
    const extra: i128 = @intCast(offset - 2 * both);
    return @intCast(if (up > down) at + @as(i128, @intCast(both)) + extra else at - @as(i128, @intCast(both)) - extra);
}

/// Any value of `T`, shrinking toward 0: an integer, positive first, halved
/// some number of times (so 0.5, 1.25 and the like), or, at the far end of
/// the first choice, one of the values float code most often gets wrong:
/// ±0, ±1, the largest and smallest normals, the subnormals, ±infinity,
/// NaN.
pub fn float(s: *Source, comptime T: type) T {
    const mark = s.begin();
    defer s.end(mark);
    const top = std.math.maxInt(u64);
    const choice = s.integer(top);
    const specials = comptime edgeFloats(T);
    if (choice > top - specials.len) return specials[@intCast(top - choice)];
    const whole: T = @floatFromInt(signed(i64, choice));
    const halvings = s.integer(@min(std.math.floatMantissaBits(T), 63));
    return whole / std.math.pow(T, 2, @floatFromInt(halvings));
}
pub fn boolean(s: *Source) bool {
    return s.below(1) == 1;
}

/// One of `E`'s named values, the first one simplest.
pub fn enumValue(s: *Source, comptime E: type) E {
    const values = comptime std.enums.values(E);
    if (values.len == 1) return values[0];
    const mark = s.begin();
    defer s.end(mark);
    return values[s.below(values.len - 1)];
}

/// One of `items`, the first one simplest. `items` must not be empty.
pub fn oneOf(s: *Source, comptime T: type, items: []const T) T {
    std.debug.assert(items.len > 0);
    if (items.len == 1) return items[0];
    const mark = s.begin();
    defer s.end(mark);
    return items[s.below(items.len - 1)];
}

/// An index into `weights`, each drawn in proportion to its weight; the
/// first one simplest. The weights must not all be 0.
pub fn weighted(s: *Source, weights: []const u32) usize {
    var total: u64 = 0;
    for (weights) |w| total += w;
    std.debug.assert(total > 0);
    const mark = s.begin();
    defer s.end(mark);
    var at = s.below(total - 1);
    for (weights, 0..) |w, i| {
        if (at < w) return i;
        at -= w;
    }
    unreachable; // unreachable: `at` is below the total of the weights
}

pub const SliceOptions = struct {
    min_len: usize = 0,
    max_len: usize = std.math.maxInt(usize),
    /// The mean length above `min_len`, before `max_len` cuts it.
    average: u32 = 8,
};

/// A list of `elem` draws. Each element and the choice to draw it are one
/// span, so the shrinker deletes elements whole.
pub fn slice(
    s: *Source,
    comptime T: type,
    comptime elem: fn (*Source) T,
    gpa: Allocator,
    options: SliceOptions,
) error{OutOfMemory}![]T {
    std.debug.assert(options.min_len <= options.max_len);
    var list: std.ArrayList(T) = .empty;
    errdefer list.deinit(gpa);
    const mark = s.begin();
    defer s.end(mark);
    while (list.items.len < options.max_len) {
        const item = s.begin();
        defer s.end(item);
        if (list.items.len >= options.min_len and !s.more(options.average)) break;
        try list.append(gpa, elem(s));
    }
    return list.toOwnedSlice(gpa);
}

pub const StringOptions = struct {
    kind: Kind = .utf8,
    /// In characters for `.ascii` and `.utf8`, in bytes for `.bytes`.
    min_len: usize = 0,
    max_len: usize = std.math.maxInt(usize),
    average: u32 = 8,

    pub const Kind = enum {
        /// Code points 0 to 127, the simplest being '0'.
        ascii,
        /// Valid UTF-8, mostly ASCII, sometimes beyond: the rest of the
        /// Basic Multilingual Plane and the planes above it, never a
        /// surrogate.
        utf8,
        /// Any bytes.
        bytes,
    };
};

/// Text of the kind asked for.
pub fn string(s: *Source, gpa: Allocator, options: StringOptions) error{OutOfMemory}![]u8 {
    std.debug.assert(options.min_len <= options.max_len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const mark = s.begin();
    defer s.end(mark);
    var len: usize = 0;
    while (len < options.max_len) : (len += 1) {
        const item = s.begin();
        defer s.end(item);
        if (len >= options.min_len and !s.more(options.average)) break;
        switch (options.kind) {
            .bytes => try out.append(gpa, @intCast(s.below(255))),
            .ascii => try out.append(gpa, ascii(s)),
            .utf8 => {
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codePoint(s), &buffer) catch unreachable; // unreachable: codePoint never draws a surrogate or a value past U+10FFFF
                try out.appendSlice(gpa, buffer[0..n]);
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A code point below 128, the simplest being '0'.
fn ascii(s: *Source) u8 {
    return @intCast((s.below(127) + '0') % 128);
}

fn codePoint(s: *Source) u21 {
    const mode = s.below(7);
    if (mode < 5) return ascii(s);
    if (mode == 5) {
        // U+0080 to U+FFFF without the surrogates.
        const c: u21 = @intCast(0x80 + s.below(0xffff - 0x80 - 0x800));
        return if (c >= 0xd800) c + 0x800 else c;
    }
    return @intCast(0x10000 + s.below(0x10ffff - 0x10000));
}

/// Any value of `T` by reflection: integers, floats, booleans, enums,
/// optionals (null simplest), arrays, vectors, structs, tagged unions and
/// slices, allocated from `gpa`. Collections grow shorter as values nest
/// deeper, so a recursive type ends.
pub fn any(s: *Source, comptime T: type, gpa: Allocator) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return boolean(s),
        .int => return int(s, T),
        .float => return float(s, T),
        .@"enum" => return enumValue(s, T),
        .optional => |o| {
            const mark = s.begin();
            defer s.end(mark);
            if (s.below(1) == 0) return null;
            return try any(s, o.child, gpa);
        },
        .array => |a| {
            var out: T = undefined;
            const mark = s.begin();
            defer s.end(mark);
            for (&out) |*item| item.* = try any(s, a.child, gpa);
            return out;
        },
        .vector => |v| {
            var out: [v.len]v.child = undefined;
            const mark = s.begin();
            defer s.end(mark);
            for (&out) |*item| item.* = try any(s, v.child, gpa);
            return out;
        },
        .@"struct" => |st| {
            var out: T = undefined;
            const mark = s.begin();
            defer s.end(mark);
            inline for (st.field_names, st.field_types) |name, F| @field(out, name) = try any(s, F, gpa);
            return out;
        },
        .@"union" => |u| {
            comptime std.debug.assert(u.tag_type != null);
            const mark = s.begin();
            defer s.end(mark);
            switch (enumValue(s, u.tag_type.?)) {
                inline else => |tag| return @unionInit(T, @tagName(tag), try any(s, @FieldType(T, @tagName(tag)), gpa)),
            }
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("any draws slices, not single pointers: " ++ @typeName(T));
            return anySlice(s, T, p, gpa);
        },
        else => @compileError("any cannot draw " ++ @typeName(T)),
    }
}

fn anySlice(s: *Source, comptime T: type, comptime p: std.builtin.Type.Pointer, gpa: Allocator) error{OutOfMemory}!T {
    const Elem = p.child;
    var list: std.ArrayList(Elem) = .empty;
    defer list.deinit(gpa);
    const mark = s.begin();
    defer s.end(mark);
    // Deeper values get shorter lists: 8 on average at the top, none
    // past 24 open spans.
    const average: u32 = if (s.depth >= 24) 0 else 8 >> @intCast(s.depth / 6);
    while (true) {
        const item = s.begin();
        defer s.end(item);
        if (!s.more(average)) break;
        try list.append(gpa, if (Elem == u8) @intCast(s.below(255)) else try any(s, Elem, gpa));
    }
    if (comptime p.sentinel()) |sentinel| {
        const out = try gpa.allocSentinel(Elem, list.items.len, sentinel);
        @memcpy(out, list.items);
        return out;
    }
    return list.toOwnedSlice(gpa);
}

/// A `draw` that `keep` accepts, trying `tries` times; each rejected try
/// stays on the tape as a span the shrinker may delete.
pub fn filter(
    s: *Source,
    comptime T: type,
    comptime draw: fn (*Source) T,
    comptime keep: fn (T) bool,
    tries: u32,
) error{Unsatisfiable}!T {
    for (0..tries) |_| {
        const mark = s.begin();
        const value = draw(s);
        s.end(mark);
        if (keep(value)) return value;
    }
    return error.Unsatisfiable;
}

fn edgeFloats(comptime T: type) []const T {
    const inf = std.math.inf(T);
    const max = std.math.floatMax(T);
    const normal = std.math.floatMin(T);
    const tiny = std.math.floatTrueMin(T);
    const out = [_]T{ std.math.nan(T), inf, -inf, max, -max, -0.0, normal, -normal, tiny, -tiny, std.math.floatEps(T), normal / 2 };
    return &out;
}

test "signed values come positive first, and every value comes from one choice" {
    var got: [5]i8 = undefined;
    for (&got, 0..) |*g, raw| g.* = signed(i8, @intCast(raw));
    try std.testing.expectEqualSlices(i8, &.{ 0, 1, -1, 2, -2 }, &got);
    var seen: [256]bool = @splat(false);
    for (0..256) |raw| {
        const v = signed(i8, @intCast(raw));
        seen[@as(u8, @bitCast(v))] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

test "a zero tape draws the simplest value of every kind" {
    var s: Source = try .init(std.testing.allocator, .{ .replay = &.{} });
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), int(&s, u32));
    try std.testing.expectEqual(@as(i64, 0), int(&s, i64));
    try std.testing.expectEqual(@as(i8, 0), intRange(&s, i8, -5, 5));
    try std.testing.expectEqual(@as(i8, 3), intRange(&s, i8, 3, 9));
    try std.testing.expectEqual(@as(i8, -3), intRange(&s, i8, -9, -3));
    try std.testing.expectEqual(@as(f64, 0), float(&s, f64));
    try std.testing.expect(!boolean(&s));
    try std.testing.expectEqual(Color.red, enumValue(&s, Color));
    const list = try slice(&s, u8, struct {
        fn f(src: *Source) u8 {
            return int(src, u8);
        }
    }.f, std.testing.allocator, .{});
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
    const text = try string(&s, std.testing.allocator, .{ .min_len = 2 });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("00", text);
    const Value = struct { a: u8, b: ?u16, c: [2]bool, d: union(enum) { x: u8, y: void } };
    const v = try any(&s, Value, std.testing.allocator);
    try std.testing.expectEqual(Value{ .a = 0, .b = null, .c = .{ false, false }, .d = .{ .x = 0 } }, v);
}

test "a range's values alternate around its target, then run along the longer side" {
    var got: [9]i8 = undefined;
    for (&got, 0..) |*g, i| g.* = fromOffset(i8, 0, 2, 6, i);
    try std.testing.expectEqualSlices(i8, &.{ 0, 1, -1, 2, -2, -3, -4, -5, -6 }, &got);
    try std.testing.expectEqual(@as(u8, 250), fromOffset(u8, 0, 255, 0, 250));
}

test "floats: halves of integers, and the specials at the far end" {
    var s: Source = try .init(std.testing.allocator, .{ .replay = &.{ 3, 1, std.math.maxInt(u64), std.math.maxInt(u64) - 1 } });
    defer s.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), float(&s, f64));
    try std.testing.expect(std.math.isNan(float(&s, f64)));
    try std.testing.expect(std.math.isPositiveInf(float(&s, f64)));
}

test "a 128-bit integer is two choices and covers its range" {
    var s: Source = try .init(std.testing.allocator, .{ .replay = &.{ std.math.maxInt(u64), std.math.maxInt(u64) } });
    defer s.deinit();
    try std.testing.expectEqual(@as(u128, std.math.maxInt(u128)), int(&s, u128));
}

const Color = enum { red, green, blue };
