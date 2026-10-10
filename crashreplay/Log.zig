//! A dm-log-writes log, as the kernel's target writes it: a superblock, then
//! one entry per block of the log device's sector size, each a write (its
//! data in the blocks after it), a flush, a discard or a mark.
const std = @import("std");
const Log = @This();

pub const magic: u64 = 0x6a736677736872;
pub const version: u64 = 1;

pub const Flags = packed struct(u64) {
    flush: bool = false,
    fua: bool = false,
    discard: bool = false,
    mark: bool = false,
    metadata: bool = false,
    _: u59 = 0,
};

pub const Entry = struct {
    /// Where on the data device, in `sectorsize` units.
    sector: u64,
    /// How long, in `sectorsize` units.
    sectors: u64,
    flags: Flags,
    /// A mark's name, or a write's data: borrowed from the log's bytes. A
    /// write of file system metadata (`flags.metadata`) is a write like any.
    data: []const u8,
};

bytes: []const u8,
sectorsize: u32,
entries: u64,

pub const Error = error{ NotALog, UnknownVersion, Truncated };

pub fn parse(bytes: []const u8) Error!Log {
    if (bytes.len < 28) return error.NotALog;
    if (std.mem.readInt(u64, bytes[0..8], .little) != magic) return error.NotALog;
    if (std.mem.readInt(u64, bytes[8..16], .little) != version) return error.UnknownVersion;
    const sectorsize = std.mem.readInt(u32, bytes[24..28], .little);
    if (sectorsize < 512 or !std.math.isPowerOfTwo(sectorsize)) return error.NotALog;
    return .{ .bytes = bytes, .sectorsize = sectorsize, .entries = std.mem.readInt(u64, bytes[16..24], .little) };
}

pub const Iterator = struct {
    log: *const Log,
    at: usize,
    left: u64,

    pub fn next(it: *Iterator) Error!?Entry {
        if (it.left == 0) return null;
        const size = it.log.sectorsize;
        if (it.at + size > it.log.bytes.len) return error.Truncated;
        const header = it.log.bytes[it.at..][0..size];
        const sector = std.mem.readInt(u64, header[0..8], .little);
        const sectors = std.mem.readInt(u64, header[8..16], .little);
        const flags: Flags = @bitCast(std.mem.readInt(u64, header[16..24], .little));
        const data_len = std.mem.readInt(u64, header[24..32], .little);
        it.at += size;
        it.left -= 1;
        if (flags.mark) {
            if (32 + data_len > size) return error.Truncated;
            return .{ .sector = sector, .sectors = 0, .flags = flags, .data = header[32..][0..@intCast(data_len)] };
        }
        if (flags.discard or sectors == 0) return .{ .sector = sector, .sectors = sectors, .flags = flags, .data = &.{} };
        const len: usize = @intCast(sectors * size);
        if (it.at + len > it.log.bytes.len) return error.Truncated;
        const data = it.log.bytes[it.at..][0..len];
        it.at += len;
        return .{ .sector = sector, .sectors = sectors, .flags = flags, .data = data };
    }
};

pub fn iterator(log: *const Log) Iterator {
    return .{ .log = log, .at = log.sectorsize, .left = log.entries };
}

/// What an entry does to the data device's bytes.
pub fn apply(log: *const Log, entry: Entry, image: []u8) error{OutOfRange}!void {
    if (entry.flags.mark) return;
    const start = std.math.mul(u64, entry.sector, log.sectorsize) catch return error.OutOfRange;
    const len = std.math.mul(u64, entry.sectors, log.sectorsize) catch return error.OutOfRange;
    if (start + len > image.len) return error.OutOfRange;
    const at: usize = @intCast(start);
    if (entry.flags.discard) {
        @memset(image[at..][0..@intCast(len)], 0);
        return;
    }
    @memcpy(image[at..][0..entry.data.len], entry.data);
}

test "a log of a write, a mark and a flush reads back and applies" {
    const size = 512;
    var bytes: [size * 6]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[0..8], magic, .little);
    std.mem.writeInt(u64, bytes[8..16], version, .little);
    std.mem.writeInt(u64, bytes[16..24], 3, .little);
    std.mem.writeInt(u32, bytes[24..28], size, .little);
    // A write of two sectors at sector 1.
    std.mem.writeInt(u64, bytes[size..][0..8], 1, .little);
    std.mem.writeInt(u64, bytes[size..][8..16], 2, .little);
    @memset(bytes[size * 2 ..][0 .. size * 2], 'w');
    // A mark.
    const mark = size * 4;
    std.mem.writeInt(u64, bytes[mark..][16..24], @bitCast(Flags{ .mark = true }), .little);
    std.mem.writeInt(u64, bytes[mark..][24..32], 5, .little);
    @memcpy(bytes[mark + 32 ..][0..5], "start");
    // A flush.
    std.mem.writeInt(u64, bytes[size * 5 ..][16..24], @bitCast(Flags{ .flush = true }), .little);
    const log = try parse(&bytes);
    var it = log.iterator();
    var image: [size * 4]u8 = @splat(0);
    const write = (try it.next()).?;
    try std.testing.expectEqual(@as(u64, 1), write.sector);
    try log.apply(write, &image);
    try std.testing.expectEqual(@as(u8, 0), image[size - 1]);
    try std.testing.expectEqual(@as(u8, 'w'), image[size]);
    try std.testing.expectEqual(@as(u8, 'w'), image[size * 3 - 1]);
    try std.testing.expectEqualStrings("start", (try it.next()).?.data);
    try std.testing.expect((try it.next()).?.flags.flush);
    try std.testing.expectEqual(@as(?Entry, null), try it.next());
}
