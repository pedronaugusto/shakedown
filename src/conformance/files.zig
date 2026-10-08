//! The same file guarantees, exercised on Threaded and simulated Io.
const std = @import("std");
const Io = std.Io;

pub fn run(gpa: std.mem.Allocator, io: Io) !void {
    var random: [8]u8 = undefined;
    io.random(&random);
    const name = "shakedown-conformance-" ++ std.fmt.hex(@as(u64, @bitCast(random)));
    const cwd = Io.Dir.cwd();
    const dir = try cwd.createDirPathOpen(io, name, .{ .open_options = .{ .iterate = true } });
    defer cwd.deleteTree(io, name) catch {};
    defer dir.close(io);
    _ = try dir.createDirPath(io, "nested/deep");
    const file = try dir.createFile(io, "nested/deep/file", .{ .read = true, .exclusive = true });
    defer file.close(io);
    if (dir.createFile(io, "nested/deep/file", .{ .exclusive = true })) |unexpected| {
        unexpected.close(io);
        return error.ExclusiveClobbered;
    } else |err| if (err != error.PathAlreadyExists) return err;
    try file.writePositionalAll(io, "abcdef", 0);
    try file.writePositionalAll(io, "Z", 2);
    var bytes: [6]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, 0) != 6 or !std.mem.eql(u8, &bytes, "abZdef")) return error.WrongData;
    try io.vtable.fileSeekTo(io.userdata, file, 1);
    var stream: [2]u8 = undefined;
    if (try io.operate(.{ .file_read_streaming = .{ .file = file, .data = &.{&stream} } }) != .file_read_streaming) return error.WrongOperation;
    if (!std.mem.eql(u8, &stream, "bZ")) return error.WrongSeek;
    try file.setLength(io, 10);
    var hole: [4]u8 = undefined;
    if (try file.readPositionalAll(io, &hole, 6) != 4 or !std.mem.allEqual(u8, &hole, 0)) return error.HoleNotZero;
    try file.setLength(io, 3);
    if (try file.length(io) != 3) return error.WrongLength;
    try file.lock(io, .exclusive);
    try file.downgradeLock(io);
    file.unlock(io);
    if (!try file.tryLock(io, .shared)) return error.LockUnavailable;
    file.unlock(io);
    try file.sync(io);
    try dir.rename("nested/deep/file", dir, "renamed", io);
    // An open description still reads its inode after a rename and unlink.
    if (try file.readPositionalAll(io, &bytes, 0) != 3) return error.RenameClosedHandle;
    try dir.hardLink("renamed", dir, "linked", io, .{});
    const before = try file.stat(io);
    const linked = try dir.statFile(io, "linked", .{});
    if (before.inode != linked.inode or before.nlink < 2) return error.LinkNotSameInode;
    try dir.deleteFile(io, "renamed");
    if (try file.readPositionalAll(io, &bytes, 0) != 3) return error.UnlinkClosedHandle;
    var listing = dir.iterate();
    var seen = false;
    while (try listing.next(io)) |entry| if (std.mem.eql(u8, entry.name, "linked")) {
        seen = true;
    };
    if (!seen) return error.ListingMissedFile;
    const opened = try dir.openFile(io, "linked", .{ .mode = .read_write });
    defer opened.close(io);
    var map = try Io.File.MemoryMap.create(io, opened, .{ .len = 3 });
    defer map.destroy(io);
    map.memory[0] = 'M';
    try map.write(io);
    if (try opened.readPositionalAll(io, &bytes, 0) != 3 or bytes[0] != 'M') return error.MapWriteLost;
    try opened.writePositionalAll(io, "Q", 1);
    try map.read(io);
    if (map.memory[1] != 'Q') return error.MapReadStale;
    const content = try dir.readFileAlloc(io, "linked", gpa, .limited(32));
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, "MQZ")) return error.ReaderWrongData;
}
