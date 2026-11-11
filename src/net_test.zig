const std = @import("std");
const Sim = @import("Sim.zig");
const Io = std.Io;
const t = std.testing;
const Source = @import("Source.zig");
const Model = @import("sim/net/Model.zig");
const shakedown = @import("shakedown.zig");

test "Net local pair preserves bytes and half close" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    _ = sim.net();
    const Work = struct {
        fn run(io: Io) !void {
            const pair = try Io.net.Socket.createPair(io, .{});
            defer pair[0].close(io);
            defer pair[1].close(io);
            const a: Io.net.Stream = .{ .socket = pair[0] };
            const b: Io.net.Stream = .{ .socket = pair[1] };
            try t.expectEqual(5, try (try io.operate(.{ .net_write = .{ .socket_handle = a.socket.handle, .header = "hello", .data = &.{}, .splat = 1, .control = &.{} } })).net_write);
            try a.shutdown(io, .send);
            var buf: [8]u8 = undefined;
            var vectors = [_][]u8{&buf};
            try t.expectEqual(5, (try b.readWithControl(io, &vectors, &.{})).data_len);
            try t.expectEqualStrings("hello", buf[0..5]);
            try t.expectEqual(0, (try b.readWithControl(io, &vectors, &.{})).data_len);
        }
    };
    const result = sim.run(Work.run, .{sim.io()});
    if (result == .failed) return result.failed;
    try t.expect(result == .finished);
}

test "Net nodes own isolated disks" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{});
    try a.fs().write("only-a", "a");
    try t.expectError(error.FileNotFound, b.fs().read(t.allocator, "only-a"));
}

fn finished(result: Sim.Outcome) !void {
    if (result == .failed) return result.failed;
    try t.expect(result == .finished);
}
fn write(io: Io, stream: Io.net.Stream, bytes: []const u8) !usize {
    const value = try (try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .header = bytes, .data = &.{} } })).net_write;
    return value;
}
fn read(io: Io, stream: Io.net.Stream, bytes: []u8) !usize {
    var vectors = [_][]u8{bytes};
    return (try stream.readWithControl(io, &vectors, &.{})).data_len;
}
fn timeout(ns: i96) Io.Timeout {
    return .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } };
}

test "Net TCP handshake latency bandwidth ordered bytes and reset" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const addr = try Io.net.IpAddress.parseIp4("10.0.0.3", 8080);
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{ .addresses = &.{addr} });
    try sim.net().link(a, b, .{ .latency = .{ .fixed = .fromMicroseconds(10) }, .bandwidth = 1000000, .buffer = 8 });
    const Work = struct {
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, address: Io.net.IpAddress) !void {
            var server = try address.listen(right.io(), .{});
            defer server.deinit(right.io());
            const start = s.now(.awake).nanoseconds;
            const client = try address.connect(left.io(), .{ .mode = .stream });
            defer client.close(left.io());
            try t.expectEqual(20000, s.now(.awake).nanoseconds - start);
            const peer = try server.accept(right.io());
            defer peer.close(right.io());
            try t.expectEqual(8, try write(left.io(), client, "123456789"));
            var buf: [8]u8 = undefined;
            try t.expectEqual(8, try read(right.io(), peer, &buf));
            try t.expectEqualStrings("12345678", &buf);
            try t.expectEqual(38000, s.now(.awake).nanoseconds - start);
            try t.expectEqual(1, try write(left.io(), client, "9"));
            try t.expectEqual(1, try read(right.io(), peer, &buf));
            s.net().resetConnections(left, right);
            try t.expectError(error.ConnectionResetByPeer, read(right.io(), peer, &buf));
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, addr }));
}

test "Net UDP duplicate peek truncate loss timeout and canceled batches" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const aa = try Io.net.IpAddress.parseIp4("10.1.0.1", 9000);
    const ba = try Io.net.IpAddress.parseIp4("10.1.0.2", 9001);
    const a = try sim.node("a", .{ .addresses = &.{aa} });
    const b = try sim.node("b", .{ .addresses = &.{ba} });
    try sim.net().link(a, b, .{ .duplicate_per_million = 1000000 });
    const Work = struct {
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, x: Io.net.IpAddress, y: Io.net.IpAddress) !void {
            const send = try x.bind(left.io(), .{ .mode = .dgram });
            defer send.close(left.io());
            const receive = try y.bind(right.io(), .{ .mode = .dgram });
            defer receive.close(right.io());
            try send.send(left.io(), &y, "abcdef");
            var buf: [3]u8 = undefined;
            var messages = [_]Io.net.IncomingMessage{.init};
            const op: Io.Operation = .{ .net_receive = .{ .socket_handle = receive.handle, .message_buffer = &messages, .data_buffer = &buf, .flags = .{} } };
            const err, const count = (try right.io().operate(op)).net_receive;
            if (err) |e| return e;
            try t.expectEqual(1, count);
            try t.expect(messages[0].flags.trunc);
            try t.expectEqualStrings("abc", messages[0].data);
            const second_err, const second_count = (try right.io().operate(op)).net_receive;
            if (second_err) |e| return e;
            try t.expectEqual(1, second_count);
            try s.net().link(left, right, .{ .loss_per_million = 1000000 });
            try send.send(left.io(), &y, "lost");
            try t.expectError(error.Timeout, right.io().operateTimeout(op, timeout(1000)));
            var storage: [1]Io.Operation.Storage = undefined;
            var batch = Io.Batch.init(&storage);
            batch.addAt(0, op);
            try t.expectError(error.Timeout, batch.awaitConcurrent(right.io(), timeout(1000)));
            batch.cancel(right.io());
            try t.expect(batch.next() == null);
            batch.addAt(0, op);
            batch.cancel(right.io());
            try t.expect(batch.next() == null);
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, aa, ba }));
}

