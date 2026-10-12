//! How a simulation runs its tasks, one at a time: each task is a context
//! that runs until it hands control to another.
//!
//! - **fibers**: a context switch of our own (std's, keeping the link
//!   register on aarch64) on stacks of our own, with our own entry
//!   trampoline. x86_64 and aarch64 outside Windows.
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
    /// ThreadSanitizer's record of the fiber, in a build it instruments.
    tsan: if (builtin.sanitize_thread) ?*anyopaque else void = if (builtin.sanitize_thread) null else {},
};

/// ThreadSanitizer follows a thread by its stack: a switch it is not told of
/// leaves it reading one fiber's stack as another's, and it crashes. Each
/// fiber is made known to it, and each switch announced, synchronizing.
const tsan = struct {
    extern fn __tsan_get_current_fiber() *anyopaque;
    extern fn __tsan_create_fiber(flags: c_uint) *anyopaque;
    extern fn __tsan_destroy_fiber(fiber: *anyopaque) void;
    extern fn __tsan_switch_to_fiber(fiber: *anyopaque, flags: c_uint) void;
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
            if (builtin.sanitize_thread) if (c.fiber.tsan) |fiber| tsan.__tsan_destroy_fiber(fiber);
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
    if (kind == .fibers and fibers_supported and builtin.sanitize_thread) c.fiber.tsan = tsan.__tsan_get_current_fiber();
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
            if (builtin.sanitize_thread) tsan.__tsan_switch_to_fiber(to.fiber.tsan.?, 0);
            contextSwitch(&.{ .old = &from.fiber.regs, .new = &to.fiber.regs });
        } else unreachable, // unreachable: Sim.init refuses an executor the target lacks
        .win32 => if (win32_supported) win32.SwitchToFiber(to.win32.?) else unreachable, // unreachable: Sim.init refuses an executor the target lacks
        .threads => {
            pass(&to.thread);
            wait(&from.thread);
        },
    }
}

// Fibers.

/// std's `Io.fiber.contextSwitch`, with two registers declared clobbered by
/// the names the compiler takes. On aarch64 the link register as `lr`: std
/// names it `x30`, which the compiler does not take for it, and an optimized
/// build kept a pointer in it across the switch, the fiber's calls overwrote
/// it, and the code that switched read through a code address once back. On
/// x86_64 the vector registers as `xmm` and `ymm`: std names them `zmm`,
/// which a CPU without AVX-512 does not have, so the compiler kept values in
/// `xmm` registers across the switch for the fiber to overwrite.
inline fn contextSwitch(s: *const std.Io.fiber.Switch) void {
    switch (builtin.cpu.arch) {
        .aarch64 => _ = asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ adr x5, 0f
            \\ ldp x4, fp, [x2]
            \\ str x5, [x0, #16]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const std.Io.fiber.Switch),
            : [message_to_send] "{x1}" (s),
            : .{
              .x0 = true,
              .x1 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x30 = true,
              .lr = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .ffr = true,
              .memory = true,
            }),
        .x86_64 => _ = asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const std.Io.fiber.Switch),
            : [message_to_send] "{rsi}" (s),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .xmm0 = true,
              .xmm1 = true,
              .xmm2 = true,
              .xmm3 = true,
              .xmm4 = true,
              .xmm5 = true,
              .xmm6 = true,
              .xmm7 = true,
              .xmm8 = true,
              .xmm9 = true,
              .xmm10 = true,
              .xmm11 = true,
              .xmm12 = true,
              .xmm13 = true,
              .xmm14 = true,
              .xmm15 = true,
              .ymm0 = true,
              .ymm1 = true,
              .ymm2 = true,
              .ymm3 = true,
              .ymm4 = true,
              .ymm5 = true,
              .ymm6 = true,
              .ymm7 = true,
              .ymm8 = true,
              .ymm9 = true,
              .ymm10 = true,
              .ymm11 = true,
              .ymm12 = true,
              .ymm13 = true,
              .ymm14 = true,
              .ymm15 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        else => unreachable, // unreachable: fibers_supported admits only these
    }
}

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
    if (builtin.sanitize_thread) f.tsan = tsan.__tsan_create_fiber(0);
    // The first frame: what the trampoline reads, at the top of the stack, which
    // is page-aligned. A function entered by `call` on x86_64 finds its stack
    // 8 mod 16, the return address just pushed; aarch64 keeps it 16-aligned.
    // Code built optimized moves 16 bytes at a time to and from the stack on
    // that promise, so a stack off by 8 faults there.
    const frame = switch (builtin.cpu.arch) {
        .x86_64 => top - 5 * @sizeOf(usize),
        .aarch64 => top - 4 * @sizeOf(usize),
        else => unreachable, // unreachable: fibers_supported admits only these
    };
    const slots: [*]usize = @ptrFromInt(frame);
    slots[0] = 0; // x86_64: the return address slot of a function entered by a jump
    slots[1] = @intFromPtr(arg); // safe: the argument, read back as a pointer by the trampoline
    slots[2] = @intFromPtr(entry); // safe: the function, called by the trampoline
    slots[3] = 0;
    f.regs = switch (builtin.cpu.arch) {
        .x86_64 => .{ .rsp = frame, .rbp = 0, .rip = @intFromPtr(&trampoline) }, // safe: the address of the naked entry
        .aarch64 => .{ .sp = frame, .fp = 0, .pc = @intFromPtr(&trampoline) }, // safe: the address of the naked entry
        else => unreachable, // unreachable: fibers_supported admits only these
    };
}

