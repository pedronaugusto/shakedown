//! A simulated disk: inode images, a directory tree and pending persistence effects.
//! Snapshots retain a tree version in O(1); file contents share immutable 4 KiB
//! pages. Power loss may retain any pending sector in any order, subject to
//! barriers and optional data-before-metadata ordering. A name replacement is
//! one indivisible effect, except a Windows rename across directories.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Source = @import("../../Source.zig");
const state = @import("state.zig");
const names = @import("names.zig");
const Image = state.Image;
const Name = state.Name;
const Entry = state.Entry;
const Change = state.Change;
const Effect = state.Effect;
const State = state.State;
const Model = @This();

pub const Options = struct {
    names: enum { posix, darwin, windows } = .posix,
    timestamp_granularity: Io.Duration = .fromNanoseconds(1),
    capacity: ?u64 = null,
    sector: u32 = 512,
    durability: Durability = .strict,
};
pub const Durability = enum { strict, ordered_metadata };
pub const CrashPolicy = enum { lose_all, keep_all, random, os_crash };
pub const Flush = enum { writeout, barrier, data, full };
pub const Error = error{ OutOfMemory, FileNotFound, BadHandle, BadPathName, NameTooLong, NotDir, IsDir, PathAlreadyExists, DirNotEmpty, SymLinkLoop, AccessDenied, NoSpaceLeft, InputOutput, NotOpenForReading, NotOpenForWriting, InvalidArgument, WouldBlock };

/// Internal state; only the owning Sim constructs and destroys an Model.
gpa: Allocator,
source: *Source,
options: Options,
root: *State,
at: Io.Timestamp = .fromNanoseconds(0),
handles: std.ArrayList(Handle) = .empty,
next_handle: u32 = 1,
lock_epoch: u32 = 0,
maps: std.ArrayList([]align(std.heap.page_size_min) u8) = .empty,

pub const Handle = struct {
    id: u32,
    inode: u32,
    offset: u64 = 0,
    read: bool,
    write: bool,
    path_only: bool = false,
    iterate: bool = false,
    lock: Io.File.Lock = .none,
};