test "Net Unix namespace, orderly close and reset" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{});
    const Work = struct {
        fn run(left: *Sim.Node, right: *Sim.Node) !void {
            const address = try Io.net.UnixAddress.init("/test.sock");
            var server = try address.listen(left.io(), .{});
            defer server.deinit(left.io());
            try t.expectError(error.FileNotFound, address.connect(right.io()));
            const client = try address.connect(left.io());
            const peer = try server.accept(left.io());
            defer peer.close(left.io());
            try t.expectEqual(2, try write(left.io(), client, "ok"));
            var buf: [2]u8 = undefined;
            try t.expectEqual(2, try read(left.io(), peer, &buf));
            // An orderly close: the peer reads the end of the stream, and
            // what it then sends draws a reset.
            client.close(left.io());
            try t.expectEqual(0, try read(left.io(), peer, &buf));
            try t.expectError(error.ConnectionResetByPeer, write(left.io(), peer, "late"));
            // A close that leaves bytes unread resets the peer at once.
            const second = try address.connect(left.io());
            const other = try server.accept(left.io());
            defer other.close(left.io());
            try t.expectEqual(2, try write(left.io(), other, "no"));
            try left.io().sleep(.fromMilliseconds(1), .awake);
            second.close(left.io());
            try t.expectError(error.ConnectionResetByPeer, read(left.io(), other, &buf));
        }
    };
    try finished(sim.run(Work.run, .{ a, b }));
}

test "Net DNS case folding family port unknown names and queue close" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const node = try sim.node("service", .{});
    try sim.net().dns("Service.Example.", node);
    const Work = struct {
        fn run(io: Io) !void {
            var storage: [16]Io.net.HostName.LookupResult = undefined;
            var queue = Io.Queue(Io.net.HostName.LookupResult).init(&storage);
            try io.vtable.netLookup(io.userdata, try .init("SERVICE.EXAMPLE."), &queue, .{ .port = 443 });
            const canonical = try queue.getOne(io);
            try t.expect(canonical == .canonical_name);
            const address = try queue.getOne(io);
            try t.expectEqual(443, address.address.getPort());
            try t.expectError(error.Closed, queue.getOne(io));
            var unknown = Io.Queue(Io.net.HostName.LookupResult).init(&storage);
            try t.expectError(error.UnknownHostName, io.vtable.netLookup(io.userdata, try .init("missing"), &unknown, .{ .port = 443 }));
            try t.expectError(error.Closed, unknown.getOne(io));
        }
    };
    try finished(sim.run(Work.run, .{sim.io()}));
}

test "Net DNS answers localhost and its subdomains with the loopback addresses, the asking node's own" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const Work = struct {
        fn addresses(io: Io, name: []const u8, family: ?Io.net.IpAddress.Family) ![2]?Io.net.IpAddress {
            var storage: [16]Io.net.HostName.LookupResult = undefined;
            var queue = Io.Queue(Io.net.HostName.LookupResult).init(&storage);
            try io.vtable.netLookup(io.userdata, try .init(name), &queue, .{ .port = 8080, .family = family });
            var found: [2]?Io.net.IpAddress = .{ null, null };
            var n: usize = 0;
            while (queue.getOne(io)) |result| switch (result) {
                .address => |a| {
                    found[n] = a;
                    n += 1;
                },
                .canonical_name => {},
            } else |err| try t.expectEqual(error.Closed, err);
            return found;
        }

        fn run(io: Io) !void {
            // RFC 6761 §6.3: IPv4's loopback first, then IPv6's, on the port asked.
            for ([_][]const u8{ "localhost", "LocalHost.", "api.localhost" }) |name| {
                const both = try addresses(io, name, null);
                try t.expect(both[0].?.eql(&try .parse("127.0.0.1", 8080)));
                try t.expect(both[1].?.eql(&try .parse("::1", 8080)));
            }
            const six = try addresses(io, "localhost", .ip6);
            try t.expect(six[0].?.eql(&try .parse("::1", 8080)));
            try t.expect(six[1] == null);
            // The name reaches a server on the node's own loopback.
            var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 8080)).listen(io, .{});
            defer listener.deinit(io);
            const stream = try (try Io.net.HostName.init("localhost")).connect(io, 8080, .{ .mode = .stream });
            stream.close(io);
            (try listener.accept(io)).close(io);
            // A name that only ends in the letters is no subdomain.
            var storage: [4]Io.net.HostName.LookupResult = undefined;
            var queue = Io.Queue(Io.net.HostName.LookupResult).init(&storage);
            try t.expectError(error.UnknownHostName, io.vtable.netLookup(io.userdata, try .init("notlocalhost"), &queue, .{ .port = 1 }));
        }
    };
    try finished(sim.run(Work.run, .{sim.io()}));
}

test "Net partition expires streams hold releases and canceled connect frees packets" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo, .net = .{ .max_packets = 2 } });
    defer sim.deinit();
    const address = try Io.net.IpAddress.parseIp4("10.3.0.2", 8000);
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{ .addresses = &.{address} });
    const Work = struct {
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, addr: Io.net.IpAddress) !void {
            var server = try addr.listen(right.io(), .{});
            defer server.deinit(right.io());
            s.net().hold(left, right);
            for (0..8) |_| try t.expectError(error.Timeout, addr.connect(left.io(), .{ .mode = .stream, .timeout = timeout(1000) }));
            try t.expectEqual(0, s.core.network.queue.items.len);
            try t.expectEqual(1, s.core.network.sockets.count());
            s.net().release(left, right);
            const client = try addr.connect(left.io(), .{ .mode = .stream });
            defer client.close(left.io());
            const peer = try server.accept(right.io());
            defer peer.close(right.io());
            s.net().partition(&.{left}, &.{right});
            try t.expectEqual(1, try write(left.io(), client, "x"));
            var byte: [1]u8 = undefined;
            const at = s.now(.awake).nanoseconds;
            try t.expectError(error.ConnectionTimedOut, read(right.io(), peer, &byte));
            try t.expectEqual(60000000000, s.now(.awake).nanoseconds - at);
            s.net().heal();
            try t.expectError(error.ConnectionTimedOut, read(right.io(), peer, &byte));
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, address }));
}

