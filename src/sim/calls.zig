//! The simulation's `Io` vtable.
//!
//! Tasks, groups, futexes, time, randomness, files and cancelation are simulated.
//! Writes to the test's own stdout and stderr, and stderr's lock, reach the
//! real ones, which a run's outcome cannot depend on. File and network calls
//! use the node's owned models; process calls run registered programs, and
//! a simulated process's standard streams are its own.
//! Every call is a step and a record in the trace, and every call
//! that can return `error.Canceled` is a cancelation point.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Core = @import("Core.zig");
const Task = Core.Task;
const fs_calls = @import("fs/calls.zig");
const net_calls = @import("net/calls.zig");
const process_calls = @import("programs/calls.zig");
const Model = @import("net/Model.zig");
const io_call = @import("../io_call.zig");
const IoCall = io_call.IoCall;

pub const vtable: Io.VTable = blk: {
    var table: Io.VTable = undefined;
    for (@typeInfo(Io.VTable).@"struct".field_names) |name| {
        @field(table, name) = if (@hasDecl(slots, name))
            @field(slots, name)
        else if (process_calls.supports(name))
            process_calls.slot(name)
        else if (process_calls.wrapsFile(name))
            process_calls.fileSlot(name, if (fs_calls.supports(name)) fs_calls.slot(name) else unsupported(name))
        else if (net_calls.supports(name))
            net_calls.slot(name)
        else if (fs_calls.supports(name))
            fs_calls.slot(name)
        else
            unsupported(name);
    }
    break :blk table;
};

/// The real system, for stdout and stderr.
fn real() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn outside(comptime what: []const u8) noreturn {
    @panic("shakedown: " ++ what ++ " blocks, and was called on a simulation's Io outside its tasks; call it from code Sim.run runs");
}

fn digest(err: anyerror) u64 {
    return std.hash.Wyhash.hash(0, @errorName(err));
}

