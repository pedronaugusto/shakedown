//! `Layer` from outside: every slot forwards, overrides keep their own
//! state, and layers stack.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");

const Empty = shakedown.Layer(struct { unused: u8 = 0 }, .{});

test "every vtable slot of an empty layer is a forwarder of its own" {
    const fields = @typeInfo(Io.VTable).@"struct".field_names;
    inline for (fields) |name| {
        const ours: *const anyopaque = @ptrCast(@field(Empty.vtable, name));
        const theirs: *const anyopaque = @ptrCast(@field(testing.io.vtable.*, name));
        try testing.expect(ours != theirs);
    }
}

/// A base that only counts which slot each call reached. It returns
/// `undefined`: the forwarded result is discarded.
const Probe = struct {
    hits: [slot_names.len]u32 = @splat(0),

    /// The userdata every forwarded call must carry: the probe's own.
    var expected: ?*anyopaque = null;

    const slot_names = @typeInfo(Io.VTable).@"struct".field_names;

    const vtable: Io.VTable = blk: {
        var table: Io.VTable = undefined;
        for (slot_names, 0..) |name, i| @field(table, name) = slot(name, i);
        break :blk table;
    };

    fn io(p: *Probe) Io {
        return .{ .userdata = p, .vtable = &vtable };
    }

    fn hit(comptime ret: type, comptime index: usize, u: ?*anyopaque) ret {
        // A forwarder that passed the layer's userdata would land here
        // with an address that is not the probe's.
        std.debug.assert(u == expected);
        const p: *Probe = @ptrCast(@alignCast(u.?)); // safe: checked above to be the probe `Probe.io` handed out
        p.hits[index] += 1;
        return undefined;
    }

    fn slot(comptime name: []const u8, comptime i: usize) @FieldType(Io.VTable, name) {
        const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
        const ret = info.return_type.?;
        const params = info.param_types;
        return switch (params.len) {
            1 => &struct {
                fn f(u: ?*anyopaque) ret {
                    return hit(ret, i, u);
                }
            }.f,
            2 => &struct {
                fn f(u: ?*anyopaque, _: params[1].?) ret {
                    return hit(ret, i, u);
                }
            }.f,
            3 => &struct {
                fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?) ret {
                    return hit(ret, i, u);
                }
            }.f,
            4 => &struct {
                fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?) ret {
                    return hit(ret, i, u);
                }
            }.f,
            5 => &struct {
                fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?, _: params[4].?) ret {
                    return hit(ret, i, u);
                }
            }.f,
            6 => &struct {
                fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?, _: params[4].?, _: params[5].?) ret {
                    return hit(ret, i, u);
                }
            }.f,
            7 => &struct {
                fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?, _: params[4].?, _: params[5].?, _: params[6].?) ret {
                    return hit(ret, i, u);
                }
            }.f,
            else => @compileError("Io.VTable." ++ name ++ " has more parameters than the probe takes"),
        };
    }
};

test "each slot of an empty layer reaches the same slot of its base, once" {
    var probe: Probe = .{};
    Probe.expected = &probe;
    defer Probe.expected = null;
    var layer: Empty = .init(probe.io(), .{});
    const io = layer.io();
    inline for (Probe.slot_names) |name| {
        const Fn = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
        // The arguments are never read: the probe only counts.
        var args: std.meta.ArgsTuple(Fn) = undefined;
        args[0] = io.userdata;
        var result = @call(.auto, @field(io.vtable, name), args);
        _ = &result;
    }
    for (Probe.slot_names, probe.hits) |name, hits| {
        if (hits != 1) {
            std.debug.print("Io.VTable.{s}: reached the base's slot {d} times\n", .{ name, hits });
            return error.TestUnexpectedResult;
        }
    }
}

test "an empty layer behaves as its base" {
    var layer: Empty = .init(testing.io, .{});
    const io = layer.io();
    try testing.expect(io.vtable == &Empty.vtable);
    try testing.expect(Empty.of(io.userdata) == &layer);

    // Files and directories.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "through the layer" });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("through the layer", try tmp.dir.readFile(io, "a", &buf));
    try tmp.dir.rename("a", tmp.dir, "b", io);
    try testing.expectEqual(@as(u64, 17), (try tmp.dir.statFile(io, "b", .{})).size);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "a", .{}));

    // Time and randomness.
    const before = Io.Timestamp.now(testing.io, .awake);
    try io.sleep(.fromMilliseconds(1), .awake);
    // Only that time did not go backwards: Windows' awake clock is coarse.
    try testing.expect(before.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= 0);
    var bytes: [32]u8 = @splat(0);
    io.random(&bytes);
    try testing.expect(!std.mem.allEqual(u8, &bytes, 0));

    // Tasks, futexes and the primitives built on them.
    var event: Io.Event = .unset;
    var task = try io.concurrent(setAfter, .{ io, &event });
    try event.wait(io);
    try task.await(io);
    var mutex: Io.Mutex = .init;
    var group: Io.Group = .init;
    var total: u32 = 0;
    for (0..8) |_| group.async(io, addLocked, .{ io, &mutex, &total });
    try group.await(io);
    try testing.expectEqual(@as(u32, 8), total);
}

fn setAfter(io: Io, event: *Io.Event) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(1), .awake);
    event.set(io);
}

fn addLocked(io: Io, mutex: *Io.Mutex, total: *u32) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    total.* += 1;
}

/// Counts `now` calls in the layer's own state, where a copied vtable
/// would need a global.
const CountNow = shakedown.Layer(struct { calls: u32 = 0 }, .{ .now = CountNowImpl.now });
const CountNowImpl = struct {
    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        const l = CountNow.of(userdata);
        l.state.calls += 1;
        return l.base.vtable.now(l.base.userdata, clock);
    }
};

/// Answers `random` with one fixed byte.
const FixedRandom = shakedown.Layer(struct { byte: u8 }, .{ .random = FixedRandomImpl.random });
const FixedRandomImpl = struct {
    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        @memset(buffer, FixedRandom.of(userdata).state.byte);
    }
};

test "layers keep their own state and stack in either order" {
    var counts: CountNow = .init(testing.io, .{});
    var fixed: FixedRandom = .init(counts.io(), .{ .byte = 0xab });
    const io = fixed.io();
    _ = Io.Timestamp.now(io, .awake);
    _ = Io.Timestamp.now(io, .real);
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    try testing.expectEqualSlices(u8, &.{ 0xab, 0xab, 0xab, 0xab }, &bytes);
    try testing.expectEqual(@as(u32, 2), counts.state.calls);

    // Two layers of one type are two states.
    var outer: CountNow = .init(counts.io(), .{});
    _ = Io.Timestamp.now(outer.io(), .awake);
    try testing.expectEqual(@as(u32, 1), outer.state.calls);
    try testing.expectEqual(@as(u32, 3), counts.state.calls);
}

test "a clock under a layer and a layer under a clock both keep the clock's time" {
    var clock: shakedown.Clock = .init(testing.io, .{});
    var counts: CountNow = .init(clock.io(), .{});
    const start = Io.Timestamp.now(counts.io(), .awake);
    clock.advance(.fromSeconds(5));
    try testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), start.durationTo(Io.Timestamp.now(counts.io(), .awake)).nanoseconds);

    var under: CountNow = .init(testing.io, .{});
    var over: shakedown.Clock = .init(under.io(), .{});
    _ = Io.Timestamp.now(over.io(), .awake);
    try testing.expectEqual(@as(u32, 0), under.state.calls);
    try over.io().sleep(.zero, .awake);
}
