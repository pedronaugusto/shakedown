//! Owned network state. No kernel sockets, task pointers, or wall clock.
const std = @import("std");
const Io = std.Io;
const Model = @This();
const Handle = Io.net.Socket.Handle;
const Address = Io.net.IpAddress;
pub const Dist = union(enum) {
    fixed: Io.Duration,
    uniform: struct { min: Io.Duration, max: Io.Duration },
    exponential: struct { mean: Io.Duration },
};
pub const Link = struct {
    latency: Dist = .{ .fixed = .fromMicroseconds(100) },
    loss_per_million: u32 = 0,
    duplicate_per_million: u32 = 0,
    reorder_per_million: u32 = 0,
    bandwidth: ?u64 = null,
    buffer: u32 = 256 * 1024,
};
pub const Options = struct { default_link: Link = .{}, max_packets: u32 = 1024 };
pub const Error = error{ OutOfMemory, SystemResources, AddressInUse, AddressUnavailable, ConnectionRefused, ConnectionResetByPeer, ConnectionTimedOut, SocketUnconnected, MessageOversize, UnsupportedSocketMode, InvalidLink, AccessDenied };
const State = struct { value: Link, held: bool = false, partitioned: bool = false, available: i64 = 0 };
pub const Socket = struct {
    handle: Handle,
    node: u32,
    address: Address,
    kind: enum { stream, listener, datagram },
    peer: ?Handle = null,
    listener: ?Handle = null,
    local: bool = false,
    connected: bool = true,
    accepted: bool = false,
    backlog: u31 = 128,
    path: []u8 = &.{},
    bytes: []u8 = &.{},
    head: usize = 0,
    len: usize = 0,
    reserved: usize = 0,
    last_delivery: i64 = 0,
    send_closed: bool = false,
    receive_closed: bool = false,
    reset: bool = false,
    timed_out: bool = false,
    allow_broadcast: bool = false,
    datagrams: std.ArrayList(*Packet) = .empty,
};
const Packet = struct {
    from: Handle,
    to: Handle,
    source: Address,
    a: u32,
    b: u32,
    kind: enum { stream, datagram, handshake },
    at: i64,
    born: i64,
    delivery: i64,
    blocked: bool = false,
    seq: u64,
    len: usize = 0,
    data: [65536]u8 = undefined,
};
fn order(_: void, a: *Packet, b: *Packet) std.math.Order {
    if (a.blocked != b.blocked) return if (a.blocked) .gt else .lt;
    return if (a.at == b.at) std.math.order(a.seq, b.seq) else std.math.order(a.at, b.at);
}
names: std.StringHashMapUnmanaged(u32) = .empty,
gpa: std.mem.Allocator,
options: Options,
now: i64 = 0,
change: u32 = 0,
next_handle: u32 = 10000,
next_port: u16 = 49152,
sequence: u64 = 0,
node_count: u32 = 0,
addresses: std.ArrayList(struct { node: u32, address: Address }) = .empty,
links: std.AutoHashMapUnmanaged(u64, State) = .empty,
sockets: std.AutoHashMapUnmanaged(Handle, *Socket) = .empty,
owned: std.ArrayList(*Socket) = .empty,
idle: std.ArrayList(*Socket) = .empty,
packets: std.ArrayList(*Packet) = .empty,
free_packets: std.ArrayList(*Packet) = .empty,
queue: std.PriorityQueue(*Packet, void, order),
drawn_by: ?*anyopaque = null,
draw_fn: ?*const fn (*anyopaque, u64) u64 = null,

