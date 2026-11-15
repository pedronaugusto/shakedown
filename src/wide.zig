//! A cell for a scalar wider than the target's word, shared between threads:
//! a step number, a call count, a clock's reading in nanoseconds. Where the
//! target's word holds it, the cell is `aegis.Atomic`. On a 32-bit target
//! (x86, arm, riscv32, wasm32) std refuses an atomic of 64 bits, so the cell
//! holds the value as two 32-bit halves under a sequence count instead:
//! a writer takes the count from even to odd, writes both halves and makes it
//! even again; a reader reads the count, the halves and the count again, and
//! reads once more until both counts are the same even number.
//!
//! The rule goes by the target's word, not by which targets have a wider
//! atomic (some 32-bit ones do): std gives no list of those, and the split
//! cell is right on every target, only slower.
//!
//! It gives the operations shakedown's cells use: `init`, `load`, `store` and
//! `fetchAddWrapping`, with aegis.Atomic's signatures. The split cell orders
//! each as acquire and release, at least what any caller here asks for.
const std = @import("std");
const aegis = @import("aegis");
const Order = std.lang.AtomicOrder;

/// A cell for `T`, an enum of an integer backing (an aegis unit or id).
pub fn Atomic(comptime T: type) type {
    if (@bitSizeOf(T) <= @bitSizeOf(usize)) return aegis.Atomic(T);
    return Split(T);
}

/// The cell as two 32-bit halves under a sequence count.
fn Split(comptime T: type) type {
    const Repr = @typeInfo(T).@"enum".tag_type;
    const Bits = u64;
    comptime aegis.assert.invariant(@bitSizeOf(Repr) == 64, "@bitSizeOf(Repr) == 64");
    return struct {
        const Self = @This();
        /// Private: even while no write is under way, odd during one.
        aegis_sequence: aegis.Atomic(Sequence),
        /// Private: the value's high and low 32 bits.
        aegis_high: aegis.Atomic(Half),
        aegis_low: aegis.Atomic(Half),

        /// A sequence word: only its parity and its sameness mean anything.
        const Sequence = enum(u32) {
            _,
            fn writing(s: Sequence) bool {
                return @backingInt(s) & 1 == 1;
            }
            fn next(s: Sequence) Sequence {
                return @fromBackingInt(@backingInt(s) +% 1);
            }
        };
        const Half = enum(u32) { _ };

        pub fn init(value: T) Self {
            const bits: Bits = @bitCast(@backingInt(value));
            return .{
                .aegis_sequence = .init(@fromBackingInt(0)),
                .aegis_high = .init(@fromBackingInt(@truncate(bits >> 32))),
                .aegis_low = .init(@fromBackingInt(@truncate(bits))),
            };
        }

        pub fn load(self: *const Self, order: Order) T {
            _ = order;
            while (true) {
                const before = self.aegis_sequence.load(.acquire);
                if (before.writing()) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                // Acquire loads, so the count read after them is not read before them.
                const high = self.aegis_high.load(.acquire);
                const low = self.aegis_low.load(.acquire);
                if (self.aegis_sequence.load(.monotonic) == before) return join(high, low);
            }
        }

        pub fn store(self: *Self, value: T, order: Order) void {
            _ = order;
            const at = self.begin();
            self.put(value);
            self.end(at);
        }

        /// Adds `delta` and wraps at 64 bits; returns the value before.
        pub fn fetchAddWrapping(self: *Self, delta: T, order: Order) T {
            _ = order;
            const at = self.begin();
            const before = join(self.aegis_high.load(.monotonic), self.aegis_low.load(.monotonic));
            const sum: Bits = @as(Bits, @bitCast(@backingInt(before))) +% @as(Bits, @bitCast(@backingInt(delta)));
            self.put(@fromBackingInt(@bitCast(sum)));
            self.end(at);
            return before;
        }

        /// Takes the count from even to odd, waiting out another writer; returns the odd count.
        fn begin(self: *Self) Sequence {
            while (true) {
                const seen = self.aegis_sequence.load(.monotonic);
                if (!seen.writing()) {
                    const odd = seen.next();
                    if (self.aegis_sequence.cmpxchgWeak(seen, odd, .acquire, .monotonic) == null) return odd;
                }
                std.atomic.spinLoopHint();
            }
        }

        fn end(self: *Self, odd: Sequence) void {
            self.aegis_sequence.store(odd.next(), .release);
        }

        fn put(self: *Self, value: T) void {
            const bits: Bits = @bitCast(@backingInt(value));
            self.aegis_high.store(@fromBackingInt(@truncate(bits >> 32)), .release);
            self.aegis_low.store(@fromBackingInt(@truncate(bits)), .release);
        }

        fn join(high: Half, low: Half) T {
            const bits = (@as(Bits, @backingInt(high)) << 32) | @backingInt(low);
            return @fromBackingInt(@bitCast(bits));
        }
    };
}

const TestCount = aegis.units.Count(struct {}, u64);

test "a split cell carries across its halves and wraps at 64 bits" {
    var cell: Split(TestCount) = .init(.fromRaw(0xffff_ffff));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), cell.fetchAddWrapping(.fromRaw(1), .monotonic).raw());
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), cell.load(.monotonic).raw());
    cell.store(.fromRaw(std.math.maxInt(u64)), .monotonic);
    _ = cell.fetchAddWrapping(.fromRaw(2), .monotonic);
    try std.testing.expectEqual(@as(u64, 1), cell.load(.monotonic).raw());
}

test "a split cell loses no add made from several threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var cell: Split(TestCount) = .init(.fromRaw(0xffff_f000));
    const each = 10_000;
    const Adder = struct {
        fn run(c: *Split(TestCount)) void {
            for (0..each) |_| _ = c.fetchAddWrapping(.fromRaw(1), .monotonic);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Adder.run, .{&cell});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 0xffff_f000 + 4 * each), cell.load(.monotonic).raw());
}
