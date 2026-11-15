//! A case that ends its process: a panic, a failed safety check
//! (`unreachable`, an overflow, an index out of bounds), anything that aborts.
//! `check` cannot shrink it or print its tape, since the process is gone, and
//! under Zig's fuzzer the input the fuzzer saves need not be what the case drew
//! (a property's draws come from the fuzzer by call site). So while a case runs,
//! its source is known here, and a SIGABRT handler writes the case's tape to
//! standard error, after the panic's message and stack, before the process
//! ends: `shakedown: a case ended the process; SHAKEDOWN_TAPE=<tape> replays it`.
//! `shakedown-fuzz` reads the line; by hand, the tape replays the crash under
//! `-Dtest-filter`. POSIX hosts in test builds; elsewhere nothing is installed.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const Source = @import("Source.zig");

const supported = builtin.is_test and switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

/// The line's start, which `shakedown-fuzz` reads.
pub const lead = "shakedown: a case ended the process; SHAKEDOWN_TAPE=";

/// The source of the case running now: the handler's to read. A case runs at a
/// time per process (a nested `check` restores the outer one's on leaving).
var running: aegis.Atomic(?*const Source) = .init(null);
/// Whether the handler is in place: installed by the first case, kept for the process.
const Hook = enum(u8) { absent, installed };
var hook: aegis.Atomic(Hook) = .init(.absent);
var previous: std.posix.Sigaction = undefined;

/// `source`'s case begins; returns the case it interrupts, for `leave`.
pub fn enter(source: *const Source) ?*const Source {
    if (!supported) return null;
    if (hook.swap(.installed, .acq_rel) == .absent) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onAbort },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.ABRT, &act, &previous);
    }
    return running.swap(source, .acq_rel);
}

/// The case `enter` began ended without ending the process.
pub fn leave(outer: ?*const Source) void {
    if (!supported) return;
    running.store(outer, .release);
}

/// Writes the running case's tape, once, then hands the signal to the handler
/// installed before this one, if it was a function; the abort goes on as it
/// would have. Only async-signal-safe work: raw writes from a static buffer.
fn onAbort(sig: std.posix.SIG) callconv(.c) void {
    if (running.swap(null, .acq_rel)) |source| writeTape(source.choices.items);
    const before = previous;
    if (before.flags & std.posix.SA.SIGINFO != 0) return;
    const handler = before.handler.handler orelse return;
    if (handler == std.posix.SIG.DFL or handler == std.posix.SIG.IGN) return;
    handler(sig);
}

var line: [4096]u8 = undefined;

fn writeTape(choices: []const u64) void {
    var n: usize = 0;
    rawWrite(lead);
    for (choices, 0..) |choice, i| {
        // A choice is at most 16 hex digits and its separator.
        if (n + 17 > line.len) {
            rawWrite(line[0..n]);
            n = 0;
        }
        if (i > 0) {
            line[n] = ':';
            n += 1;
        }
        n += hex(choice, line[n..]);
    }
    line[n] = '\n';
    rawWrite(line[0 .. n + 1]);
}

/// `value` in lowercase hex, no leading zeros, as `Tape.format` writes it.
fn hex(value: u64, out: []u8) usize {
    const digits = "0123456789abcdef";
    var len: usize = 1;
    var rest = value >> 4;
    while (rest != 0) : (rest >>= 4) len += 1;
    var v = value;
    var i = len;
    while (i > 0) {
        i -= 1;
        out[i] = digits[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    return len;
}

fn rawWrite(bytes: []const u8) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.write(2, bytes.ptr, bytes.len),
        else => _ = std.c.write(2, bytes.ptr, bytes.len),
    }
}

test "a choice reads in hex as Tape.format writes it" {
    var out: [16]u8 = undefined;
    for ([_]u64{ 0, 0xa, 0xff87, 0xdead_beef_0001, std.math.maxInt(u64) }) |value| {
        var expected: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&expected);
        try w.print("{x}", .{value});
        try std.testing.expectEqualStrings(w.buffered(), out[0..hex(value, &out)]);
    }
}

test "a case's source is the running one until it leaves, and a nested case restores the outer" {
    if (!supported) return error.SkipZigTest;
    var outer: Source = try .init(std.testing.allocator, .{ .prng = 1 });
    defer outer.deinit();
    var inner: Source = try .init(std.testing.allocator, .{ .prng = 2 });
    defer inner.deinit();
    const before = enter(&outer);
    try std.testing.expectEqual(@as(?*const Source, &outer), running.load(.acquire));
    const interrupted = enter(&inner);
    try std.testing.expectEqual(@as(?*const Source, &outer), interrupted);
    leave(interrupted);
    try std.testing.expectEqual(@as(?*const Source, &outer), running.load(.acquire));
    leave(before);
    try std.testing.expectEqual(before, running.load(.acquire));
}
