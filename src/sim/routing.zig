//! Select a node before entering the one shared outer fault layer.
const std = @import("std");
const Io = std.Io;
const Core = @import("Core.zig");
const layer = @import("../layer.zig");
const State = struct { context: *Core.Context };
const Overrides = blk: {
    var overrides: layer.Overrides = .{};
    for (@typeInfo(Io.VTable).@"struct".field_names) |name| @field(overrides, name) = forwarder(name);
    break :blk overrides;
};
pub const Routing = layer.Layer(State, Overrides);
fn forwarder(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const Fn = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
    const info = @typeInfo(Fn).@"fn";
    const ret = info.return_type.?;
    const params = info.param_types;
    const Forward = struct {
        inline fn base(u: ?*anyopaque) Io {
            const l = Routing.of(u);
            _ = Core.of(l.state.context);
            return l.base;
        }
    };
    return switch (params.len) {
        1 => &struct {
            fn f(u: ?*anyopaque) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata);
            }
        }.f,
        2 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata, a);
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata, a, c);
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata, a, c, d);
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?, e: params[4].?) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata, a, c, d, e);
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?, e: params[4].?, g: params[5].?) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata, a, c, d, e, g);
            }
        }.f,
        7 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?, e: params[4].?, g: params[5].?, h: params[6].?) ret {
                const b = Forward.base(u);
                return @field(b.vtable, name)(b.userdata, a, c, d, e, g, h);
            }
        }.f,
        else => @compileError("Io.VTable." ++ name ++ " has more parameters than a Layer forwards"),
    };
}
