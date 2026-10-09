//! The death tests of a simulation's tasks: a task that overflows its stack
//! must die on the guard page below it, never write past it; and a task
//! that panics under `shakedown.panic` must name the simulation it ran in
//! before std's handler ends the process.
//!
//! Run with no argument, the program spawns itself once per case and passes
//! only when each child died as it had to: of the overflow, by the fault
//! handler below (which exits with `faulted`), by the signal itself, or, on
//! Windows, by the stack overflow or guard-page access exception; of the panic, with the
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
const access_violation: u32 = 0xC0000005;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "overflow")) return overflow(init.gpa);
        if (std.mem.eql(u8, args[1], "panic")) return panicking(init.gpa);
        if (std.mem.eql(u8, args[1], "ordinary-exit")) std.process.exit(5);
        return error.UnknownCase;
    }
    if (args.len != 1) return error.Usage;
    const self = try std.process.executablePathAlloc(init.io, arena);

    var child = try std.process.spawn(init.io, .{ .argv = &.{ self, "overflow" } });
    defer child.kill(init.io);
    // std.process.Child.Term truncates Windows exit statuses to u8. Read the
    // native exception status before wait closes its handle: ordinary exit 5
    // must never stand in for an access violation on the guard page.
    const native_status: ?u32 = if (builtin.os.tag == .windows) try waitWindowsStatus(&child) else null;
    const term = try child.wait(init.io);
    const died = switch (term) {
        .exited => |code| if (native_status) |status| status == faulted or overflowStatus(status) else code == faulted,
        .signal => true,
        .stopped, .unknown => false,
    };
    if (!died) {
        std.debug.print("the child {f}, where its task had to fault on its stack's guard page\n", .{term});
        return error.Survived;
    }

    if (builtin.os.tag == .windows) {
        var ordinary = try std.process.spawn(init.io, .{ .argv = &.{ self, "ordinary-exit" } });
        defer ordinary.kill(init.io);
        const status = try waitWindowsStatus(&ordinary);
        _ = try ordinary.wait(init.io);
        if (status != 5 or overflowStatus(status)) return error.FalsePositive;
    }

    const run = try std.process.run(arena, init.io, .{ .argv = &.{ self, "panic" } });
    const said = std.mem.find(u8, run.stderr, "shakedown: a task panicked in a simulation") != null and
        std.mem.find(u8, run.stderr, "seed 0x2a") != null;
    if (run.term == .exited and run.term.exited == 0 or !said) {
        std.debug.print("the panicking child {f}, and wrote:\n{s}\n", .{ run.term, run.stderr });
        return error.PanicNotReported;
    }
}

fn overflowStatus(status: u32) bool {
    return status == stack_overflow or status == access_violation;
}

/// This death-test child is intentionally awaited outside the Io backend so
/// its full NTSTATUS remains available until Child.wait performs cleanup.
fn waitWindowsStatus(child: *std.process.Child) error{NativeWaitFailed}!u32 {
    const windows = std.os.windows;
    if (windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, null) != .SUCCESS) return error.NativeWaitFailed;
    var info: windows.PROCESS.BASIC_INFORMATION = undefined;
    if (windows.ntdll.NtQueryInformationProcess(child.id.?, .BasicInformation, &info, @sizeOf(windows.PROCESS.BASIC_INFORMATION), null) != .SUCCESS) return error.NativeWaitFailed;
    return @backingInt(info.ExitStatus);
}

fn overflow(gpa: std.mem.Allocator) !void {
    const sim = try shakedown.Sim.init(gpa, .{ .stack_size = .fromRaw(64 * 1024), .watchdog = null });
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