pub fn init(gpa: Allocator, source: *Source, options: Options) !*Model {
    std.debug.assert(options.sector > 0);
    std.debug.assert(options.timestamp_granularity.nanoseconds > 0);
    const fs = try gpa.create(Model);
    errdefer gpa.destroy(fs);
    const root = try gpa.create(State);
    root.* = .{};
    fs.* = .{ .gpa = gpa, .source = source, .options = options, .root = root };
    errdefer root.release(gpa);
    _ = try fs.newNode(.directory, .default_dir, null);
    return fs;
}
pub fn deinit(fs: *Model) void {
    for (fs.maps.items) |memory| fs.gpa.free(memory);
    fs.maps.deinit(fs.gpa);
    fs.handles.deinit(fs.gpa);
    fs.root.release(fs.gpa);
    fs.gpa.destroy(fs);
}
fn unique(fs: *Model) !void {
    if (fs.root.refs == 1) return;
    const next = try fs.root.clone(fs.gpa);
    fs.root.release(fs.gpa);
    fs.root = next;
}
pub fn rounded(fs: *const Model, at: Io.Timestamp) Io.Timestamp {
    const grain = fs.options.timestamp_granularity.nanoseconds;
    return .fromNanoseconds(@divFloor(at.nanoseconds, grain) * grain);
}
fn newNode(fs: *Model, kind: Io.File.Kind, permissions: Io.File.Permissions, target: ?[]const u8) !u32 {
    try fs.root.nodes.ensureUnusedCapacity(fs.gpa, 1);
    const image = try Image.empty(fs.gpa);
    errdefer image.release(fs.gpa);
    const name = if (target) |t| try Name.create(fs.gpa, t) else null;
    errdefer if (name) |n| n.release(fs.gpa);
    const meta: state.Meta = .{ .permissions = permissions, .atime = fs.rounded(fs.at), .mtime = fs.rounded(fs.at), .ctime = fs.rounded(fs.at) };
    var id: u32 = @intCast(fs.root.nodes.items.len);
    for (fs.root.nodes.items, 0..) |n, i| if (n.kind == .unknown) {
        id = @intCast(i);
        break;
    };
    const node: state.Node = .{ .kind = kind, .live = image, .disk = image.retain(), .meta = meta, .disk_meta = meta, .target = name };
    if (id == fs.root.nodes.items.len) {
        fs.root.nodes.appendAssumeCapacity(node);
    } else {
        fs.root.nodes.items[id].release(fs.gpa);
        fs.root.nodes.items[id] = node;
    }
    return id;
}
pub fn encode(id: u32) Io.File.Handle {
    if (builtin.os.tag == .windows) return @ptrFromInt(std.math.maxInt(usize) - 0x7fff_ffff + @as(usize, id) * 4); // safe: negative NT kernel handles; user-mode calls cannot resolve them
    return -1_048_576 - @as(i32, @intCast(id));
}
fn decode(raw: Io.File.Handle) ?u32 {
    if (builtin.os.tag == .windows) {
        const value = @intFromPtr(raw); // safe: opaque handle, never dereferenced
        const base = std.math.maxInt(usize) - 0x7fff_ffff;
        if (value < base + 4 or value % 4 != 0) return null;
        return std.math.cast(u32, (value - base) / 4);
    }
    if (raw >= -1_048_576) return null;
    return @intCast(-@as(i64, raw) - 1_048_576);
}
pub fn handle(fs: *Model, raw: Io.File.Handle) Error!*Handle {
    const id = decode(raw) orelse return error.BadHandle;
    for (fs.handles.items) |*h| if (h.id == id) return h;
    return error.BadHandle;
}
pub fn directory(fs: *Model, dir: Io.Dir) Error!u32 {
    if (dir.handle == Io.Dir.cwd().handle) return 0;
    const h = try fs.handle(dir.handle);
    if (fs.root.nodes.items[h.inode].kind != .directory) return error.NotDir;
    return h.inode;
}
pub fn openHandle(fs: *Model, inode: u32, read_access: bool, write_access: bool, path_only: bool, iterate: bool) !Io.File {
    if (fs.next_handle >= 0x1000_0000) return error.OutOfMemory;
    const id = fs.next_handle;
    try fs.handles.append(fs.gpa, .{ .id = id, .inode = inode, .read = read_access, .write = write_access, .path_only = path_only, .iterate = iterate });
    fs.next_handle += 1;
    return .{ .handle = encode(id), .flags = .{ .nonblocking = false } };
}
pub fn close(fs: *Model, raw: Io.File.Handle) void {
    const id = decode(raw) orelse return;
    for (fs.handles.items, 0..) |h, i| if (h.id == id) {
        _ = fs.handles.swapRemove(i);
        return;
    };
}
fn separator(fs: *const Model, c: u8) bool {
    return c == '/' or (fs.options.names == .windows and c == '\\');
}
fn sameName(fs: *const Model, a: []const u8, b: []const u8) bool {
    if (fs.options.names == .posix) return std.mem.eql(u8, a, b);
    return names.equal(a, b, fs.options.names == .darwin);
}
fn validName(fs: *const Model, name: []const u8) Error!void {
    if (name.len == 0 or std.mem.findScalar(u8, name, 0) != null) return error.BadPathName;
    if (fs.options.names != .windows) {
        if (name.len > 255) return error.NameTooLong;
        return;
    }
    var view = std.unicode.Wtf8View.init(name) catch return error.BadPathName;
    var iter = view.iterator();
    var units: usize = 0;
    while (iter.nextCodepoint()) |cp| units += if (cp > 0xffff) @as(usize, 2) else 1;
    if (units > 255) return error.NameTooLong;
    for (name) |c| if (c < 32 or std.mem.findScalar(u8, "<>:\"|?*", c) != null) return error.BadPathName;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.BadPathName;
    const stem = name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.BadPathName;
    if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        const suffix = stem[3..];
        if (suffix.len == 1 and suffix[0] >= '1' and suffix[0] <= '9') return error.BadPathName;
        for ([_][]const u8{ "¹", "²", "³" }) |digit| if (std.mem.eql(u8, suffix, digit)) return error.BadPathName;
    }
}
pub fn find(fs: *const Model, entries: []const Entry, parent_id: u32, name: []const u8) ?usize {
    for (entries, 0..) |e, i| if (e.parent == parent_id and fs.sameName(e.name.bytes, name)) return i;
    return null;
}
fn parentOf(fs: *const Model, inode: u32) u32 {
    for (fs.root.entries.items) |e| if (e.inode == inode) return e.parent;
    return 0;
}
pub fn resolve(fs: *Model, base: u32, path: []const u8, follow: bool) Error!u32 {
    return fs.walk(base, path, follow, 0);
}
fn walk(fs: *Model, base: u32, path: []const u8, follow: bool, depth: u8) Error!u32 {
    if (depth >= 40) return error.SymLinkLoop;
    if (path.len == 0) return error.FileNotFound;
    var inode: u32 = if (fs.separator(path[0])) 0 else base;
    var rest = path;
    while (rest.len != 0) {
        while (rest.len > 0 and fs.separator(rest[0])) rest = rest[1..];
        if (rest.len == 0) {
            if (fs.root.nodes.items[inode].kind != .directory) return error.NotDir;
            break;
        }
        var end: usize = 0;
        while (end < rest.len and !fs.separator(rest[end])) end += 1;
        const component = rest[0..end];
        rest = rest[end..];
        if (fs.root.nodes.items[inode].kind != .directory) return error.NotDir;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            inode = fs.parentOf(inode);
            continue;
        }
        try fs.validName(component);
        const i = fs.find(fs.root.entries.items, inode, component) orelse return error.FileNotFound;
        const child = fs.root.entries.items[i].inode;
        const n = &fs.root.nodes.items[child];
        if (n.kind == .sym_link and (follow or rest.len != 0)) {
            var buffer: [4096]u8 = undefined;
            const target = n.target.?.bytes;
            if (target.len + rest.len > buffer.len) return error.NameTooLong;
            @memcpy(buffer[0..target.len], target);
            @memcpy(buffer[target.len..][0..rest.len], rest);
            return fs.walk(inode, buffer[0 .. target.len + rest.len], follow, depth + 1);
        }
        inode = child;
    }
    return inode;
}
pub const Parent = struct { inode: u32, name: []const u8 };
pub fn parent(fs: *Model, base: u32, path: []const u8) Error!Parent {
    if (path.len == 0) return error.BadPathName;
    var end = path.len;
    while (end > 0 and fs.separator(path[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !fs.separator(path[start - 1])) start -= 1;
    const name = path[start..end];
    try fs.validName(name);
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.BadPathName;
    const id = if (start == 0) base else try fs.resolve(base, path[0..start], true);
    if (fs.root.nodes.items[id].kind != .directory) return error.NotDir;
    return .{ .inode = id, .name = name };
}
fn record(fs: *Model, effect: Effect) !void {
    const op = try fs.gpa.create(state.Op);
    errdefer fs.gpa.destroy(op);
    try fs.root.pending.ensureUnusedCapacity(fs.gpa, 1);
    fs.root.serial += 1;
    op.* = .{ .serial = fs.root.serial, .before = fs.root.barrier, .effect = effect };
    switch (effect) {
        .write => |w| _ = w.image.retain(),
        .length => |l| _ = l.image.retain(),
        .entries => |e| for (e.changes[0..e.len]) |c| {
            _ = c.name.retain();
        },
        .metadata => {},
    }
    fs.root.pending.appendAssumeCapacity(.{ .op = op });
}
fn recordData(fs: *Model, effect: Effect, inode: u32, meta: state.Meta) !void {
    const before = fs.root.pending.items.len;
    const serial = fs.root.serial;
    errdefer {
        while (fs.root.pending.items.len > before) {
            const record_ = fs.root.pending.pop().?;
            record_.op.release(fs.gpa);
        }
        fs.root.serial = serial;
    }
    try fs.record(effect);
    if (!std.meta.eql(meta, fs.root.nodes.items[inode].meta)) try fs.record(.{ .metadata = .{ .inode = inode, .meta = meta } });
}
fn change(fs: *Model, entries: *std.ArrayList(Entry), c: Change) !void {
    if (fs.find(entries.items, c.parent, c.name.bytes)) |i| {
        if (c.inode) |id| {
            entries.items[i].inode = id;
        } else {
            const e = entries.orderedRemove(i);
            e.name.release(fs.gpa);
        }
    } else if (c.inode) |id| {
        try entries.ensureUnusedCapacity(fs.gpa, 1);
        entries.appendAssumeCapacity(.{ .parent = c.parent, .name = c.name.retain(), .inode = id });
    }
}
fn entryEffect(fs: *Model, changes: []const Change, data_inode: ?u32) !void {
    try fs.root.entries.ensureUnusedCapacity(fs.gpa, changes.len);
    const before = fs.root.pending.items.len;
    const serial = fs.root.serial;
    errdefer {
        while (fs.root.pending.items.len > before) {
            const record_ = fs.root.pending.pop().?;
            record_.op.release(fs.gpa);
        }
        fs.root.serial = serial;
    }
    var effect: Effect = .{ .entries = .{ .changes = undefined, .len = @intCast(changes.len), .data_inode = data_inode } };
    @memcpy(effect.entries.changes[0..changes.len], changes);
    try fs.record(effect);
    var metadata_: [2]state.Meta = undefined;
    for (changes, 0..) |c, i| {
        var meta = fs.root.nodes.items[c.parent].meta;
        meta.mtime = fs.rounded(fs.at);
        meta.ctime = meta.mtime;
        metadata_[i] = meta;
        if (i == 1 and c.parent == changes[0].parent) continue;
        if (!std.meta.eql(meta, fs.root.nodes.items[c.parent].meta)) try fs.record(.{ .metadata = .{ .inode = c.parent, .meta = meta } });
    }
    for (changes, 0..) |c, i| {
        try fs.change(&fs.root.entries, c);
        fs.root.nodes.items[c.parent].meta = metadata_[i];
    }
}
pub fn create(fs: *Model, base: u32, path: []const u8, kind: Io.File.Kind, permissions: Io.File.Permissions, target: ?[]const u8) Error!u32 {
    const p = try fs.parent(base, path);
    if (fs.find(fs.root.entries.items, p.inode, p.name) != null) return error.PathAlreadyExists;
    try fs.unique();
    const name = try Name.create(fs.gpa, p.name);
    defer name.release(fs.gpa);
    try fs.root.entries.ensureUnusedCapacity(fs.gpa, 1);
    try fs.root.pending.ensureUnusedCapacity(fs.gpa, 1);
    fs.collect();
    const id = try fs.newNode(kind, permissions, target);
    try fs.entryEffect(&.{.{ .parent = p.inode, .name = name, .inode = id }}, id);
    return id;
}
pub fn remove(fs: *Model, base: u32, path: []const u8, directory_only: bool) Error!void {
    const p = try fs.parent(base, path);
    const i = fs.find(fs.root.entries.items, p.inode, p.name) orelse return error.FileNotFound;
    const entry = fs.root.entries.items[i];
    const n = fs.root.nodes.items[entry.inode];
    if (directory_only and n.kind != .directory) return error.NotDir;
    if (!directory_only and n.kind == .directory) return error.IsDir;
    if (n.kind == .directory) for (fs.root.entries.items) |e| if (e.parent == entry.inode) return error.DirNotEmpty;
    try fs.unique();
    try fs.entryEffect(&.{.{ .parent = p.inode, .name = fs.root.entries.items[i].name, .inode = null }}, null);
}
pub fn rename(fs: *Model, old_base: u32, old_path: []const u8, new_base: u32, new_path: []const u8, preserve: bool) Error!void {
    const from = try fs.parent(old_base, old_path);
    const to = try fs.parent(new_base, new_path);
    const i = fs.find(fs.root.entries.items, from.inode, from.name) orelse return error.FileNotFound;
    const inode = fs.root.entries.items[i].inode;
    if (fs.find(fs.root.entries.items, to.inode, to.name)) |j| {
        if (preserve) return error.PathAlreadyExists;
        if (inode == fs.root.entries.items[j].inode and !fs.sameName(from.name, to.name)) return;
        const src_kind = fs.root.nodes.items[inode].kind;
        const dst = fs.root.entries.items[j].inode;
        const dst_kind = fs.root.nodes.items[dst].kind;
        if (src_kind == .directory and dst_kind != .directory) return error.NotDir;
        if (src_kind != .directory and dst_kind == .directory) return error.IsDir;
        if (dst_kind == .directory) for (fs.root.entries.items) |e| if (e.parent == dst) return error.DirNotEmpty;
    }
    if (fs.root.nodes.items[inode].kind == .directory) {
        var ancestor = to.inode;
        while (ancestor != 0) {
            if (ancestor == inode) return error.InvalidArgument;
            ancestor = fs.parentOf(ancestor);
        }
    }
    try fs.unique();
    const name = try Name.create(fs.gpa, to.name);
    defer name.release(fs.gpa);
    const changes = [_]Change{ .{ .parent = from.inode, .name = fs.root.entries.items[i].name, .inode = null }, .{ .parent = to.inode, .name = name, .inode = inode } };
    if (fs.options.names == .windows and from.inode != to.inode) {
        // Reserve both records before exposing either half of the live rename.
        const checkpoint = try fs.snapshot();
        defer checkpoint.deinit();
        errdefer fs.restoreStorage(checkpoint);
        try fs.unique();
        try fs.entryEffect(changes[0..1], null);
        try fs.entryEffect(changes[1..2], inode);
    } else try fs.entryEffect(&changes, inode);
}
pub fn link(fs: *Model, inode: u32, base: u32, path: []const u8) Error!void {
    if (fs.root.nodes.items[inode].kind == .directory) return error.AccessDenied;
    const p = try fs.parent(base, path);
    if (fs.find(fs.root.entries.items, p.inode, p.name) != null) return error.PathAlreadyExists;
    try fs.unique();
    const name = try Name.create(fs.gpa, p.name);
    defer name.release(fs.gpa);
    try fs.entryEffect(&.{.{ .parent = p.inode, .name = name, .inode = inode }}, inode);
}
pub fn stat(fs: *const Model, inode: u32) Io.File.Stat {
    const n = fs.root.nodes.items[inode];
    var links: Io.File.NLink = 0;
    for (fs.root.entries.items) |e| if (e.inode == inode) {
        links += 1;
    };
    return .{ .inode = @intCast(inode + 1), .nlink = links, .size = if (n.target) |t| t.bytes.len else n.live.size, .permissions = n.meta.permissions, .kind = n.kind, .atime = n.meta.atime, .mtime = n.meta.mtime, .ctime = n.meta.ctime, .block_size = Image.page_size };
}
fn used(fs: *const Model) u64 {
    var size: u64 = 0;
    for (fs.root.nodes.items, 0..) |n, id| {
        var linked = id == 0;
        for (fs.root.entries.items) |e| if (e.inode == id) {
            linked = true;
            break;
        };
        if (!linked) for (fs.handles.items) |h| if (h.inode == id) {
            linked = true;
            break;
        };
        if (linked) size +|= n.live.size;
    }
    return size;
}
pub fn put(fs: *Model, inode: u32, requested_offset: u64, bytes: []const u8) Error!usize {
    if (bytes.len == 0) return 0;
    const n = fs.root.nodes.items[inode];
    if (n.kind == .directory) return error.IsDir;
    const offset = n.misdirect orelse requested_offset;
    const end = std.math.add(u64, offset, bytes.len) catch return error.NoSpaceLeft;
    const size = @max(n.live.size, end);
    if (fs.options.capacity) |cap| if (size - n.live.size > cap -| fs.used()) return error.NoSpaceLeft;
    const next = try n.live.edit(fs.gpa, size, offset, bytes);
    errdefer next.release(fs.gpa);
    try fs.unique();
    var meta = n.meta;
    meta.mtime = fs.rounded(fs.at);
    meta.ctime = meta.mtime;
    try fs.recordData(.{ .write = .{ .inode = inode, .offset = offset, .len = bytes.len, .image = next } }, inode, meta);
    const node = &fs.root.nodes.items[inode];
    node.live.release(fs.gpa);
    node.live = next;
    node.misdirect = null;
    node.meta = meta;
    return bytes.len;
}
pub fn setLength(fs: *Model, inode: u32, size: u64) Error!void {
    const n = fs.root.nodes.items[inode];
    if (n.kind == .directory) return error.IsDir;
    if (fs.options.capacity) |cap| if (size -| n.live.size > cap -| fs.used()) return error.NoSpaceLeft;
    const next = try n.live.edit(fs.gpa, size, 0, &.{});
    errdefer next.release(fs.gpa);
    try fs.unique();
    var meta = n.meta;
    meta.mtime = fs.rounded(fs.at);
    meta.ctime = meta.mtime;
    try fs.recordData(.{ .length = .{ .inode = inode, .image = next } }, inode, meta);
    const node = &fs.root.nodes.items[inode];
    node.live.release(fs.gpa);
    node.live = next;
    node.meta = meta;
}
pub fn get(fs: *Model, inode: u32, offset: u64, out: []u8) Error!usize {
    if (out.len == 0) return 0;
    const n = fs.root.nodes.items[inode];
    if (n.kind == .directory) return error.IsDir;
    const end = offset +| @as(u64, out.len);
    if (n.bad_len != 0 and offset < n.bad_start +| n.bad_len and end > n.bad_start) return error.InputOutput;
    return n.live.read(offset, out);
}
pub fn metadata(fs: *Model, inode: u32, meta: state.Meta) !void {
    try fs.unique();
    try fs.record(.{ .metadata = .{ .inode = inode, .meta = meta } });
    fs.root.nodes.items[inode].meta = meta;
}
/// Populate a file before a run, including missing parents, and make the setup durable.
pub fn write(fs: *Model, path: []const u8, bytes: []const u8) !void {
    try fs.setupParents(path);
    const id = fs.resolve(0, path, true) catch try fs.create(0, path, .file, .default_file, null);
    try fs.setLength(id, 0);
    _ = try fs.put(id, 0, bytes);
    try fs.syncSetup();
}
pub fn mkdir(fs: *Model, path: []const u8) !void {
    try fs.setupParents(path);
    _ = fs.resolve(0, path, true) catch try fs.create(0, path, .directory, .default_dir, null);
    try fs.syncSetup();
}
fn setupParents(fs: *Model, path: []const u8) !void {
    for (path, 0..) |c, i| if (i != 0 and fs.separator(c)) {
        _ = fs.resolve(0, path[0..i], true) catch try fs.create(0, path[0..i], .directory, .default_dir, null);
    };
}
fn syncSetup(fs: *Model) !void {
    try fs.unique();
    for (fs.root.nodes.items) |*n| {
        n.disk.release(fs.gpa);
        n.disk = n.live.retain();
        n.disk_meta = n.meta;
    }
    try fs.root.disk_entries.ensureTotalCapacity(fs.gpa, fs.root.entries.items.len);
    for (fs.root.disk_entries.items) |e| e.name.release(fs.gpa);
    fs.root.disk_entries.clearRetainingCapacity();
    for (fs.root.entries.items) |e| fs.root.disk_entries.appendAssumeCapacity(e.retain());
    for (fs.root.pending.items) |r| r.op.release(fs.gpa);
    fs.root.pending.clearRetainingCapacity();
}
pub fn read(fs: *Model, gpa: Allocator, path: []const u8) ![]u8 {
    const id = try fs.resolve(0, path, true);
    const image = fs.root.nodes.items[id].live;
    const bytes = try gpa.alloc(u8, @intCast(image.size));
    errdefer gpa.free(bytes);
    _ = try fs.get(id, 0, bytes);
    return bytes;
}
pub fn corrupt(fs: *Model, path: []const u8, offset: u64, len: u32) !void {
    const id = try fs.resolve(0, path, true);
    const image = fs.root.nodes.items[id].live;
    const count: usize = @intCast(@min(len, image.size -| offset));
    const bytes = try fs.gpa.alloc(u8, count);
    defer fs.gpa.free(bytes);
    _ = image.read(offset, bytes);
    for (bytes) |*b| b.* ^= 0xff;
    const next = try image.edit(fs.gpa, image.size, offset, bytes);
    errdefer next.release(fs.gpa);
    const disk = fs.root.nodes.items[id].disk;
    const disk_count: usize = @intCast(@min(count, disk.size -| offset));
    _ = disk.read(offset, bytes[0..disk_count]);
    for (bytes[0..disk_count]) |*v| v.* ^= 0xff;
    const durable = try disk.edit(fs.gpa, disk.size, offset, bytes[0..disk_count]);
    errdefer durable.release(fs.gpa);
    try fs.unique();
    const n = &fs.root.nodes.items[id];
    n.live.release(fs.gpa);
    n.disk.release(fs.gpa);
    n.live = next;
    n.disk = durable;
    // Latent media corruption affects already durable and subsequent reads.
}
pub fn failReads(fs: *Model, path: []const u8, offset: u64, len: u32) !void {
    const id = try fs.resolve(0, path, true);
    try fs.unique();
    fs.root.nodes.items[id].bad_start = offset;
    fs.root.nodes.items[id].bad_len = len;
}
pub fn misdirectNextWrite(fs: *Model, path: []const u8, to_offset: u64) !void {
    const id = try fs.resolve(0, path, true);
    try fs.unique();
    fs.root.nodes.items[id].misdirect = to_offset;
}
fn touches(effect: Effect, id: u32) bool {
    return switch (effect) {
        .write => |w| w.inode == id,
        .length => |l| l.inode == id,
        .metadata => |m| m.inode == id,
        .entries => |e| blk: {
            for (e.changes[0..e.len]) |c| if (c.parent == id) break :blk true;
            break :blk false;
        },
    };
}
/// A raw sync for seams. OutOfMemory is explicit when a snapshot shares the tree.
pub fn flush(fs: *Model, raw: Io.File.Handle, kind: Flush) !void {
    const id = if (raw == Io.Dir.cwd().handle) @as(u32, 0) else (try fs.handle(raw)).inode;
    try fs.flushInode(id, kind);
}
pub fn flushDir(fs: *Model, raw: Io.Dir.Handle, kind: Flush) !void {
    const id = try fs.directory(.{ .handle = raw });
    try fs.flushInode(id, kind);
}
pub fn flushInode(fs: *Model, id: u32, kind: Flush) !void {
    try fs.unique();
    for (fs.root.pending.items) |*r| if (!r.synced and touches(r.op.effect, id)) {
        // fdatasync does not promise permissions or timestamps.
        if (kind == .data and r.op.effect == .metadata) continue;
        r.written = true;
    };
    if (kind == .writeout) return;
    if (kind == .barrier) {
        for (fs.root.pending.items) |*r| if (r.written) {
            r.ordered = true;
        };
        fs.root.barrier = fs.root.serial;
        return;
    }
    // A device flush also persists what earlier writeouts handed to this disk.
    // Data-only flushes do not upgrade unrelated metadata to full.
    for (fs.root.pending.items) |*r| {
        if (r.synced or !r.written) continue;
        if (kind == .data and r.op.effect == .metadata) continue;
        // The target's live image already represents all its content effects.
        // Retain it once below; only other writeouts need patch replay.
        const own_content = switch (r.op.effect) {
            .write => |w| w.inode == id,
            .length => |l| l.inode == id,
            else => false,
        };
        try fs.persistPrerequisites(r.op);
        if (!own_content) try fs.apply(r.op.effect, null);
        r.synced = true;
    }
    const n = &fs.root.nodes.items[id];
    n.disk.release(fs.gpa);
    n.disk = n.live.retain();
    if (kind == .full) n.disk_meta = n.meta;
    var kept: usize = 0;
    for (fs.root.pending.items) |r| {
        if (r.synced) r.op.release(fs.gpa) else {
            fs.root.pending.items[kept] = r;
            kept += 1;
        }
    }
    fs.root.pending.items.len = kept;
    fs.collect();
}
// Ordered metadata cannot become durable ahead of the data it publishes,
// including when a directory sync forces it instead of a crash choosing it.
fn persistPrerequisites(fs: *Model, op: *state.Op) !void {
    if (fs.options.durability != .ordered_metadata or op.effect != .entries) return;
    const id = op.effect.entries.data_inode orelse return;
    for (fs.root.pending.items) |*earlier| {
        if (earlier.synced or earlier.op.serial >= op.serial) continue;
        const required = switch (earlier.op.effect) {
            .write => |w| w.inode == id,
            .length => |l| l.inode == id,
            else => false,
        };
        if (!required) continue;
        try fs.apply(earlier.op.effect, null);
        earlier.synced = true;
    }
}
// Reclaim unlinked, closed inodes after their persistence effects are spent.
// Numeric handles never repeat, even when inode slots are reused.
fn collect(fs: *Model) void {
    for (fs.root.nodes.items, 0..) |*n, id| {
        if (id == 0 or n.kind == .unknown) continue;
        var referenced = false;
        for (fs.root.entries.items) |e| if (e.inode == id or e.parent == id) {
            referenced = true;
            break;
        };
        if (!referenced) for (fs.root.disk_entries.items) |e| if (e.inode == id or e.parent == id) {
            referenced = true;
            break;
        };
        if (!referenced) for (fs.handles.items) |h| if (h.inode == id) {
            referenced = true;
            break;
        };
        if (!referenced) for (fs.root.pending.items) |r| {
            if (r.op.effect == .entries and touches(r.op.effect, @intCast(id))) {
                referenced = true;
                break;
            }
            if (r.op.effect == .entries) for (r.op.effect.entries.changes[0..r.op.effect.entries.len]) |ch| if (ch.inode == @as(u32, @intCast(id))) {
                referenced = true;
                break;
            };
        };
        if (referenced) continue;
        // No name, handle or pending publication can reach this inode anymore.
        // Its leftover timestamps/data cannot affect any future crash image.
        var kept: usize = 0;
        for (fs.root.pending.items) |r| {
            if (touches(r.op.effect, @intCast(id))) r.op.release(fs.gpa) else {
                fs.root.pending.items[kept] = r;
                kept += 1;
            }
        }
        fs.root.pending.items.len = kept;
        const meta = n.meta;
        n.release(fs.gpa);
        const empty = fs.root.nodes.items[0].live;
        n.* = .{ .kind = .unknown, .live = empty.retain(), .disk = empty.retain(), .meta = meta, .disk_meta = meta };
    }
}
fn apply(fs: *Model, effect: Effect, sector_index: ?u64) !void {
    switch (effect) {
        .write => |w| {
            var offset = w.offset;
            var len = w.len;
            if (sector_index) |i| {
                const start = (w.offset / fs.options.sector + i) * fs.options.sector;
                offset = @max(start, w.offset);
                len = @min(w.offset + w.len, start + fs.options.sector) - offset;
            }
            const n = &fs.root.nodes.items[w.inode];
            var buffer: [4096]u8 = undefined;
            var pos: u64 = 0;
            while (pos < len) {
                const count: usize = @intCast(@min(buffer.len, len - pos));
                _ = w.image.read(offset + pos, buffer[0..count]);
                const next = try n.disk.edit(fs.gpa, @max(n.disk.size, offset + pos + count), offset + pos, buffer[0..count]);
                n.disk.release(fs.gpa);
                n.disk = next;
                pos += count;
            }
        },
        .length => |l| {
            const n = &fs.root.nodes.items[l.inode];
            const next = try n.disk.edit(fs.gpa, l.image.size, 0, &.{});
            n.disk.release(fs.gpa);
            n.disk = next;
        },
        .metadata => |m| fs.root.nodes.items[m.inode].disk_meta = m.meta,
        .entries => |e| {
            try fs.root.disk_entries.ensureUnusedCapacity(fs.gpa, e.len);
            for (e.changes[0..e.len]) |c| try fs.change(&fs.root.disk_entries, c);
        },
    }
}
fn crashed(fs: *Model) !void {
    try fs.root.entries.ensureTotalCapacity(fs.gpa, fs.root.disk_entries.items.len);
    for (fs.root.entries.items) |e| e.name.release(fs.gpa);
    fs.root.entries.clearRetainingCapacity();
    for (fs.root.disk_entries.items) |e| fs.root.entries.appendAssumeCapacity(e.retain());
    for (fs.root.nodes.items) |*n| {
        n.live.release(fs.gpa);
        n.live = n.disk.retain();
        n.meta = n.disk_meta;
        n.misdirect = null;
    }
    for (fs.root.pending.items) |r| r.op.release(fs.gpa);
    fs.root.pending.clearRetainingCapacity();
    fs.root.barrier = 0;
}
/// Power loss. Storage survives; all open handles and locks are invalidated.
/// Failure to allocate leaves the original disk and live tree intact.
pub fn crash(fs: *Model, policy: CrashPolicy) !void {
    const before = try fs.snapshot();
    defer before.deinit();
    errdefer fs.restoreStorage(before);
    try fs.unique();
    if (policy == .keep_all or policy == .os_crash) {
        for (fs.root.pending.items) |r| if (!r.synced and (policy == .keep_all or r.written)) {
            try fs.persistPrerequisites(r.op);
            try fs.apply(r.op.effect, null);
        };
    } else if (policy == .random) {
        var iter = try fs.crashStates(std.math.maxInt(u32));
        defer iter.deinit();
        // Draw a subset and its application order directly; every draw is on Source.
        const order = try fs.gpa.alloc(Unit, iter.units.len);
        defer fs.gpa.free(order);
        var len: usize = 0;
        for (iter.units) |u| if (fs.source.below(1) != 0) {
            order[len] = u;
            len += 1;
        };
        var i = len;
        while (i > 1) {
            i -= 1;
            std.mem.swap(Unit, &order[i], &order[fs.source.below(i)]);
        }
        var applied: usize = 0;
        for (0..len) |k| {
            const u = order[k];
            order[applied] = u;
            if (!iter.allowed(order[0 .. applied + 1], u)) continue;
            const r = fs.root.pending.items[u.record];
            try fs.apply(r.op.effect, u.sector);
            applied += 1;
        }
    }
    try fs.crashed();
    fs.handles.clearRetainingCapacity();
}
pub const Snapshot = struct {
    /// Owned reference; release once. Restore borrows it and keeps another reference.
    root: *State,
    gpa: Allocator,
    pub fn deinit(snap: Snapshot) void {
        snap.root.release(snap.gpa);
    }
};
pub fn snapshot(fs: *Model) error{OutOfMemory}!Snapshot {
    fs.root.refs += 1;
    return .{ .root = fs.root, .gpa = fs.gpa };
}
/// Restore storage only. Handles and advisory locks are invalidated.
fn restoreStorage(fs: *Model, snap: Snapshot) void {
    snap.root.refs += 1;
    fs.root.release(fs.gpa);
    fs.root = snap.root;
}
pub fn restore(fs: *Model, snap: Snapshot) void {
    std.debug.assert(std.meta.eql(fs.gpa, snap.gpa));
    fs.restoreStorage(snap);
    fs.handles.clearRetainingCapacity();
}
const Unit = struct { record: usize, sector: ?u64 };
/// Bounded exploration: increasing number of retained effects, all subsets and
/// all orders within each subset, including individual sectors of pending writes.
/// Identical persisted trees reached by distinct histories are returned once.
pub const CrashStateIterator = struct {
    fs: *Model,
    before: Snapshot,
    units: []Unit,
    indices: []usize,
    order: []Unit,
    kept: usize = 0,
    started: bool = false,
    done: bool = false,
    emitted: u32 = 0,
    seen: std.ArrayList(Snapshot) = .empty,
    limit: u32,
    pub fn deinit(it: *CrashStateIterator) void {
        for (it.seen.items) |snap| snap.deinit();
        it.seen.deinit(it.fs.gpa);
        it.before.deinit();
        it.fs.gpa.free(it.units);
        it.fs.gpa.free(it.indices);
        it.fs.gpa.free(it.order);
        it.* = undefined;
    }
    fn advance(it: *CrashStateIterator) void {
        if (!it.started) {
            it.started = true;
            return;
        }
        if (nextPermutation(it.order[0..it.kept])) return;
        var j = it.kept;
        while (j > 0) {
            j -= 1;
            if (it.indices[j] < it.units.len - it.kept + j) {
                it.indices[j] += 1;
                for (j + 1..it.kept) |k| it.indices[k] = it.indices[k - 1] + 1;
                for (0..it.kept) |k| it.order[k] = it.units[it.indices[k]];
                return;
            }
        }
        it.kept += 1;
        if (it.kept > it.units.len) {
            it.done = true;
            return;
        }
        for (0..it.kept) |k| {
            it.indices[k] = k;
            it.order[k] = it.units[k];
        }
    }
    fn allowed(it: *const CrashStateIterator, chosen: []const Unit, unit: Unit) bool {
        const records = it.before.root.pending.items;
        const op = records[unit.record].op;
        for (it.units) |needed| {
            const earlier = records[needed.record];
            if (earlier.op.serial >= op.serial) continue;
            var require = earlier.ordered and earlier.op.serial <= op.before;
            if (it.fs.options.durability == .ordered_metadata and op.effect == .entries) {
                if (op.effect.entries.data_inode) |inode| require = require or switch (earlier.op.effect) {
                    .write => |w| w.inode == inode,
                    .length => |l| l.inode == inode,
                    else => false,
                };
            }
            if (!require) continue;
            var found = false;
            for (chosen) |candidate| if (candidate.record == needed.record and candidate.sector == needed.sector) {
                found = true;
                break;
            };
            if (!found) return false;
            // A barrier constrains order as well as the persisted subset.
            for (chosen) |candidate| {
                if (candidate.record == needed.record and candidate.sector == needed.sector) break;
                if (candidate.record == unit.record and candidate.sector == unit.sector) return false;
            }
        }
        return true;
    }
    pub fn next(it: *CrashStateIterator) error{OutOfMemory}!?Snapshot {
        if (it.emitted >= it.limit or it.done) return null;
        while (true) {
            it.advance();
            if (it.done) return null;
            const chosen = it.order[0..it.kept];
            var legal = true;
            for (chosen) |u| if (!it.allowed(chosen, u)) {
                legal = false;
                break;
            };
            if (!legal) continue;
            const saved = try it.fs.snapshot();
            defer saved.deinit();
            it.fs.restoreStorage(it.before);
            defer it.fs.restoreStorage(saved);
            try it.fs.unique();
            for (chosen) |u| try it.fs.apply(it.before.root.pending.items[u.record].op.effect, u.sector);
            try it.fs.crashed();
            var duplicate = false;
            for (it.seen.items) |snap| if (it.fs.sameStorage(snap.root)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            try it.seen.ensureUnusedCapacity(it.fs.gpa, 1);
            const snap = try it.fs.snapshot();
            it.seen.appendAssumeCapacity(snap);
            it.emitted += 1;
            const retained = try it.fs.snapshot();
            return retained;
        }
    }
};
fn sameStorage(fs: *const Model, other: *const State) bool {
    if (fs.root.entries.items.len != other.entries.items.len or fs.root.nodes.items.len != other.nodes.items.len) return false;
    for (fs.root.entries.items) |e| {
        const i = fs.find(other.entries.items, e.parent, e.name.bytes) orelse return false;
        if (e.inode != other.entries.items[i].inode) return false;
    }
    for (fs.root.nodes.items, other.nodes.items) |a, b| {
        if (!std.meta.eql(a.meta, b.meta) or !Image.eql(a.live, b.live)) return false;
    }
    return true;
}
fn unitLess(a: Unit, b: Unit) bool {
    return a.record < b.record or (a.record == b.record and (a.sector orelse 0) < (b.sector orelse 0));
}
fn nextPermutation(items: []Unit) bool {
    if (items.len < 2) return false;
    var i = items.len - 1;
    while (i > 0 and !unitLess(items[i - 1], items[i])) i -= 1;
    if (i == 0) {
        std.mem.reverse(Unit, items);
        return false;
    }
    var j = items.len - 1;
    while (!unitLess(items[i - 1], items[j])) j -= 1;
    std.mem.swap(Unit, &items[i - 1], &items[j]);
    std.mem.reverse(Unit, items[i..]);
    return true;
}
pub fn crashStates(fs: *Model, limit: u32) error{OutOfMemory}!CrashStateIterator {
    var units: std.ArrayList(Unit) = .empty;
    errdefer units.deinit(fs.gpa);
    for (fs.root.pending.items, 0..) |r, i| if (!r.synced) {
        if (r.op.effect == .write) {
            const w = r.op.effect.write;
            const count = (w.offset + w.len - 1) / fs.options.sector - w.offset / fs.options.sector + 1;
            for (0..@intCast(count)) |s| try units.append(fs.gpa, .{ .record = i, .sector = s });
        } else try units.append(fs.gpa, .{ .record = i, .sector = null });
    };
    const indices = try fs.gpa.alloc(usize, units.items.len);
    errdefer fs.gpa.free(indices);
    const order = try fs.gpa.alloc(Unit, units.items.len);
    errdefer fs.gpa.free(order);
    const owned = try units.toOwnedSlice(fs.gpa);
    errdefer fs.gpa.free(owned);
    return .{ .fs = fs, .before = try fs.snapshot(), .units = owned, .indices = indices, .order = order, .limit = limit };
}
pub fn dump(fs: *const Model, w: *Io.Writer) Io.Writer.Error!void {
    for (fs.root.entries.items) |e| try w.print("{d}/{s} -> {d} {t} {d} bytes\n", .{ e.parent, e.name.bytes, e.inode, fs.root.nodes.items[e.inode].kind, fs.root.nodes.items[e.inode].live.size });
}
/// Advisory locks are on open descriptions, and conflict across hard links.
pub fn tryLock(fs: *Model, raw: Io.File.Handle, lock: Io.File.Lock) Error!bool {
    const h = try fs.handle(raw);
    for (fs.handles.items) |other| if (other.id != h.id and other.inode == h.inode and other.lock != .none and lock != .none) {
        if (lock == .exclusive or other.lock == .exclusive) return false;
    };
    h.lock = lock;
    return true;
}
/// A canonical path relative to the simulated root.
pub fn realPath(fs: *const Model, inode: u32, out: []u8) Error!usize {
    var chain: [256]u32 = undefined;
    var len: usize = 0;
    var id = inode;
    while (id != 0) {
        if (len == chain.len) return error.NameTooLong;
        chain[len] = id;
        len += 1;
        var found = false;
        for (fs.root.entries.items) |e| if (e.inode == id) {
            id = e.parent;
            found = true;
            break;
        };
        if (!found) return error.FileNotFound;
    }
    if (out.len == 0) return error.NameTooLong;
    out[0] = '/';
    var used_len: usize = 1;
    while (len > 0) {
        len -= 1;
        for (fs.root.entries.items) |e| if (e.inode == chain[len]) {
            if (used_len + e.name.bytes.len + @intFromBool(len > 0) > out.len) return error.NameTooLong;
            @memcpy(out[used_len..][0..e.name.bytes.len], e.name.bytes);
            used_len += e.name.bytes.len;
            if (len > 0) {
                out[used_len] = '/';
                used_len += 1;
            }
            break;
        };
    }
    return used_len;
}