test "Net hold release backpressure and cancellation wake blocked writer" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const address = try Io.net.IpAddress.parseIp4("10.4.0.2", 8000);
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{ .addresses = &.{address} });
    try sim.net().link(a, b, .{ .buffer = 1 });
    const Work = struct {
        fn blocked(io: Io, stream: Io.net.Stream) !usize {
            return write(io, stream, "b");
        }
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, addr: Io.net.IpAddress) !void {
            var server = try addr.listen(right.io(), .{});
            defer server.deinit(right.io());
            const client = try addr.connect(left.io(), .{ .mode = .stream });
            defer client.close(left.io());
            const peer = try server.accept(right.io());
            defer peer.close(right.io());
            s.net().hold(left, right);
            try t.expectEqual(1, try write(left.io(), client, "a"));
            var writer = try left.io().concurrent(blocked, .{ left.io(), client });
            try s.io().sleep(.fromNanoseconds(1000), .awake);
            try t.expectError(error.Canceled, writer.cancel(s.io()));
            s.net().release(left, right);
            var buf: [1]u8 = undefined;
            try t.expectEqual(1, try read(right.io(), peer, &buf));
            try t.expectEqualStrings("a", &buf);
            try t.expectEqual(1, try write(left.io(), client, "b"));
            try t.expectEqual(1, try read(right.io(), peer, &buf));
            try t.expectEqualStrings("b", &buf);
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, address }));
}

test "Net kill cancels node tasks resets peers crash keeps durable disk restart" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const a = try sim.node("a", .{});
    try a.fs().write("durable", "kept");
    const Work = struct {
        fn blocked(io: Io, stream: Io.net.Stream) !void {
            var b: [1]u8 = undefined;
            _ = try read(io, stream, &b);
        }
        fn restarted(io: Io, called: *bool) void {
            _ = Io.Clock.awake.now(io);
            called.* = true;
        }
        fn run(s: *Sim, node: *Sim.Node, called: *bool) !void {
            const io = node.io();
            const pair = try Io.net.Socket.createPair(io, .{});
            var task = try io.concurrent(blocked, .{ io, Io.net.Stream{ .socket = pair[0] } });
            try s.io().sleep(.fromNanoseconds(1), .awake);
            try node.crash(.lose_all);
            try t.expectError(error.Canceled, task.await(s.io()));
            try t.expectEqual(0, s.core.network.sockets.count());
            try node.restart(restarted, .{ io, called });
        }
    };
    var called = false;
    try finished(sim.run(Work.run, .{ sim, a, &called }));
    try t.expect(called);
    const bytes = try a.fs().read(t.allocator, "durable");
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("kept", bytes);
}

const Replay = struct {
    fn run(io: Io, a: *Sim.Node, b: *Sim.Node, aa: Io.net.IpAddress, ba: Io.net.IpAddress, checksum: *u64) !void {
        _ = io;
        const send = try aa.bind(a.io(), .{ .mode = .dgram });
        defer send.close(a.io());
        const receive = try ba.bind(b.io(), .{ .mode = .dgram });
        defer receive.close(b.io());
        for (0..8) |i| {
            var byte = [_]u8{@intCast(i)};
            try send.send(a.io(), &ba, &byte);
        }
        var buf: [1]u8 = undefined;
        var messages = [_]Io.net.IncomingMessage{.init};
        const op: Io.Operation = .{ .net_receive = .{ .socket_handle = receive.handle, .message_buffer = &messages, .data_buffer = &buf, .flags = .{} } };
        while (true) {
            const result = b.io().operateTimeout(op, timeout(1000000)) catch |err| {
                if (err == error.Timeout) break;
                return err;
            };
            const err, const count = result.net_receive;
            if (err) |e| return e;
            try t.expectEqual(1, count);
            checksum.* = std.hash.int(checksum.* ^ (@as(u64, buf[0]) + 1));
        }
    }
    fn execute(source: *Source, executor: Sim.Executor) !struct { hash: u64, checksum: u64, time: i96 } {
        const sim = try Sim.init(t.allocator, .{ .watchdog = null, .source = source, .executor = executor });
        defer sim.deinit();
        const aa = try Io.net.IpAddress.parseIp4("10.5.0.1", 123);
        const ba = try Io.net.IpAddress.parseIp4("10.5.0.2", 456);
        const a = try sim.node("a", .{ .addresses = &.{aa} });
        const b = try sim.node("b", .{ .addresses = &.{ba} });
        try sim.net().link(a, b, .{ .latency = .{ .uniform = .{ .min = .fromNanoseconds(1), .max = .fromMicroseconds(10) } }, .loss_per_million = 250000, .duplicate_per_million = 250000, .reorder_per_million = 500000, .bandwidth = 1000000 });
        var checksum: u64 = 0;
        try finished(sim.run(run, .{ sim.io(), a, b, aa, ba, &checksum }));
        return .{ .hash = sim.trace().hash(), .checksum = checksum, .time = sim.now(.awake).nanoseconds };
    }
};
test "Net one source tape replays loss duplication reordering and bandwidth across executors" {
    for (0..12) |seed| {
        var recording = try Source.initRecording(t.allocator, .{ .prng = seed }, .{ .max_choices = 4096 });
        defer recording.deinit();
        const before = try Replay.execute(&recording, .auto);
        var replay = try Source.init(t.allocator, .{ .replay = recording.tape().choices });
        defer replay.deinit();
        try t.expectEqualDeep(before, try Replay.execute(&replay, .threads));
    }
}

