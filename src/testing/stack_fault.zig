//! The death tests of a simulation's tasks: a task that overflows its stack
//! must die on the guard page below it, never write past it; and a task
//! that panics under `shakedown.panic` must name the simulation it ran in
//! before std's handler ends the process.
//!
//! Run with no argument, the program spawns itself once per case and passes
//! only when each child died as it had to: of the overflow, by the fault
//! handler below (which exits with `faulted`), by the signal itself, or, on
//! Windows, by the stack overflow exception; of the panic, with the
//! simulation's report on its stderr. Run with a case name, it is that
//! child.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");

pub const panic = shakedown.panic;

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
    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "overflow")) return overflow(init.gpa);
        if (std.mem.eql(u8, args[1], "panic")) return panicking(init.gpa);
        return error.UnknownCase;
    }
    if (args.len != 1) return error.Usage;
    const self = try std.process.executablePathAlloc(init.io, arena);

    var child = try std.process.spawn(init.io, .{ .argv = &.{ self, "overflow" } });
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

    const run = try std.process.run(arena, init.io, .{ .argv = &.{ self, "panic" } });
    const said = std.mem.find(u8, run.stderr, "shakedown: a task panicked in a simulation") != null and
        std.mem.find(u8, run.stderr, "seed 0x2a") != null;
    if (run.term == .exited and run.term.exited == 0 or !said) {
        std.debug.print("the panicking child {f}, and wrote:\n{s}\n", .{ run.term, run.stderr });
        return error.PanicNotReported;
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

fn panicking(gpa: std.mem.Allocator) !void {
    const sim = try shakedown.Sim.init(gpa, .{ .seed = 42, .watchdog = null });
    defer sim.deinit();
    _ = sim.run(boom, .{sim.io()});
    std.debug.print("survived the panic\n", .{});
}

fn boom(io: Io) !void {
    try io.sleep(.fromSeconds(1), .awake);
    @panic("boom");
}
