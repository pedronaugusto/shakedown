//! The simulation's pipes: a bounded byte buffer between a read end and a
//! write end, each end a handle of its own, as `std.process` makes them for
//! a child's standard streams. A read waits for bytes or for the write end
//! to close (then it is the end of the stream); a write waits for room, and
//! fails with `BrokenPipe` once the read end is closed. Bytes keep their
//! order and are read once.
//!
//! The model never blocks: `read` and `write` answer `null` when the call
//! would wait, and the caller waits on the simulation's readiness and asks
//! again. Every change to a pipe advances `change`, which is what a waiter
//! is woken by.
//!
//! An end handed to a child is the child's own copy of it (`dup`), as a
//! descriptor a process inherits is: a pipe's read side is open while any
//! copy of a read end is, and so is its write side.
//!
//! A terminal is two pipes and a window size: the master writes what the
//! slave reads and reads what the slave writes, and the slave's ends say
//! they are a terminal. There is no line discipline: bytes cross as they
//! are written.
//!
//! Handles are values the kernel rejects, so a raw system call on one fails
//! and can never touch a real descriptor: on POSIX, negative numbers below
//! -524288 and above the file system's range; on Windows, kernel-mode
//! values in their own range. A null device (`StdIo.ignore`) is an end too:
//! it reads as an empty stream and takes every write.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Pipes = @This();

pub const Kind = enum { read, write, null_device };

pub const End = struct {
    pipe: u32,
    kind: Kind,
    /// The process that opened this end, closed when it ends; 0 for none.
    owner: u32 = 0,
    open: bool = true,
    /// The terminal this end is a side of, and whether it is its slave's.
    terminal: ?u32 = null,
    slave: bool = false,
};

const Pipe = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,
    /// Open copies of the read ends and the write ends.
    readers: u32 = 1,
    writers: u32 = 1,
};

/// A terminal's window, in character cells.
pub const Size = struct { rows: u16, cols: u16 };

gpa: Allocator,
capacity: usize,
/// Every end ever issued, by id; an end's id is its index.
ends: std.ArrayList(End) = .empty,
pipes: std.ArrayList(Pipe) = .empty,
/// Every terminal's window size, by id.
terminals: std.ArrayList(Size) = .empty,
/// Advanced on every change a waiter may be waiting for.
change: u32 = 0,

/// The most ends one simulation issues.
pub const max_ends = 1 << 19;

pub fn init(gpa: Allocator, capacity: usize) Pipes {
    return .{ .gpa = gpa, .capacity = @max(capacity, 1) };
}

pub fn deinit(p: *Pipes) void {
    for (p.pipes.items) |pipe| p.gpa.free(pipe.bytes);
    p.pipes.deinit(p.gpa);
    p.ends.deinit(p.gpa);
    p.terminals.deinit(p.gpa);
    p.* = undefined;
}

pub const CreateError = error{ OutOfMemory, SystemResources };

/// A new pipe: its read end and its write end.
pub fn create(p: *Pipes, owner_read: u32, owner_write: u32) CreateError![2]Io.File.Handle {
    if (p.ends.items.len + 2 > max_ends) return error.SystemResources;
    try p.ends.ensureUnusedCapacity(p.gpa, 2);
    try p.pipes.ensureUnusedCapacity(p.gpa, 1);
    const bytes = try p.gpa.alloc(u8, p.capacity);
    const index: u32 = @intCast(p.pipes.items.len);
    p.pipes.appendAssumeCapacity(.{ .bytes = bytes });
    const read_id: u32 = @intCast(p.ends.items.len);
    p.ends.appendAssumeCapacity(.{ .pipe = index, .kind = .read, .owner = owner_read });
    p.ends.appendAssumeCapacity(.{ .pipe = index, .kind = .write, .owner = owner_write });
    return .{ encode(read_id), encode(read_id + 1) };
}

/// A terminal's four ends: the master's read and write ends, the slave's
/// read and write ends, all `owner`'s.
pub const Terminal = struct { master_read: Io.File.Handle, master_write: Io.File.Handle, slave_read: Io.File.Handle, slave_write: Io.File.Handle };