test "Net standard HTTP Client talks to standard HTTP Server over DNS TCP" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const address = try Io.net.IpAddress.parseIp4("10.6.0.2", 8080);
    const a = try sim.node("client", .{});
    const b = try sim.node("server", .{ .addresses = &.{address} });
    try sim.net().dns("server.test", b);
    const Work = struct {
        fn serve(io: Io, listener: *Io.net.Server, ack: *Io.Event) !void {
            const stream = try listener.accept(io);
            defer stream.close(io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var input = stream.reader(io, &read_buffer);
            var output = stream.writer(io, &write_buffer);
            var server = std.http.Server.init(&input.interface, &output.interface);
            var request = try server.receiveHead();
            try t.expectEqualStrings("/hello", request.head.target);
            try request.respond("hello from the simulated server", .{});
            try ack.wait(io);
        }
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, addr: Io.net.IpAddress) !void {
            var listener = try addr.listen(right.io(), .{});
            defer listener.deinit(right.io());
            var ack: Io.Event = .unset;
            var server = try right.io().concurrent(serve, .{ right.io(), &listener, &ack });
            // glint-ignore: Z026 -- cleanup of a task the test has already awaited or abandons when it fails; the failure it reports is the test's own
            defer server.cancel(s.io()) catch {};
            var client: std.http.Client = .{ .allocator = t.allocator, .io = left.io() };
            defer client.deinit();
            var body: Io.Writer.Allocating = .init(t.allocator);
            defer body.deinit();
            const response = try client.fetch(.{ .location = .{ .url = "http://server.test:8080/hello" }, .response_writer = &body.writer });
            try t.expectEqual(.ok, response.status);
            try t.expectEqualStrings("hello from the simulated server", body.written());
            ack.set(s.io());
            try server.await(s.io());
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, address }));
}

test "Net forced UDP reordering has a hand derived arrival order" {
    var source = try Source.init(t.allocator, .{ .replay = &.{ 9, 9, 0, 0 } });
    defer source.deinit();
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .source = &source, .schedule = .fifo });
    defer sim.deinit();
    const aa = try Io.net.IpAddress.parseIp4("10.7.0.1", 123);
    const ba = try Io.net.IpAddress.parseIp4("10.7.0.2", 456);
    const a = try sim.node("a", .{ .addresses = &.{aa} });
    const b = try sim.node("b", .{ .addresses = &.{ba} });
    try sim.net().link(a, b, .{ .latency = .{ .uniform = .{ .min = .fromNanoseconds(1), .max = .fromNanoseconds(10) } }, .reorder_per_million = 1000000 });
    const Work = struct {
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, x: Io.net.IpAddress, y: Io.net.IpAddress) !void {
            const send = try x.bind(left.io(), .{ .mode = .dgram });
            defer send.close(left.io());
            const receive = try y.bind(right.io(), .{ .mode = .dgram });
            defer receive.close(right.io());
            try send.send(left.io(), &y, "1");
            try send.send(left.io(), &y, "2");
            var buf: [1]u8 = undefined;
            var messages = [_]Io.net.IncomingMessage{.init};
            const op: Io.Operation = .{ .net_receive = .{ .socket_handle = receive.handle, .message_buffer = &messages, .data_buffer = &buf, .flags = .{} } };
            _ = try right.io().operate(op);
            try t.expectEqual('2', buf[0]);
            try t.expectEqual(1000000002, s.now(.awake).nanoseconds);
            _ = try right.io().operate(op);
            try t.expectEqual('1', buf[0]);
            try t.expectEqual(1000000020, s.now(.awake).nanoseconds);
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, aa, ba }));
}

test "Net TCP total loss times out instead of losing delivered bytes" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const aa = try Io.net.IpAddress.parseIp4("10.8.0.1", 123);
    const ba = try Io.net.IpAddress.parseIp4("10.8.0.2", 456);
    const a = try sim.node("a", .{ .addresses = &.{aa} });
    const b = try sim.node("b", .{ .addresses = &.{ba} });
    try sim.net().link(a, b, .{ .latency = .{ .fixed = .fromNanoseconds(0) }, .loss_per_million = 1000000 });
    const Work = struct {
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, addr: Io.net.IpAddress) !void {
            var server = try addr.listen(right.io(), .{});
            defer server.deinit(right.io());
            try t.expectError(error.Timeout, addr.connect(left.io(), .{ .mode = .stream }));
            try t.expectEqual(61000000000, s.now(.awake).nanoseconds);
            try t.expectEqual(1, s.core.network.sockets.count());
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, ba }));
}

