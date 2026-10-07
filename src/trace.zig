//! `Trace(Event)`: the record of what a run did, step by step.
//!
//! A trace keeps every record (`.all`), the last n (`.last`) or none
//! (`.off`). Whatever it keeps, it hashes every record it is given into a
//! rolling hash, so two runs can be compared in any mode, and outside
//! `.off` it remembers the hash after each record, so `firstDifference`
//! names the first record at which two runs part.
//!
//! Byte slices in an event (paths, names) are copied into the trace and
//! interned on `append`, so a caller may pass temporaries; a path a run
//! names a thousand times is stored once.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn Trace(comptime Event: type) type {
    return struct {
        /// Private: everything below is the trace's.
        gpa: Allocator,
        mode: Mode,
        /// Private: `.all` keeps records here in order; `.last` keeps each
        /// one twice, at `i % n` and `i % n + n`, so the newest n are
        /// always one contiguous slice.
        kept: std.ArrayList(Record) = .empty,
        /// Private: the rolling hash after each record, outside `.off`.
        prefixes: std.ArrayList(u64) = .empty,
        /// Private: interned bytes.
        strings: std.StringHashMapUnmanaged(void) = .empty,
        arena: std.heap.ArenaAllocator,
        count: u64 = 0,
        rolling: u64 = seed,

        const Self = @This();
        const seed: u64 = 0x5348_414b_4544_4f57;

        pub const Mode = union(enum) { off, all, last: u32 };

        pub const Record = struct {
            step: u64,
            /// The task that made the call, where the base knows tasks; 0 otherwise.
            task: u32 = 0,
            /// When the call returned, on the base's awake clock. Not hashed:
            /// two runs on a real clock differ in it and nothing else.
            at: Io.Timestamp = .zero,
            event: Event,
        };

        pub fn init(gpa: Allocator, mode: Mode) Self {
            if (mode == .last) std.debug.assert(mode.last > 0);
            return .{ .gpa = gpa, .mode = mode, .arena = .init(gpa) };
        }

        pub fn deinit(t: *Self) void {
            t.kept.deinit(t.gpa);
            t.prefixes.deinit(t.gpa);
            t.strings.deinit(t.gpa);
            t.arena.deinit();
            t.* = undefined;
        }

        /// Forgets every record and hash; keeps the interned strings.
        pub fn clear(t: *Self) void {
            t.kept.clearRetainingCapacity();
            t.prefixes.clearRetainingCapacity();
            t.count = 0;
            t.rolling = seed;
        }

        pub const AppendError = error{OutOfMemory};

        pub fn append(t: *Self, record: Record) AppendError!void {
            const h = recordHash(record);
            t.rolling = std.hash.Wyhash.hash(t.rolling, std.mem.asBytes(&h));
            if (t.mode == .off) {
                t.count += 1;
                return;
            }
            try t.prefixes.append(t.gpa, t.rolling);
            errdefer _ = t.prefixes.pop();
            var kept = record;
            kept.event = try t.intern(Event, record.event);
            switch (t.mode) {
                .off => unreachable, // unreachable: returned above
                .all => try t.kept.append(t.gpa, kept),
                .last => |n| {
                    if (t.kept.items.len == 0) try t.kept.ensureTotalCapacityPrecise(t.gpa, 2 * @as(usize, n));
                    if (t.kept.items.len < 2 * @as(usize, n)) t.kept.items.len = 2 * @as(usize, n);
                    const at: usize = @intCast(t.count % n);
                    t.kept.items[at] = kept;
                    t.kept.items[at + n] = kept;
                },
            }
            t.count += 1;
        }

        /// The kept records, oldest first: every one for `.all`, the newest
        /// n for `.last`, none for `.off`. Under one task this is step
        /// order; tasks on a threaded base append as their calls return.
        pub fn records(t: *const Self) []const Record {
            return switch (t.mode) {
                .off => &.{},
                .all => t.kept.items,
                .last => |n| if (t.count <= n)
                    t.kept.items[0..@intCast(t.count)]
                else
                    t.kept.items[@intCast(t.count % n)..][0..n],
            };
        }

        /// A rolling hash over every record ever appended, in every mode.
        pub fn hash(t: *const Self) u64 {
            return t.rolling;
        }

        /// How many records were appended, kept or not.
        pub fn len(t: *const Self) u64 {
            return t.count;
        }

        /// The rolling hash after record `index`, outside `.off`.
        pub fn hashAt(t: *const Self, index: u64) ?u64 {
            if (t.mode == .off or index >= t.prefixes.items.len) return null;
            return t.prefixes.items[@intCast(index)];
        }

        /// The first index at which `a` and `b` differ; null if one is a
        /// prefix of the other. With `.off` on either side only the totals
        /// are known, and any difference is reported at index 0.
        pub fn firstDifference(a: *const Self, b: *const Self) ?u64 {
            if (a.mode == .off or b.mode == .off) return if (a.count == b.count and a.rolling == b.rolling) null else 0;
            const shorter = @min(a.prefixes.items.len, b.prefixes.items.len);
            // The prefix hashes agree up to the first difference and never
            // after it, so the first disagreement is a binary search away.
            var lo: usize = 0;
            var hi: usize = shorter;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (a.prefixes.items[mid] == b.prefixes.items[mid]) lo = mid + 1 else hi = mid;
            }
            return if (lo == shorter) null else lo;
        }

        /// One line per kept record: step, task and event.
        pub fn format(t: *const Self, w: *Io.Writer) Io.Writer.Error!void {
            for (t.records()) |r| {
                if (comptime std.meta.hasMethod(Event, "format")) {
                    try w.print("{d:>6} {d:>3} {f}\n", .{ r.step, r.task, r.event });
                } else {
                    try w.print("{d:>6} {d:>3} {any}\n", .{ r.step, r.task, r.event });
                }
            }
        }

        fn recordHash(record: Record) u64 {
            var hasher: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hasher, record.step);
            if (comptime std.meta.hasMethod(Event, "hash")) {
                record.event.hash(&hasher);
            } else {
                std.hash.autoHashStrat(&hasher, record.event, .Deep);
            }
            return hasher.final();
        }

        /// A copy of `value` whose byte slices are the trace's own.
        fn intern(t: *Self, comptime T: type, value: T) AppendError!T {
            if (comptime !hasBytes(T)) return value;
            switch (@typeInfo(T)) {
                .pointer => |p| {
                    if (p.size != .slice or p.child != u8) return value;
                    const copy = try t.internBytes(value);
                    return if (p.sentinel() != null) copy else copy[0..copy.len];
                },
                .optional => |o| return if (value) |v| try t.intern(o.child, v) else null,
                .@"struct" => |s| {
                    var out = value;
                    inline for (s.field_names, s.field_types) |name, F| {
                        @field(out, name) = try t.intern(F, @field(value, name));
                    }
                    return out;
                },
                .@"union" => |u| {
                    if (u.tag_type == null) return value;
                    switch (value) {
                        inline else => |payload, tag| {
                            const F = @TypeOf(payload);
                            return @unionInit(T, @tagName(tag), try t.intern(F, payload));
                        },
                    }
                },
                else => return value,
            }
        }

        /// Whether a `T` can hold a byte slice that `intern` copies.
        fn hasBytes(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .pointer => |p| p.size == .slice and p.child == u8,
                .optional => |o| hasBytes(o.child),
                .@"struct" => |s| for (s.field_types) |F| {
                    if (hasBytes(F)) break true;
                } else false,
                .@"union" => |u| u.tag_type != null and for (u.field_types) |F| {
                    if (hasBytes(F)) break true;
                } else false,
                else => false,
            };
        }

        fn internBytes(t: *Self, bytes: []const u8) AppendError![:0]const u8 {
            const entry = try t.strings.getOrPut(t.gpa, bytes);
            if (entry.found_existing) return entry.key_ptr.*.ptr[0..bytes.len :0];
            errdefer t.strings.removeByPtr(entry.key_ptr);
            const copy = try t.arena.allocator().alloc(u8, bytes.len + 1);
            @memcpy(copy[0..bytes.len], bytes);
            copy[bytes.len] = 0;
            entry.key_ptr.* = copy[0..bytes.len];
            return copy[0..bytes.len :0];
        }
    };
}