/// A new terminal of window `size`.
pub fn terminal(p: *Pipes, owner: u32, size: Size) CreateError!Terminal {
    try p.terminals.ensureUnusedCapacity(p.gpa, 1);
    const input = try p.create(owner, owner);
    errdefer p.close(input[0]);
    errdefer p.close(input[1]);
    const output = try p.create(owner, owner);
    const id_: u32 = @intCast(p.terminals.items.len);
    p.terminals.appendAssumeCapacity(size);
    for ([_]Io.File.Handle{ input[0], input[1], output[0], output[1] }) |h| p.ends.items[decode(h).?].terminal = id_;
    p.ends.items[decode(input[0]).?].slave = true;
    p.ends.items[decode(output[1]).?].slave = true;
    return .{ .master_read = output[0], .master_write = input[1], .slave_read = input[0], .slave_write = output[1] };
}

/// Another copy of an open end, `owner`'s: the side it is on stays open
/// until every copy is closed.
pub fn dup(p: *Pipes, handle: Io.File.Handle, owner: u32) (CreateError || HandleError)!Io.File.Handle {
    const original = (try p.end(handle)).*;
    if (p.ends.items.len + 1 > max_ends) return error.SystemResources;
    const end_id: u32 = @intCast(p.ends.items.len);
    var copy = original;
    copy.owner = owner;
    try p.ends.append(p.gpa, copy);
    switch (original.kind) {
        .read => p.pipes.items[original.pipe].readers += 1,
        .write => p.pipes.items[original.pipe].writers += 1,
        .null_device => {},
    }
    return encode(end_id);
}

/// Whether `handle` is a terminal's slave end, which a program sees as its
/// terminal.
pub fn isTerminal(p: *Pipes, handle: Io.File.Handle) HandleError!bool {
    return (try p.end(handle)).slave;
}

/// The window of the terminal `handle` is a side of.
pub fn windowSize(p: *Pipes, handle: Io.File.Handle) error{ BadHandle, NotTerminalDevice }!Size {
    const t = (try p.end(handle)).terminal orelse return error.NotTerminalDevice;
    return p.terminals.items[t];
}

pub fn setWindowSize(p: *Pipes, handle: Io.File.Handle, size: Size) error{ BadHandle, NotTerminalDevice }!void {
    const t = (try p.end(handle)).terminal orelse return error.NotTerminalDevice;
    p.terminals.items[t] = size;
    p.change +%= 1;
}

/// A null device end: reads end at once, writes vanish.
pub fn nullDevice(p: *Pipes, owner: u32) CreateError!Io.File.Handle {
    if (p.ends.items.len + 1 > max_ends) return error.SystemResources;
    const end_id: u32 = @intCast(p.ends.items.len);
    try p.ends.append(p.gpa, .{ .pipe = 0, .kind = .null_device, .owner = owner });
    return encode(end_id);
}

/// Whether `handle` is one of this model's ends, open or not.
pub fn owns(handle: Io.File.Handle) bool {
    return decode(handle) != null;
}

pub const HandleError = error{BadHandle};

pub fn end(p: *Pipes, handle: Io.File.Handle) HandleError!*End {
    const end_id = decode(handle) orelse return error.BadHandle;
    if (end_id >= p.ends.items.len) return error.BadHandle;
    const e = &p.ends.items[end_id];
    if (!e.open) return error.BadHandle;
    return e;
}

/// Closes an end; a closed or unknown handle is ignored, as a double close
/// of a descriptor is a bug the kernel only reports.
pub fn close(p: *Pipes, handle: Io.File.Handle) void {
    const e = p.end(handle) catch return;
    e.open = false;
    switch (e.kind) {
        .read => p.pipes.items[e.pipe].readers -= 1,
        .write => p.pipes.items[e.pipe].writers -= 1,
        .null_device => {},
    }
    p.change +%= 1;
}

/// Closes every open end `owner` opened.
pub fn closeOwned(p: *Pipes, owner: u32) void {
    for (p.ends.items, 0..) |e, end_id| if (e.open and e.owner == owner) p.close(encode(@intCast(end_id)));
}