const slots = struct {
    pub fn crashHandler(userdata: ?*anyopaque) void {
        const c = Core.of(userdata);
        if (c.current) |t| t.protection = .blocked;
    }

    // Tasks.

    pub fn async(
        userdata: ?*anyopaque,
        result: []u8,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*Io.AnyFuture {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const at_once = switch (c.options.async_start) {
            .eager, .deferred => true,
            .concurrent => false,
            .any => c.draw(1) == 0,
        };
        if (!at_once) {
            if (c.spawn(.{ .future = start }, context, context_alignment, result.len, result_alignment, .ready)) |t| {
                t.spawned_at = @returnAddress();
                c.record(.async, e, t.id.raw());
                return @ptrCast(t); // safe: a future of this simulation is its task, cast back by await and cancel
            } else |_| {}
        }
        c.record(.async, e, 0);
        start(context.ptr, result.ptr);
        return null;
    }

    pub fn concurrent(
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Io.ConcurrentError!*Io.AnyFuture {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const t = c.spawn(.{ .future = start }, context, context_alignment, result_len, result_alignment, .ready) catch {
            c.record(.concurrent, e, digest(error.ConcurrencyUnavailable));
            return error.ConcurrencyUnavailable;
        };
        t.spawned_at = @returnAddress();
        c.record(.concurrent, e, t.id.raw());
        return @ptrCast(t); // safe: a future of this simulation is its task, cast back by await and cancel
    }

    pub fn await(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse outside("await");
        const target: *Task = @ptrCast(@alignCast(any_future)); // safe: a future of this simulation is its task
        c.touch(Core.Object.task(c.actorOf(target)), true);
        if (target.state != .done) {
            target.awaiter = t;
            if (c.block(t, .{ .task = target }, true) == .canceled) {
                // As std's threaded Io does: the cancel passes on to the
                // awaited task, and stays the awaiter's if that task does
                // not take it.
                c.requestCancel(target);
                while (target.state != .done) _ = c.block(t, .{ .task = target }, false);
                if (target.cancel != .delivered) t.cancel = .requested;
            }
        }
        @memcpy(result, target.result());
        c.release(target);
        c.record(.await, e, 0);
    }

    pub fn cancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse outside("cancel");
        const target: *Task = @ptrCast(@alignCast(any_future)); // safe: a future of this simulation is its task
        c.touch(Core.Object.task(c.actorOf(target)), true);
        c.requestCancel(target);
        target.awaiter = t;
        while (target.state != .done) _ = c.block(t, .{ .task = target }, false);
        @memcpy(result, target.result());
        c.release(target);
        c.record(.cancel, e, 0);
    }

    pub fn groupAsync(
        userdata: ?*anyopaque,
        group: *Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const state: ?Core.Start = switch (c.options.async_start) {
            .eager => null,
            .concurrent => .ready,
            .deferred => .deferred,
            .any => if (c.draw(1) == 0) null else .ready,
        };
        if (state) |s| if (spawnMember(c, group, context, context_alignment, start, s, @returnAddress())) |t| {
            c.record(.groupAsync, e, t.id.raw());
            return;
        } else |_| {};
        c.record(.groupAsync, e, 0);
        start(context.ptr);
    }

    pub fn groupConcurrent(
        userdata: ?*anyopaque,
        group: *Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) Io.ConcurrentError!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const t = spawnMember(c, group, context, context_alignment, start, .ready, @returnAddress()) catch {
            c.record(.groupConcurrent, e, digest(error.ConcurrencyUnavailable));
            return error.ConcurrencyUnavailable;
        };
        c.record(.groupConcurrent, e, t.id.raw());
    }

    pub fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) Io.Cancelable!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse outside("Group.await");
        c.touch(Core.Object.group(@intFromPtr(group)), true); // safe: the address only names the group
        startDeferred(c, group);
        defer group.token.raw = null;
        if (group.state == 0) return c.record(.groupAwait, e, 0);
        group.token.raw = t;
        const canceled = Core.cancelPoint(t) or c.block(t, .{ .group = group }, true) == .canceled;
        if (canceled) {
            cancelMembers(c, group);
            while (group.state != 0) _ = c.block(t, .{ .group = group }, false);
            c.record(.groupAwait, e, digest(error.Canceled));
            return error.Canceled;
        }
        while (group.state != 0) _ = c.block(t, .{ .group = group }, false);
        c.record(.groupAwait, e, 0);
    }

    pub fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse outside("Group.cancel");
        c.touch(Core.Object.group(@intFromPtr(group)), true); // safe: the address only names the group
        startDeferred(c, group);
        cancelMembers(c, group);
        group.token.raw = t;
        while (group.state != 0) _ = c.block(t, .{ .group = group }, false);
        group.token.raw = null;
        c.record(.groupCancel, e, 0);
    }

    pub fn recancel(userdata: ?*anyopaque) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const t = e.task orelse @panic("shakedown: recancel outside a task, which was never canceled");
        std.debug.assert(t.cancel == .delivered); // recancel without a cancel delivered
        t.cancel = .requested;
        c.record(.recancel, e, 0);
    }

    pub fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const t = e.task orelse {
            c.record(.swapCancelProtection, e, 0);
            return .unblocked;
        };
        const old = t.protection;
        t.protection = new;
        c.record(.swapCancelProtection, e, @backingInt(old));
        return old;
    }

    pub fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.checkCancel, e, digest(error.Canceled));
            return error.Canceled;
        };
        c.record(.checkCancel, e, 0);
    }

    // Futexes.

    pub fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse {
            if (@atomicLoad(u32, ptr, .acquire) != expected) return;
            outside("futexWait");
        };
        if (Core.cancelPoint(t)) {
            c.record(.futexWait, e, digest(error.Canceled));
            return error.Canceled;
        }
        const wake = wait(c, t, ptr, expected, timeout, true);
        c.record(.futexWait, e, @backingInt(wake));
        if (wake == .canceled) return error.Canceled;
    }

    pub fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse {
            if (@atomicLoad(u32, ptr, .acquire) != expected) return;
            outside("futexWaitUncancelable");
        };
        const wake = wait(c, t, ptr, expected, .none, false);
        c.record(.futexWaitUncancelable, e, @backingInt(wake));
    }

    pub fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        c.touch(Core.Object.futex(@intFromPtr(ptr)), true); // safe: the address only identifies the futex
        const woken = c.wakeFutex(@intFromPtr(ptr), max_waiters); // safe: the address only identifies the futex
        c.record(.futexWake, e, woken);
    }

    // Time.

    pub fn now(userdata: ?*anyopaque, which: Io.Clock) Io.Timestamp {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const at = c.now(which);
        c.record(.now, e, @truncate(@as(u96, @bitCast(at.nanoseconds))));
        return at;
    }

    pub fn clockResolution(userdata: ?*anyopaque, _: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        c.record(.clockResolution, e, 0);
        return c.options.clock.resolution;
    }

    pub fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse outside("sleep");
        if (Core.cancelPoint(t)) {
            c.record(.sleep, e, digest(error.Canceled));
            return error.Canceled;
        }
        const wake: Core.Wake = switch (c.deadline(timeout)) {
            .due => .timeout,
            .never => c.block(t, .sleep, true),
            .at => |at| wake: {
                c.arm(t, at.clock, at.ns);
                break :wake c.block(t, .sleep, true);
            },
        };
        if (wake == .canceled) {
            c.record(.sleep, e, digest(error.Canceled));
            return error.Canceled;
        }
        c.record(.sleep, e, 0);
    }

    // Randomness.

    pub fn random(userdata: ?*anyopaque, buffer: []u8) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        fill(c, buffer);
        c.record(.random, e, std.hash.Wyhash.hash(0, buffer));
    }

    pub fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.randomSecure, e, digest(error.Canceled));
            return error.Canceled;
        };
        fill(c, buffer);
        c.record(.randomSecure, e, std.hash.Wyhash.hash(0, buffer));
    }

    // Operations and batches.

    pub fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(callOf(operation), e, digest(error.Canceled));
            return error.Canceled;
        };
        const op = process_calls.translateOperation(c, operation);
        const result = while (true) {
            if (attempt(c, e.node, op)) |result| break result;
            net_calls.wait(c, e.task, .never) catch {
                c.record(callOf(operation), e, digest(error.Canceled));
                return error.Canceled;
            };
        };
        c.record(callOf(operation), e, operationDigest(c, e.node, op, result));
        return result;
    }

    pub fn batchAwaitAsync(userdata: ?*anyopaque, b: *Io.Batch) Io.Cancelable!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.batchAwaitAsync, e, digest(error.Canceled));
            return error.Canceled;
        };
        var batch_digest: u64 = 0;
        while (!complete(c, e.node, b, &batch_digest)) net_calls.wait(c, e.task, .never) catch {
            c.record(.batchAwaitAsync, e, digest(error.Canceled));
            return error.Canceled;
        };
        c.record(.batchAwaitAsync, e, batch_digest);
    }

    pub fn batchAwaitConcurrent(userdata: ?*anyopaque, b: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.batchAwaitConcurrent, e, digest(error.Canceled));
            return error.Canceled;
        };
        const deadline = c.deadline(timeout);
        var batch_digest: u64 = 0;
        while (!complete(c, e.node, b, &batch_digest)) net_calls.wait(c, e.task, deadline) catch |err| {
            c.record(.batchAwaitConcurrent, e, digest(err));
            return err;
        };
        c.record(.batchAwaitConcurrent, e, batch_digest);
    }

    pub fn batchCancel(userdata: ?*anyopaque, _: *Io.Batch) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        // Readiness probes own no resources. Batch.cancel releases unstarted submissions.
        c.record(.batchCancel, e, 0);
    }

    // The real terminal.

    pub fn lockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.lockStderr, e, digest(error.Canceled));
            return error.Canceled;
        };
        c.record(.lockStderr, e, 0);
        const r = real();
        return r.vtable.lockStderr(r.userdata, mode);
    }

    pub fn tryLockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.tryLockStderr, e, digest(error.Canceled));
            return error.Canceled;
        };
        c.record(.tryLockStderr, e, 0);
        const r = real();
        return r.vtable.tryLockStderr(r.userdata, mode);
    }

    pub fn unlockStderr(userdata: ?*anyopaque) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        c.record(.unlockStderr, e, 0);
        const r = real();
        r.vtable.unlockStderr(r.userdata);
    }

    pub fn fileIsTty(userdata: ?*anyopaque, _: Io.File) Io.Cancelable!bool {
        return noTerminal(.fileIsTty, userdata);
    }

    pub fn fileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, _: Io.File) Io.Cancelable!bool {
        return noTerminal(.fileSupportsAnsiEscapeCodes, userdata);
    }
};

