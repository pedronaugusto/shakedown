//! How a simulation runs its tasks, one at a time: each task is a context
//! that runs until it hands control to another.
//!
//! - **fibers**: std's `Io.fiber.contextSwitch` on stacks of our own, with
//!   our own entry trampoline. x86_64 and aarch64 outside Windows.
//! - **win32**: Win32 fibers, which keep the thread's stack bounds right
//!   for stack probes and unwinding.
//! - **threads**: an OS thread per task, and a baton passed over a futex,
//!   so exactly one runs. Everywhere threads exist; about a hundred times
//!   slower to switch.
//!
//! A context runs `entry(arg)`, which never returns: when a task ends, the
//! scheduler switches away from it for good, or reuses it for another task
//! by switching back into its loop.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

pub const Kind = enum { fibers, win32, threads };

const fibers_supported = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => builtin.os.tag != .windows and builtin.os.tag != .uefi and builtin.os.tag != .freestanding,
    else => false,
};
const win32_supported = builtin.os.tag == .windows;
const threads_supported = !builtin.single_threaded and builtin.os.tag != .wasi and builtin.os.tag != .freestanding;

/// Whether `kind` runs on this target.
pub fn available(kind: Kind) bool {
    return switch (kind) {
        .fibers => fibers_supported,
        .win32 => win32_supported,
        .threads => threads_supported,
    };
}

/// The fastest executor this target has, or null when it has none.
pub const best: ?Kind = if (win32_supported) .win32 else if (fibers_supported) .fibers else if (threads_supported) .threads else null;

/// Called with the C convention, so the trampoline knows where its argument goes.
pub const Entry = *const fn (arg: *anyopaque) callconv(.c) noreturn;

/// A context: a task's, or the driver's, which is the thread that runs the
/// simulation and gets control back when a run pauses or ends.
pub const Context = struct {
    kind: Kind,
    fiber: if (fibers_supported) Fiber else void = if (fibers_supported) .{} else {},
    win32: ?*anyopaque = null,
    thread: Baton = .{},
};