pub const ReadError = error{ BadHandle, NotOpenForReading, EndOfStream };

/// Bytes into `data`, in order; null when the pipe is empty and its writer
/// still open. A read into no room reads nothing.
pub fn read(p: *Pipes, handle: Io.File.Handle, data: []const []u8) ReadError!?usize {
    const e = try p.end(handle);
    switch (e.kind) {
        .write => return error.NotOpenForReading,
        .null_device => return error.EndOfStream,
        .read => {},
    }
    var room: usize = 0;
    for (data) |d| room += d.len;
    if (room == 0) return 0;
    const pipe = &p.pipes.items[e.pipe];
    if (pipe.len == 0) return if (pipe.writers > 0) null else error.EndOfStream;
    var n: usize = 0;
    for (data) |d| {
        var at: usize = 0;
        while (at < d.len and pipe.len > 0) {
            const run = @min(d.len - at, pipe.len, pipe.bytes.len - pipe.head);
            @memcpy(d[at..][0..run], pipe.bytes[pipe.head..][0..run]);
            pipe.head = (pipe.head + run) % pipe.bytes.len;
            pipe.len -= run;
            at += run;
            n += run;
        }
        if (pipe.len == 0) break;
    }
    if (pipe.len == 0) pipe.head = 0;
    p.change +%= 1;
    return n;
}

pub const WriteError = error{ BadHandle, NotOpenForWriting, BrokenPipe };

/// As many bytes of `header`, then `data` with its last slice `splat`
/// times, as the pipe has room for; null when it has none.
pub fn write(p: *Pipes, handle: Io.File.Handle, header: []const u8, data: []const []const u8, splat: usize) WriteError!?usize {
    const e = try p.end(handle);
    var total: usize = header.len;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |d| total += d.len;
        total += data[data.len - 1].len * splat;
    }
    switch (e.kind) {
        .read => return error.NotOpenForWriting,
        .null_device => return total,
        .write => {},
    }
    const pipe = &p.pipes.items[e.pipe];
    if (pipe.readers == 0) return error.BrokenPipe;
    if (total == 0) return 0;
    if (pipe.len == pipe.bytes.len) return null;
    var n: usize = 0;
    n += put(pipe, header);
    if (data.len > 0 and n == header.len) {
        for (data[0 .. data.len - 1]) |d| {
            const put_n = put(pipe, d);
            n += put_n;
            if (put_n < d.len) break;
        } else {
            const last = data[data.len - 1];
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                const put_n = put(pipe, last);
                n += put_n;
                if (put_n < last.len) break;
            }
        }
    }
    p.change +%= 1;
    return n;
}

fn put(pipe: *Pipe, bytes: []const u8) usize {
    var n: usize = 0;
    while (n < bytes.len and pipe.len < pipe.bytes.len) {
        const tail = (pipe.head + pipe.len) % pipe.bytes.len;
        const run = @min(bytes.len - n, pipe.bytes.len - pipe.len, pipe.bytes.len - tail);
        @memcpy(pipe.bytes[tail..][0..run], bytes[n..][0..run]);
        pipe.len += run;
        n += run;
    }
    return n;
}

/// Bytes waiting in the pipe of a read end.
pub fn buffered(p: *Pipes, handle: Io.File.Handle) HandleError!usize {
    const e = try p.end(handle);
    return if (e.kind == .read) p.pipes.items[e.pipe].len else 0;
}

/// An end's id, as a trace names it on every system.
pub fn id(handle: Io.File.Handle) ?u32 {
    return decode(handle);
}

// Handles.

const posix_base: i32 = -524_288;

pub fn encode(end_id: u32) Io.File.Handle {
    if (builtin.os.tag == .windows) return @ptrFromInt(windows_base + @as(usize, end_id) * 4); // safe: kernel-mode values user-mode calls cannot resolve, never dereferenced
    return posix_base - @as(i32, @intCast(end_id));
}