test "Net allocation failures leave one owned resource graph" {
    const Work = struct {
        fn allocations(gpa: std.mem.Allocator) !void {
            var model = Model.init(gpa, .{});
            defer model.deinit();
            const a = try model.addNode(&.{});
            const b = try model.addNode(&.{});
            const pair = try model.pair(a, b, false);
            _ = try model.write(pair[0], "a");
            model.now = 100000;
            model.pump();
            var buf: [1]u8 = undefined;
            try t.expectEqual(1, (try model.read(pair[1], &buf)).?);
            model.close(pair[0].handle);
            model.close(pair[1].handle);
            const again = try model.pair(a, b, false);
            model.close(again[0].handle);
            model.close(again[1].handle);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Work.allocations, .{});
}

test "Net warmed message delivery and socket reuse allocate nothing" {
    const Counting = @import("alloc/Counting.zig");
    var counted = Counting.init(t.allocator);
    var model = Model.init(counted.allocator(), .{});
    defer model.deinit();
    const only = try model.addNode(&.{});
    const pair = try model.pair(only, only, true);
    var byte: [1]u8 = undefined;
    _ = try model.write(pair[0], "x");
    model.pump();
    _ = try model.read(pair[1], &byte);
    const allocations = counted.allocations + counted.resizes + counted.remaps;
    for (0..1000) |_| {
        _ = try model.write(pair[0], "x");
        model.pump();
        _ = try model.read(pair[1], &byte);
    }
    model.close(pair[0].handle);
    model.close(pair[1].handle);
    const reused = try model.pair(only, only, true);
    try t.expectEqual(allocations, counted.allocations + counted.resizes + counted.remaps);
    model.close(reused[0].handle);
    model.close(reused[1].handle);
}

test "Net node Io uses one shared outer fault counter and isolated file slots" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .faults = &.{.{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 2 } }, .fault = .{ .fail = error.FileNotFound } }} });
    defer sim.deinit();
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{});
    try a.fs().write("file", "a");
    try b.fs().write("file", "b");
    const Work = struct {
        fn run(left: *Sim.Node, right: *Sim.Node) !void {
            const file = try Io.Dir.cwd().openFile(left.io(), "file", .{});
            defer file.close(left.io());
            try t.expectError(error.FileNotFound, Io.Dir.cwd().openFile(right.io(), "file", .{}));
            const other = try Io.Dir.cwd().openFile(right.io(), "file", .{});
            defer other.close(right.io());
            var byte: [1]u8 = undefined;
            try t.expectEqual(1, try other.readPositional(right.io(), &.{&byte}, 0));
            try t.expectEqual('b', byte[0]);
        }
    };
    try finished(sim.run(Work.run, .{ a, b }));
    try t.expectEqual(3, sim.faults().?.count(.dirOpenFile));
}

test "Net trace identifies node and detects changed bytes" {
    const Work = struct {
        fn run(io: Io, byte: u8) !void {
            const pair = try Io.net.Socket.createPair(io, .{});
            defer pair[0].close(io);
            defer pair[1].close(io);
            const bytes = [_]u8{byte};
            _ = try write(io, .{ .socket = pair[0] }, &bytes);
        }
        fn digest(byte: u8) !u64 {
            const sim = try Sim.init(t.allocator, .{ .watchdog = null });
            defer sim.deinit();
            const node = try sim.node("node", .{});
            try finished(sim.run(run, .{ node.io(), byte }));
            return sim.trace().hash();
        }
    };
    try t.expectEqual(try Work.digest('a'), try Work.digest('a'));
    try t.expect(try Work.digest('a') != try Work.digest('b'));
}
test "Net invalid link configuration fails before running" {
    try t.expectError(error.InvalidLink, Sim.init(t.allocator, .{ .net = .{ .default_link = .{ .bandwidth = 0 } } }));
    try t.expectError(error.InvalidLink, Model.validate(.{ .loss_per_million = 1000001 }));
    try t.expectError(error.InvalidLink, Model.validate(.{ .latency = .{ .uniform = .{ .min = .fromNanoseconds(2), .max = .fromNanoseconds(1) } } }));
}

test "Net TCP retransmission delivers bytes exactly once in order" {
    var source = try Source.init(t.allocator, .{ .replay = &.{ 0, 999999, 0, 999999, 999999 } });
    defer source.deinit();
    const sim = try Sim.init(t.allocator, .{ .source = &source, .schedule = .fifo, .watchdog = null });
    defer sim.deinit();
    const address = try Io.net.IpAddress.parseIp4("10.9.0.2", 80);
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{ .addresses = &.{address} });
    try sim.net().link(a, b, .{ .latency = .{ .fixed = .fromNanoseconds(0) }, .loss_per_million = 500000 });
    const Work = struct {
        fn run(s: *Sim, left: *Sim.Node, right: *Sim.Node, addr: Io.net.IpAddress) !void {
            var server = try addr.listen(right.io(), .{});
            defer server.deinit(right.io());
            const client = try addr.connect(left.io(), .{ .mode = .stream });
            defer client.close(left.io());
            const peer = try server.accept(right.io());
            defer peer.close(right.io());
            try t.expectEqual(1200000000, s.now(.awake).nanoseconds);
            _ = try write(left.io(), client, "a");
            _ = try write(left.io(), client, "b");
            try client.shutdown(left.io(), .send);
            var bytes: [2]u8 = undefined;
            try t.expectEqual(2, try read(right.io(), peer, &bytes));
            try t.expectEqualStrings("ab", &bytes);
            try t.expectEqual(1400000000, s.now(.awake).nanoseconds);
            try t.expectEqual(0, try read(right.io(), peer, &bytes));
        }
    };
    try finished(sim.run(Work.run, .{ sim, a, b, address }));
}