const TestEvent = struct { name: []const u8, value: u32 };
const TestTrace = Trace(TestEvent);

test "a trace keeps every record, or the newest n, or none, and hashes them all" {
    var buffer: [8]u8 = undefined;
    var all: TestTrace = .init(std.testing.allocator, .all);
    defer all.deinit();
    var last: TestTrace = .init(std.testing.allocator, .{ .last = 3 });
    defer last.deinit();
    var off: TestTrace = .init(std.testing.allocator, .off);
    defer off.deinit();
    for (0..5) |i| {
        // A temporary name: the trace keeps its own copy.
        const name = try std.mem.print(&buffer, "n{d}", .{i % 2});
        const record: TestTrace.Record = .{ .step = i, .event = .{ .name = name, .value = @intCast(i) } };
        try all.append(record);
        try last.append(record);
        try off.append(record);
    }
    @memset(&buffer, 'x');
    try std.testing.expectEqual(@as(usize, 5), all.records().len);
    try std.testing.expectEqualStrings("n0", all.records()[4].event.name);
    try std.testing.expect(all.records()[0].event.name.ptr == all.records()[2].event.name.ptr);
    const tail = last.records();
    try std.testing.expectEqual(@as(usize, 3), tail.len);
    for (tail, 2..) |r, step| try std.testing.expectEqual(@as(u64, step), r.step);
    try std.testing.expectEqual(@as(usize, 0), off.records().len);
    try std.testing.expectEqual(all.hash(), last.hash());
    try std.testing.expectEqual(all.hash(), off.hash());
    try std.testing.expectEqual(@as(u64, 5), off.len());
}

