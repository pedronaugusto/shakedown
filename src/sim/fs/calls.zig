//! File slots of the one simulation. Every call crosses the scheduler once;
//! tree and disk state live in Fs, while waiting on locks uses the core futexes.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Core = @import("../Core.zig");
const Fs = @import("Model.zig");
const IoCall = @import("../../io_call.zig").IoCall;
const io_call = @import("../../io_call.zig");

pub fn supports(comptime name: []const u8) bool {
    return @hasDecl(slots, name);
}
fn Return(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?;
}
fn mapped(comptime E: type, err: anyerror) E {
    const names = @typeInfo(E).error_set.error_names.?;
    inline for (names) |name| if (err == @field(anyerror, name)) return @field(E, name);
    if (err == error.OutOfMemory) {
        inline for (names) |name| if (comptime std.mem.eql(u8, name, "SystemResources")) return error.SystemResources;
    }
    inline for (names) |name| if (comptime std.mem.eql(u8, name, "Unexpected")) return error.Unexpected;
    return @field(E, names[0]);
}
fn resultDigest(value: anytype) u64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .void => 0,
        .int => @intCast(value),
        .bool => @intFromBool(value),
        .@"enum" => @intCast(@backingInt(value)),
        else => 0,
    };
}
// Paths and write inputs belong in the trace; two runs using different names
// must not pass a crash sweep's prefix check merely because both opens succeeded.
fn inputDigest(fs: *Fs, args: anytype) u64 {
    var hash: std.hash.Wyhash = .init(0);
    inline for (args) |arg| {
        const T = @TypeOf(arg);
        if (T == []const u8) {
            hash.update(arg);
        } else if (T == []const []const u8) {
            for (arg) |bytes| hash.update(bytes);
        } else if (T == Io.File or T == Io.Dir) {
            // Trace the portable description id, not the platform's invalid
            // kernel handle encoding, so the same seed has one golden on every OS.
            const id: u64 = if (arg.handle == Io.Dir.cwd().handle) 0 else if (fs.handle(arg.handle)) |h| h.id else |_| std.math.maxInt(u64);
            hash.update(std.mem.asBytes(&id));
        } else switch (@typeInfo(T)) {
            .int, .bool => hash.update(std.mem.asBytes(&arg)),
            else => {},
        }
    }
    return hash.final();
}
/// `args` with `Dir.cwd()` meaning the calling context's working directory,
/// when it has one: a simulated process's, or a node's that changed it.
fn workingDirectory(c: *const Core, args: anytype) @TypeOf(args) {
    var local = args;
    const ctx = c.currentContext() orelse return local;
    const cwd = Core.cwdOf(ctx) orelse return local;
    inline for (0..args.len) |i| {
        if (@TypeOf(args[i]) == Io.Dir and args[i].handle == Io.Dir.cwd().handle) local[i] = cwd;
    }
    return local;
}
/// Marks what a call opened as the calling process's.
fn own(fs: *Fs, value: anytype, owner: u32) void {
    if (owner == 0) return;
    const T = @TypeOf(value);
    if (T == Io.File or T == Io.Dir) {
        fs.setOwner(value.handle, owner);
    } else if (T == Io.File.Atomic) {
        if (value.file_open) fs.setOwner(value.file.handle, owner);
        if (value.close_dir_on_deinit) fs.setOwner(value.dir.handle, owner);
    }
}
fn invoke(comptime name: []const u8, userdata: ?*anyopaque, args: anytype, ret: usize) Return(name) {
    const c = Core.of(userdata);
    const e = c.enter(ret, true);
    const call = @field(IoCall, name);
    const R = Return(name);
    if (comptime io_call.cancelable(call)) if (e.task) |t| if (Core.cancelPoint(t)) {
        c.record(call, e, std.hash.Wyhash.hash(0, "Canceled"));
        return error.Canceled;
    };
    const disk = c.disk(e.node) orelse {
        c.record(call, e, std.hash.Wyhash.hash(0, "Unexpected"));
        if (R == void) return;
        return mapped(@typeInfo(R).error_union.error_set, error.Unexpected);
    };
    const fs = disk.model;
    fs.at = c.now(.real);
    c.touch(Core.Object.disk(e.node), true);
    const local = workingDirectory(c, args);
    const input = inputDigest(fs, local);
    const value = @call(.auto, @field(slots, name), .{ c, fs } ++ local);
    if (comptime @typeInfo(@TypeOf(value)) == .error_union) {
        const payload = value catch |err| {
            c.record(call, e, input ^ std.hash.Wyhash.hash(0, @errorName(err)));
            return mapped(@typeInfo(R).error_union.error_set, err);
        };
        own(fs, payload, c.ownerOf());
        c.record(call, e, input ^ resultDigest(payload));
        return payload;
    } else {
        c.record(call, e, input ^ resultDigest(value));
        return value;
    }
}
pub fn slot(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const params = info.param_types;
    const return_type = info.return_type.?;
    return switch (params.len) {
        2 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?) return_type {
                return invoke(name, u, .{a}, @returnAddress());
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?) return_type {
                return invoke(name, u, .{ a, b }, @returnAddress());
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, d: params[3].?) return_type {
                return invoke(name, u, .{ a, b, d }, @returnAddress());
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, d: params[3].?, e: params[4].?) return_type {
                return invoke(name, u, .{ a, b, d, e }, @returnAddress());
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, d: params[3].?, e: params[4].?, f_: params[5].?) return_type {
                return invoke(name, u, .{ a, b, d, e, f_ }, @returnAddress());
            }
        }.f,
        7 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, d: params[3].?, e: params[4].?, f_: params[5].?, g: params[6].?) return_type {
                return invoke(name, u, .{ a, b, d, e, f_, g }, @returnAddress());
            }
        }.f,
        else => @compileError("file slot arity unsupported"),
    };
}
fn readable(fs: *Fs, file: Io.File) !*Fs.Handle {
    const h = try fs.handle(file.handle);
    if (!h.read or h.path_only) return error.NotOpenForReading;
    return h;
}
fn writable(fs: *Fs, file: Io.File) !*Fs.Handle {
    const h = try fs.handle(file.handle);
    if (!h.write or h.path_only) return error.NotOpenForWriting;
    return h;
}
pub fn readVector(fs: *Fs, file: Io.File, buffers: []const []u8, offset: u64) !usize {
    const id = (try readable(fs, file)).inode;
    var total: usize = 0;
    for (buffers) |out| {
        const n = try fs.get(id, offset + total, out);
        total += n;
        if (n < out.len) break;
    }
    return total;
}
pub fn writeVector(fs: *Fs, file: Io.File, header: []const u8, buffers: []const []const u8, splat: usize, offset: u64) !usize {
    const id = (try writable(fs, file)).inode;
    var total: usize = 0;
    total += try fs.put(id, offset, header);
    for (buffers, 0..) |bytes, i| {
        const repeats = if (i + 1 == buffers.len) splat else 1;
        for (0..repeats) |_| {
            const n = fs.put(id, offset + total, bytes) catch |err| {
                if (total != 0) return total;
                return err;
            };
            total += n;
        }
    }
    return total;
}
/// Operation arms share the open description's seek position.
pub fn perform(fs: *Fs, op: Io.Operation) ?Io.Operation.Result {
    switch (op) {
        .file_read_streaming => |r| {
            const h = fs.handle(r.file.handle) catch |err| return .{ .file_read_streaming = mapped(Io.Operation.FileReadStreaming.Error, err) };
            const n = readVector(fs, r.file, r.data, h.offset) catch |err| return .{ .file_read_streaming = mapped(Io.Operation.FileReadStreaming.Error, err) };
            h.offset += n;
            var capacity: usize = 0;
            for (r.data) |b| capacity += b.len;
            return .{ .file_read_streaming = if (n == 0 and capacity != 0) error.EndOfStream else n };
        },
        .file_write_streaming => |w| {
            const h = fs.handle(w.file.handle) catch |err| return .{ .file_write_streaming = mapped(Io.Operation.FileWriteStreaming.Error, err) };
            const n = writeVector(fs, w.file, w.header, w.data, w.splat, h.offset) catch |err| return .{ .file_write_streaming = mapped(Io.Operation.FileWriteStreaming.Error, err) };
            h.offset += n;
            return .{ .file_write_streaming = n };
        },
        else => return null,
    }
}
const slots = struct {
    pub fn dirCreateDir(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, permissions: Io.Dir.Permissions) !void {
        _ = try fs.create(try fs.directory(dir), path, .directory, permissions, null);
    }
    pub fn dirCreateDirPath(c: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, permissions: Io.Dir.Permissions) !Io.Dir.CreatePathStatus {
        const base = try fs.directory(dir);
        var created = false;
        for (path, 0..) |ch, i| if (i != 0 and (ch == '/' or (fs.options.names == .windows and ch == '\\'))) {
            const part = path[0..i];
            _ = fs.resolve(base, part, true) catch |err| blk: {
                if (err != error.FileNotFound) return err;
                try dirCreateDir(c, fs, dir, part, permissions);
                created = true;
                break :blk 0;
            };
        };
        const id = fs.resolve(base, path, true) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            created = true;
            break :blk try fs.create(base, path, .directory, permissions, null);
        };
        if (fs.root.nodes.items[id].kind != .directory) return error.NotDir;
        return if (created) .created else .existed;
    }
    pub fn dirCreateDirPathOpen(c: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) !Io.Dir {
        _ = try dirCreateDirPath(c, fs, dir, path, permissions);
        return dirOpenDir(c, fs, dir, path, options);
    }
    pub fn dirOpenDir(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) !Io.Dir {
        const id = try fs.resolve(try fs.directory(dir), path, options.follow_symlinks);
        if (fs.root.nodes.items[id].kind != .directory) return error.NotDir;
        return .{ .handle = (try fs.openHandle(id, true, false, false, options.iterate)).handle };
    }
    pub fn dirStat(_: *Core, fs: *Fs, dir: Io.Dir) !Io.Dir.Stat {
        return fs.stat(try fs.directory(dir));
    }
    pub fn dirStatFile(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.StatFileOptions) !Io.File.Stat {
        return fs.stat(try fs.resolve(try fs.directory(dir), path, options.follow_symlinks));
    }
    pub fn dirAccess(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.AccessOptions) !void {
        const id = try fs.resolve(try fs.directory(dir), path, options.follow_symlinks);
        if (options.write and !canWrite(fs.root.nodes.items[id].meta.permissions)) return error.AccessDenied;
    }
    pub fn dirCreateFile(c: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.CreateFileOptions) !Io.File {
        const base = try fs.directory(dir);
        const id = try fs.openOrCreate(base, path, options.permissions, options.exclusive);
        if (fs.root.nodes.items[id].kind == .directory) return error.IsDir;
        if (!canWrite(fs.root.nodes.items[id].meta.permissions)) return error.AccessDenied;
        const file = try fs.openHandle(id, options.read, true, false, false);
        errdefer fs.close(file.handle);
        if (options.lock != .none) try acquire(c, fs, file, options.lock, options.lock_nonblocking);
        if (options.truncate) try fs.setLength(id, 0);
        return file;
    }
    pub fn dirCreateFileAtomic(c: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.CreateFileAtomicOptions) !Io.File.Atomic {
        var end = path.len;
        while (end > 0 and path[end - 1] != '/' and !(fs.options.names == .windows and path[end - 1] == '\\')) end -= 1;
        var parent_dir = dir;
        const owns = end != 0;
        if (owns) {
            if (options.make_path) _ = try dirCreateDirPath(c, fs, dir, path[0..end], .default_dir);
            parent_dir = try dirOpenDir(c, fs, dir, path[0..end], .{});
        }
        errdefer if (owns) fs.close(parent_dir.handle);
        for (0..4) |_| {
            const value = c.draw(std.math.maxInt(u64));
            const name = std.fmt.hex(value);
            const file = dirCreateFile(c, fs, parent_dir, &name, .{ .exclusive = true, .permissions = options.permissions }) catch |err| {
                if (err == error.PathAlreadyExists) continue;
                return err;
            };
            return .{ .file = file, .file_basename_hex = value, .file_open = true, .file_exists = true, .dir = parent_dir, .close_dir_on_deinit = owns, .dest_sub_path = path[end..] };
        }
        return error.PathAlreadyExists;
    }
    pub fn dirOpenFile(c: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenFileOptions) !Io.File {
        const id = try fs.resolve(try fs.directory(dir), path, options.follow_symlinks);
        const n = fs.root.nodes.items[id];
        if (n.kind == .sym_link and !options.follow_symlinks and !options.path_only) return error.SymLinkLoop;
        if (n.kind == .directory and (!options.allow_directory or options.isWrite())) return error.IsDir;
        if (options.isWrite() and !canWrite(n.meta.permissions)) return error.AccessDenied;
        const file = try fs.openHandle(id, options.isRead(), options.isWrite(), options.path_only, false);
        errdefer fs.close(file.handle);
        if (options.lock != .none) try acquire(c, fs, file, options.lock, options.lock_nonblocking);
        return file;
    }
    pub fn dirClose(c: *Core, fs: *Fs, dirs: []const Io.Dir) void {
        for (dirs) |d| fs.close(d.handle);
        wakeLocks(c, fs);
    }
    pub fn dirRead(_: *Core, fs: *Fs, r: *Io.Dir.Reader, out: []Io.Dir.Entry) !usize {
        const id = try fs.directory(r.dir);
        if (r.dir.handle != Io.Dir.cwd().handle and !(try fs.handle(r.dir.handle)).iterate) return error.AccessDenied;
        if (r.state == .reset) {
            r.index = 0;
            r.state = .reading;
        }
        // `r.index` is the cookie the listing resumes at: entries are in
        // cookie order, and one removed since the last read moves nothing.
        var count: usize = 0;
        var bytes: usize = 0;
        var at: usize = 0;
        while (at < fs.root.entries.items.len and fs.root.entries.items[at].cookie < r.index) at += 1;
        while (at < fs.root.entries.items.len and count < out.len) : (at += 1) {
            const e = fs.root.entries.items[at];
            if (e.parent != id) continue;
            if (bytes + e.name.bytes.len > r.buffer.len) break;
            @memcpy(r.buffer[bytes..][0..e.name.bytes.len], e.name.bytes);
            out[count] = .{ .name = r.buffer[bytes..][0..e.name.bytes.len], .kind = fs.root.nodes.items[e.inode].kind, .inode = @intCast(e.inode + 1) };
            bytes += e.name.bytes.len;
            count += 1;
            r.index = @intCast(e.cookie + 1);
        }
        if (at == fs.root.entries.items.len) r.state = .finished;
        return count;
    }
    pub fn dirRealPath(_: *Core, fs: *Fs, dir: Io.Dir, out: []u8) !usize {
        return fs.realPath(try fs.directory(dir), out);
    }
    pub fn dirRealPathFile(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, out: []u8) !usize {
        return fs.realPath(try fs.resolve(try fs.directory(dir), path, true), out);
    }
    pub fn dirDeleteFile(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8) !void {
        return fs.remove(try fs.directory(dir), path, false);
    }
    pub fn dirDeleteDir(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8) !void {
        return fs.remove(try fs.directory(dir), path, true);
    }
    pub fn dirRename(_: *Core, fs: *Fs, old: Io.Dir, from: []const u8, new: Io.Dir, to: []const u8) !void {
        return fs.rename(try fs.directory(old), from, try fs.directory(new), to, false);
    }
    pub fn dirRenamePreserve(_: *Core, fs: *Fs, old: Io.Dir, from: []const u8, new: Io.Dir, to: []const u8) !void {
        return fs.rename(try fs.directory(old), from, try fs.directory(new), to, true);
    }
    pub fn dirSymLink(_: *Core, fs: *Fs, dir: Io.Dir, target: []const u8, path: []const u8, _: Io.Dir.SymLinkFlags) !void {
        _ = try fs.create(try fs.directory(dir), path, .sym_link, .default_file, target);
    }
    pub fn dirReadLink(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, out: []u8) !usize {
        const id = try fs.resolve(try fs.directory(dir), path, false);
        const t = fs.root.nodes.items[id].target orelse return error.NotLink;
        const count = @min(out.len, t.bytes.len);
        @memcpy(out[0..count], t.bytes[0..count]);
        return count;
    }
    pub fn dirSetOwner(_: *Core, fs: *Fs, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) !void {
        return setOwner(fs, try fs.directory(dir), uid, gid);
    }
    pub fn dirSetFileOwner(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) !void {
        return setOwner(fs, try fs.resolve(try fs.directory(dir), path, options.follow_symlinks), uid, gid);
    }
    pub fn dirSetPermissions(_: *Core, fs: *Fs, dir: Io.Dir, permissions: Io.Dir.Permissions) !void {
        return setPermissions(fs, try fs.directory(dir), permissions);
    }
    pub fn dirSetFilePermissions(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) !void {
        return setPermissions(fs, try fs.resolve(try fs.directory(dir), path, options.follow_symlinks), permissions);
    }
    pub fn dirSetTimestamps(_: *Core, fs: *Fs, dir: Io.Dir, path: []const u8, options: Io.Dir.SetTimestampsOptions) !void {
        return timestamps(fs, try fs.resolve(try fs.directory(dir), path, options.follow_symlinks), .{ .access_timestamp = options.access_timestamp, .modify_timestamp = options.modify_timestamp });
    }
    pub fn dirHardLink(_: *Core, fs: *Fs, old: Io.Dir, from: []const u8, new: Io.Dir, to: []const u8, options: Io.Dir.HardLinkOptions) !void {
        return fs.link(try fs.resolve(try fs.directory(old), from, options.follow_symlinks), try fs.directory(new), to);
    }
    pub fn fileStat(_: *Core, fs: *Fs, file: Io.File) !Io.File.Stat {
        return fs.stat((try fs.handle(file.handle)).inode);
    }
    pub fn fileLength(_: *Core, fs: *Fs, file: Io.File) !u64 {
        return fs.root.nodes.items[(try fs.handle(file.handle)).inode].live.size;
    }
    pub fn fileClose(c: *Core, fs: *Fs, files: []const Io.File) void {
        for (files) |f| fs.close(f.handle);
        wakeLocks(c, fs);
    }
    pub fn fileReadPositional(_: *Core, fs: *Fs, file: Io.File, buffers: []const []u8, offset: u64) !usize {
        return readVector(fs, file, buffers, offset);
    }
    pub fn fileWritePositional(_: *Core, fs: *Fs, file: Io.File, header: []const u8, buffers: []const []const u8, splat: usize, offset: u64) !usize {
        return writeVector(fs, file, header, buffers, splat, offset);
    }
    pub fn fileSeekBy(_: *Core, fs: *Fs, file: Io.File, by: i64) !void {
        const h = try fs.handle(file.handle);
        const pos = @as(i128, h.offset) + by;
        if (pos < 0 or pos > std.math.maxInt(u64)) return error.Unseekable;
        h.offset = @intCast(pos);
    }
    pub fn fileSeekTo(_: *Core, fs: *Fs, file: Io.File, offset: u64) !void {
        (try fs.handle(file.handle)).offset = offset;
    }
    pub fn fileSync(_: *Core, fs: *Fs, file: Io.File) !void {
        return fs.flush(file.handle, .full);
    }
    pub fn fileSetLength(_: *Core, fs: *Fs, file: Io.File, size: u64) !void {
        return fs.setLength((try writable(fs, file)).inode, size);
    }
    pub fn fileSetOwner(_: *Core, fs: *Fs, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) !void {
        return setOwner(fs, (try fs.handle(file.handle)).inode, uid, gid);
    }
    pub fn fileSetPermissions(_: *Core, fs: *Fs, file: Io.File, permissions: Io.File.Permissions) !void {
        return setPermissions(fs, (try fs.handle(file.handle)).inode, permissions);
    }
    pub fn fileSetTimestamps(_: *Core, fs: *Fs, file: Io.File, options: Io.File.SetTimestampsOptions) !void {
        return timestamps(fs, (try fs.handle(file.handle)).inode, options);
    }
    pub fn fileLock(c: *Core, fs: *Fs, file: Io.File, lock: Io.File.Lock) !void {
        return acquire(c, fs, file, lock, false);
    }
    pub fn fileTryLock(_: *Core, fs: *Fs, file: Io.File, lock: Io.File.Lock) !bool {
        return fs.tryLock(file.handle, lock);
    }
    pub fn fileUnlock(c: *Core, fs: *Fs, file: Io.File) void {
        _ = fs.tryLock(file.handle, .none) catch return;
        wakeLocks(c, fs);
    }
    pub fn fileDowngradeLock(c: *Core, fs: *Fs, file: Io.File) !void {
        _ = try fs.tryLock(file.handle, .shared);
        wakeLocks(c, fs);
    }
    pub fn fileRealPath(_: *Core, fs: *Fs, file: Io.File, out: []u8) !usize {
        return fs.realPath((try fs.handle(file.handle)).inode, out);
    }
    pub fn fileHardLink(_: *Core, fs: *Fs, file: Io.File, dir: Io.Dir, path: []const u8, _: Io.File.HardLinkOptions) !void {
        return fs.link((try fs.handle(file.handle)).inode, try fs.directory(dir), path);
    }
    pub fn fileMemoryMapCreate(_: *Core, fs: *Fs, file: Io.File, options: Io.File.MemoryMap.CreateOptions) !Io.File.MemoryMap {
        const h = try fs.handle(file.handle);
        if (fs.root.nodes.items[h.inode].kind != .file or (options.protection.read and !h.read) or (options.protection.write and !h.write) or h.path_only) return error.AccessDenied;
        const memory = try fs.gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), options.len);
        errdefer fs.gpa.free(memory);
        @memset(memory, 0);
        _ = try fs.get(h.inode, options.offset, memory);
        try fs.maps.append(fs.gpa, memory);
        return .{ .file = file, .offset = options.offset, .memory = memory, .section = null };
    }
    pub fn fileMemoryMapDestroy(_: *Core, fs: *Fs, mm: *Io.File.MemoryMap) void {
        for (fs.maps.items, 0..) |m, i| if (m.ptr == mm.memory.ptr) {
            _ = fs.maps.swapRemove(i);
            fs.gpa.free(m);
            break;
        };
        mm.* = undefined;
    }
    pub fn fileMemoryMapSetLength(_: *Core, fs: *Fs, mm: *Io.File.MemoryMap, len: usize) !void {
        const memory = try fs.gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), len);
        @memset(memory, 0);
        @memcpy(memory[0..@min(len, mm.memory.len)], mm.memory[0..@min(len, mm.memory.len)]);
        for (fs.maps.items) |*m| if (m.ptr == mm.memory.ptr) {
            fs.gpa.free(m.*);
            m.* = memory;
            mm.memory = memory;
            return;
        };
        fs.gpa.free(memory);
        return error.AccessDenied;
    }
    pub fn fileMemoryMapRead(_: *Core, fs: *Fs, mm: *Io.File.MemoryMap) !void {
        const n = try fs.get((try readable(fs, mm.file)).inode, mm.offset, mm.memory);
        @memset(mm.memory[n..], 0);
    }
    pub fn fileMemoryMapWrite(_: *Core, fs: *Fs, mm: *Io.File.MemoryMap) !void {
        _ = try fs.put((try writable(fs, mm.file)).inode, mm.offset, mm.memory);
    }
    pub fn fileWriteFileStreaming(_: *Core, fs: *Fs, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) !usize {
        const h = try writable(fs, file);
        const offset = h.offset;
        const n = try copyFile(fs, file, header, reader, limit, offset);
        (try fs.handle(file.handle)).offset += n;
        return n;
    }
    pub fn fileWriteFilePositional(_: *Core, fs: *Fs, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit, offset: u64) !usize {
        return copyFile(fs, file, header, reader, limit, offset);
    }
};
fn setPermissions(fs: *Fs, id: u32, permissions: Io.File.Permissions) !void {
    var meta = fs.root.nodes.items[id].meta;
    meta.permissions = permissions;
    meta.ctime = fs.rounded(fs.at);
    return fs.metadata(id, meta);
}
fn setOwner(fs: *Fs, id: u32, uid: ?Io.File.Uid, gid: ?Io.File.Gid) !void {
    var meta = fs.root.nodes.items[id].meta;
    if (uid) |u| meta.uid = u;
    if (gid) |g| meta.gid = g;
    meta.ctime = fs.rounded(fs.at);
    return fs.metadata(id, meta);
}
fn timestamp(fs: *Fs, old: Io.Timestamp, option: Io.File.SetTimestamp) Io.Timestamp {
    return switch (option) {
        .unchanged => old,
        .now => fs.rounded(fs.at),
        .new => |at| fs.rounded(at),
    };
}
fn timestamps(fs: *Fs, id: u32, options: Io.File.SetTimestampsOptions) !void {
    var meta = fs.root.nodes.items[id].meta;
    meta.atime = timestamp(fs, meta.atime, options.access_timestamp);
    meta.mtime = timestamp(fs, meta.mtime, options.modify_timestamp);
    meta.ctime = fs.rounded(fs.at);
    return fs.metadata(id, meta);
}
fn acquire(c: *Core, fs: *Fs, file: Io.File, lock: Io.File.Lock, nonblocking: bool) !void {
    while (!try fs.tryLock(file.handle, lock)) {
        if (nonblocking) return error.WouldBlock;
        const expected = fs.lock_epoch;
        try c.outer.futexWait(u32, &fs.lock_epoch, expected);
    }
}
fn wakeLocks(c: *Core, fs: *Fs) void {
    fs.lock_epoch +%= 1;
    if (c.current != null) c.outer.futexWake(u32, &fs.lock_epoch, std.math.maxInt(u32));
}
fn copyFile(fs: *Fs, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit, offset: u64) !usize {
    const id = (try writable(fs, file)).inode;
    var n = try fs.put(id, offset, header);
    var buffer: [4096]u8 = undefined;
    const count = try reader.interface.readSliceShort(limit.slice(&buffer));
    n += try fs.put(id, offset + n, buffer[0..count]);
    if (n == 0) return error.EndOfStream;
    return n;
}

fn canWrite(permissions: Io.File.Permissions) bool {
    // Windows permissions are attributes; POSIX permissions are mode bits.
    if (builtin.os.tag == .windows) return !permissions.toAttributes().READONLY;
    return permissions.toMode() & 0o222 != 0;
}
