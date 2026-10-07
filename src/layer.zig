//! `Layer`: an `Io` that overrides some vtable slots and forwards the rest
//! to a base `Io`, with state of its own.
//!
//! A double that copies `std.testing.io.vtable` and replaces a slot keeps
//! the base's userdata, so its state has to live in a global, and two such
//! doubles cannot be stacked. A layer's userdata is its own `state`; every
//! slot it does not override recovers the layer from that pointer and calls
//! the base with the base's userdata.
const std = @import("std");
const Io = std.Io;

const vtable_fields = @typeInfo(Io.VTable).@"struct";

/// One optional function pointer per `Io.VTable` field, all null by
/// default. Built at compile time from `Io.VTable`, so a slot a later Zig
/// adds is an override like any other.
pub const Overrides = blk: {
    var types: [vtable_fields.field_names.len]type = undefined;
    var attrs: [vtable_fields.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (vtable_fields.field_types, 0..) |T, i| {
        const none: ?T = null;
        types[i] = ?T;
        attrs[i] = .{ .default_value_ptr = @ptrCast(&none) }; // safe: a type-erased pointer to a `?T` default, as `@Struct` takes it
    }
    break :blk @Struct(.auto, null, vtable_fields.field_names, &types, &attrs);
};

/// An `Io` whose userdata is `&layer.state`. Every slot not in `overrides`
/// forwards to `base` with the base's own userdata.
///
/// The vtable is one constant per layer type, so `io.vtable == &L.vtable`
/// tells whether an `Io` is a layer of exactly this type, and `L.of` then
/// recovers it. `State` must not be zero-sized: `&layer.state` has to be an
/// address of its own.
pub fn Layer(comptime State: type, comptime overrides: Overrides) type {
    comptime std.debug.assert(@sizeOf(State) > 0);
    return struct {
        state: State,
        base: Io,

        const Self = @This();

        pub const vtable: Io.VTable = blk: {
            var table: Io.VTable = undefined;
            for (vtable_fields.field_names) |name| {
                @field(table, name) = @field(overrides, name) orelse forwarder(Self, name);
            }
            break :blk table;
        };

        pub fn init(base: Io, state: State) Self {
            return .{ .state = state, .base = base };
        }

        /// The layer must not move while the returned `Io` is in use.
        pub fn io(l: *Self) Io {
            return .{ .userdata = &l.state, .vtable = &vtable };
        }

        /// From inside an override: the layer whose state `userdata` is.
        pub fn of(userdata: ?*anyopaque) *Self {
            const state: *State = @ptrCast(@alignCast(userdata.?)); // safe: every Io this type hands out carries `&layer.state`
            return @alignCast(@fieldParentPtr("state", state)); // safe: `state` is the field of a layer, aligned as one
        }
    };
}

/// The forwarder for slot `name` of layer type `L`: one template per
/// parameter count, the largest slot (`async`) having seven.
fn forwarder(comptime L: type, comptime name: []const u8) @FieldType(Io.VTable, name) {
    const Fn = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
    const info = @typeInfo(Fn).@"fn";
    const ret = info.return_type.?;
    const params = info.param_types;
    const Forward = struct {
        inline fn base(u: ?*anyopaque) Io {
            return L.of(u).base;
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
