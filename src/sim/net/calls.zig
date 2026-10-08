//! Network Io slots: model readiness and scheduler waits share one cancel path.
const std = @import("std");
const Io = std.Io;
const Core = @import("../Core.zig");
const Model = @import("Model.zig");
const IoCall = @import("../../io_call.zig").IoCall;
const io_call = @import("../../io_call.zig");
pub fn supports(comptime name: []const u8) bool {
    return @hasDecl(slots, name);
}
fn Return(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?;
}
fn mapped(comptime E: type, err: anyerror) E {
    inline for (@typeInfo(E).error_set.error_names.?) |name| if (err == @field(anyerror, name)) return @field(E, name);
    if (err == error.OutOfMemory) {
        inline for (@typeInfo(E).error_set.error_names.?) |name| if (comptime std.mem.eql(u8, name, "SystemResources")) return error.SystemResources;
    }
    if (err == error.ConnectionTimedOut) {
        inline for (@typeInfo(E).error_set.error_names.?) |name| if (comptime std.mem.eql(u8, name, "Timeout")) return error.Timeout;
    }
    return error.Unexpected;
}
fn begin(c: *Core) *Model {
    c.notifyNetwork();
    return &c.network;
}
pub fn wait(c: *Core, task: ?*Core.Task, deadline: Core.Deadline) error{ Canceled, Timeout }!void {
    const t = task orelse @panic("shakedown: network wait outside Sim.run");
    if (Core.cancelPoint(t)) return error.Canceled;
    switch (deadline) {
        .due => return error.Timeout,
        .never => {},
        .at => |d| {
            if (c.clocks[@backingInt(d.clock)] >= d.ns) return error.Timeout;
            c.arm(t, d.clock, d.ns);
        },
    }
    c.link(t, @intFromPtr(&c.network.change)); // safe: the network epoch has a stable address until Core.deinit
    switch (c.block(t, .{ .futex = @intFromPtr(&c.network.change) }, true)) { // safe: the network epoch has a stable address until Core.deinit
        .canceled => return error.Canceled,
        .timeout => return error.Timeout,
        else => {},
    }
}
fn socketResult(s: *Model.Socket, address: Io.net.IpAddress) Io.net.Socket {
    return .{ .handle = s.handle, .address = address };
}
const slots = struct {
    pub fn netInterfaceNameResolve(_: *Core, _: u32, _: *const Io.net.Interface.Name) !Io.net.Interface {
        return error.InterfaceNotFound;
    }
    pub fn netInterfaceName(_: *Core, _: u32, _: Io.net.Interface) !Io.net.Interface.Name {
        return error.InterfaceNotFound;
    }

    pub fn netListenIp(c: *Core, node: u32, addr: *const Io.net.IpAddress, o: Io.net.IpAddress.ListenOptions) !Io.net.Socket {
        if (o.mode != .stream) return error.SocketModeUnsupported;
        if (o.protocol != .tcp) return error.ProtocolUnsupportedBySystem;
        const s = try begin(c).bind(node, addr.*, .listener);
        s.backlog = o.kernel_backlog;
        return socketResult(s, s.address);
    }
    pub fn netBindIp(c: *Core, node: u32, addr: *const Io.net.IpAddress, o: Io.net.IpAddress.BindOptions) !Io.net.Socket {
        if (o.mode != .dgram) return error.SocketModeUnsupported;
        if (o.ip6_only == false) return error.OptionUnsupported;
        if (o.protocol) |protocol| if (protocol != .udp) return error.ProtocolUnsupportedBySystem;
        const s = try begin(c).bind(node, addr.*, .datagram);
        s.allow_broadcast = o.allow_broadcast;
        return socketResult(s, s.address);
    }
    pub fn netConnectIp(c: *Core, node: u32, addr: *const Io.net.IpAddress, o: Io.net.IpAddress.ConnectOptions) !Io.net.Socket {
        if (o.mode != .stream) return error.SocketModeUnsupported;
        if (o.protocol) |protocol| if (protocol != .tcp) return error.ProtocolUnsupportedBySystem;
        const m = begin(c);
        const s = try m.connect(node, addr.*);
        const handle = s.handle;
        errdefer {
            if (m.sockets.get(handle)) |left| {
                const peer = left.peer;
                m.close(handle);
                if (peer) |p| m.close(p);
            }
        }
        const deadline = c.deadline(o.timeout);
        while (true) {
            c.notifyNetwork();
            const live = try m.get(handle, node);
            if (live.connected) return socketResult(live, addr.*);
            try wait(c, c.current, deadline);
        }
    }
    pub fn netAccept(c: *Core, node: u32, handle: Io.net.Socket.Handle, _: Io.net.Server.AcceptOptions) !Io.net.Socket {
        const m = begin(c);
        while (true) {
            const s = try m.get(handle, node);
            if (s.kind != .listener) return error.SocketUnconnected;
            if (m.accept(s)) |accepted| {
                const peer = m.sockets.get(accepted.peer.?) orelse return error.ConnectionResetByPeer;
                return socketResult(accepted, peer.address);
            }
            try wait(c, c.current, .never);
        }
    }
    pub fn netSocketCreatePair(c: *Core, node: u32, o: Io.net.Socket.CreatePairOptions) ![2]Io.net.Socket {
        if (o.mode != .stream) return error.SocketModeUnsupported;
        const pair = try begin(c).pair(node, node, true);
        if (o.family == .ip6) {
            pair[0].address = .{ .ip6 = .loopback(0) };
            pair[1].address = .{ .ip6 = .loopback(0) };
        }
        return .{ socketResult(pair[0], pair[0].address), socketResult(pair[1], pair[1].address) };
    }
    pub fn netListenUnix(c: *Core, node: u32, addr: *const Io.net.UnixAddress, o: Io.net.UnixAddress.ListenOptions) !Io.net.Socket.Handle {
        const m = begin(c);
        var it = m.sockets.valueIterator();
        while (it.next()) |s| if (s.*.node == node and std.mem.eql(u8, s.*.path, addr.path)) return error.AddressInUse;
        const path = try c.gpa.dupe(u8, addr.path);
        errdefer c.gpa.free(path);
        const s = try m.bind(node, .{ .ip4 = .loopback(0) }, .listener);
        s.path = path;
        s.backlog = o.kernel_backlog;
        return s.handle;
    }
    pub fn netConnectUnix(c: *Core, node: u32, addr: *const Io.net.UnixAddress) !Io.net.Socket.Handle {
        const m = begin(c);
        var found: ?*Model.Socket = null;
        var it = m.sockets.valueIterator();
        while (it.next()) |s| if (s.*.node == node and s.*.kind == .listener and std.mem.eql(u8, s.*.path, addr.path)) {
            found = s.*;
            break;
        };
        const s = try m.connectListener(node, found orelse return error.FileNotFound, true);
        const handle = s.handle;
        errdefer {
            const peer = s.peer;
            m.close(handle);
            if (peer) |p| m.close(p);
        }
        while (!(try m.get(handle, node)).connected) try wait(c, c.current, .never);
        return handle;
    }
    pub fn netClose(c: *Core, node: u32, sockets: []const Io.net.Socket) void {
        const m = begin(c);
        for (sockets) |s| if (m.sockets.get(s.handle)) |live| if (live.node == node) m.close(s.handle);
        c.notifyNetwork();
    }
    pub fn netShutdown(c: *Core, node: u32, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) !void {
        const m = begin(c);
        const s = try m.get(handle, node);
        if (s.kind != .stream) return error.SocketUnconnected;
        switch (how) {
            .send => s.send_closed = true,
            .recv => s.receive_closed = true,
            .both => {
                s.send_closed = true;
                s.receive_closed = true;
            },
        }
        m.change +%= 1;
        c.notifyNetwork();
    }
    pub fn netLookup(c: *Core, _: u32, host: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), o: Io.net.HostName.LookupOptions) !void {
        const io: Io = .{ .userdata = if (c.nodeId() == 0) &c.context else c.contexts.items[c.nodeId() - 1], .vtable = c.vtable };
        defer queue.close(io);
        var normalized: [Io.net.HostName.max_len]u8 = undefined;
        const bytes = std.mem.trimEnd(u8, host.bytes, ".");
        for (bytes, 0..) |b, i| normalized[i] = std.ascii.toLower(b);
        const m = begin(c);
        const node = m.names.get(normalized[0..bytes.len]) orelse return error.UnknownHostName;
        var canonical = host;
        if (o.canonical_name_buffer) |buffer| {
            @memcpy(buffer[0..bytes.len], normalized[0..bytes.len]);
            canonical = try Io.net.HostName.init(buffer[0..bytes.len]);
        }
        try queue.putOne(io, .{ .canonical_name = canonical });
        var count: usize = 0;
        for (m.addresses.items) |item| if (item.node == node) {
            if (o.family) |f| if (std.meta.activeTag(item.address) != f) continue;
            var address = item.address;
            address.setPort(o.port);
            try queue.putOne(io, .{ .address = address });
            count += 1;
        };
        if (count == 0) return error.NoAddressReturned;
    }
    pub fn netWriteFile(c: *Core, node: u32, handle: Io.net.Socket.Handle, header: []const u8, file: *Io.File.Reader, limit: Io.Limit) !usize {
        const m = begin(c);
        if (header.len == 0 and limit == .nothing) return 0;
        const bytes = if (header.len != 0) header else limit.sliceConst(try file.interface.peekGreedy(1));
        while (true) {
            const s = try m.get(handle, node);
            if (try m.write(s, bytes)) |n| {
                if (header.len == 0) file.interface.toss(n);
                return n;
            }
            try wait(c, c.current, .never);
        }
    }
};
fn invoke(comptime name: []const u8, user: ?*anyopaque, args: anytype, ret: usize) Return(name) {
    const c = Core.of(user);
    const e = c.enter(ret, true);
    const call = @field(IoCall, name);
    const return_type = Return(name);
    if (comptime io_call.cancelable(call)) if (e.task) |task| if (Core.cancelPoint(task)) {
        c.record(call, e, std.hash.Wyhash.hash(0, "Canceled"));
        return error.Canceled;
    };
    if (c.options.net == null) {
        if (return_type == void) return;
        return error.Unexpected;
    }
    const input = inputs(e.node, args);
    const result = @call(.auto, @field(slots, name), .{ c, e.node } ++ args);
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
        const value = result catch |err| {
            c.record(call, e, input ^ std.hash.Wyhash.hash(0, @errorName(err)));
            return mapped(@typeInfo(return_type).error_union.error_set, err);
        };
        c.record(call, e, input ^ outputDigest(value));
        return value;
    } else {
        c.record(call, e, input ^ outputDigest(result));
        return result;
    }
}
pub fn slot(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const p = info.param_types;
    const return_type = info.return_type.?;
    return switch (p.len) {
        2 => &struct {
            fn f(u: ?*anyopaque, a: p[1].?) return_type {
                return invoke(name, u, .{a}, @returnAddress());
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, a: p[1].?, b: p[2].?) return_type {
                return invoke(name, u, .{ a, b }, @returnAddress());
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, a: p[1].?, b: p[2].?, d: p[3].?) return_type {
                return invoke(name, u, .{ a, b, d }, @returnAddress());
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, a: p[1].?, b: p[2].?, d: p[3].?, e: p[4].?) return_type {
                return invoke(name, u, .{ a, b, d, e }, @returnAddress());
            }
        }.f,
        else => @compileError("network slot arity"),
    };
}
/// Readiness is transactional: null leaves a submitted operation untouched.
pub fn perform(c: *Core, node: u32, operation: Io.Operation) ?Io.Operation.Result {
    const m = begin(c);
    return switch (operation) {
        .net_read => |r| blk: {
            const s = m.get(r.socket_handle, node) catch |err| break :blk .{ .net_read = mapped(Io.Operation.NetRead.Error, err) };
            var n: usize = 0;
            for (r.data) |buf| {
                const read = m.read(s, buf) catch |err| break :blk .{ .net_read = mapped(Io.Operation.NetRead.Error, err) };
                if (read) |count| {
                    n += count;
                    if (count < buf.len) break;
                } else {
                    if (n == 0) break :blk null;
                    break;
                }
            }
            break :blk .{ .net_read = .{ .data_len = n } };
        },
        .net_write => |w| blk: {
            const s = m.get(w.socket_handle, node) catch |err| break :blk .{ .net_write = mapped(Io.Operation.NetWrite.Error, err) };
            var n: usize = 0;
            const hn = m.write(s, w.header) catch |err| break :blk .{ .net_write = mapped(Io.Operation.NetWrite.Error, err) };
            if (hn) |count| {
                n += count;
                if (count < w.header.len) break :blk .{ .net_write = n };
            } else break :blk null;
            for (w.data, 0..) |bytes, i| {
                const repetitions = if (i + 1 == w.data.len) w.splat else 1;
                for (0..repetitions) |_| {
                    const written = m.write(s, bytes) catch |err| {
                        if (n != 0) break :blk .{ .net_write = n };
                        break :blk .{ .net_write = mapped(Io.Operation.NetWrite.Error, err) };
                    };
                    if (written) |count| {
                        n += count;
                        if (count < bytes.len) break :blk .{ .net_write = n };
                    } else {
                        if (n == 0) break :blk null;
                        break :blk .{ .net_write = n };
                    }
                }
            }
            break :blk .{ .net_write = n };
        },
        .net_send => |w| blk: {
            const s = m.get(w.socket_handle, node) catch |err| break :blk .{ .net_send = .{ mapped(Io.Operation.NetSend.Error, err), 0 } };
            for (w.messages, 0..) |*msg, i| {
                m.send(s, msg.address.*, msg.data_ptr[0..msg.data_len]) catch |err| break :blk .{ .net_send = .{ mapped(Io.Operation.NetSend.Error, err), i } };
            }
            break :blk .{ .net_send = .{ null, w.messages.len } };
        },
        .net_receive => |r| blk: {
            const s = m.get(r.socket_handle, node) catch |err| break :blk .{ .net_receive = .{ mapped(Io.Operation.NetReceive.Error, err), 0 } };
            var used: usize = 0;
            var count: usize = 0;
            for (r.message_buffer) |*msg| {
                const received = m.receive(s, r.data_buffer[used..], r.flags.peek) orelse break;
                msg.* = .{ .from = received.address, .data = r.data_buffer[used..][0..received.len], .control = &.{}, .flags = .{ .trunc = received.truncated, .eor = false, .ctrunc = false, .oob = false, .errqueue = false } };
                used += received.len;
                count += 1;
                if (r.flags.peek or used == r.data_buffer.len) break;
            }
            if (count == 0 and r.message_buffer.len != 0) break :blk null;
            break :blk .{ .net_receive = .{ null, count } };
        },
        else => null,
    };
}
pub fn isNetwork(op: Io.Operation) bool {
    return switch (op) {
        .net_read, .net_write, .net_send, .net_receive => true,
        else => false,
    };
}