fn noTerminal(comptime call: IoCall, userdata: ?*anyopaque) Io.Cancelable!bool {
    const c = Core.of(userdata);
    const e = c.enter(@returnAddress(), true);
    if (e.task) |t| if (Core.cancelPoint(t)) {
        c.record(call, e, digest(error.Canceled));
        return error.Canceled;
    };
    c.record(call, e, 0);
    return false;
}

/// A futex wait from task `t`, after its cancelation point.
fn wait(c: *Core, t: *Task, ptr: *const u32, expected: u32, timeout: Io.Timeout, cancelable: bool) Core.Wake {
    c.touch(Core.Object.futex(@intFromPtr(ptr)), true); // safe: the address only identifies the futex
    if (@atomicLoad(u32, ptr, .acquire) != expected) return .woken;
    const deadline = c.deadline(timeout);
    if (deadline == .due) return .timeout;
    if (c.spurious()) {
        // A spurious wake, as std allows: others may run, then it returns.
        c.yield(t);
        return .spurious;
    }
    const address = @intFromPtr(ptr); // safe: the address only identifies the futex
    c.link(t, address);
    switch (deadline) {
        .at => |at| c.arm(t, at.clock, at.ns),
        .never, .due => {},
    }
    var wake = c.block(t, .{ .futex = address }, cancelable);
    if (wake == .woken and t.cancel == .requested and t.cancelable) {
        // A wake and a cancel both landed while it waited: either may be
        // reported. Reporting the cancel hands the wake on to the next
        // waiter, as if the cancel had come first.
        if (c.draw(1) == 1) {
            _ = c.wakeFutex(address, 1);
            t.cancel = .delivered;
            wake = .canceled;
        }
    }
    return wake;
}

