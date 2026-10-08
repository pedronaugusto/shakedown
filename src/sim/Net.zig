//! Topology controls for the simulation's owned network.
const std = @import("std");
const Core = @import("Core.zig");
const Node = @import("Node.zig");
const Model = @import("net/Model.zig");
const Net = @This();
pub const Options = Model.Options;
pub const Dist = Model.Dist;
pub const Link = Model.Link;
core: *Core,
fn changed(n: *Net) void {
    _ = n.core.wakeFutex(@intFromPtr(&n.core.network.change), std.math.maxInt(u32)); // safe: the network epoch has a stable address until Core.deinit
}
fn id(n: *Net, node: *Node) u32 {
    std.debug.assert(node.context.core == n.core);
    return node.context.node;
}
pub fn link(n: *Net, a: *Node, b: *Node, value: Link) Model.Error!void {
    try n.core.network.configure(n.id(a), n.id(b), value);
}
pub fn partition(n: *Net, a: []const *Node, b: []const *Node) void {
    for (a) |left| for (b) |right| n.core.network.status(n.id(left), n.id(right), null, true);
    n.changed();
}
pub fn heal(n: *Net) void {
    for (0..n.core.network.node_count) |a| for (a..n.core.network.node_count) |b| n.core.network.status(@intCast(a), @intCast(b), null, false);
    n.changed();
}
pub fn hold(n: *Net, a: *Node, b: *Node) void {
    n.core.network.status(n.id(a), n.id(b), true, null);
    n.changed();
}
pub fn release(n: *Net, a: *Node, b: *Node) void {
    n.core.network.status(n.id(a), n.id(b), false, null);
    n.changed();
}
pub fn resetConnections(n: *Net, a: *Node, b: *Node) void {
    n.core.network.reset(n.id(a), n.id(b));
    n.changed();
}
pub fn dns(n: *Net, name: []const u8, node: *Node) error{OutOfMemory}!void {
    const bytes = try n.core.gpa.dupe(u8, std.mem.trimEnd(u8, name, "."));
    errdefer n.core.gpa.free(bytes);
    for (bytes) |*byte| byte.* = std.ascii.toLower(byte.*);
    const result = try n.core.network.names.getOrPut(n.core.gpa, bytes);
    if (result.found_existing) n.core.gpa.free(bytes);
    result.value_ptr.* = n.id(node);
}