fn number(hash: *std.hash.Wyhash, value: anytype) void {
    const portable: u64 = if (@typeInfo(@TypeOf(value)) == .pointer) @intFromPtr(value) else @intCast(value); // safe: opaque socket handles encode virtual identifiers, never host addresses
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, portable));
    hash.update(&bytes);
}
fn addressDigest(hash: *std.hash.Wyhash, address: Io.net.IpAddress) void {
    number(hash, address.getPort());
    switch (address) {
        .ip4 => |ip| hash.update(&ip.bytes),
        .ip6 => |ip| hash.update(&ip.bytes),
    }
}
fn inputs(node: u32, args: anytype) u64 {
    var hash = std.hash.Wyhash.init(node);
    inline for (args) |arg| {
        const T = @TypeOf(arg);
        if (T == *const Io.net.IpAddress) addressDigest(&hash, arg.*) else if (T == *const Io.net.UnixAddress) hash.update(arg.path) else if (T == Io.net.HostName) hash.update(arg.bytes) else if (T == []const Io.net.Socket) {
            for (arg) |socket| number(&hash, socket.handle);
        } else if (T == Io.net.Socket.Handle) number(&hash, arg) else if (T == []const u8) hash.update(arg) else if (@typeInfo(T) == .@"enum") number(&hash, @backingInt(arg));
    }
    return hash.final();
}
fn outputDigest(value: anytype) u64 {
    var hash = std.hash.Wyhash.init(0);
    const T = @TypeOf(value);
    if (T == Io.net.Socket) {
        number(&hash, value.handle);
        addressDigest(&hash, value.address);
    } else if (T == [2]Io.net.Socket) {
        for (value) |socket| {
            number(&hash, socket.handle);
            addressDigest(&hash, socket.address);
        }
    } else if (@typeInfo(T) == .int) number(&hash, value);
    return hash.final();
}
pub fn operationDigest(node: u32, op: Io.Operation, result: Io.Operation.Result) u64 {
    var hash = std.hash.Wyhash.init(node);
    switch (op) {
        .net_read => |r| {
            number(&hash, r.socket_handle);
            if (result.net_read) |value| {
                number(&hash, value.data_len);
                var left = value.data_len;
                for (r.data) |bytes| {
                    const n = @min(left, bytes.len);
                    hash.update(bytes[0..n]);
                    left -= n;
                }
            } else |err| hash.update(@errorName(err));
        },
        .net_write => |w| {
            number(&hash, w.socket_handle);
            hash.update(w.header);
            for (w.data) |bytes| hash.update(bytes);
            number(&hash, w.splat);
            if (result.net_write) |n| number(&hash, n) else |err| hash.update(@errorName(err));
        },
        .net_receive => |r| {
            number(&hash, r.socket_handle);
            const err, const count = result.net_receive;
            if (err) |e| hash.update(@errorName(e));
            number(&hash, count);
            for (r.message_buffer[0..count]) |msg| {
                addressDigest(&hash, msg.from);
                hash.update(msg.data);
            }
        },
        .net_send => |s| {
            number(&hash, s.socket_handle);
            for (s.messages) |msg| {
                addressDigest(&hash, msg.address.*);
                hash.update(msg.data_ptr[0..msg.data_len]);
            }
            const err, const count = result.net_send;
            if (err) |e| hash.update(@errorName(e));
            number(&hash, count);
        },
        else => unreachable, // unreachable: called only for network operations
    }
    return hash.final();
}
