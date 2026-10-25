//! What the system says of a thread of this process, asked from another:
//! the CPU time it has had and whether it is blocked in the kernel. The
//! watchdog reads the thread running a simulation's task, to count only
//! the time that task could run: a thread waiting for a CPU on a loaded
//! host gets none, and one blocked in the kernel could not have made a call
//! either.
//!
//! Linux reads `/proc/self/task/<tid>/stat` and the thread's CPU clock,
//! macOS `thread_info`, Windows the system's process snapshot. Elsewhere
//! nothing can be read, and `read` returns null.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const linux = std.os.linux;

/// A thread, as `current` names it; `none` names no thread.
pub const Thread = enum(u64) { none = 0, _ };

/// The calling thread.
pub fn current() Thread {
    if (own == .none) own = switch (builtin.os.tag) {
        .linux => @fromBackingInt(@intCast(@as(u32, @bitCast(linux.gettid())))),
        .macos, .ios, .tvos, .watchos, .visionos => @fromBackingInt(@intCast(pthread_mach_thread_np(std.c.pthread_self()))),
        .windows => @fromBackingInt(@intCast(windows.GetCurrentThreadId())),
        else => .none,
    };
    return own;
}

threadlocal var own: Thread = .none;

extern "c" fn pthread_mach_thread_np(thread: std.c.pthread_t) std.c.mach_port_t;

/// One reading of a thread.
pub const Reading = struct {
    /// CPU time the thread has had, in nanoseconds.
    cpu: i64,
    /// Waiting in the kernel for something other than a CPU.
    blocked: bool,
};

/// What the system says of `thread` now; null when it says nothing: the
/// thread is gone, or this system has no way to ask.
pub fn read(thread: Thread) ?Reading {
    if (thread == .none) return null;
    return switch (builtin.os.tag) {
        .linux => readLinux(@intCast(@backingInt(thread))),
        .macos, .ios, .tvos, .watchos, .visionos => readMach(@intCast(@backingInt(thread))),
        .windows => readWindows(@intCast(@backingInt(thread))),
        else => null,
    };
}

/// How much of `wall` nanoseconds, between readings `before` and `after`,
/// the thread could run: its CPU time, or all of it when it was blocked at
/// both readings; all of it, too, when a reading is missing, since then
/// nothing tells it from running.
pub fn couldRun(before: ?Reading, after: ?Reading, wall: i64) i64 {
    const b = before orelse return wall;
    const a = after orelse return wall;
    if (b.blocked and a.blocked) return wall;
    return std.math.clamp(a.cpu -| b.cpu, 0, wall);
}

fn readLinux(tid: u32) ?Reading {
    // The thread's CPU clock: the kernel's MAKE_THREAD_CPUCLOCK(tid, CPUCLOCK_SCHED).
    const clock: linux.clockid_t = @fromBackingInt(@intCast((~tid << 3) | 6));
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(clock, &ts)) != .SUCCESS) return null;
    var path_buf: [48]u8 = undefined;
    // unreachable: the longest tid fits with room to spare
    const path = std.mem.printSentinel(&path_buf, "/proc/self/task/{d}/stat", .{tid}, 0) catch unreachable;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var buf: [512]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return .{ .cpu = @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec, .blocked = blockedState(buf[0..n]) orelse return null };
}

/// Whether the state in a `/proc/<pid>/task/<tid>/stat` line is a wait in
/// the kernel: sleeping (`S`), in uninterruptible sleep (`D`), idle (`I`).
/// Running or runnable is `R`; stopped (`T`, `t`) is neither, as a debugger
/// leaves it. The name before the state is in parentheses and may hold
/// any of them.
fn blockedState(line: []const u8) ?bool {
    const close = std.mem.findScalarLast(u8, line, ')') orelse return null;
    if (close + 2 >= line.len) return null;
    return switch (line[close + 2]) {
        'S', 'D', 'I' => true,
        else => false,
    };
}

fn readMach(port: std.c.mach_port_t) ?Reading {
    var info: std.c.thread_basic_info = undefined;
    var count: std.c.mach_msg_type_number_t = std.c.THREAD.BASIC.INFO_COUNT;
    if (std.c.thread_info(port, std.c.THREAD.BASIC.INFO, @ptrCast(&info), &count) != 0) return null; // safe: thread_info fills a thread_basic_info, as count says
    const us = @as(i64, info.user_time.seconds + info.system_time.seconds) * std.time.us_per_s + info.user_time.microseconds + info.system_time.microseconds;
    // TH_STATE_WAITING, TH_STATE_UNINTERRUPTIBLE; TH_STATE_RUNNING is running or runnable.
    return .{ .cpu = us * std.time.ns_per_us, .blocked = info.run_state == 3 or info.run_state == 4 };
}

/// `SYSTEM_PROCESS_INFORMATION`, its threads after it.
const ProcessInformation = extern struct {
    next_entry_offset: u32,
    number_of_threads: u32,
    working_set_private_size: i64,
    hard_fault_count: u32,
    number_of_threads_high_watermark: u32,
    cycle_time: u64,
    create_time: i64,
    user_time: i64,
    kernel_time: i64,
    image_name: windows.UNICODE_STRING,
    base_priority: i32,
    unique_process_id: usize,
    inherited_from_unique_process_id: usize,
    handle_count: u32,
    session_id: u32,
    unique_process_key: usize,
    sizes: [10]usize,
    page_fault_count_and_private: [2]usize,
    operation_counts: [6]i64,
};

