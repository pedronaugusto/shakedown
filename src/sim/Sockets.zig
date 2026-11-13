//! The sockets of a simulated node, for a seam whose raw socket calls go
//! past the `Io`: a connect from a local endpoint bound before it, as a
//! socket made by hand is bound. `Sim.socketsOf` hands one out for a
//! simulation's `Io`.
const std = @import("std");
const Io = std.Io;
const Core = @import("Core.zig");
const calls = @import("calls.zig");
const net_calls = @import("net/calls.zig");
const Sockets = @This();

/// Private: the node's context.
context: *Core.Context,

pub const ConnectOptions = struct {
    /// The local endpoint, bound before the connect; null connects as
    /// `IpAddress.connect` does. Port 0 takes a free ephemeral port; a
    /// wildcard IP becomes the one the connect goes from. Its family must
    /// be the destination's (`AddressFamilyUnsupported`).
    local: ?Io.net.IpAddress = null,
    /// With `local`: share its port (`SO_REUSEADDR`, `SO_REUSEPORT`). The
    /// bind of a port a stream or listener of the node holds goes through
    /// only when both share it; otherwise, and for a second connection
    /// with the same source and destination, the connect is
    /// `AddressUnavailable`, as a kernel reports a bind it refused there.
    reuse_address: bool = false,
    timeout: Io.Timeout = .none,
    /// The interface to restrict the connection to. A simulated node has
    /// none to name: any but `.none` ends the run `unmodeled`.
    interface: Io.net.Interface = .none,
    mode: Io.net.Socket.Mode = .stream,
    protocol: ?Io.net.Protocol = null,
};

/// A stream connection to `address`, as `IpAddress.connect` makes one on
/// the simulation, from the local endpoint `options` asks for. It is the
/// simulation's connect call, recorded and cancelable as that is.
pub fn connect(s: Sockets, address: *const Io.net.IpAddress, options: ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    if (!options.interface.isNone()) s.context.core.unmodeled(.netConnectIp, null, "a connect restricted to an interface: a simulated node has no interfaces to name");
    const plain: Io.net.IpAddress.ConnectOptions = .{ .mode = options.mode, .protocol = options.protocol, .timeout = options.timeout };
    const local = options.local orelse {
        return calls.vtable.netConnectIp(s.context, address, plain);
    };
    return net_calls.connectBound(s.context, address, plain, &local, options.reuse_address, @returnAddress());
}
