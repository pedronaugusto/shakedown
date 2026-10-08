//! Shared tree versions, metadata and persistence records.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const Image = @import("Image.zig");
pub const Name = struct {
    refs: usize = 1,
    bytes: []u8,
    pub fn create(gpa: Allocator, bytes: []const u8) !*Name {
        const n = try gpa.create(Name);
        errdefer gpa.destroy(n);
        n.* = .{ .bytes = try gpa.dupe(u8, bytes) };
        return n;
    }
    pub fn retain(n: *Name) *Name {
        n.refs += 1;
        return n;
    }
    pub fn release(n: *Name, gpa: Allocator) void {
        n.refs -= 1;
        if (n.refs == 0) {
            gpa.free(n.bytes);
            gpa.destroy(n);
        }
    }
};
pub const Meta = struct {
    permissions: Io.File.Permissions,
    atime: Io.Timestamp,
    mtime: Io.Timestamp,
    ctime: Io.Timestamp,
    uid: ?Io.File.Uid = null,
    gid: ?Io.File.Gid = null,
};
pub const Node = struct {
    kind: Io.File.Kind,
    live: *Image,
    disk: *Image,
    meta: Meta,
    disk_meta: Meta,
    target: ?*Name = null,
    bad_start: u64 = 0,
    bad_len: u32 = 0,
    misdirect: ?u64 = null,
    pub fn retain(n: Node) Node {
        _ = n.live.retain();
        _ = n.disk.retain();
        if (n.target) |t| _ = t.retain();
        return n;
    }
    pub fn release(n: Node, gpa: Allocator) void {
        n.live.release(gpa);
        n.disk.release(gpa);
        if (n.target) |t| t.release(gpa);
    }
};
pub const Entry = struct {
    parent: u32,
    name: *Name,
    inode: u32,
    pub fn retain(e: Entry) Entry {
        _ = e.name.retain();
        return e;
    }
};
pub const Change = struct { parent: u32, name: *Name, inode: ?u32 };
pub const Effect = union(enum) {
    write: struct { inode: u32, offset: u64, len: u64, image: *Image },
    length: struct { inode: u32, image: *Image },
    metadata: struct { inode: u32, meta: Meta },
    entries: struct { changes: [2]Change, len: u2, data_inode: ?u32 },
};
pub const Op = struct {
    refs: usize = 1,
    serial: u64,
    before: u64,
    effect: Effect,
    pub fn retain(op: *Op) *Op {
        op.refs += 1;
        return op;
    }
    pub fn release(op: *Op, gpa: Allocator) void {
        op.refs -= 1;
        if (op.refs != 0) return;
        switch (op.effect) {
            .write => |w| w.image.release(gpa),
            .length => |l| l.image.release(gpa),
            .entries => |e| for (e.changes[0..e.len]) |c| c.name.release(gpa),
            .metadata => {},
        }
        gpa.destroy(op);
    }
};
pub const Record = struct { op: *Op, synced: bool = false, written: bool = false, ordered: bool = false };
pub const State = struct {
    refs: usize = 1,
    nodes: std.ArrayList(Node) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    disk_entries: std.ArrayList(Entry) = .empty,
    pending: std.ArrayList(Record) = .empty,
    serial: u64 = 0,
    barrier: u64 = 0,
    pub fn release(s: *State, gpa: Allocator) void {
        s.refs -= 1;
        if (s.refs != 0) return;
        for (s.nodes.items) |n| n.release(gpa);
        for (s.entries.items) |e| e.name.release(gpa);
        for (s.disk_entries.items) |e| e.name.release(gpa);
        for (s.pending.items) |r| r.op.release(gpa);
        s.nodes.deinit(gpa);
        s.entries.deinit(gpa);
        s.disk_entries.deinit(gpa);
        s.pending.deinit(gpa);
        gpa.destroy(s);
    }
    pub fn clone(s: *State, gpa: Allocator) !*State {
        const next = try gpa.create(State);
        next.* = .{ .serial = s.serial, .barrier = s.barrier };
        errdefer next.release(gpa);
        try next.nodes.ensureTotalCapacity(gpa, s.nodes.items.len);
        for (s.nodes.items) |n| next.nodes.appendAssumeCapacity(n.retain());
        try next.entries.ensureTotalCapacity(gpa, s.entries.items.len);
        for (s.entries.items) |e| next.entries.appendAssumeCapacity(e.retain());
        try next.disk_entries.ensureTotalCapacity(gpa, s.disk_entries.items.len);
        for (s.disk_entries.items) |e| next.disk_entries.appendAssumeCapacity(e.retain());
        try next.pending.ensureTotalCapacity(gpa, s.pending.items.len);
        for (s.pending.items) |r| {
            _ = r.op.retain();
            next.pending.appendAssumeCapacity(r);
        }
        return next;
    }
};