test "firstDifference names the first record two runs part at" {
    var a: TestTrace = .init(std.testing.allocator, .all);
    defer a.deinit();
    var b: TestTrace = .init(std.testing.allocator, .{ .last = 2 });
    defer b.deinit();
    for (0..100) |i| {
        try a.append(.{ .step = i, .event = .{ .name = "x", .value = @intCast(i) } });
        const v: u32 = if (i == 61) 0 else @intCast(i);
        try b.append(.{ .step = i, .event = .{ .name = "x", .value = v } });
    }
    try std.testing.expectEqual(@as(?u64, 61), TestTrace.firstDifference(&a, &b));
    var prefix: TestTrace = .init(std.testing.allocator, .all);
    defer prefix.deinit();
    for (0..40) |i| try prefix.append(.{ .step = i, .event = .{ .name = "x", .value = @intCast(i) } });
    try std.testing.expectEqual(@as(?u64, null), TestTrace.firstDifference(&a, &prefix));
    try std.testing.expectEqual(a.hashAt(39), prefix.hashAt(39));
}

test "the timestamp and task are not part of the hash" {
    var a: TestTrace = .init(std.testing.allocator, .off);
    defer a.deinit();
    var b: TestTrace = .init(std.testing.allocator, .off);
    defer b.deinit();
    try a.append(.{ .step = 0, .task = 1, .at = .fromNanoseconds(5), .event = .{ .name = "x", .value = 1 } });
    try b.append(.{ .step = 0, .task = 2, .at = .fromNanoseconds(9), .event = .{ .name = "x", .value = 1 } });
    try std.testing.expectEqual(a.hash(), b.hash());
    try std.testing.expectEqual(@as(?u64, null), TestTrace.firstDifference(&a, &b));
}

test "a trace formats one line per record" {
    var t: TestTrace = .init(std.testing.allocator, .all);
    defer t.deinit();
    try t.append(.{ .step = 0, .event = .{ .name = "open", .value = 3 } });
    try t.append(.{ .step = 1, .event = .{ .name = "read", .value = 4 } });
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try t.format(&out.writer);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "     0   0 "));
}