/// The return addresses of the fiber `c`, which is running, innermost first
/// into `out`, from `first_address` when it is one of them: each frame's
/// pointer to its caller's, while it stays inside the fiber's own stack and
/// up to the zero frame pointer the fiber starts with. std's unwinder is not
/// used on a fiber: on aarch64 Darwin it restores a frame's saved registers
/// reading up from its frame pointer, and past the fiber's first frame that
/// reads beyond the top of the stack and faults. Empty where frame pointers
/// are omitted.
pub noinline fn fiberTrace(c: *const Context, first_address: ?usize, out: []usize) []usize {
    if (!fibers_supported or builtin.omit_frame_pointer) return out[0..0];
    const low = @intFromPtr(c.fiber.stack.ptr); // safe: an address, kept as a number to bound the walk
    const high = low + c.fiber.stack.len;
    var fp = @frameAddress();
    var n: usize = 0;
    var skipping = first_address != null;
    // [fp] is the caller's frame pointer and [fp + 8] the return address, on both.
    while (n < out.len and fp >= low and fp % @alignOf(usize) == 0 and fp + 2 * @sizeOf(usize) <= high) {
        const frame: *const [2]usize = @ptrFromInt(fp);
        const caller = frame[0];
        const ra = frame[1];
        if (ra <= 1) break;
        if (skipping and ra == first_address.?) skipping = false;
        if (!skipping) {
            out[n] = ra;
            n += 1;
        }
        // The stack grows down: a caller's frame is above.
        if (caller <= fp) break;
        fp = caller;
    }
    return out[0..n];
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

test "a fiber enters its function with the stack a call leaves, so a local aligned to the stack's alignment is aligned" {
    if (!fibers_supported) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = undefined;
        var task: Context = undefined;
        var address: usize = 0;
        fn run(arg: *anyopaque) callconv(.c) noreturn {
            _ = arg;
            var local: u128 align(16) = 0;
            std.mem.doNotOptimizeAway(&local);
            address = @intFromPtr(&local); // safe: an address, kept as a number to test its alignment
            switchTo(&task, &driver);
            unreachable; // unreachable: the test destroys the fiber without switching back to it
        }
    };
    Probe.driver = try initDriver(.fibers);
    defer finishDriver(&Probe.driver);
    Probe.task = try create(.fibers, Probe.run, &Probe.address, 64 * 1024);
    defer destroy(&Probe.task);
    switchTo(&Probe.driver, &Probe.task);
    try std.testing.expectEqual(@as(usize, 0), Probe.address % 16);
}