fn decode(raw: Io.File.Handle) ?u32 {
    if (builtin.os.tag == .windows) {
        const value = @intFromPtr(raw); // safe: an opaque handle, never dereferenced
        if (value < windows_base or value % 4 != 0) return null;
        const end_id = (value - windows_base) / 4;
        return if (end_id < max_ends) @intCast(end_id) else null;
    }
    if (raw > posix_base) return null;
    const end_id = @as(i64, posix_base) - raw;
    return if (end_id < max_ends) @intCast(end_id) else null;
}

/// Below the file system's handles (`fs/Model.encode`), above the processes'.
const windows_base: usize = std.math.maxInt(usize) - 0xffff_ffff;

test "bytes cross a pipe in order, and a closed writer ends the stream" {
    var p: Pipes = .init(std.testing.allocator, 8);
    defer p.deinit();
    const ends = try p.create(0, 0);
    try std.testing.expectEqual(@as(?usize, 5), try p.write(ends[1], "ab", &.{ "c", "de" }, 1));
    try std.testing.expectEqual(@as(?usize, 3), try p.write(ends[1], "", &.{"xy"}, 2));
    try std.testing.expectEqual(@as(?usize, null), try p.write(ends[1], "z", &.{}, 1));
    var a: [3]u8 = undefined;
    var b: [10]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 8), try p.read(ends[0], &.{ &a, &b }));
    try std.testing.expectEqualStrings("abc", &a);
    try std.testing.expectEqualStrings("dexyx", b[0..5]);
    try std.testing.expectEqual(@as(?usize, null), try p.read(ends[0], &.{&b}));
    p.close(ends[1]);
    try std.testing.expectError(error.EndOfStream, p.read(ends[0], &.{&b}));
    try std.testing.expectError(error.BadHandle, p.write(ends[1], "a", &.{}, 1));
}

test "a closed reader breaks the pipe, and handles never decode as another's" {
    var p: Pipes = .init(std.testing.allocator, 4);
    defer p.deinit();
    const ends = try p.create(7, 7);
    const null_end = try p.nullDevice(0);
    try std.testing.expectEqual(@as(?usize, 3), try p.write(null_end, "abc", &.{}, 1));
    var b: [4]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, p.read(null_end, &.{&b}));
    p.closeOwned(7);
    try std.testing.expectError(error.BadHandle, p.write(ends[1], "a", &.{}, 1));
    const again = try p.create(0, 0);
    p.close(again[0]);
    try std.testing.expectError(error.BrokenPipe, p.write(again[1], "a", &.{}, 1));
    try std.testing.expect(!owns(Io.File.stdout().handle));
    try std.testing.expect(owns(again[1]));
}

test "a copy of an end keeps its side open, and a terminal crosses both ways" {
    var p: Pipes = .init(std.testing.allocator, 8);
    defer p.deinit();
    const ends = try p.create(0, 0);
    const copy = try p.dup(ends[1], 3);
    p.close(ends[1]);
    var b: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), try p.read(ends[0], &.{&b}));
    try std.testing.expectEqual(@as(?usize, 2), try p.write(copy, "hi", &.{}, 1));
    p.closeOwned(3);
    try std.testing.expectEqual(@as(?usize, 2), try p.read(ends[0], &.{&b}));
    try std.testing.expectError(error.EndOfStream, p.read(ends[0], &.{&b}));

    const t = try p.terminal(0, .{ .rows = 24, .cols = 80 });
    try std.testing.expectEqual(@as(?usize, 1), try p.write(t.master_write, "a", &.{}, 1));
    try std.testing.expectEqual(@as(?usize, 1), try p.read(t.slave_read, &.{&b}));
    try std.testing.expectEqual(@as(?usize, 1), try p.write(t.slave_write, "b", &.{}, 1));
    try std.testing.expectEqual(@as(?usize, 1), try p.read(t.master_read, &.{&b}));
    try std.testing.expect(try p.isTerminal(t.slave_read));
    try std.testing.expect(!try p.isTerminal(t.master_read));
    try p.setWindowSize(t.master_write, .{ .rows = 50, .cols = 132 });
    try std.testing.expectEqual(@as(u16, 132), (try p.windowSize(t.slave_write)).cols);
    try std.testing.expectError(error.NotTerminalDevice, p.windowSize(ends[0]));
}
