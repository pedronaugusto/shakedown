//! Time as a `Clock` and a simulation keep it: nanoseconds in an `i64`,
//! from each clock's zero, which past ±292 years saturate. std's spans and
//! timestamps come in here, by aegis's checked conversions, and go back out.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// A span as it is kept.
pub const Span = aegis.units.Duration(.nanosecond, i64);

/// A reading of a clock of `ClockTag`'s as it is kept.
pub fn Reading(comptime ClockTag: anytype) type {
    return aegis.units.Instant(ClockTag, .nanosecond, i64);
}

/// std's span, which holds every one kept and more.
const WideSpan = aegis.units.Duration(.nanosecond, i96);

/// `d` as it is kept.
pub fn span(d: Io.Duration) Span {
    const wide = WideSpan.fromIoDuration(d, .exact);
    return wide.convert(.nanosecond, i64, .exact) catch
        if (wide.compare(.fromRaw(0)) == .lt) .fromRaw(std.math.minInt(i64)) else .fromRaw(std.math.maxInt(i64));
}

/// `t`, read on a clock of `ClockTag`'s, as it is kept.
pub fn reading(comptime ClockTag: anytype, t: Io.Timestamp) Reading(ClockTag) {
    const wide = aegis.units.Instant(ClockTag, .nanosecond, i96).fromTimestamp(t, .exact);
    return wide.convert(.nanosecond, i64, .exact) catch
        if (wide.compare(.fromRaw(0)) == .lt) .fromRaw(std.math.minInt(i64)) else .fromRaw(std.math.maxInt(i64));
}

test "spans and readings past an i64 saturate, and those within come back as they went" {
    const T = enum { clock };
    try std.testing.expectEqual(@as(i64, -5), span(.fromNanoseconds(-5)).raw());
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), span(.max).raw());
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), span(.fromNanoseconds(std.math.minInt(i96))).raw());
    const t: Io.Timestamp = .fromNanoseconds(1_767_225_600_000_000_000);
    try std.testing.expect(reading(T.clock, t).toTimestamp().compare(.eq, t));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), reading(T.clock, .fromNanoseconds(std.math.maxInt(i96))).raw());
}
