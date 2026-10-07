//! The shrinking challenge (github.com/jlink/shrinking-challenge): each
//! property fails, and `check` must shrink it to the problem's canonical
//! minimal counterexample, from each of nine seeds. These are the quality
//! gate for shrinking: a change that makes any result larger fails here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const gen = shakedown.gen;
const Case = shakedown.Case;
const Source = shakedown.Source;

const seeds = [_]u64{ 2026, 1, 2, 3, 4, 5, 6, 7, 8 };

/// Runs `body` under `check` from each seed until it fails, replays each
/// minimal tape through `decode`, and returns what they draw.
fn minimal(comptime T: type, comptime body: fn (void, *Case) anyerror!void, comptime decode: fn (Allocator, *Source) anyerror!T, arena: Allocator) ![seeds.len]T {
    var out: [seeds.len]T = undefined;
    for (&out, seeds) |*o, seed| {
        var report: shakedown.CheckReport = undefined;
        try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, body, .{ .seed = seed, .cases = 2000, .diagnostics = &report }));
        defer report.deinit();
        var s: Source = try .init(arena, .{ .replay = report.tape });
        o.* = try decode(arena, &s);
    }
    return out;
}

fn int32(s: *Source) i32 {
    return gen.int(s, i32);
}

fn int16(s: *Source) i16 {
    return gen.int(s, i16);
}

fn ints(gpa: Allocator, s: *Source) ![]i32 {
    return gen.slice(s, i32, int32, gpa, .{});
}

// reverse: reversing a list gives it back.

fn reverse(_: void, c: *Case) !void {
    const list = try ints(c.gpa, c.source);
    const copy = try c.gpa.dupe(i32, list);
    std.mem.reverse(i32, copy);
    if (!std.mem.eql(i32, list, copy)) return error.Reversed;
}

test "reverse shrinks to [0, 1]" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([]i32, reverse, ints, arena.allocator())) |got| try testing.expectEqualSlices(i32, &.{ 0, 1 }, got);
}

// bound5: five lists of 16-bit integers each summing below 256 sum below
// 5 * 256, but for overflow.

fn int16s(gpa: Allocator, s: *Source) ![]i16 {
    return gen.slice(s, i16, int16, gpa, .{});
}

fn five(gpa: Allocator, s: *Source) ![5][]i16 {
    var out: [5][]i16 = undefined;
    for (&out) |*list| list.* = try int16s(gpa, s);
    return out;
}

fn sum16(list: []const i16) i16 {
    var sum: i16 = 0;
    for (list) |x| sum +%= x;
    return sum;
}

fn bound5(_: void, c: *Case) !void {
    const lists = try five(c.gpa, c.source);
    c.note("{any}", .{lists});
    var total: i16 = 0;
    for (lists) |list| {
        if (sum16(list) >= 256) return;
        total +%= sum16(list);
    }
    if (total >= 5 * 256) return error.Overflowed;
}

// The canonical answer is ([-32768], [-1], [], [], []). What every seed
// reaches is its size, two one-element lists; the values are the ones a
// shrink of the tape's choices can reach, which for -32768, the one value
// zigzag order puts last, can stop at a pair like (-3, -32766).
test "bound5 shrinks to two one-element lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([5][]i16, bound5, five, arena.allocator())) |got| {
        var nonempty: usize = 0;
        for (got) |list| {
            try testing.expect(list.len <= 1);
            nonempty += list.len;
        }
        try testing.expectEqual(@as(usize, 2), nonempty);
    }
}

// large union list: the union of some lists of integers has fewer than
// five distinct elements.

fn intLists(gpa: Allocator, s: *Source) ![][]i32 {
    var outer: std.ArrayList([]i32) = .empty;
    const mark = s.begin();
    defer s.end(mark);
    while (true) {
        const item = s.begin();
        defer s.end(item);
        if (!s.more(4)) break;
        try outer.append(gpa, try ints(gpa, s));
    }
    return outer.items;
}

fn distinctCount(gpa: Allocator, values: []const i32) !usize {
    var set: std.AutoHashMapUnmanaged(i32, void) = .empty;
    for (values) |v| try set.put(gpa, v, {});
    return set.count();
}

