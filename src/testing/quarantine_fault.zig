//! The death test of `alloc.Quarantine`: memory it has closed must kill
//! the process that touches it.
//!
//! Run with no argument, the program spawns itself once per case and passes
//! only when every child died of its access: by the fault handler below,
//! which exits with `faulted`, or by the signal itself. A child that
//! survives exits 0 and fails the run. Run with a case name, it is that
//! child.
const std = @import("std");
const shakedown = @import("shakedown");

pub const std_options: std.Options = .{ .enable_segfault_handler = true };

pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, _: ?std.debug.CpuContextPtr) noreturn {
        std.debug.print("{s} at 0x{x}, as expected\n", .{ name, addr orelse 0 });
        std.process.exit(faulted);
    }
};

const faulted = 86;

const cases = [_][]const u8{ "use-after-free", "overflow", "foreign-free" };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2) return touch(args[1]);
    if (args.len != 1) return error.Usage;
    if (!shakedown.alloc.Quarantine.supported) return;
    const self = try std.process.executablePathAlloc(init.io, arena);
    for (cases) |case| {
        var child = try std.process.spawn(init.io, .{ .argv = &.{ self, case } });
        const term = try child.wait(init.io);
        const died = switch (term) {
            .exited => |code| code == faulted,
            .signal => true,
            .stopped, .unknown => false,
        };
        if (!died) {
            std.debug.print("{s}: the child {f}, where it had to fault\n", .{ case, term });
            return error.Survived;
        }
    }
}

fn touch(case: []const u8) !void {
    var quarantine: shakedown.alloc.Quarantine = .init(.{ .guard = .after });
    defer quarantine.deinit();
    const gpa = quarantine.allocator();
    const block = try gpa.alloc(u8, 40);
    @memset(block, 1);
    if (std.mem.eql(u8, case, "foreign-free")) {
        // Memory the quarantine never gave out: a free it must stop at, in
        // every build, rather than corrupt its tables.
        const foreign = try std.heap.page_allocator.alloc(u8, 40);
        defer std.heap.page_allocator.free(foreign);
        gpa.free(foreign);
        std.debug.print("survived the {s}\n", .{case});
        return;
    }
    const target: *volatile u8 = if (std.mem.eql(u8, case, "use-after-free")) at: {
        gpa.free(block);
        break :at &block[0];
    } else if (std.mem.eql(u8, case, "overflow")) at: {
        // One past the end, as an off-by-one writes it.
        break :at @ptrFromInt(@intFromPtr(block.ptr) + block.len); // safe: the address is the guard page's first byte, which must fault
    } else return error.UnknownCase;
    target.* = 2;
    std.debug.print("survived the {s}\n", .{case});
}