test "Net UDP successful send survives sender close and stale handles cannot alias reuse" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const aa = try Io.net.IpAddress.parseIp4("10.10.0.1", 123);
    const ba = try Io.net.IpAddress.parseIp4("10.10.0.2", 456);
    const a = try sim.node("a", .{ .addresses = &.{aa} });
    const b = try sim.node("b", .{ .addresses = &.{ba} });
    const Work = struct {
        fn run(left: *Sim.Node, right: *Sim.Node, x: Io.net.IpAddress, y: Io.net.IpAddress) !void {
            const send = try x.bind(left.io(), .{ .mode = .dgram });
            const receive = try y.bind(right.io(), .{ .mode = .dgram });
            defer receive.close(right.io());
            try send.send(left.io(), &y, "sent");
            send.close(left.io());
            const reused = try x.bind(left.io(), .{ .mode = .dgram });
            defer reused.close(left.io());
            try t.expect(reused.handle != send.handle);
            try t.expectError(error.SocketUnconnected, send.send(left.io(), &y, "stale"));
            var bytes: [4]u8 = undefined;
            var messages = [_]Io.net.IncomingMessage{.init};
            const err, const count = (try right.io().operate(.{ .net_receive = .{ .socket_handle = receive.handle, .message_buffer = &messages, .data_buffer = &bytes, .flags = .{} } })).net_receive;
            if (err) |e| return e;
            try t.expectEqual(1, count);
            try t.expectEqualStrings("sent", &bytes);
        }
    };
    try finished(sim.run(Work.run, .{ a, b, aa, ba }));
}

test "Net broadcast requires permission and reaches registered receivers" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const aa = try Io.net.IpAddress.parseIp4("10.11.0.1", 123);
    const ba = try Io.net.IpAddress.parseIp4("10.11.0.2", 456);
    const a = try sim.node("a", .{ .addresses = &.{aa} });
    const b = try sim.node("b", .{ .addresses = &.{ba} });
    const Work = struct {
        fn run(left: *Sim.Node, right: *Sim.Node, x: Io.net.IpAddress, y: Io.net.IpAddress) !void {
            const denied = try x.bind(left.io(), .{ .mode = .dgram });
            const broadcast = try Io.net.IpAddress.parseIp4("255.255.255.255", 456);
            try t.expectError(error.AccessDenied, denied.send(left.io(), &broadcast, "b"));
            denied.close(left.io());
            const send = try x.bind(left.io(), .{ .mode = .dgram, .allow_broadcast = true });
            defer send.close(left.io());
            const receive = try y.bind(right.io(), .{ .mode = .dgram });
            defer receive.close(right.io());
            try send.send(left.io(), &broadcast, "b");
            var buf: [1]u8 = undefined;
            var messages = [_]Io.net.IncomingMessage{.init};
            const err, const count = (try right.io().operate(.{ .net_receive = .{ .socket_handle = receive.handle, .message_buffer = &messages, .data_buffer = &buf, .flags = .{} } })).net_receive;
            if (err) |e| return e;
            try t.expectEqual(1, count);
            try t.expectEqual('b', buf[0]);
        }
    };
    try finished(sim.run(Work.run, .{ a, b, aa, ba }));
}

test "Net saturated finite delivery hits the time limit instead of deadlock" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .net = .{ .default_link = .{ .latency = .{ .fixed = .fromNanoseconds(std.math.maxInt(i64)) } } } });
    defer sim.deinit();
    const address = try Io.net.IpAddress.parseIp4("10.12.0.2", 80);
    const a = try sim.node("a", .{});
    const b = try sim.node("b", .{ .addresses = &.{address} });
    const Work = struct {
        fn run(left: *Sim.Node, right: *Sim.Node, addr: Io.net.IpAddress) !void {
            var server = try addr.listen(right.io(), .{});
            defer server.deinit(right.io());
            const client = try addr.connect(left.io(), .{ .mode = .stream });
            defer client.close(left.io());
        }
    };
    try t.expect(sim.run(Work.run, .{ a, b, address }) == .time_limit);
}

test "Net exponential latency agrees with independent inverse CDF landmarks" {
    const Draw = struct {
        fn half(_: *anyopaque, _: u64) u64 {
            return (1 << 31) - 1;
        }
    };
    var token: u8 = 0;
    var model = Model.init(t.allocator, .{ .default_link = .{ .latency = .{ .exponential = .{ .mean = .fromSeconds(1) } } } });
    defer model.deinit();
    model.drawn_by = &token;
    model.draw_fn = Draw.half;
    const a = try model.addNode(&.{});
    const b = try model.addNode(&.{});
    const pair = try model.pair(a, b, false);
    _ = try model.write(pair[0], "a");
    // -ln(1/2) seconds, rounded down to nanoseconds. This is independent
    // of the fixed-point series used by the production distribution.
    try t.expectEqual(693147180, model.nextDeadline().?);
    model.now = 693147179;
    model.pump();
    var byte: [1]u8 = undefined;
    try t.expectEqual(null, try model.read(pair[1], &byte));
    model.now += 1;
    model.pump();
    try t.expectEqual(1, (try model.read(pair[1], &byte)).?);
    try t.expectEqual('a', byte[0]);
    try model.configure(a, b, .{ .latency = .{ .exponential = .{ .mean = .zero } } });
    _ = try model.write(pair[0], "b");
    try t.expectEqual(model.now, model.nextDeadline().?);
    model.pump();
    try t.expectEqual(1, (try model.read(pair[1], &byte)).?);
    try t.expectEqual('b', byte[0]);
}

test "Net accept returns queued connections in virtual handle order" {
    var model = Model.init(t.allocator, .{});
    defer model.deinit();
    const only = try model.addNode(&.{});
    const listener = try model.bind(only, model.address(only), .listener);
    const first = try model.connect(only, listener.address);
    const second = try model.connect(only, listener.address);
    model.now = 200000;
    model.pump();
    try t.expectEqual(first.peer.?, model.accept(listener).?.handle);
    try t.expectEqual(second.peer.?, model.accept(listener).?.handle);
    try t.expectEqual(null, model.accept(listener));
}