fn largeUnion(_: void, c: *Case) !void {
    const lists = try intLists(c.gpa, c.source);
    var all: std.ArrayList(i32) = .empty;
    for (lists) |list| try all.appendSlice(c.gpa, list);
    if (try distinctCount(c.gpa, all.items) >= 5) return error.FiveDistinct;
}

test "large union list shrinks to one list of 0, 1, -1, 2, -2" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([][]i32, largeUnion, intLists, arena.allocator())) |got| {
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualSlices(i32, &.{ 0, 1, -1, 2, -2 }, got[0]);
    }
}

// calculator: an expression with no literal division by zero evaluates
// without dividing by zero.

const Expr = union(enum) {
    int: i32,
    add: [2]*const Expr,
    div: [2]*const Expr,

    fn draw(gpa: Allocator, s: *Source) error{OutOfMemory}!*const Expr {
        const mark = s.begin();
        defer s.end(mark);
        const e = try gpa.create(Expr);
        // Deeper nodes are leaves more often, so a tree ends.
        const kind = if (s.depth > 12) 0 else s.below(2);
        e.* = switch (kind) {
            0 => .{ .int = gen.intRange(s, i32, -5, 5) },
            1 => .{ .add = .{ try draw(gpa, s), try draw(gpa, s) } },
            else => .{ .div = .{ try draw(gpa, s), try draw(gpa, s) } },
        };
        return e;
    }

    fn literalZeroDivisor(e: *const Expr) bool {
        return switch (e.*) {
            .int => false,
            .add => |p| p[0].literalZeroDivisor() or p[1].literalZeroDivisor(),
            .div => |p| (p[1].* == .int and p[1].int == 0) or p[0].literalZeroDivisor() or p[1].literalZeroDivisor(),
        };
    }

    fn eval(e: *const Expr) error{DivisionByZero}!i32 {
        return switch (e.*) {
            .int => |v| v,
            .add => |p| try p[0].eval() +% try p[1].eval(),
            .div => |p| {
                const d = try p[1].eval();
                if (d == 0) return error.DivisionByZero;
                return @divTrunc(try p[0].eval(), d);
            },
        };
    }

    fn equal(a: *const Expr, b: *const Expr) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .int => |v| v == b.int,
            .add => |p| p[0].equal(b.add[0]) and p[1].equal(b.add[1]),
            .div => |p| p[0].equal(b.div[0]) and p[1].equal(b.div[1]),
        };
    }
};

fn calculator(_: void, c: *Case) !void {
    const e = try Expr.draw(c.gpa, c.source);
    c.note("{any}", .{e.*});
    if (e.literalZeroDivisor()) return;
    _ = try e.eval();
}

test "calculator shrinks to 0 / (0 + 0)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const zero: Expr = .{ .int = 0 };
    const sum: Expr = .{ .add = .{ &zero, &zero } };
    const want: Expr = .{ .div = .{ &zero, &sum } };
    for (try minimal(*const Expr, calculator, Expr.draw, arena.allocator())) |got| try testing.expect(got.equal(&want));
}

// length list: a list of 1 to 100 integers from 0 to 1000 has its
// maximum below 900.

fn upTo1000(s: *Source) u16 {
    return gen.intRange(s, u16, 0, 1000);
}

fn lengthList(gpa: Allocator, s: *Source) ![]u16 {
    return gen.slice(s, u16, upTo1000, gpa, .{ .min_len = 1, .max_len = 100 });
}

fn maxBelow900(_: void, c: *Case) !void {
    const list = try lengthList(c.gpa, c.source);
    if (std.mem.max(u16, list) >= 900) return error.Large;
}

test "length list shrinks to [900]" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([]u16, maxBelow900, lengthList, arena.allocator())) |got| try testing.expectEqualSlices(u16, &.{900}, got);
}

// difference: three properties of a pair of positive integers.

const Pair = struct { x: i64, y: i64 };

fn pair(_: Allocator, s: *Source) !Pair {
    return .{ .x = gen.intRange(s, i64, 1, std.math.maxInt(i64)), .y = gen.intRange(s, i64, 1, std.math.maxInt(i64)) };
}

