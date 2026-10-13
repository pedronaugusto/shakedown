//! How a simulation runs its tasks, one at a time: each task is a context
//! that runs until it hands control to another.
//!
//! - **fibers**: shuttle's contexts, each on a stack of its own with a guard
//!   below it. x86_64, aarch64 and riscv64, Windows included: the switch
//!   keeps the thread information block's stack bounds on the running stack.
//! - **threads**: an OS thread per task, and a baton passed over a futex,
//!   so exactly one runs. Everywhere threads exist; about a hundred times
//!   slower to switch.
//!
//! A context runs `entry(arg)`, which never returns: when a task ends, the
//! scheduler switches away from it for good, or reuses it for another task
//! by switching back into its loop.
const builtin = @import("builtin");
const std = @import("std");
const shuttle = @import("shuttle");
const windows = std.os.windows;

pub const Kind = enum { fibers, threads };

const fibers_supported = shuttle.supported and switch (builtin.os.tag) {
    .freestanding, .uefi, .wasi, .other => false,
    else => true,
};
const threads_supported = !builtin.single_threaded and builtin.os.tag != .wasi and builtin.os.tag != .freestanding;

/// Whether `kind` runs on this target.
pub fn available(kind: Kind) bool {
    return switch (kind) {
        .fibers => fibers_supported,
        .threads => threads_supported,
    };
}

/// The fastest executor this target has, or null when it has none.
pub const best: ?Kind = if (fibers_supported) .fibers else if (threads_supported) .threads else null;

/// The task's function; it never returns.
pub const Entry = *const fn (arg: *anyopaque) noreturn;

/// A context: a task's, or the driver's, which is the thread that runs the
/// simulation and gets control back when a run pauses or ends.
pub const Context = struct {
    kind: Kind,
    /// The fiber, once `start` made it; the driver's is the thread's own.
    fiber: if (fibers_supported) ?shuttle.Context else void = if (fibers_supported) null else {},
    thread: Baton = .{},
};

const Baton = struct {
    /// 1 when this context may run.
    turn: std.atomic.Value(u32) = .init(0),
    /// Set to make the thread exit when it next gets the baton.
    exit: bool = false,
    handle: ?Thread = null,
    entry: ?Entry = null,
    arg: ?*anyopaque = null,
};

/// A task's thread. On Windows a thread of our own: std's `Thread.join`
/// there requires the thread to have returned through std's entry, and a
/// thread the executor ends never does.
const Thread = if (builtin.os.tag == .windows) windows.HANDLE else std.Thread;

pub const CreateError = error{ OutOfMemory, SystemResources };

/// A task context that will run `entry(arg)` when first switched to, once
/// `start` has been called on it where it will stay.
pub fn create(kind: Kind) Context {
    return .{ .kind = kind };
}

/// Makes the fiber or the thread of a context, which must not move from
/// here: they find their entry through it. `stack_size` is the usable
/// stack, a guard below it.
pub fn start(c: *Context, entry: Entry, arg: *anyopaque, stack_size: usize) CreateError!void {
    c.thread.entry = entry;
    c.thread.arg = arg;
    switch (c.kind) {
        .fibers => {
            if (!fibers_supported) unreachable; // unreachable: Sim.init refuses an executor the target lacks
            var stack = shuttle.Stack.init(.{ .size = .fromRaw(@max(stack_size, 16 * 1024)) }) catch |err| return switch (err) {
                error.SystemResources => error.SystemResources,
                error.Overflow => error.OutOfMemory,
            };
            errdefer stack.deinit();
            c.fiber = shuttle.Context.init(stack, fiberStart, &c.thread) catch return error.SystemResources;
        },
        .threads => {
            if (!threads_supported) unreachable; // unreachable: Sim.init refuses an executor the target lacks
            if (builtin.os.tag == .windows) {
                c.thread.handle = win32.CreateThread(null, stack_size, win32ThreadStart, &c.thread, win32.stack_size_param_is_a_reservation, null) orelse return error.SystemResources;
                return;
            }
            c.thread.handle = std.Thread.spawn(.{ .stack_size = stack_size }, threadMain, .{&c.thread}) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SystemResources,
            };
        },
    }
}