fn fill(c: *Core, buffer: []u8) void {
    if (c.options.schedule == .bounded) if (c.current) |t| {
        // Searched orders differ in which task draws first: each task's
        // bytes are its own stream, so one task's draws never move
        // another's.
        var prng: std.Random.Xoshiro256 = .init(c.options.seed ^ std.hash.int(@as(u64, c.actorOf(t))) ^ (t.random_draws *% 0x9e37_79b9_7f4a_7c15));
        t.random_draws += 1;
        prng.fill(buffer);
        return;
    };
    var rest = buffer;
    while (rest.len > 0) {
        const word: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, c.draw(std.math.maxInt(u64))));
        const n = @min(rest.len, 8);
        @memcpy(rest[0..n], word[0..n]);
        rest = rest[n..];
    }
}

fn touchGroup(c: *Core, group: *Io.Group) void {
    c.touch(Core.Object.group(@intFromPtr(group)), true); // safe: the address only names the group
}

fn spawnMember(
    c: *Core,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
    state: Core.Start,
    spawned_at: usize,
) Core.SpawnError!*Task {
    touchGroup(c, group);
    const t = try c.spawn(.{ .member = start }, context, context_alignment, 0, .@"1", state);
    t.group = group;
    t.spawned_at = spawned_at;
    group.state += 1;
    if (group.token.raw == null) group.token.raw = Core.groupMarker(group);
    return t;
}

fn startDeferred(c: *Core, group: *Io.Group) void {
    for (c.tasks.items) |t| {
        if (t.state == .deferred and t.group == group) c.makeReady(t);
    }
}

fn cancelMembers(c: *Core, group: *Io.Group) void {
    for (c.tasks.items) |t| {
        if (t.group == group) c.requestCancel(t);
    }
}

// Operations.

fn callOf(operation: Io.Operation) IoCall {
    return switch (operation) {
        inline else => |_, tag| @field(IoCall, @tagName(tag)),
    };
}

fn standard(file: Io.File) bool {
    return file.handle == Io.File.stdout().handle or file.handle == Io.File.stderr().handle;
}

/// An operation's result: standard output reaches the process, file operations
/// reach this simulation's disk, and unavailable parts fail.
fn perform(c: *Core, operation: Io.Operation) Io.Operation.Result {
    switch (operation) {
        .file_write_streaming => |w| if (standard(w.file)) {
            const r = real();
            if (r.vtable.operate(r.userdata, operation)) |result| return result else |_| {}
        },
        else => {},
    }
    if (c.disk(c.nodeId())) |fs| {
        fs.model.at = c.now(.real);
        if (fs_calls.perform(fs.model, operation)) |result| return result;
    }
    return switch (operation) {
        inline else => |_, tag| failed(tag),
    };
}

fn failed(comptime tag: Io.Operation.Tag) Io.Operation.Result {
    const result_type = @FieldType(Io.Operation.Result, @tagName(tag));
    if (result_type == noreturn) unreachable; // unreachable: an operation this target cannot make cannot be made
    if (comptime tag == .device_io_control) {
        // Results as the system gives them: a negative errno, or a status.
        const value: result_type = if (builtin.os.tag == .windows) .{ .u = .{ .Status = .INVALID_HANDLE }, .Information = 0 } else -@as(result_type, @intCast(@backingInt(std.posix.E.BADF)));
        return @unionInit(Io.Operation.Result, @tagName(tag), value);
    }
    return @unionInit(Io.Operation.Result, @tagName(tag), switch (@typeInfo(result_type)) {
        .error_union => error.Unexpected,
        .@"struct" => .{ error.Unexpected, 0 },
        else => @compileError("an operation result shakedown cannot fail: " ++ @typeName(result_type)),
    });
}