const Fiber = struct {
    regs: std.Io.fiber.Context = undefined,
    /// The mapping: a guard page, then the stack. Empty for the driver.
    stack: []align(std.heap.page_size_min) u8 = &.{},
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
/// `start` has been called on it where it will stay. `stack_size` is the
/// usable stack, a guard page below it.
pub fn create(kind: Kind, entry: Entry, arg: *anyopaque, stack_size: usize) CreateError!Context {
    var c: Context = .{ .kind = kind };
    if (kind == .fibers) {
        if (!fibers_supported) unreachable; // unreachable: Sim.init refuses an executor the target lacks
        try createFiber(&c.fiber, entry, arg, stack_size);
    }
    return c;
}

/// Makes the fiber or the thread of a context, which must not move from
/// here: they find their entry through it.
pub fn start(c: *Context, entry: Entry, arg: *anyopaque, stack_size: usize) CreateError!void {
    c.thread.entry = entry;
    c.thread.arg = arg;
    switch (c.kind) {
        .fibers => {},
        .win32 => {
            if (!win32_supported) unreachable; // unreachable: Sim.init refuses an executor the target lacks
            // Reserve the whole stack, commit its first pages: the system
            // grows it through its guard page as it is used.
            c.win32 = win32.CreateFiberEx(@min(stack_size, 64 * 1024), stack_size, win32.fiber_flag_float_switch, win32Start, &c.thread) orelse return error.SystemResources;
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

/// Releases a task context that is not running: its stack, its fiber, or
/// its thread, which exits without unwinding whatever it was doing.
pub fn destroy(c: *Context) void {
    switch (c.kind) {
        .fibers => if (fibers_supported) {
            if (c.fiber.stack.len > 0) std.heap.PageAllocator.unmap(c.fiber.stack);
        },
        .win32 => if (win32_supported) {
            if (c.win32) |f| win32.DeleteFiber(f);
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

/// Makes the calling thread a driver context. `finishDriver` undoes it.
pub fn initDriver(kind: Kind) CreateError!Context {
    var c: Context = .{ .kind = kind };
    if (kind == .win32) if (win32_supported) {
        if (win32.IsThreadAFiber().toBool()) {
            c.win32 = windows.teb().NtTib.DUMMYUNIONNAME.FiberData;
        } else {
            c.win32 = win32.ConvertThreadToFiber(null) orelse return error.SystemResources;
            c.thread.exit = true; // converted here: convert back when done
        }
    };
    return c;
}

pub fn finishDriver(c: *Context) void {
    if (c.kind == .win32) if (win32_supported) {
        if (c.thread.exit) _ = win32.ConvertFiberToThread();
    };
}

/// Saves the running context into `from` and runs `to`. Returns when some
/// context switches back to `from`.
pub inline fn switchTo(from: *Context, to: *Context) void {
    switch (from.kind) {
        .fibers => if (fibers_supported) {
            _ = std.Io.fiber.contextSwitch(&.{ .old = &from.fiber.regs, .new = &to.fiber.regs });
        } else unreachable, // unreachable: Sim.init refuses an executor the target lacks
        .win32 => if (win32_supported) win32.SwitchToFiber(to.win32.?) else unreachable, // unreachable: Sim.init refuses an executor the target lacks
        .threads => {
            pass(&to.thread);
            wait(&from.thread);
        },
    }
}

// Fibers.

fn createFiber(f: *Fiber, entry: Entry, arg: *anyopaque, stack_size: usize) CreateError!void {
    const page = std.heap.pageSize();
    const usable = std.mem.alignForward(usize, @max(stack_size, 16 * 1024), page);
    const len = usable + page;
    const base = std.heap.PageAllocator.map(len, .fromByteUnits(page)) orelse return error.OutOfMemory;
    const stack: []align(std.heap.page_size_min) u8 = @alignCast(base[0..len]); // safe: PageAllocator.map returns page-aligned memory
    // The guard page: an overflow faults instead of writing past the stack.
    if (std.posix.errno(std.posix.system.mprotect(stack.ptr, page, std.mem.zeroes(std.posix.PROT))) != .SUCCESS) {
        std.heap.PageAllocator.unmap(stack);
        return error.SystemResources;
    }
    const top = @intFromPtr(stack.ptr) + len; // safe: an address, kept as a number to lay out the first frame
    f.stack = stack;
    // The first frame: what the trampoline reads, at the top of the stack.
    const slots: [*]usize = @ptrFromInt(top - 4 * @sizeOf(usize));
    slots[0] = 0; // x86_64: the return address slot of a function entered by a jump
    slots[1] = @intFromPtr(arg); // safe: the argument, read back as a pointer by the trampoline
    slots[2] = @intFromPtr(entry); // safe: the function, called by the trampoline
    slots[3] = 0;
    f.regs = switch (builtin.cpu.arch) {
        .x86_64 => .{ .rsp = top - 4 * @sizeOf(usize), .rbp = 0, .rip = @intFromPtr(&trampoline) }, // safe: the address of the naked entry
        .aarch64 => .{ .sp = top - 4 * @sizeOf(usize), .fp = 0, .pc = @intFromPtr(&trampoline) }, // safe: the address of the naked entry
        else => unreachable, // unreachable: fibers_supported admits only these
    };
}

/// The first instructions of a fiber: the argument and the function from
/// the top of its stack, then a jump into the function, which never
/// returns. Frame pointers are zero, so a stack walk ends here.
fn trampoline() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        // [rsp] = 0 (the return address slot), [rsp+8] = arg, [rsp+16] = entry.
        // rsp is 8 mod 16, as at the entry of a called function.
        .x86_64 => asm volatile (
            \\ movq 8(%%rsp), %%rdi
            \\ jmpq *16(%%rsp)
        ),
        // [sp] = 0, [sp+8] = arg, [sp+16] = entry; sp is 16-aligned.
        .aarch64 => asm volatile (
            \\ ldr x0, [sp, #8]
            \\ ldr x9, [sp, #16]
            \\ mov x30, xzr
            \\ br x9
        ),
        else => unreachable, // unreachable: fibers_supported admits only these
    }
}

// Win32 fibers.

const win32 = struct {
    const fiber_flag_float_switch: u32 = 1;
    extern "kernel32" fn CreateFiberEx(commit: usize, reserve: usize, flags: u32, start: *const fn (?*anyopaque) callconv(.winapi) void, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn DeleteFiber(fiber: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn SwitchToFiber(fiber: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn ConvertThreadToFiber(param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ConvertFiberToThread() callconv(.winapi) windows.BOOL;
    extern "kernel32" fn IsThreadAFiber() callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ExitThread(code: u32) callconv(.winapi) noreturn;
    const stack_size_param_is_a_reservation: u32 = 0x10000;
    extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?windows.HANDLE;
};

fn win32ThreadStart(param: ?*anyopaque) callconv(.winapi) u32 {
    threadMain(@ptrCast(@alignCast(param.?))); // safe: `start` passes the context's baton
    return 0;
}

fn win32Start(param: ?*anyopaque) callconv(.winapi) void {
    const b: *Baton = @ptrCast(@alignCast(param.?)); // safe: `start` passes the context's baton, which holds the entry
    b.entry.?(b.arg.?);
}

// Threads.

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