test "a fiber's own stack trace ends at its first frame, inside its stack" {
    if (!fibers_supported or builtin.omit_frame_pointer) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = undefined;
        var task: Context = undefined;
        var addresses: [64]usize = undefined;
        var len: usize = 0;
        fn run(arg: *anyopaque) callconv(.c) noreturn {
            _ = arg;
            len = fiberTrace(&task, null, &addresses).len;
            switchTo(&task, &driver);
            unreachable; // unreachable: the test destroys the fiber without switching back to it
        }
    };
    Probe.driver = try initDriver(.fibers);
    defer finishDriver(&Probe.driver);
    Probe.task = try create(.fibers, Probe.run, &Probe.len, 64 * 1024);
    defer destroy(&Probe.task);
    switchTo(&Probe.driver, &Probe.task);
    // The run's frame, and the walk stopped there, short of the room it had.
    try std.testing.expect(Probe.len >= 1 and Probe.len < Probe.addresses.len);
}

test "values the switching code keeps in vector registers survive a fiber that overwrites them" {
    if (!fibers_supported) return error.SkipZigTest;
    const V = @Vector(4, f32);
    const Probe = struct {
        var driver: Context = undefined;
        var task: Context = undefined;
        fn run(arg: *anyopaque) callconv(.c) noreturn {
            _ = arg;
            overwrite();
            switchTo(&task, &driver);
            unreachable; // unreachable: the test destroys the fiber without switching back to it
        }
        /// What any fiber's code may do with the vector registers: here,
        /// every one of them set, and nothing told.
        noinline fn overwrite() void {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile (
                    \\ pcmpeqd %%xmm0, %%xmm0
                    \\ pcmpeqd %%xmm1, %%xmm1
                    \\ pcmpeqd %%xmm2, %%xmm2
                    \\ pcmpeqd %%xmm3, %%xmm3
                    \\ pcmpeqd %%xmm4, %%xmm4
                    \\ pcmpeqd %%xmm5, %%xmm5
                    \\ pcmpeqd %%xmm6, %%xmm6
                    \\ pcmpeqd %%xmm7, %%xmm7
                    \\ pcmpeqd %%xmm8, %%xmm8
                    \\ pcmpeqd %%xmm9, %%xmm9
                    \\ pcmpeqd %%xmm10, %%xmm10
                    \\ pcmpeqd %%xmm11, %%xmm11
                    \\ pcmpeqd %%xmm12, %%xmm12
                    \\ pcmpeqd %%xmm13, %%xmm13
                    \\ pcmpeqd %%xmm14, %%xmm14
                    \\ pcmpeqd %%xmm15, %%xmm15
                ),
                .aarch64 => asm volatile (
                    \\ movi v0.16b, #0xff
                    \\ movi v1.16b, #0xff
                    \\ movi v2.16b, #0xff
                    \\ movi v3.16b, #0xff
                    \\ movi v4.16b, #0xff
                    \\ movi v5.16b, #0xff
                    \\ movi v6.16b, #0xff
                    \\ movi v7.16b, #0xff
                    \\ movi v16.16b, #0xff
                    \\ movi v17.16b, #0xff
                    \\ movi v18.16b, #0xff
                    \\ movi v19.16b, #0xff
                    \\ movi v20.16b, #0xff
                    \\ movi v21.16b, #0xff
                    \\ movi v22.16b, #0xff
                    \\ movi v23.16b, #0xff
                ),
                else => unreachable, // unreachable: fibers_supported admits only these
            }
        }
    };
    var input: [12]V = undefined;
    for (&input, 0..) |*v, i| v.* = @splat(@floatFromInt(i + 1));
    std.mem.doNotOptimizeAway(&input);
    Probe.driver = try initDriver(.fibers);
    defer finishDriver(&Probe.driver);
    Probe.task = try create(.fibers, Probe.run, &Probe.driver, 64 * 1024);
    defer destroy(&Probe.task);
    // Nothing but the switch between computing them and reading them: no
    // call for the compiler to spill around.
    var kept: [12]V = undefined;
    inline for (0..12) |i| kept[i] = input[i] * input[i];
    switchTo(&Probe.driver, &Probe.task);
    inline for (0..12) |i| {
        const square: f32 = @floatFromInt((i + 1) * (i + 1));
        try std.testing.expectEqual(@as(V, @splat(square)), kept[i]);
    }
}