test "Net file transfer honors headers limits partial writes EOF and cancellation" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .schedule = .fifo, .net = .{ .default_link = .{ .buffer = 2 } } });
    defer sim.deinit();
    try sim.fs().write("payload", "abcd");
    const Work = struct {
        fn send(io: Io, stream: Io.net.Stream, reader: *Io.File.Reader) !usize {
            return io.vtable.netWriteFile(io.userdata, stream.socket.handle, &.{}, reader, .unlimited);
        }
        fn run(io: Io) !void {
            const file = try Io.Dir.cwd().openFile(io, "payload", .{});
            defer file.close(io);
            var file_buffer: [4]u8 = undefined;
            var reader = file.reader(io, &file_buffer);
            const pair = try Io.net.Socket.createPair(io, .{});
            defer pair[0].close(io);
            defer pair[1].close(io);
            const outgoing: Io.net.Stream = .{ .socket = pair[0] };
            const incoming: Io.net.Stream = .{ .socket = pair[1] };
            try t.expectEqual(1, try io.vtable.netWriteFile(io.userdata, pair[0].handle, "H", &reader, .nothing));
            try t.expectEqual(0, reader.logicalPos());
            try t.expectEqual(1, try send(io, outgoing, &reader));
            try t.expectEqual(1, reader.logicalPos());
            var bytes: [2]u8 = undefined;
            try t.expectEqual(2, try read(io, incoming, &bytes));
            try t.expectEqualStrings("Ha", &bytes);
            try t.expectEqual(1, try io.vtable.netWriteFile(io.userdata, pair[0].handle, &.{}, &reader, .limited(1)));
            try t.expectEqual(1, try send(io, outgoing, &reader));
            try t.expectEqual(3, reader.logicalPos());
            try t.expectEqual(2, try read(io, incoming, &bytes));
            try t.expectEqualStrings("bc", &bytes);
            try t.expectEqual(1, try send(io, outgoing, &reader));
            try t.expectEqual(4, reader.logicalPos());
            try t.expectEqual(1, try read(io, incoming, &bytes));
            try t.expectEqual('d', bytes[0]);
            try t.expectError(error.EndOfStream, send(io, outgoing, &reader));
            try t.expectEqual(0, try io.vtable.netWriteFile(io.userdata, pair[0].handle, &.{}, &reader, .nothing));
            try reader.seekTo(0);
            try t.expectEqual(2, try write(io, outgoing, "zz"));
            var blocked = try io.concurrent(send, .{ io, outgoing, &reader });
            try io.sleep(.fromNanoseconds(1), .awake);
            try t.expectError(error.Canceled, blocked.cancel(io));
            try t.expectEqual(0, reader.logicalPos());
            try t.expectEqual(2, try read(io, incoming, &bytes));
            try t.expectEqualStrings("zz", &bytes);
            try t.expectEqual(2, try send(io, outgoing, &reader));
            try t.expectEqual(2, reader.logicalPos());
            try t.expectEqual(2, try read(io, incoming, &bytes));
            try t.expectEqualStrings("ab", &bytes);
        }
    };
    try finished(sim.run(Work.run, .{sim.io()}));
}

/// A client that connects through a partition, retrying every second, and
/// a server that answers one byte. With `give_up_after`, the client has a
/// bug: after that many tries it waits for a reply to a request it never
/// sent, for ever.
const Retry = struct {
    done: bool = false,
    tries: u32 = 0,
    give_up_after: ?u32 = null,
    progress: Sim.Progress = .{ .holds = holds },

    fn holds(p: *Sim.Progress) bool {
        const r: *Retry = @fieldParentPtr("progress", p);
        return r.done;
    }

    fn client(r: *Retry, io: Io, addr: Io.net.IpAddress) !void {
        while (true) {
            r.tries += 1;
            if (addr.connect(io, .{ .mode = .stream, .timeout = timeout(std.time.ns_per_s) })) |stream| {
                defer stream.close(io);
                _ = try write(io, stream, "x");
                var byte: [1]u8 = undefined;
                _ = try read(io, stream, &byte);
                r.done = true;
                return;
            } else |err| switch (err) {
                error.Timeout, error.ConnectionRefused => {},
                else => |e| return e,
            }
            if (r.give_up_after) |n| if (r.tries >= n) {
                var reply: Io.Event = .unset;
                try reply.wait(io);
            };
            try io.sleep(.fromSeconds(1), .awake);
        }
    }

    fn serve(io: Io, server: *Io.net.Server) !void {
        const peer = try server.accept(io);
        defer peer.close(io);
        var byte: [1]u8 = undefined;
        _ = try read(io, peer, &byte);
        _ = try write(io, peer, &byte);
    }

    fn main(r: *Retry, left: Io, right: Io, addr: Io.net.IpAddress) !void {
        var server = try addr.listen(right, .{});
        defer server.deinit(right);
        var answering = try right.concurrent(serve, .{ right, &server });
        try r.client(left, addr);
        try answering.await(right);
    }

    /// Two nodes, partitioned for `partitioned`, then the faults end.
    fn run(r: *Retry, sim: *Sim, partitioned: Io.Duration, within: Io.Duration, until: Sim.Settle.Until) !Sim.Settled {
        const address = try Io.net.IpAddress.parseIp4("10.9.0.2", 8000);
        const a = try sim.node("a", .{});
        const b = try sim.node("b", .{ .addresses = &.{address} });
        sim.net().partition(&.{a}, &.{b});
        try sim.start(main, .{ r, a.io(), b.io(), address });
        try t.expectEqual(null, sim.runFor(partitioned));
        return sim.settle(.{ .within = within, .until = until });
    }
};