pub fn init(gpa: std.mem.Allocator, options: Options) Model {
    return .{ .gpa = gpa, .options = options, .queue = .initContext({}) };
}
pub fn deinit(m: *Model) void {
    for (m.owned.items) |s| {
        m.gpa.free(s.path);
        m.gpa.free(s.bytes);
        s.datagrams.deinit(m.gpa);
        m.gpa.destroy(s);
    }
    for (m.packets.items) |p| m.gpa.destroy(p);
    var names = m.names.keyIterator();
    while (names.next()) |name| m.gpa.free(name.*);
    m.names.deinit(m.gpa);
    m.queue.deinit(m.gpa);
    m.free_packets.deinit(m.gpa);
    m.packets.deinit(m.gpa);
    m.sockets.deinit(m.gpa);
    m.owned.deinit(m.gpa);
    m.idle.deinit(m.gpa);
    m.links.deinit(m.gpa);
    m.addresses.deinit(m.gpa);
    m.* = undefined;
}
fn key(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}
pub fn addNode(m: *Model, addresses: []const Address) error{OutOfMemory}!u32 {
    const id = m.node_count;
    try m.links.ensureUnusedCapacity(m.gpa, 2 * id + 1);
    try m.addresses.ensureUnusedCapacity(m.gpa, @max(1, addresses.len));
    for (0..id + 1) |other| {
        m.links.putAssumeCapacity(key(id, @intCast(other)), .{ .value = m.options.default_link });
        if (other != id) m.links.putAssumeCapacity(key(@intCast(other), id), .{ .value = m.options.default_link });
    }
    if (addresses.len == 0) {
        m.addresses.appendAssumeCapacity(.{ .node = id, .address = .{ .ip4 = .{ .bytes = .{ 10, @truncate(id >> 16), @truncate(id >> 8), @truncate(id + 1) }, .port = 0 } } });
    } else for (addresses) |addr| m.addresses.appendAssumeCapacity(.{ .node = id, .address = addr });
    m.node_count += 1;
    return id;
}
pub fn address(m: *Model, node: u32) Address {
    for (m.addresses.items) |item| if (item.node == node) return item.address;
    unreachable; // node IDs are made only by addNode
}
fn sameIp(a: Address, b: Address) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .ip4 => |v| std.mem.eql(u8, &v.bytes, &b.ip4.bytes),
        .ip6 => |v| std.mem.eql(u8, &v.bytes, &b.ip6.bytes),
    };
}
fn wildcard(a: Address) bool {
    return switch (a) {
        .ip4 => |v| std.mem.allEqual(u8, &v.bytes, 0),
        .ip6 => |v| std.mem.allEqual(u8, &v.bytes, 0),
    };
}
fn route(m: *Model, caller: u32, address_: Address) ?u32 {
    if (sameIp(address_, .{ .ip4 = .loopback(0) }) or sameIp(address_, .{ .ip6 = .loopback(0) })) return caller;
    for (m.addresses.items) |a| if (sameIp(a.address, address_)) return a.node;
    return null;
}
pub fn validate(value: Link) error{InvalidLink}!void {
    if (value.loss_per_million > 1000000 or value.duplicate_per_million > 1000000 or value.reorder_per_million > 1000000 or value.buffer == 0 or value.bandwidth == 0) return error.InvalidLink;
    switch (value.latency) {
        .fixed => |d| if (d.nanoseconds < 0) return error.InvalidLink,
        .uniform => |d| if (d.min.nanoseconds < 0 or d.max.nanoseconds < d.min.nanoseconds) return error.InvalidLink,
        .exponential => |d| if (d.mean.nanoseconds < 0) return error.InvalidLink,
    }
}
pub fn configure(m: *Model, a: u32, b: u32, value: Link) Error!void {
    try validate(value);
    m.links.getPtr(key(a, b)).?.value = value;
    m.links.getPtr(key(b, a)).?.value = value;
}
pub fn status(m: *Model, a: u32, b: u32, held: ?bool, partitioned: ?bool) void {
    for ([_]u64{ key(a, b), key(b, a) }) |k| {
        const s = m.links.getPtr(k).?;
        if (held) |v| s.held = v;
        if (partitioned) |v| s.partitioned = v;
    }
    // Rebuild event priorities after a link changes. This allocates no memory.
    const count = m.queue.items.len;
    for (m.queue.items[0..count]) |p| m.adjust(p);
    std.mem.sort(*Packet, m.queue.items[0..count], {}, struct {
        fn less(_: void, left: *Packet, right: *Packet) bool {
            return order({}, left, right) == .lt;
        }
    }.less);
    m.change +%= 1;
}
fn adjust(m: *Model, p: *Packet) void {
    if (m.sockets.get(p.to)) |s| if (s.local) return;
    const state = m.links.getPtr(key(p.a, p.b)).?;
    p.blocked = state.held and !state.partitioned;
    p.at = if (state.partitioned) p.born +| 60000000000 else if (state.held) std.math.maxInt(i64) else @max(m.now, p.delivery);
}
fn draw(m: *Model, max: u64) u64 {
    return m.draw_fn.?(m.drawn_by.?, max);
}
fn chance(m: *Model, ppm: u32) bool {
    return ppm != 0 and (ppm == 1000000 or m.draw(999999) < ppm);
}
fn duration(d: Io.Duration) i64 {
    return std.math.lossyCast(i64, d.nanoseconds);
}
fn latency(m: *Model, d: Dist) i64 {
    return switch (d) {
        .fixed => |v| duration(v),
        .uniform => |v| duration(v.min) +| @as(i64, @intCast(m.draw(@intCast(duration(v.max) - duration(v.min))))),
        .exponential => |v| blk: {
            // Fixed-point inverse CDF: ln(x) via atanh on [1, 2), Q32.
            const x = m.draw(std.math.maxInt(u32) - 1) + 1;
            const shift: u6 = @intCast(@clz(@as(u32, @intCast(x))));
            const normalized = x << shift;
            const y: u128 = ((normalized - (1 << 31)) << 32) / (normalized + (1 << 31));
            const square = (y * y) >> 32;
            var term = y;
            var sum: u128 = 0;
            for (0..16) |i| {
                sum += term / (2 * i + 1);
                term = (term * square) >> 32;
            }
            const log: u128 = (@as(u128, shift) + 1) * 2977044472 - 2 * sum;
            break :blk std.math.lossyCast(i64, (@as(u128, @intCast(@max(0, duration(v.mean)))) * log) >> 32);
        },
    };
}
fn packet(m: *Model) Error!*Packet {
    if (m.free_packets.pop()) |p| return p;
    if (m.packets.items.len >= m.options.max_packets) return error.SystemResources;
    try m.queue.ensureTotalCapacity(m.gpa, m.options.max_packets);
    try m.packets.ensureUnusedCapacity(m.gpa, 1);
    try m.free_packets.ensureTotalCapacity(m.gpa, m.options.max_packets);
    const p = try m.gpa.create(Packet);
    m.packets.appendAssumeCapacity(p);
    return p;
}
fn recycle(m: *Model, p: *Packet) void {
    m.free_packets.appendAssumeCapacity(p);
}
fn handleFromId(id: u32) Handle {
    return switch (@typeInfo(Handle)) {
        .pointer => @ptrFromInt(id), // safe: virtual opaque handles are identifiers, never dereferenced
        .int => @intCast(id),
        else => @compileError("unsupported Io socket handle representation"),
    };
}
fn handleId(handle: Handle) u64 {
    return switch (@typeInfo(Handle)) {
        .pointer => @intFromPtr(handle), // safe: recover a virtual identifier, not a memory address
        .int => @intCast(handle),
        else => @compileError("unsupported Io socket handle representation"),
    };
}
fn socket(m: *Model, node: u32, kind: @FieldType(Socket, "kind"), address_: Address, capacity: usize) Error!*Socket {
    const limit = switch (@typeInfo(Handle)) {
        .pointer => std.math.maxInt(u32),
        .int => @min(std.math.maxInt(u32), std.math.maxInt(Handle)),
        else => @compileError("unsupported Io socket handle representation"),
    };
    if (m.next_handle >= limit) return error.SystemResources;
    try m.sockets.ensureUnusedCapacity(m.gpa, 1);
    try m.idle.ensureTotalCapacity(m.gpa, m.owned.items.len + 1);
    const s = if (m.idle.pop()) |old| old else blk: {
        try m.owned.ensureUnusedCapacity(m.gpa, 1);
        const fresh = try m.gpa.create(Socket);
        fresh.* = .{ .handle = undefined, .node = node, .kind = kind, .address = address_ };
        m.owned.appendAssumeCapacity(fresh);
        break :blk fresh;
    };
    errdefer m.idle.appendAssumeCapacity(s);
    if (s.bytes.len < capacity) {
        const bytes = try m.gpa.alloc(u8, capacity);
        m.gpa.free(s.bytes);
        s.bytes = bytes;
    }
    try s.datagrams.ensureTotalCapacity(m.gpa, m.options.max_packets);
    m.gpa.free(s.path);
    s.* = .{ .handle = handleFromId(m.next_handle), .node = node, .kind = kind, .address = address_, .bytes = s.bytes, .datagrams = s.datagrams };
    s.datagrams.clearRetainingCapacity();
    m.next_handle += 1;
    m.sockets.putAssumeCapacity(s.handle, s);
    return s;
}
pub fn get(m: *Model, handle: Handle, node: u32) Error!*Socket {
    const s = m.sockets.get(handle) orelse return error.SocketUnconnected;
    if (s.node != node) return error.SocketUnconnected;
    if (s.timed_out) return error.ConnectionTimedOut;
    if (s.reset) return error.ConnectionResetByPeer;
    return s;
}
pub fn bind(m: *Model, node: u32, requested: Address, kind: @FieldType(Socket, "kind")) Error!*Socket {
    var addr = requested;
    if (!wildcard(addr) and m.route(node, addr) != node) return error.AddressUnavailable;
    if (addr.getPort() == 0) {
        var attempts: u32 = 0;
        while (attempts < 16384) : (attempts += 1) {
            addr.setPort(m.next_port);
            m.next_port = if (m.next_port == 65535) 49152 else m.next_port + 1;
            if (m.bound(node, addr, kind) == null) break;
        }
        if (attempts == 16384) return error.SystemResources;
    } else if (m.bound(node, addr, kind) != null) return error.AddressInUse;
    return m.socket(node, kind, addr, if (kind == .stream) m.options.default_link.buffer else 0);
}
fn bound(m: *Model, node: u32, addr: Address, kind: @FieldType(Socket, "kind")) ?*Socket {
    var it = m.sockets.valueIterator();
    while (it.next()) |item| {
        const s = item.*;
        if (s.node == node and s.kind == kind and std.meta.activeTag(s.address) == std.meta.activeTag(addr) and s.address.getPort() == addr.getPort() and (wildcard(s.address) or wildcard(addr) or sameIp(s.address, addr))) return s;
    }
    return null;
}
pub fn pair(m: *Model, a: u32, b: u32, local: bool) Error![2]*Socket {
    const capacity = m.links.getPtr(key(a, b)).?.value.buffer;
    const left = try m.socket(a, .stream, m.address(a), capacity);
    errdefer m.close(left.handle);
    const right = try m.socket(b, .stream, m.address(b), capacity);
    left.peer = right.handle;
    right.peer = left.handle;
    left.local = local;
    right.local = local;
    return .{ left, right };
}
pub fn connect(m: *Model, node: u32, addr: Address) Error!*Socket {
    const destination = m.route(node, addr) orelse return error.ConnectionRefused;
    const listener = m.bound(destination, addr, .listener) orelse return error.ConnectionRefused;
    return m.connectListener(node, listener, false);
}
pub fn connectListener(m: *Model, node: u32, listener: *Socket, local: bool) Error!*Socket {
    var count: usize = 0;
    var it = m.sockets.valueIterator();
    while (it.next()) |s| if (s.*.listener == listener.handle and !s.*.accepted) {
        count += 1;
    };
    if (count >= listener.backlog) return error.ConnectionRefused;
    const endpoints = try m.pair(node, listener.node, local);
    errdefer {
        m.close(endpoints[0].handle);
        m.close(endpoints[1].handle);
    }
    endpoints[0].address.setPort(m.next_port);
    m.next_port = if (m.next_port == 65535) 49152 else m.next_port + 1;
    endpoints[1].address = listener.address;
    endpoints[0].connected = false;
    endpoints[1].connected = false;
    endpoints[1].listener = listener.handle;
    const p = try m.packet();
    m.sequence += 1;
    const l = m.links.getPtr(key(node, listener.node)).?.value;
    var delay: i64 = if (local) 0 else m.latency(l.latency) +| m.latency(l.latency);
    if (!local) delay +|= m.retransmit(l);
    p.* = .{ .from = endpoints[0].handle, .to = endpoints[1].handle, .source = endpoints[0].address, .a = node, .b = listener.node, .kind = .handshake, .at = m.now +| delay, .born = m.now, .delivery = m.now +| delay, .seq = m.sequence };
    if (!local and (m.links.getPtr(key(node, listener.node)).?.held or m.links.getPtr(key(node, listener.node)).?.partitioned)) m.adjust(p);
    m.queue.push(m.gpa, p) catch unreachable; // unreachable: packet reserves queue capacity
    m.change +%= 1;
    return endpoints[0];
}
pub fn accept(m: *Model, listener: *Socket) ?*Socket {
    var first: ?*Socket = null;
    var it = m.sockets.valueIterator();
    while (it.next()) |item| {
        const s = item.*;
        if (s.listener == listener.handle and s.connected and !s.accepted and !s.reset and (first == null or handleId(s.handle) < handleId(first.?.handle))) first = s;
    }
    if (first) |s| s.accepted = true;
    return first;
}
fn retransmit(m: *Model, l: Link) i64 {
    var delay: i64 = 0;
    var retry: u6 = 0;
    while (m.chance(l.loss_per_million)) : (retry += 1) {
        delay +|= @as(i64, 200000000) << retry;
        if (delay >= 60000000000) return 60000000000;
    }
    return delay;
}
fn enqueue(m: *Model, sender: *Socket, receiver: *Socket, bytes: []const u8, kind: @FieldType(Packet, "kind")) Error!void {
    const p = try m.packet();
    const state = m.links.getPtr(key(sender.node, receiver.node)).?;
    m.sequence += 1;
    var at = m.now;
    if (!sender.local) {
        if (state.value.bandwidth) |rate| {
            const service = std.math.lossyCast(i64, (@as(u128, bytes.len) * 1000000000 + rate - 1) / rate);
            state.available = @max(state.available, m.now) +| service;
            at = state.available;
        }
        at +|= m.latency(state.value.latency);
        if (kind == .stream) at +|= m.retransmit(state.value) else if (m.chance(state.value.reorder_per_million)) at +|= m.latency(state.value.latency);
    }
    if (kind == .stream) {
        at = @max(at, receiver.last_delivery);
        receiver.last_delivery = at;
        receiver.reserved += bytes.len;
    }
    p.* = .{ .from = sender.handle, .to = receiver.handle, .source = blk: {
        var source = if (wildcard(sender.address)) m.address(sender.node) else sender.address;
        source.setPort(sender.address.getPort());
        break :blk source;
    }, .a = sender.node, .b = receiver.node, .kind = kind, .at = at, .born = m.now, .delivery = at, .seq = m.sequence, .len = bytes.len };
    @memcpy(p.data[0..bytes.len], bytes);
    if (!sender.local and (state.held or state.partitioned)) m.adjust(p);
    m.queue.push(m.gpa, p) catch unreachable; // unreachable: packet reserves queue capacity
}
pub fn write(m: *Model, s: *Socket, bytes: []const u8) Error!?usize {
    if (s.kind != .stream or s.send_closed) return error.SocketUnconnected;
    const receiver = m.sockets.get(s.peer orelse return error.SocketUnconnected) orelse return error.ConnectionResetByPeer;
    if (receiver.reset) return error.ConnectionResetByPeer;
    if (receiver.receive_closed) return error.SocketUnconnected;
    const capacity = @min(receiver.bytes.len, m.links.getPtr(key(s.node, receiver.node)).?.value.buffer);
    const available = capacity -| (receiver.len + receiver.reserved);
    if (available == 0 and bytes.len != 0) return null;
    const n = @min(@min(bytes.len, available), 65536);
    if (n != 0) try m.enqueue(s, receiver, bytes[0..n], .stream);
    return n;
}
pub fn read(m: *Model, s: *Socket, out: []u8) Error!?usize {
    if (s.kind != .stream) return error.SocketUnconnected;
    if (s.len == 0) {
        if (out.len == 0 or s.receive_closed) return 0;
        const peer = m.sockets.get(s.peer orelse return error.SocketUnconnected) orelse return error.ConnectionResetByPeer;
        if (peer.send_closed and s.reserved == 0) return 0;
        return null;
    }
    const n = @min(s.len, out.len);
    const first = @min(n, s.bytes.len - s.head);
    @memcpy(out[0..first], s.bytes[s.head..][0..first]);
    @memcpy(out[first..n], s.bytes[0 .. n - first]);
    s.head = (s.head + n) % s.bytes.len;
    s.len -= n;
    if (n != 0) m.change +%= 1;
    return n;
}
pub fn send(m: *Model, s: *Socket, addr: Address, bytes: []const u8) Error!void {
    if (s.kind != .datagram or s.send_closed) return error.SocketUnconnected;
    if (bytes.len > 65535) return error.MessageOversize;
    if (addr == .ip4 and std.mem.allEqual(u8, &addr.ip4.bytes, 255)) {
        if (!s.allow_broadcast) return error.AccessDenied;
        // Allocation order is stable across OS handle widths; hash-table order is not.
        for (m.owned.items) |receiver| {
            if (m.sockets.get(receiver.handle) != receiver or receiver.kind != .datagram or receiver.address != .ip4 or receiver.address.getPort() != addr.getPort()) continue;
            try m.sendTo(s, receiver, bytes);
        }
        return;
    }
    const destination = m.route(s.node, addr) orelse return; // UDP has no delivery guarantee
    const receiver = m.bound(destination, addr, .datagram) orelse return;
    try m.sendTo(s, receiver, bytes);
}
fn sendTo(m: *Model, sender: *Socket, receiver: *Socket, bytes: []const u8) Error!void {
    const l = m.links.getPtr(key(sender.node, receiver.node)).?.value;
    if (m.chance(l.loss_per_million)) return;
    try m.enqueue(sender, receiver, bytes, .datagram);
    if (m.chance(l.duplicate_per_million)) m.enqueue(sender, receiver, bytes, .datagram) catch return; // A bounded receive queue may drop a duplicate.
}
pub const Received = struct { address: Address, len: usize, truncated: bool };
pub fn receive(m: *Model, s: *Socket, out: []u8, peek: bool) ?Received {
    if (s.datagrams.items.len == 0) return null;
    const p = s.datagrams.items[0];
    const n = @min(out.len, p.len);
    @memcpy(out[0..n], p.data[0..n]);
    const result: Received = .{ .address = p.source, .len = n, .truncated = n != p.len };
    if (!peek) {
        _ = s.datagrams.orderedRemove(0);
        m.recycle(p);
        m.change +%= 1;
    }
    return result;
}
pub fn close(m: *Model, handle: Handle) void {
    const s = m.sockets.fetchRemove(handle) orelse return;
    var index: usize = 0;
    while (index < m.queue.items.len) {
        const p = m.queue.items[index];
        if (p.to == handle or (p.from == handle and p.kind != .datagram)) {
            _ = m.queue.popIndex(index);
            if (p.kind == .stream) if (m.sockets.get(p.to)) |receiver| {
                receiver.reserved -|= p.len;
            };
            m.recycle(p);
        } else index += 1;
    }
    if (s.value.kind == .listener) {
        while (true) {
            var child: ?Handle = null;
            var children = m.sockets.valueIterator();
            while (children.next()) |item| if (item.*.listener == handle and !item.*.accepted) {
                child = item.*.handle;
                break;
            };
            m.close(child orelse break);
        }
    }
    if (s.value.peer) |peer| if (m.sockets.get(peer)) |other| {
        other.reset = true;
    };
    for (s.value.datagrams.items) |p| m.recycle(p);
    s.value.datagrams.clearRetainingCapacity();
    m.idle.appendAssumeCapacity(s.value);
    m.change +%= 1;
}
pub fn reset(m: *Model, a: u32, b: u32) void {
    var it = m.sockets.valueIterator();
    while (it.next()) |s| if (s.*.kind == .stream) {
        if (m.sockets.get(s.*.peer orelse continue)) |p| if ((s.*.node == a and p.node == b) or (s.*.node == b and p.node == a)) {
            s.*.reset = true;
        };
    };
    m.change +%= 1;
}
pub fn kill(m: *Model, node: u32) void {
    while (true) {
        var found: ?Handle = null;
        var it = m.sockets.valueIterator();
        while (it.next()) |s| if (s.*.node == node) {
            found = s.*.handle;
            break;
        };
        m.close(found orelse break);
    }
}
pub fn nextDeadline(m: *Model) ?i64 {
    const p = m.queue.peek() orelse return null;
    return if (p.blocked) null else p.at;
}
pub fn pump(m: *Model) void {
    while (m.queue.peek()) |p| {
        if (p.at > m.now) break;
        _ = m.queue.pop();
        const s = m.sockets.get(p.to) orelse {
            m.recycle(p);
            continue;
        };
        const state = m.links.getPtr(key(p.a, p.b)).?;
        if (!s.local and (state.partitioned or p.at -| p.born >= 60000000000)) {
            if (p.kind != .datagram) {
                s.timed_out = true;
                if (m.sockets.get(p.from)) |sender| sender.timed_out = true;
            }
            s.reserved -|= p.len;
            m.recycle(p);
        } else if (s.reset) {
            s.reserved -|= p.len;
            m.recycle(p);
        } else switch (p.kind) {
            .handshake => {
                if (m.sockets.get(p.from)) |sender| {
                    s.connected = true;
                    sender.connected = true;
                } else s.reset = true;
                m.recycle(p);
            },
            .stream => {
                const tail = (s.head + s.len) % s.bytes.len;
                const first = @min(p.len, s.bytes.len - tail);
                @memcpy(s.bytes[tail..][0..first], p.data[0..first]);
                @memcpy(s.bytes[0 .. p.len - first], p.data[first..p.len]);
                s.len += p.len;
                s.reserved -= p.len;
                m.recycle(p);
            },
            .datagram => if (s.datagrams.items.len < m.options.max_packets) s.datagrams.appendAssumeCapacity(p) else m.recycle(p),
        }
        m.change +%= 1;
    }
}