/// `SYSTEM_THREAD_INFORMATION`.
const ThreadInformation = extern struct {
    kernel_time: i64,
    user_time: i64,
    create_time: i64,
    wait_time: u32,
    start_address: usize,
    client_id: windows.CLIENT_ID,
    priority: i32,
    base_priority: i32,
    context_switches: u32,
    thread_state: u32,
    wait_reason: u32,
};

comptime {
    if (builtin.os.tag == .windows and @sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(ProcessInformation) == 0x100);
        std.debug.assert(@sizeOf(ThreadInformation) == 0x50);
    }
}

fn readWindows(id: u32) ?Reading {
    const gpa = std.heap.page_allocator;
    var len: usize = 256 * 1024;
    while (true) {
        const buf = gpa.alignedAlloc(u8, .of(ProcessInformation), len) catch return null;
        defer gpa.free(buf);
        var needed: windows.ULONG = 0;
        switch (windows.ntdll.NtQuerySystemInformation(.Process, buf.ptr, @intCast(buf.len), &needed)) {
            .SUCCESS => return findThread(buf, id),
            .INFO_LENGTH_MISMATCH => len = @max(len * 2, needed + 64 * 1024),
            else => return null,
        }
    }
}

fn findThread(snapshot: []align(@alignOf(ProcessInformation)) const u8, id: u32) ?Reading {
    const pid = windows.GetCurrentProcessId();
    var at: usize = 0;
    while (at + @sizeOf(ProcessInformation) <= snapshot.len) {
        const process: *const ProcessInformation = @ptrCast(@alignCast(snapshot[at..].ptr)); // safe: entries start 8-aligned, as the system lays them
        if (process.unique_process_id == pid) {
            const threads: [*]const ThreadInformation = @ptrCast(@alignCast(snapshot[at + @sizeOf(ProcessInformation) ..].ptr)); // safe: the threads follow their process
            for (threads[0..process.number_of_threads]) |t| {
                if (@intFromPtr(t.client_id.UniqueThread) != id) continue; // safe: the system keeps a thread id in the handle's place
                // KTHREAD_STATE's Waiting; times count 100 ns.
                return .{ .cpu = (t.kernel_time + t.user_time) * 100, .blocked = t.thread_state == 5 };
            }
            return null;
        }
        if (process.next_entry_offset == 0) return null;
        at += process.next_entry_offset;
    }
    return null;
}

test "a blocked state is read past a name that holds parentheses and states" {
    try std.testing.expectEqual(@as(?bool, true), blockedState("12 (a) R (b)) S 1 2"));
    try std.testing.expectEqual(@as(?bool, false), blockedState("12 (x) R 1"));
    try std.testing.expectEqual(@as(?bool, false), blockedState("12 (x) t 1"));
    try std.testing.expectEqual(@as(?bool, null), blockedState("12 (x"));
}

test "a thread reads its own CPU time going up while it spins" {
    const first = read(current()) orelse return error.SkipZigTest;
    try std.testing.expect(!first.blocked);
    var later = first;
    while (later.cpu == first.cpu) later = read(current()).?;
    try std.testing.expect(later.cpu > first.cpu);
}

test "a thread blocked in the kernel reads as blocked, its CPU time still" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const Blocked = struct {
        id: std.atomic.Value(u64) = .init(0),
        go: std.atomic.Value(u32) = .init(0),
        fn run(b: *@This()) void {
            b.id.store(@backingInt(current()), .release);
            const io = std.Io.Threaded.global_single_threaded.io();
            while (b.go.load(.acquire) == 0) io.futexWaitUncancelable(u32, &b.go.raw, 0);
        }
    };
    var b: Blocked = .{};
    const thread = try std.Thread.spawn(.{}, Blocked.run, .{&b});
    defer thread.join();
    defer {
        b.go.store(1, .release);
        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &b.go.raw, 1);
    }
    while (b.id.load(.acquire) == 0) std.atomic.spinLoopHint();
    const id: Thread = @fromBackingInt(@intCast(b.id.load(.acquire)));
    // The thread blocks soon after it names itself; a few readings see it there.
    var reading = read(id) orelse return error.SkipZigTest;
    var tries: u32 = 0;
    while (!reading.blocked) : (tries += 1) {
        if (tries == 1000) return error.TestUnexpectedResult;
        // glint-ignore: Z026 -- a sleep cut short only reads sooner
        std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
        reading = read(id).?;
    }
    const again = read(id).?;
    try std.testing.expect(again.blocked);
    try std.testing.expectEqual(reading.cpu, again.cpu);
}

test "a thread could run all of an interval it spent blocked, and only its CPU time of one it did not" {
    const ms = std.time.ns_per_ms;
    try std.testing.expectEqual(@as(i64, 50 * ms), couldRun(.{ .cpu = 0, .blocked = true }, .{ .cpu = 0, .blocked = true }, 50 * ms));
    try std.testing.expectEqual(@as(i64, 2 * ms), couldRun(.{ .cpu = 0, .blocked = false }, .{ .cpu = 2 * ms, .blocked = false }, 50 * ms));
    try std.testing.expectEqual(@as(i64, 2 * ms), couldRun(.{ .cpu = 0, .blocked = true }, .{ .cpu = 2 * ms, .blocked = false }, 50 * ms));
    try std.testing.expectEqual(@as(i64, 50 * ms), couldRun(.{ .cpu = 0, .blocked = false }, .{ .cpu = 60 * ms, .blocked = false }, 50 * ms));
    try std.testing.expectEqual(@as(i64, 50 * ms), couldRun(null, .{ .cpu = 0, .blocked = false }, 50 * ms));
}
