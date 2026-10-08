//! Immutable sparse file images. A radix tree shares both 4 KiB pages and
//! their index: a write copies only its path, even in a terabyte sparse file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @This();
pub const page_size = 4096;
const bits = 6;
const fanout = 1 << bits;
const Page = struct { refs: usize = 1, bytes: [page_size]u8 = @splat(0) };
const Branch = struct { refs: usize = 1, children: [fanout]Link = @splat(.empty) };
const Link = union(enum) {
    empty,
    page: *Page,
    branch: *Branch,
    fn retain(link: Link) Link {
        switch (link) {
            .empty => {},
            .page => |p| p.refs += 1,
            .branch => |b| b.refs += 1,
        }
        return link;
    }
    fn release(link: Link, gpa: Allocator) void {
        switch (link) {
            .empty => {},
            .page => |p| {
                p.refs -= 1;
                if (p.refs == 0) gpa.destroy(p);
            },
            .branch => |b| {
                b.refs -= 1;
                if (b.refs != 0) return;
                for (b.children) |child| child.release(gpa);
                gpa.destroy(b);
            },
        }
    }
};
refs: usize = 1,
size: u64,
root: Link = .empty,
depth: u4 = 0,

pub fn empty(gpa: Allocator) !*Image {
    const image = try gpa.create(Image);
    image.* = .{ .size = 0 };
    return image;
}
pub fn retain(image: *Image) *Image {
    image.refs += 1;
    return image;
}
pub fn release(image: *Image, gpa: Allocator) void {
    image.refs -= 1;
    if (image.refs != 0) return;
    image.root.release(gpa);
    gpa.destroy(image);
}
fn shift(depth: u4) u6 {
    return @intCast(@as(u8, depth) * bits);
}
fn pageAt(image: *const Image, index: u64) ?*Page {
    if (index >= (@as(u64, 1) << shift(image.depth))) return null;
    var link = image.root;
    var depth = image.depth;
    while (depth != 0) {
        if (link == .empty) return null;
        depth -= 1;
        link = link.branch.children[@intCast((index >> shift(depth)) & (fanout - 1))];
    }
    return switch (link) {
        .empty => null,
        .page => |p| p,
        .branch => unreachable,
    }; // unreachable: tree depth ends at pages
}
pub fn read(image: *const Image, offset: u64, out: []u8) usize {
    if (offset >= image.size) return 0;
    const n: usize = @intCast(@min(out.len, image.size - offset));
    var at: usize = 0;
    while (at < n) {
        const pos = offset + at;
        const within: usize = @intCast(pos % page_size);
        const take = @min(n - at, page_size - within);
        if (image.pageAt(pos / page_size)) |p| @memcpy(out[at..][0..take], p.bytes[within..][0..take]) else @memset(out[at..][0..take], 0);
        at += take;
    }
    return n;
}
fn uniqueBranch(gpa: Allocator, link: *Link) !*Branch {
    if (link.* == .branch and link.branch.refs == 1) return link.branch;
    const b = try gpa.create(Branch);
    b.* = .{};
    if (link.* == .branch) for (link.branch.children, 0..) |child, i| {
        b.children[i] = child.retain();
    };
    link.release(gpa);
    link.* = .{ .branch = b };
    return b;
}
fn uniquePage(gpa: Allocator, link: *Link) !*Page {
    if (link.* == .page and link.page.refs == 1) return link.page;
    const p = try gpa.create(Page);
    p.* = .{};
    if (link.* == .page) p.bytes = link.page.bytes;
    link.release(gpa);
    link.* = .{ .page = p };
    return p;
}
fn writablePage(image: *Image, gpa: Allocator, index: u64) !*Page {
    while (index >= (@as(u64, 1) << shift(image.depth))) {
        if (image.root == .empty) {
            image.depth += 1;
            continue;
        }
        const b = try gpa.create(Branch);
        b.* = .{};
        b.children[0] = image.root; // transfer this reference into the new root
        image.root = .{ .branch = b };
        image.depth += 1;
    }
    var link = &image.root;
    var depth = image.depth;
    while (depth != 0) {
        const b = try uniqueBranch(gpa, link);
        depth -= 1;
        link = &b.children[@intCast((index >> shift(depth)) & (fanout - 1))];
    }
    return uniquePage(gpa, link);
}
fn truncate(gpa: Allocator, link: *Link, depth: u4, base: u64, keep: u64) !void {
    if (link.* == .empty) return;
    if (base >= keep) {
        link.release(gpa);
        link.* = .empty;
        return;
    }
    const width = @as(u64, 1) << shift(depth);
    if (base + width <= keep or depth == 0) return;
    const b = try uniqueBranch(gpa, link);
    const child_width = width / fanout;
    for (&b.children, 0..) |*child, i| try truncate(gpa, child, depth - 1, base + i * child_width, keep);
}
/// Change length and overwrite a range. Unchanged branches and pages stay shared;
/// growing a hole allocates no pages. Truncation discards pages and zeroes its tail.
pub fn edit(image: *const Image, gpa: Allocator, size: u64, offset: u64, bytes: []const u8) !*Image {
    const next = try gpa.create(Image);
    next.* = .{ .size = size, .root = image.root.retain(), .depth = image.depth };
    errdefer next.release(gpa);
    if (size < image.size) {
        const keep = size / page_size + @intFromBool(size % page_size != 0);
        try truncate(gpa, &next.root, next.depth, 0, keep);
        while (next.depth != 0) {
            if (next.root == .empty) {
                next.depth = 0;
                break;
            }
            var only_zero = true;
            for (next.root.branch.children[1..]) |child| if (child != .empty) {
                only_zero = false;
                break;
            };
            if (!only_zero) break;
            const child = next.root.branch.children[0].retain();
            next.root.release(gpa);
            next.root = child;
            next.depth -= 1;
        }
        if (size % page_size != 0 and next.pageAt(size / page_size) != null) {
            const p = try next.writablePage(gpa, size / page_size);
            @memset(p.bytes[@intCast(size % page_size)..], 0);
        }
    }
    var at: usize = 0;
    const len: usize = @intCast(@min(bytes.len, size -| offset));
    while (at < len) {
        const pos = offset + at;
        const within: usize = @intCast(pos % page_size);
        const take = @min(len - at, page_size - within);
        const p = try next.writablePage(gpa, pos / page_size);
        @memcpy(p.bytes[within..][0..take], bytes[at..][0..take]);
        at += take;
    }
    return next;
}

/// Compare sparse images without walking their holes; shared subtrees compare once.
pub fn eql(a: *const Image, b: *const Image) bool {
    return a == b or (a.size == b.size and equalLinks(a.root, a.depth, b.root, b.depth));
}
fn zero(link: Link) bool {
    return switch (link) {
        .empty => true,
        .page => |p| std.mem.allEqual(u8, &p.bytes, 0),
        .branch => |b| blk: {
            for (b.children) |child| if (!zero(child)) break :blk false;
            break :blk true;
        },
    };
}
fn equalLinks(a: Link, ad: u4, b: Link, bd: u4) bool {
    if (a == .empty) return zero(b);
    if (b == .empty) return zero(a);
    if (ad > bd) {
        for (a.branch.children[1..]) |child| if (!zero(child)) return false;
        return equalLinks(a.branch.children[0], ad - 1, b, bd);
    }
    if (bd > ad) return equalLinks(b, bd, a, ad);
    if (ad == 0) return a.page == b.page or std.mem.eql(u8, &a.page.bytes, &b.page.bytes);
    if (a.branch == b.branch) return true;
    for (a.branch.children, b.branch.children) |ac, bc| if (!equalLinks(ac, ad - 1, bc, bd - 1)) return false;
    return true;
}