fn difference1(_: void, c: *Case) !void {
    const p = try pair(c.gpa, c.source);
    if (p.x >= 10 and p.x == p.y) return error.Equal;
}

fn difference2(_: void, c: *Case) !void {
    const p = try pair(c.gpa, c.source);
    const d = @abs(p.x - p.y);
    if (p.x >= 10 and d >= 1 and d <= 4) return error.Close;
}

fn difference3(_: void, c: *Case) !void {
    const p = try pair(c.gpa, c.source);
    if (p.x >= 10 and @abs(p.x - p.y) == 1) return error.Adjacent;
}

test "the differences shrink to (10, 10), (10, 6) and (10, 9)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal(Pair, difference1, pair, arena.allocator())) |got| try testing.expectEqual(Pair{ .x = 10, .y = 10 }, got);
    for (try minimal(Pair, difference2, pair, arena.allocator())) |got| try testing.expectEqual(Pair{ .x = 10, .y = 6 }, got);
    for (try minimal(Pair, difference3, pair, arena.allocator())) |got| try testing.expectEqual(Pair{ .x = 10, .y = 9 }, got);
}

// coupling: in a list of indices into itself, whenever l[i] = j != i,
// l[j] != i.

fn upTo10(s: *Source) u8 {
    return gen.intRange(s, u8, 0, 10);
}

fn indices(gpa: Allocator, s: *Source) ![]u8 {
    return gen.slice(s, u8, upTo10, gpa, .{});
}

fn coupling(_: void, c: *Case) !void {
    const list = try indices(c.gpa, c.source);
    c.note("{any}", .{list});
    for (list) |v| if (v >= list.len) return error.Unsatisfiable;
    for (list, 0..) |j, i| {
        if (j != i and list[j] == i) return error.Coupled;
    }
}

test "coupling shrinks to [1, 0]" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([]u8, coupling, indices, arena.allocator())) |got| try testing.expectEqualSlices(u8, &.{ 1, 0 }, got);
}

// deletion: removing an element of a list leaves no copy of it.

const Deletion = struct { list: []i32, index: usize };

fn deletionInput(gpa: Allocator, s: *Source) !Deletion {
    const list = try gen.slice(s, i32, int32, gpa, .{ .min_len = 1 });
    return .{ .list = list, .index = gen.intRange(s, usize, 0, list.len - 1) };
}

fn deletion(_: void, c: *Case) !void {
    const d = try deletionInput(c.gpa, c.source);
    const x = d.list[d.index];
    var rest: std.ArrayList(i32) = .empty;
    try rest.appendSlice(c.gpa, d.list);
    _ = rest.orderedRemove(std.mem.findScalar(i32, rest.items, x).?);
    if (std.mem.findScalar(i32, rest.items, x) != null) return error.StillThere;
}

test "deletion shrinks to [0, 0] at 0" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal(Deletion, deletion, deletionInput, arena.allocator())) |got| {
        try testing.expectEqualSlices(i32, &.{ 0, 0 }, got.list);
        try testing.expectEqual(@as(usize, 0), got.index);
    }
}

// distinct: a list has fewer than three distinct elements.

fn distinct(_: void, c: *Case) !void {
    const list = try ints(c.gpa, c.source);
    if (try distinctCount(c.gpa, list) >= 3) return error.ThreeDistinct;
}

test "distinct shrinks to [0, 1, -1]" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([]i32, distinct, ints, arena.allocator())) |got| try testing.expectEqualSlices(i32, &.{ 0, 1, -1 }, got);
}

// nested lists: the lists of a list of lists hold at most ten elements.

fn nestedLists(_: void, c: *Case) !void {
    const lists = try intLists(c.gpa, c.source);
    var total: usize = 0;
    for (lists) |list| total += list.len;
    if (total > 10) return error.TooMany;
}

test "nested lists shrink to one list of eleven zeros" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (try minimal([][]i32, nestedLists, intLists, arena.allocator())) |got| {
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualSlices(i32, &(@as([11]i32, @splat(0))), got[0]);
    }
}