/// Releases a task context that is not running: its fiber and stack, or
/// its thread, which exits without unwinding whatever it was doing.
pub fn destroy(c: *Context) void {
    switch (c.kind) {
        .fibers => if (fibers_supported) if (c.fiber) |*f| {
            var stack = f.deinit();
            stack.deinit();
        },
        .threads => if (c.thread.handle) |handle| {
            c.thread.exit = true;
            pass(&c.thread);
            if (builtin.os.tag == .windows) {
                _ = windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null);
                windows.CloseHandle(handle);
            } else handle.join();
        },
    }
    c.* = undefined;
}

/// The calling thread's context, as the driver.
pub fn initDriver(kind: Kind) Context {
    var c: Context = .{ .kind = kind };
    if (kind == .fibers) if (fibers_supported) {
        c.fiber = .{};
    };
    return c;
}

/// Saves the running context into `from` and runs `to`. Returns when some
/// context switches back to `from`.
pub inline fn switchTo(from: *Context, to: *Context) void {
    switch (from.kind) {
        .fibers => if (fibers_supported) {
            _ = shuttle.switchTo(&from.fiber.?, &to.fiber.?, null);
        } else unreachable, // unreachable: Sim.init refuses an executor the target lacks
        .threads => {
            pass(&to.thread);
            wait(&from.thread);
        },
    }
}

/// The return addresses of the running fiber `c`, innermost first into
/// `out`, from the frame that returns to `first_address` when it is one of
/// them, to the fiber's first frame.
pub fn fiberTrace(c: *const Context, first_address: usize, out: []usize) []usize {
    if (!fibers_supported) return out[0..0];
    return c.fiber.?.traceFrom(first_address, out);
}

fn fiberStart(arg: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
    const b: *Baton = @ptrCast(@alignCast(arg.?)); // safe: `start` passes the context's baton, which holds the entry
    b.entry.?(b.arg.?);
}

// Threads.

const win32 = struct {
    extern "kernel32" fn ExitThread(code: u32) callconv(.winapi) noreturn;
    const stack_size_param_is_a_reservation: u32 = 0x10000;
    extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?windows.HANDLE;
};

fn win32ThreadStart(param: ?*anyopaque) callconv(.winapi) u32 {
    threadMain(@ptrCast(@alignCast(param.?))); // safe: `start` passes the context's baton
    return 0;
}

fn threadMain(b: *Baton) void {
    wait(b);
    b.entry.?(b.arg.?);
}

/// The real system's futex, for handing the baton between threads.
fn real() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn pass(b: *Baton) void {
    b.turn.store(1, .release);
    real().futexWake(u32, &b.turn.raw, 1);
}

/// Waits for this context's turn. A context told to exit leaves its thread
/// there, without unwinding.
fn wait(b: *Baton) void {
    while (b.turn.load(.acquire) == 0) real().futexWaitUncancelable(u32, &b.turn.raw, 0);
    b.turn.store(0, .monotonic);
    if (b.exit) exitThread();
}

fn exitThread() noreturn {
    if (builtin.os.tag == .windows) win32.ExitThread(0);
    if (builtin.link_libc) std.c.pthread_exit(null);
    if (builtin.os.tag == .linux) std.os.linux.exit(0);
    @panic("a simulation thread cannot exit on this target");
}

test "a fiber's trace from a call site it kept ends at its first frame" {
    if (!fibers_supported or builtin.omit_frame_pointer) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = undefined;
        var task: Context = undefined;
        var addresses: [64]usize = undefined;
        var len: usize = 0;
        fn run(_: *anyopaque) noreturn {
            len = fiberTrace(&task, @returnAddress(), &addresses).len;
            switchTo(&task, &driver);
            unreachable; // unreachable: the test destroys the fiber without switching back to it
        }
    };
    Probe.driver = initDriver(.fibers);
    Probe.task = create(.fibers);
    try start(&Probe.task, Probe.run, &Probe.len, 64 * 1024);
    defer destroy(&Probe.task);
    switchTo(&Probe.driver, &Probe.task);
    // The run's frames, and the walk stopped there, short of the room it had.
    try std.testing.expect(Probe.len >= 1 and Probe.len < Probe.addresses.len);
}
