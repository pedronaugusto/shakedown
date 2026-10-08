//! A node's stable Io namespace and cooperative lifecycle.
const std = @import("std");
const Io = std.Io;
const Core = @import("Core.zig");
const Fs = @import("Fs.zig");
const calls = @import("calls.zig");
const Routing = @import("routing.zig").Routing;
const Node = @This();
pub const Options = struct { addresses: []const Io.net.IpAddress = &.{}, fs: ?Fs.Options = .{} };
context: *Core.Context,
name: []u8,
outer: ?Routing = null,
pub fn io(n: *Node) Io {
    if (n.outer) |*outer| return outer.io();
    return .{ .userdata = n.context, .vtable = &calls.vtable };
}
pub fn fs(n: *Node) *Fs {
    return &n.context.disk.?;
}
pub fn kill(n: *Node) void {
    const c = n.context.core;
    c.network.kill(n.context.node);
    for (c.tasks.items) |task| if (task.node == n.context.node) {
        c.requestCancel(task);
    };
    _ = c.wakeFutex(@intFromPtr(&c.network.change), std.math.maxInt(u32)); // safe: the network epoch has a stable address until Core.deinit
}
pub fn crash(n: *Node, policy: Fs.CrashPolicy) Fs.CrashError!void {
    n.kill();
    if (n.context.disk) |*disk| try disk.crash(policy);
}
/// Restart is explicit and cooperative: await cancellation before restarting.
pub fn restart(n: *Node, comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) error{ OutOfMemory, SystemResources, NodeBusy, SimulationEnded }!void {
    const c = n.context.core;
    if (c.outcome != null) return error.SimulationEnded;
    for (c.tasks.items) |task| if (task.node == n.context.node and (task.state == .ready or task.state == .running or task.state == .parked or task.state == .deferred)) return error.NodeBusy;
    const Args = @TypeOf(args);
    const Start = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const a: *const Args = @ptrCast(@alignCast(context)); // safe: copied by Core.spawn
            const err: *?anyerror = @ptrCast(@alignCast(result)); // safe: allocated as optional error below
            const value = @call(.auto, f, a.*);
            err.* = switch (@typeInfo(@TypeOf(value))) {
                .error_union => if (value) |_| null else |e| e,
                .error_set => value,
                else => null,
            };
        }
    };
    const task = try c.spawn(.{ .node = Start.start }, std.mem.asBytes(&args), .of(Args), @sizeOf(?anyerror), .of(?anyerror), .ready);
    task.node = n.context.node;
    task.io_node = n.context.node;
}
