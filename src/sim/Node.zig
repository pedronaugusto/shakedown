//! A node's stable Io namespace and cooperative lifecycle.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Core = @import("Core.zig");
const Fs = @import("Fs.zig");
const calls = @import("calls.zig");
const Routing = @import("routing.zig").Routing;
const nanoseconds = @import("../nanoseconds.zig");
const Node = @This();
/// A node's clocks against the simulation's: set, or drawn from the source.
pub const Clock = @import("options.zig").NodeClock;
pub const Options = struct {
    addresses: []const Io.net.IpAddress = &.{},
    fs: ?Fs.Options = .{},
    /// The node's clocks: by default the simulation's own. Node zero, the
    /// test's (`Sim.io`), always keeps the simulation's time, which
    /// `Sim.now` reads.
    clock: Clock = .{ .set = .{} },
};
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
/// What `which` reads on this node: the simulation's time, skewed as the
/// node's clock says. Drawing nothing, it never steps the wall clock.
pub fn now(n: *Node, which: Io.Clock) Io.Timestamp {
    return n.context.core.nowOn(n.context.node, which);
}
/// A wall-clock step on this node, as NTP or an operator makes it, backwards
/// too: only its `.real` changes, to read `to`. Timers waiting on its real
/// time keep the readings they wait for, so a step forward fires those it
/// passes and one back puts them off. The simulation's time and the other
/// nodes' clocks do not move.
pub fn stepReal(n: *Node, to: Io.Timestamp) void {
    const c = n.context.core;
    const from = nanoseconds.reading(Core, c.nowOn(n.context.node, .real)).raw();
    c.jump(n.context.node, .{ 0, 0, nanoseconds.reading(Core, to).raw() -| from });
}
/// The node's machine slept for `d`: its boot and real clocks jump forward
/// by `d`, its awake clock does not, and the timers on boot or real time it
/// passes fire. Monotonic time never goes back: `d` is not negative. The
/// simulation's time and the other nodes' clocks do not move.
pub fn suspendFor(n: *Node, d: Io.Duration) void {
    const by = nanoseconds.span(d).raw();
    aegis.assert.invariant(by >= 0, "a machine sleeps forward: monotonic time never goes back");
    n.context.core.jump(n.context.node, .{ 0, by, by });
}
pub fn kill(n: *Node) void {
    const c = n.context.core;
    c.endProcessesOn(n.context.node);
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
    for (c.tasks.items) |task| if (task.node == n.context.node and switch (task.state.current()) {
        .ready, .running, .parked, .deferred => true,
        .idle, .done, .abandoned => false,
    }) return error.NodeBusy;
    const Args = @TypeOf(args);
    const Start = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const a: *const Args = @ptrCast(@alignCast(context)); // aegis: no-danger(A019): copied by Core.spawn
            const err: *?anyerror = @ptrCast(@alignCast(result)); // aegis: no-danger(A019): allocated as optional error below
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
    task.io_context = n.context;
}