test "settle heals a partition, and a client that retries finishes within the bound" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .seed = 1 });
    defer sim.deinit();
    var r: Retry = .{};
    const settled = try r.run(sim, .fromSeconds(10), .fromSeconds(30), .finished);
    try t.expect(!r.done or r.tries > 1);
    try t.expect(settled == .live);
    // A connect timeout and a backoff at most after the heal.
    try t.expect(settled.live.nanoseconds <= 2 * std.time.ns_per_s);
    try t.expect(r.done);
    try t.expect(r.tries > 5);
}

test "settle reports a client that gave up as stalled, where it waits, at exactly the bound" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .seed = 1 });
    defer sim.deinit();
    var r: Retry = .{ .give_up_after = 3 };
    const before = sim.now(.awake).nanoseconds;
    const settled = try r.run(sim, .fromSeconds(10), .fromSeconds(30), .{ .holds = &r.progress });
    try t.expect(settled == .stalled);
    try t.expectEqual(@as(i96, 40 * std.time.ns_per_s), sim.now(.awake).nanoseconds - before);
    // The client waits on its reply, the server's task on the network.
    try t.expectEqual(@as(usize, 2), settled.stalled.len);
    for (settled.stalled) |report| {
        try t.expect(report.waiting == .futex);
        try t.expect(report.len > 0);
    }
    var text: std.Io.Writer.Allocating = .init(t.allocator);
    defer text.deinit();
    try text.writer.print("{f}", .{settled});
    try t.expect(std.mem.find(u8, text.written(), "not live: the bound passed with 2 tasks alive") != null);
    try t.expect(std.mem.find(u8, text.written(), "waiting on the futex") != null);
}

test "settle empties the fault plan, so a connect refused by plan goes through" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .seed = 2, .faults = &.{.{
        .at = .{ .chance = .{ .call = .netConnectIp, .per_million = 1_000_000 } },
        .fault = .{ .fail = error.ConnectionRefused },
        .times = 0,
    }} });
    defer sim.deinit();
    var r: Retry = .{};
    const settled = try r.run(sim, .fromSeconds(5), .fromSeconds(30), .finished);
    try t.expect(settled == .live);
    try t.expect(r.done);
}

/// Counts to ten, a second a count.
const Ticks = struct {
    count: u32 = 0,
    goal: u32 = 10,
    progress: Sim.Progress = .{ .holds = holds },

    fn holds(p: *Sim.Progress) bool {
        const self: *Ticks = @fieldParentPtr("progress", p);
        return self.count >= self.goal;
    }

    fn run(self: *Ticks, io: Io) !void {
        for (0..10) |_| {
            try io.sleep(.fromSeconds(1), .awake);
            self.count += 1;
        }
    }
};

test "settle stops at its bound with the run alive, and goes on from there when asked again" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    var ticks: Ticks = .{};
    try sim.start(Ticks.run, .{ &ticks, sim.io() });
    const short = try sim.settle(.{ .within = .fromSeconds(5), .until = .{ .holds = &ticks.progress } });
    try t.expect(short == .stalled);
    try t.expectEqual(@as(usize, 1), short.stalled.len);
    try t.expect(short.stalled[0].waiting == .sleep);
    try t.expectEqual(@as(u32, 5), ticks.count);
    const long = try sim.settle(.{ .within = .fromSeconds(20), .until = .{ .holds = &ticks.progress } });
    try t.expectEqual(@as(i96, 5 * std.time.ns_per_s), long.live.nanoseconds);
    const ended = try sim.settle(.{ .within = .fromSeconds(1), .until = .finished });
    try t.expectEqual(@as(i96, 0), ended.live.nanoseconds);
}

test "settle reports a run that ended without its predicate holding" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    var ticks: Ticks = .{ .goal = 11 };
    try sim.start(Ticks.run, .{ &ticks, sim.io() });
    const settled = try sim.settle(.{ .within = .fromSeconds(60), .until = .{ .holds = &ticks.progress } });
    try t.expect(settled == .ended);
    try t.expect(settled.ended == .finished);
}

/// The client that gives up after four tries, partitioned for a drawn
/// number of seconds: past about seven it gives up before the heal.
fn settlesAfterPartition(_: void, c: *shakedown.Case) !void {
    const seconds = c.source.below(9);
    const sim = try c.sim(.{});
    var r: Retry = .{ .give_up_after = 4 };
    const settled = try r.run(sim, .fromSeconds(@intCast(seconds)), .fromSeconds(30), .{ .holds = &r.progress });
    if (settled != .live) {
        c.note("partitioned {d} s: {f}", .{ seconds, settled });
        return error.NotLive;
    }
}

test "a case that is not live after faults heal is found, shrinks, and replays to the same failure" {
    var report: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, shakedown.check(t.allocator, {}, settlesAfterPartition, .{ .cases = 100, .seed = 5, .diagnostics = &report, .fuzz = false }));
    defer report.deinit();
    try t.expectEqual(error.NotLive, report.err);
    try t.expect(std.mem.find(u8, report.text, "not live") != null);
    var text: std.Io.Writer.Allocating = .init(t.allocator);
    defer text.deinit();
    try text.writer.print("{f}", .{shakedown.Tape{ .choices = report.tape }});
    var replayed: shakedown.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, shakedown.check(t.allocator, {}, settlesAfterPartition, .{ .regressions = &.{text.written()}, .cases = 0, .diagnostics = &replayed, .fuzz = false }));
    defer replayed.deinit();
    try t.expectEqual(error.NotLive, replayed.err);
    try t.expectEqualSlices(u64, report.tape, replayed.tape);
}