/// What an operation does, or null while it would wait: a network
/// operation on the network model, a stream of a pipe on the pipes, the
/// rest at once.
fn attempt(c: *Core, node: Model.NodeId, op: Io.Operation) ?Io.Operation.Result {
    if (net_calls.isNetwork(op) and c.options.net != null) {
        c.touch(Core.Object.network, true);
        return net_calls.perform(c, node, op);
    }
    if (process_calls.isPipe(op)) {
        c.touch(Core.Object.pipes, true);
        return process_calls.perform(c, op);
    }
    c.touch(Core.Object.disk(node), true);
    return perform(c, op);
}

/// An operation's digest for the trace: 0 for the file system's, whose
/// calls trace their own effects.
fn operationDigest(c: *Core, node: Model.NodeId, op: Io.Operation, result: Io.Operation.Result) u64 {
    if (net_calls.isNetwork(op) and c.options.net != null) return net_calls.operationDigest(node, op, result);
    if (process_calls.isPipe(op)) return process_calls.operationDigest(op, result);
    return 0;
}

/// Probe all submissions, leaving blocked operations available to retry or cancel.
fn complete(c: *Core, node: Model.NodeId, b: *Io.Batch, batch_digest: *u64) bool {
    var tail = b.completed.tail;
    var pending: @TypeOf(b.submitted) = .{ .head = .none, .tail = .none };
    var index = b.submitted.head;
    while (index != .none) {
        const storage = &b.storage[index.toIndex()];
        const next = storage.submission.node.next;
        const op = process_calls.translateOperation(c, storage.submission.operation);
        const result = attempt(c, node, op);
        if (result) |value| {
            const op_digest = operationDigest(c, node, op, value);
            if (op_digest != 0) batch_digest.* = std.hash.int(batch_digest.* ^ op_digest ^ index.toIndex());
            switch (tail) {
                .none => b.completed.head = index,
                else => b.storage[tail.toIndex()].completion.node.next = index,
            }
            storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = value } };
            tail = index;
        } else {
            switch (pending.tail) {
                .none => pending.head = index,
                else => b.storage[pending.tail.toIndex()].submission.node.next = index,
            }
            pending.tail = index;
            storage.submission.node.next = .none;
        }
        index = next;
    }
    b.completed.tail = tail;
    b.submitted = pending;
    return b.completed.head != .none or b.submitted.head == .none;
}

// Everything else.

fn Return(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?;
}

/// What a call the simulation does not have returns, once no cancel has
/// landed: nothing for one that cannot fail, `error.Unexpected` where its
/// error set allows it, else the first error of its set.
fn fallback(comptime R: type) R {
    return switch (@typeInfo(R)) {
        .void => {},
        .error_union => |u| failure(u.error_set),
        .error_set => failure(R),
        else => @compileError("no fallback for " ++ @typeName(R)),
    };
}

fn failure(comptime E: type) E {
    const names = @typeInfo(E).error_set.error_names orelse return error.Unexpected;
    inline for (names) |n| if (comptime std.mem.eql(u8, n, "Unexpected")) return error.Unexpected;
    return @field(E, names[0]);
}

fn unsupported(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const return_type = info.return_type.?;
    const params = info.param_types;
    const call = @field(IoCall, name);
    const Body = struct {
        inline fn run(userdata: ?*anyopaque, ret: usize) return_type {
            const c = Core.of(userdata);
            const e = c.enter(ret, true);
            if (comptime io_call.cancelable(call)) if (e.task) |t| if (Core.cancelPoint(t)) {
                c.record(call, e, digest(error.Canceled));
                return error.Canceled;
            };
            const value = fallback(return_type);
            c.record(call, e, switch (@typeInfo(return_type)) {
                .void => 0,
                .error_set => digest(value),
                else => digest(if (value) |_| unreachable else |err| err), // unreachable: a fallback is always an error
            });
            return value;
        }
    };
    return switch (params.len) {
        1 => &struct {
            fn f(u: ?*anyopaque) return_type {
                return Body.run(u, @returnAddress());
            }
        }.f,
        2 => &struct {
            fn f(u: ?*anyopaque, _: params[1].?) return_type {
                return Body.run(u, @returnAddress());
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?) return_type {
                return Body.run(u, @returnAddress());
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?) return_type {
                return Body.run(u, @returnAddress());
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?, _: params[4].?) return_type {
                return Body.run(u, @returnAddress());
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, _: params[1].?, _: params[2].?, _: params[3].?, _: params[4].?, _: params[5].?) return_type {
                return Body.run(u, @returnAddress());
            }
        }.f,
        else => @compileError("Io.VTable." ++ name ++ " has more parameters than the simulation's fallback takes"),
    };
}
