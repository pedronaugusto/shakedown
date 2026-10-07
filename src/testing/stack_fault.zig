//! The death test of a simulation's task stacks: a task that overflows its
//! stack must die on the guard page below it, never write past it.
//!
//! Run with no argument, the program spawns itself and passes only when the
//! child died of the overflow: by the fault handler below, which exits with
//! `faulted`, by the signal itself, or, on Windows, by the stack overflow
//! exception. A child that survives exits 0 and fails the run. Run with an
//! argument, it is that child.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");

pub const std_options: std.Options = .{ .enable_segfault_handler = true };

pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, _: ?std.debug.CpuContextPtr) noreturn {
        std.debug.print("{s} at 0x{x}, as expected\n", .{ name, addr orelse 0 });
        std.process.exit(faulted);
    }
};

const faulted = 86;

/// Windows ends a thread whose stack overflowed with this status.
const stack_overflow: u32 = 0xC00000FD;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2) return overflow(init.gpa);
    if (args.len != 1) return error.Usage;
    const self = try std.process.executablePathAlloc(init.io, arena);
    var child = try std.process.spawn(init.io, .{ .argv = &.{ self, "child" } });
    const term = try child.wait(init.io);
    const died = switch (term) {
        .exited => |code| code == faulted or (builtin.os.tag == .windows and @as(u32, @bitCast(@as(i32, code))) == stack_overflow),
        .signal => true,
        .stopped, .unknown => false,
    };
    if (!died) {
        std.debug.print("the child {f}, where its task had to fault on its stack's guard page\n", .{term});
        return error.Survived;
    }
}

fn overflow(gpa: std.mem.Allocator) !void {
    const sim = try shakedown.Sim.init(gpa, .{ .stack_size = 64 * 1024, .watchdog = null });
    defer sim.deinit();
    const outcome = sim.run(deep, .{ sim.io(), 1 << 20 });
    std.debug.print("survived the overflow: {any}\n", .{outcome});
}

/// Recurses with a page of locals a frame, far past any task's stack.
fn deep(io: Io, depth: u64) error{Canceled}!void {
    var page: [4096]u8 = undefined;
    @memset(@as(*volatile [4096]u8, &page), @truncate(depth));
    if (depth == 0) return io.checkCancel();
    try @call(.never_inline, deep, .{ io, depth - 1 });
    std.mem.doNotOptimizeAway(&page);
}
