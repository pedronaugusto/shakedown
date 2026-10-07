//! `FaultIo`: an `Io` that counts, traces and faults every call the code
//! under test makes, and forwards it to a base `Io`.
//!
//! Every vtable slot is wrapped, and so is every `operate` operation, by
//! code generated from `Io.VTable` and `Io.Operation` at compile time. A
//! call takes a step from the run's `Steps`, is counted, and, when a plan
//! or a trace asks for it, is decided and recorded. With an empty plan and
//! the trace off a call costs a step, a count and one bit test on its way
//! to the base.
//!
//! A plan's faults are checked against the calls they name when the plan
//! is set, so a plan that asks for an error a call cannot return is
//! refused rather than ignored. An entry that names no call, or names a
//! step, fires on whatever call it lands on; if its fault cannot apply to
//! that call, it does nothing.
//!
//! `FaultIo` is safe to use from several tasks at once. Decisions and
//! records are taken under a lock, never across the forwarded call. A
//! `FaultIo` must not move, which `init` guarantees by allocating it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const io_call = @import("io_call.zig");
const IoCall = io_call.IoCall;
const IoFault = io_call.IoFault;
const IoEvent = io_call.IoEvent;
const Plan = @import("plan.zig").Plan;
const Trace = @import("trace.zig").Trace;
const Source = @import("Source.zig");
const Steps = @import("Steps.zig");

const FaultIo = @This();

pub const IoPlan = Plan(IoCall, IoFault);
pub const IoTrace = Trace(IoEvent);
const CallSet = std.EnumSet(IoCall);

/// Private: the allocator everything here comes from.
gpa: Allocator,
/// Private: where every call goes.
base: Io,
/// Private: what `init` was given.
options: Options,
/// Private: guards the plan, the trace, the path table and `random`.
mutex: Io.Mutex = .init,
steps_: Steps = .init(),
counts: [io_call.call_count]std.atomic.Value(u64) = @splat(.init(0)),
trace_: IoTrace,
/// Private: the plan and its storage, all owned.
plan: IoPlan,
entries: []IoPlan.Entry = &.{},
counters: []u32 = &.{},
fired_storage: []IoPlan.Fired = &.{},
/// Private: the calls that leave the fast path.
watched: CallSet = .empty,
/// Private: the calls the plan may fire on.
planned: CallSet = .empty,
/// Private: open handle to the path it was opened by.
paths: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,
path_arena: std.heap.ArenaAllocator,
/// Private: `io.random` under `random_seed`, and the draws of `.chance`
/// entries when `Options.source` is null.
random: Source,
shims: std.ArrayList(*AllocatorShim) = .empty,

pub const Options = struct {
    plan: []const IoPlan.Entry = &.{},
    /// Counts are always kept, whatever the trace keeps.
    trace: IoTrace.Mode = .off,
    /// Keep a table from open handle to the path it was opened by, so
    /// records and `Match` see paths for handle calls too.
    track_paths: bool = true,
    /// `io.random` and `randomSecure` from a generator seeded with this.
    random_seed: ?u64 = null,
    /// Draws for `.chance` entries; without one they come from a
    /// generator seeded with `random_seed`, or 0.
    source: ?*Source = null,
};

pub const InitError = error{ OutOfMemory, FaultNotInErrorSet, FaultNotApplicable };

/// The vtable every `FaultIo` hands out: `io.vtable == &FaultIo.vtable`
/// tells whether an `Io` is one.
pub const vtable: Io.VTable = blk: {
    var table: Io.VTable = undefined;
    for (@typeInfo(Io.VTable).@"struct".field_names) |name| @field(table, name) = shim(name);
    break :blk table;
};

pub fn init(gpa: Allocator, base: Io, options: Options) InitError!*FaultIo {
    const f = try gpa.create(FaultIo);
    errdefer gpa.destroy(f);
    f.* = .{
        .gpa = gpa,
        .base = base,
        .options = options,
        .trace_ = .init(gpa, options.trace),
        .plan = undefined,
        .path_arena = .init(gpa),
        .random = try .init(gpa, .{ .prng = options.random_seed orelse 0 }),
    };
    errdefer f.trace_.deinit();
    errdefer f.path_arena.deinit();
    f.plan = .init(&.{}, .{ .steps = &f.steps_, .counters = &.{} });
    try f.setPlan(options.plan);
    return f;
}

pub fn deinit(f: *FaultIo) void {
    const gpa = f.gpa;
    f.trace_.deinit();
    f.paths.deinit(gpa);
    f.path_arena.deinit();
    f.random.deinit();
    gpa.free(f.entries);
    gpa.free(f.counters);
    gpa.free(f.fired_storage);
    for (f.shims.items) |s| gpa.destroy(s);
    f.shims.deinit(gpa);
    gpa.destroy(f);
}

/// The `Io` to hand the code under test.
pub fn io(f: *FaultIo) Io {
    return .{ .userdata = f, .vtable = &vtable };
}

/// Replaces the plan and forgets the old one's matches. Not to be called
/// while calls are in flight.
pub fn setPlan(f: *FaultIo, entries: []const IoPlan.Entry) InitError!void {
    var planned: CallSet = .empty;
    for (entries) |entry| {
        if (entry.fault == .crash) return error.FaultNotApplicable;
        const call = switch (entry.at) {
            .step => null,
            .nth => |nth| nth.call,
            .chance => |c| c.call,
        };
        if (call) |c| {
            try entry.fault.check(c);
            planned.insert(c);
        } else {
            planned = .full;
        }
    }
    const owned = try f.gpa.dupe(IoPlan.Entry, entries);
    errdefer f.gpa.free(owned);
    const counters = try f.gpa.alloc(u32, entries.len);
    errdefer f.gpa.free(counters);
    const fired_list = try f.gpa.alloc(IoPlan.Fired, @min(entries.len * 4 + 16, 4096));
    f.gpa.free(f.entries);
    f.gpa.free(f.counters);
    f.gpa.free(f.fired_storage);
    f.entries = owned;
    f.counters = counters;
    f.fired_storage = fired_list;
    f.plan = .init(owned, .{
        .steps = &f.steps_,
        .source = f.options.source orelse &f.random,
        .counters = counters,
        .fired = fired_list,
    });
    f.planned = planned;
    f.watched = planned;
    if (f.options.trace != .off) f.watched = .full;
    if (f.options.track_paths) f.watched.setUnion(path_calls);
    if (f.options.random_seed != null) {
        f.watched.insert(.random);
        f.watched.insert(.randomSecure);
    }
}

/// How many times `call` was made.
pub fn count(f: *const FaultIo, call: IoCall) u64 {
    return f.counts[@backingInt(call)].load(.monotonic);
}

pub fn trace(f: *FaultIo) *IoTrace {
    return &f.trace_;
}

/// The run's step counter. A seam's own plan shares it, so its calls and
/// these interleave into one sequence.
pub fn steps(f: *FaultIo) *Steps {
    return &f.steps_;
}

/// The faults the plan injected, in order, with the step of each.
pub fn fired(f: *const FaultIo) []const IoPlan.Fired {
    return f.plan.fired();
}

/// Forgets counts, steps, the trace and the plan's matches; keeps the plan
/// and the path table.
pub fn reset(f: *FaultIo) void {
    for (&f.counts) |*c| c.store(0, .monotonic);
    f.steps_.reset();
    f.trace_.clear();
    f.plan.reset();
}

// Seams.

/// A seam's raw call, begun: its step, and the fault the plan has for it.
pub const Foreign = struct {
    step: u64,
    fault: ?IoFault,
    event: IoEvent,
};

/// Takes a step for a seam's raw call and asks the plan about it, as
/// `.foreign` with `path` as its subject. The seam injects the fault
/// itself (`fail` as its own error, say), makes or skips the call, then
/// hands the outcome to `endForeign`.
pub fn beginForeign(f: *FaultIo, comptime Call: type, call: Call, path: ?[]const u8) Foreign {
    _ = f.counts[@backingInt(IoCall.foreign)].fetchAdd(1, .monotonic);
    const event: IoEvent = .{
        .call = .foreign,
        .subject = .{ .path = path },
        .foreign = .{ .domain = @typeName(Call), .call = foreignIndex(Call, call) },
    };
    f.lock();
    defer f.unlock();
    const step = f.steps_.take();
    var fault: ?IoFault = null;
    if (f.planned.contains(.foreign)) fault = f.plan.decideAt(step, .foreign, path);
    if (fault) |x| x.check(.foreign) catch {
        fault = null;
    };
    return .{ .step = step, .fault = fault, .event = event };
}

/// Records the outcome of a call `beginForeign` began.
pub fn endForeign(f: *FaultIo, begun: Foreign, outcome: IoEvent.Outcome) void {
    var event = begun.event;
    event.outcome = outcome;
    if (begun.fault) |x| event.fault = x;
    f.record(begun.step, event);
}

/// A seam's raw call that already happened, into the same step sequence
/// and trace. The plan is not asked: use `beginForeign` for a call a plan
/// may fault.
pub fn recordForeign(f: *FaultIo, comptime Call: type, call: Call, path: ?[]const u8, outcome: IoEvent.Outcome) void {
    _ = f.counts[@backingInt(IoCall.foreign)].fetchAdd(1, .monotonic);
    const step = f.steps_.take();
    f.record(step, .{
        .call = .foreign,
        .subject = .{ .path = path },
        .outcome = outcome,
        .foreign = .{ .domain = @typeName(Call), .call = foreignIndex(Call, call) },
    });
}

fn foreignIndex(comptime Call: type, call: Call) u32 {
    return switch (@typeInfo(Call)) {
        .@"enum" => @backingInt(call),
        .@"union" => @backingInt(std.meta.activeTag(call)),
        .int => @intCast(call),
        else => @compileError("a foreign call is an enum, a tagged union or an integer"),
    };
}

// Allocation.

const AllocatorShim = struct {
    fio: *FaultIo,
    child: Allocator,
};

/// `child`, with every allocation, resize and remap counted, stepped,
/// traced and planned as `.alloc`, `.resize` and `.remap`. A `fail` fault
/// is a refusal. Lives as long as the `FaultIo`.
pub fn allocator(f: *FaultIo, child: Allocator) Allocator {
    const s = f.gpa.create(AllocatorShim) catch @panic("FaultIo.allocator: out of memory");
    s.* = .{ .fio = f, .child = child };
    f.shims.append(f.gpa, s) catch {
        f.gpa.destroy(s);
        @panic("FaultIo.allocator: out of memory");
    };
    return .{ .ptr = s, .vtable = &allocator_vtable };
}

const allocator_vtable: Allocator.VTable = .{
    .alloc = shimAlloc,
    .resize = shimResize,
    .remap = shimRemap,
    .free = shimFree,
};

fn shimOf(ptr: *anyopaque) *AllocatorShim {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with an AllocatorShim
}

fn shimAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const s = shimOf(ptr);
    const f = s.fio;
    _ = f.counts[@backingInt(IoCall.alloc)].fetchAdd(1, .monotonic);
    if (!f.watched.contains(.alloc)) {
        _ = f.steps_.take();
        return s.child.rawAlloc(len, alignment, ret_addr);
    }
    const d = f.decide(.alloc, .{});
    if (d.fault) |fault| if (fault == .fail) {
        f.record(d.step, .{ .call = .alloc, .outcome = .{ .err = error.OutOfMemory }, .fault = .fail });
        return null;
    };
    f.beforeAnywhere(d.fault);
    const result = s.child.rawAlloc(len, alignment, ret_addr);
    f.record(d.step, .{
        .call = .alloc,
        .outcome = if (result != null) .{ .ok = len } else .{ .err = error.OutOfMemory },
        .fault = if (d.fault) |x| x else null,
    });
    return result;
}

fn shimResize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const s = shimOf(ptr);
    const f = s.fio;
    _ = f.counts[@backingInt(IoCall.resize)].fetchAdd(1, .monotonic);
    if (!f.watched.contains(.resize)) {
        _ = f.steps_.take();
        return s.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    const d = f.decide(.resize, .{});
    if (d.fault) |fault| if (fault == .fail) {
        f.record(d.step, .{ .call = .resize, .outcome = .{ .err = error.OutOfMemory }, .fault = .fail });
        return false;
    };
    f.beforeAnywhere(d.fault);
    const ok = s.child.rawResize(memory, alignment, new_len, ret_addr);
    f.record(d.step, .{
        .call = .resize,
        .outcome = if (ok) .{ .ok = new_len } else .{ .err = error.OutOfMemory },
        .fault = if (d.fault) |x| x else null,
    });
    return ok;
}

fn shimRemap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const s = shimOf(ptr);
    const f = s.fio;
    _ = f.counts[@backingInt(IoCall.remap)].fetchAdd(1, .monotonic);
    if (!f.watched.contains(.remap)) {
        _ = f.steps_.take();
        return s.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    const d = f.decide(.remap, .{});
    if (d.fault) |fault| if (fault == .fail) {
        f.record(d.step, .{ .call = .remap, .outcome = .{ .err = error.OutOfMemory }, .fault = .fail });
        return null;
    };
    f.beforeAnywhere(d.fault);
    const result = s.child.rawRemap(memory, alignment, new_len, ret_addr);
    f.record(d.step, .{
        .call = .remap,
        .outcome = if (result != null) .{ .ok = new_len } else .{ .err = error.OutOfMemory },
        .fault = if (d.fault) |x| x else null,
    });
    return result;
}

fn shimFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    shimOf(ptr).child.rawFree(memory, alignment, ret_addr);
}

// The shared slow path.

fn lock(f: *FaultIo) void {
    f.mutex.lockUncancelable(f.base);
}

fn unlock(f: *FaultIo) void {
    f.mutex.unlock(f.base);
}

const Decision = struct { step: u64, fault: ?IoFault };

/// Takes the call's step and asks the plan about it, under the lock so
/// that steps and plan counters move together.
fn decide(f: *FaultIo, call: IoCall, subject: IoEvent.Subject) Decision {
    f.lock();
    defer f.unlock();
    return f.decideLocked(call, subject);
}

fn decideLocked(f: *FaultIo, call: IoCall, subject: IoEvent.Subject) Decision {
    const step = f.steps_.take();
    if (!f.planned.contains(call)) return .{ .step = step, .fault = null };
    const fault = f.plan.decideAt(step, call, subject.path) orelse return .{ .step = step, .fault = null };
    fault.check(call) catch return .{ .step = step, .fault = null };
    return .{ .step = step, .fault = fault };
}

/// What a fault does before the call is made: a delay or a callback.
/// Returns `error.Canceled` when a delay is canceled at a cancelation
/// point; elsewhere the cancel is put back for the next one.
fn before(f: *FaultIo, fault: ?IoFault, cancelation_point: bool) Io.Cancelable!void {
    const x = fault orelse return;
    switch (x) {
        .delay => |d| f.base.vtable.sleep(f.base.userdata, .{ .duration = .{ .raw = d, .clock = .awake } }) catch |err| {
            if (cancelation_point) return err;
            f.base.vtable.recancel(f.base.userdata);
        },
        .call => |c| c.f(f.base, c.ctx),
        .fail, .short, .cancel, .crash => {},
    }
}

/// `before` for a call that is no cancelation point: a canceled delay puts
/// the cancel back for the next one, so nothing is returned.
fn beforeAnywhere(f: *FaultIo, fault: ?IoFault) void {
    f.before(fault, false) catch unreachable; // unreachable: off a cancelation point, before puts the cancel back
}

fn record(f: *FaultIo, step: u64, event: IoEvent) void {
    if (f.options.trace == .off) return;
    const at = f.base.vtable.now(f.base.userdata, .awake);
    f.lock();
    defer f.unlock();
    // ziglint-ignore: Z026 a record that cannot be stored is dropped; the counts and steps still hold
    f.trace_.append(.{ .step = step, .at = at, .event = event }) catch {};
}

// The generated vtable.

/// The wrapper for slot `name`: one template per parameter count, the
/// largest slot (`async`) having seven.
fn shim(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const ret = info.return_type.?;
    const params = info.param_types;
    return switch (params.len) {
        1 => &struct {
            fn f(u: ?*anyopaque) ret {
                return intercept(name, u, .{});
            }
        }.f,
        2 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?) ret {
                return intercept(name, u, .{a});
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?) ret {
                return intercept(name, u, .{ a, c });
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?) ret {
                return intercept(name, u, .{ a, c, d });
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?, e: params[4].?) ret {
                return intercept(name, u, .{ a, c, d, e });
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?, e: params[4].?, g: params[5].?) ret {
                return intercept(name, u, .{ a, c, d, e, g });
            }
        }.f,
        7 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, c: params[2].?, d: params[3].?, e: params[4].?, g: params[5].?, h: params[6].?) ret {
                return intercept(name, u, .{ a, c, d, e, g, h });
            }
        }.f,
        else => @compileError("Io.VTable." ++ name ++ " has more parameters than FaultIo wraps"),
    };
}

fn Return(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?;
}

fn of(userdata: ?*anyopaque) *FaultIo {
    return @ptrCast(@alignCast(userdata.?)); // safe: every Io a FaultIo hands out carries the FaultIo itself
}

fn forward(f: *FaultIo, comptime name: []const u8, args: anytype) Return(name) {
    return @call(.auto, @field(f.base.vtable, name), .{f.base.userdata} ++ args);
}

fn intercept(comptime name: []const u8, userdata: ?*anyopaque, args: anytype) Return(name) {
    const f = of(userdata);
    if (comptime std.mem.eql(u8, name, "operate")) return f.operate(args[0]);
    const call = comptime @field(IoCall, name);
    _ = f.counts[@backingInt(call)].fetchAdd(1, .monotonic);
    if (!f.watched.contains(call)) {
        _ = f.steps_.take();
        return f.forward(name, args);
    }
    return f.slow(name, args);
}

fn slow(f: *FaultIo, comptime name: []const u8, args: anytype) Return(name) {
    const call = comptime @field(IoCall, name);
    const R = Return(name);
    var path_buffer: [path_capacity]u8 = undefined;
    // One lock for the subject's path and the decision.
    f.lock();
    const subject = f.subjectOf(name, args, &path_buffer);
    const d = f.decideLocked(call, subject);
    f.unlock();
    var event: IoEvent = .{ .call = call, .subject = subject, .fault = if (d.fault) |x| x else null };
    if (d.fault) |fault| switch (fault) {
        .fail => |err| if (comptime io_call.failSet(call)) |E| {
            event.outcome = .{ .err = err };
            f.record(d.step, event);
            return failAs(R, E, err);
        },
        .cancel => if (comptime io_call.failSet(call)) |E| {
            event.outcome = .{ .err = error.Canceled };
            f.record(d.step, event);
            return failAs(R, E, error.Canceled);
        },
        .short => |n| if (comptime cutsSlot(name)) {
            const result = f.cutSlot(name, args, n);
            event.outcome = outcomeOf(R, result);
            f.record(d.step, event);
            return result;
        },
        .delay, .call, .crash => {},
    };
    f.before(d.fault, comptime io_call.cancelable(call)) catch |err| if (comptime io_call.failSet(call)) |E| {
        event.outcome = .{ .err = err };
        f.record(d.step, event);
        return failAs(R, E, err);
    };
    if (comptime closes(name)) f.forget(name, args);
    if (comptime std.mem.eql(u8, name, "random") or std.mem.eql(u8, name, "randomSecure")) {
        if (f.options.random_seed != null) {
            f.fillRandom(args[0]);
            f.record(d.step, event);
            return;
        }
    }
    const result = f.forward(name, args);
    if (comptime opens(name)) f.remember(name, result, subject.path);
    event.outcome = outcomeOf(R, result);
    f.record(d.step, event);
    return result;
}

fn fillRandom(f: *FaultIo, buffer: []u8) void {
    f.lock();
    defer f.unlock();
    f.random.bytes(buffer);
}

/// `err`, as the slot's return type gives it.
fn failAs(comptime R: type, comptime E: type, err: anyerror) R {
    if (E == anyerror) return err;
    const names = @typeInfo(E).error_set.error_names orelse return err;
    inline for (names) |n| {
        if (err == @field(anyerror, n)) return @field(E, n);
    }
    unreachable; // unreachable: setPlan and decide checked the error against the set
}

fn outcomeOf(comptime R: type, result: R) IoEvent.Outcome {
    switch (@typeInfo(R)) {
        .error_union => |u| {
            const value = result catch |err| return .{ .err = err };
            return .{ .ok = bytesOf(u.payload, value) };
        },
        .error_set => return .{ .err = result },
        else => return .{ .ok = bytesOf(R, result) },
    }
}

fn bytesOf(comptime T: type, value: T) u64 {
    if (T == usize) return value;
    if (T == Io.net.Stream.ReadResult) return value.data_len;
    return 0;
}

// Operations.

fn operate(f: *FaultIo, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    switch (operation) {
        inline else => |op, tag| {
            const call = comptime @field(IoCall, @tagName(tag));
            _ = f.counts[@backingInt(call)].fetchAdd(1, .monotonic);
            if (!f.watched.contains(call)) {
                _ = f.steps_.take();
                return f.base.vtable.operate(f.base.userdata, operation);
            }
            return f.operateSlow(tag, op);
        },
    }
}

fn operateSlow(f: *FaultIo, comptime tag: Io.Operation.Tag, op: @FieldType(Io.Operation, @tagName(tag))) Io.Cancelable!Io.Operation.Result {
    const call = comptime @field(IoCall, @tagName(tag));
    const op_type = @FieldType(Io.Operation, @tagName(tag));
    var event: IoEvent = .{ .call = call, .subject = .{ .handle = operationHandle(op_type, op) } };
    f.lock();
    if (event.subject.handle != -1) event.subject.path = f.paths.get(event.subject.handle);
    const d = f.decideLocked(call, event.subject);
    f.unlock();
    if (d.fault) |x| event.fault = x;
    if (d.fault) |fault| switch (fault) {
        .cancel => {
            event.outcome = .{ .err = error.Canceled };
            f.record(d.step, event);
            return error.Canceled;
        },
        .fail => |err| {
            event.outcome = .{ .err = err };
            f.record(d.step, event);
            if (err == error.Canceled) return error.Canceled;
            return failedOperation(tag, err);
        },
        .short => |n| if (comptime shortOperation(tag)) {
            const result = try f.shortOperate(tag, op, n);
            event.outcome = operationOutcome(tag, result);
            f.record(d.step, event);
            return result;
        },
        .delay, .call, .crash => {},
    };
    f.before(d.fault, true) catch |err| {
        event.outcome = .{ .err = err };
        f.record(d.step, event);
        return err;
    };
    const result = f.base.vtable.operate(f.base.userdata, @unionInit(Io.Operation, @tagName(tag), op)) catch |err| {
        event.outcome = .{ .err = err };
        f.record(d.step, event);
        return err;
    };
    event.outcome = operationOutcome(tag, result);
    f.record(d.step, event);
    return result;
}

fn operationHandle(comptime Op: type, op: Op) i64 {
    if (Op == noreturn) return -1;
    if (@hasField(Op, "file")) return handleId(op.file.handle);
    if (@hasField(Op, "socket_handle")) return handleId(op.socket_handle);
    return -1;
}

/// An operation's result carrying `err`.
fn failedOperation(comptime tag: Io.Operation.Tag, err: anyerror) Io.Operation.Result {
    const result_type = @FieldType(Io.Operation.Result, @tagName(tag));
    switch (@typeInfo(result_type)) {
        .error_union => |u| return @unionInit(Io.Operation.Result, @tagName(tag), failAs(result_type, u.error_set, err)),
        .@"struct" => |s| {
            if (s.field_types.len == 2 and comptime std.mem.eql(u8, s.field_names[0], "0")) switch (@typeInfo(s.field_types[0])) {
                .optional => |o| if (@typeInfo(o.child) == .error_set) {
                    return @unionInit(Io.Operation.Result, @tagName(tag), .{ failAs(o.child, o.child, err), 0 });
                },
                else => {},
            };
            unreachable; // unreachable: decide checked the error against the operation's set
        },
        else => unreachable, // unreachable: decide checked the error against the operation's set
    }
}

fn operationOutcome(comptime tag: Io.Operation.Tag, result: Io.Operation.Result) IoEvent.Outcome {
    const value = @field(result, @tagName(tag));
    const R = @TypeOf(value);
    switch (@typeInfo(R)) {
        .error_union => |u| {
            const ok = value catch |err| return .{ .err = err };
            return .{ .ok = bytesOf(u.payload, ok) };
        },
        .@"struct" => |s| {
            if (s.field_types.len == 2 and comptime std.mem.eql(u8, s.field_names[0], "0") and s.field_types[1] == usize) {
                if (@typeInfo(s.field_types[0]) == .optional) {
                    if (value[0]) |err| return .{ .err = err };
                }
                return .{ .ok = value[1] };
            }
            return .{ .ok = 0 };
        },
        else => return .{ .ok = 0 },
    }
}

// Short reads and writes.

/// The most buffers a short call passes on; past them it moves less,
/// which a short call may.
const max_vectors = 16;

fn cutsSlot(comptime name: []const u8) bool {
    inline for (.{ "fileReadPositional", "fileWritePositional", "fileWriteFileStreaming", "fileWriteFilePositional", "netWriteFile" }) |n| {
        if (comptime std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn shortOperation(comptime tag: Io.Operation.Tag) bool {
    return switch (tag) {
        .file_read_streaming, .file_write_streaming, .net_read, .net_write => true,
        else => false,
    };
}

fn cutSlot(f: *FaultIo, comptime name: []const u8, args: anytype, n: u32) Return(name) {
    if (n == 0) return 0;
    if (comptime std.mem.eql(u8, name, "fileReadPositional")) {
        var storage: [max_vectors][]u8 = undefined;
        return f.forward(name, .{ args[0], cutReads([]u8, args[1], n, &storage), args[2] });
    } else if (comptime std.mem.eql(u8, name, "fileWritePositional")) {
        var storage: [max_vectors][]const u8 = undefined;
        const cut = cutWrite(args[1], args[2], args[3], n, &storage);
        return f.forward(name, .{ args[0], cut.header, cut.data, cut.splat, args[4] });
    } else {
        // header, reader, limit, ...: the header and the limit share n.
        const header = args[1][0..@min(args[1].len, n)];
        const limit = args[3].min(.limited(n - header.len));
        if (comptime std.mem.eql(u8, name, "fileWriteFilePositional")) {
            return f.forward(name, .{ args[0], header, args[2], limit, args[4] });
        }
        return f.forward(name, .{ args[0], header, args[2], limit });
    }
}

fn shortOperate(f: *FaultIo, comptime tag: Io.Operation.Tag, op: @FieldType(Io.Operation, @tagName(tag)), n: u32) Io.Cancelable!Io.Operation.Result {
    switch (tag) {
        .file_read_streaming => {
            if (n == 0) return @unionInit(Io.Operation.Result, "file_read_streaming", 0);
            var storage: [max_vectors][]u8 = undefined;
            var cut = op;
            cut.data = cutReads([]u8, op.data, n, &storage);
            return f.base.vtable.operate(f.base.userdata, .{ .file_read_streaming = cut });
        },
        .net_read => {
            if (n == 0) return @unionInit(Io.Operation.Result, "net_read", .{ .data_len = 0 });
            var storage: [max_vectors][]u8 = undefined;
            var cut = op;
            cut.data = cutReads([]u8, op.data, n, &storage);
            return f.base.vtable.operate(f.base.userdata, .{ .net_read = cut });
        },
        .file_write_streaming, .net_write => {
            if (n == 0) return @unionInit(Io.Operation.Result, @tagName(tag), 0);
            var storage: [max_vectors][]const u8 = undefined;
            const c = cutWrite(op.header, op.data, op.splat, n, &storage);
            var cut = op;
            cut.header = c.header;
            cut.data = c.data;
            cut.splat = c.splat;
            return f.base.vtable.operate(f.base.userdata, @unionInit(Io.Operation, @tagName(tag), cut));
        },
        else => unreachable, // unreachable: shortOperation admits only these
    }
}

/// The first `n` bytes of `data`, as buffers.
fn cutReads(comptime B: type, data: []const B, n: usize, storage: *[max_vectors]B) []B {
    if (data.len == 0) return storage[0..0];
    var left = n;
    var len: usize = 0;
    for (data) |buffer| {
        if (left == 0 or len == max_vectors) break;
        const take = @min(buffer.len, left);
        storage[len] = buffer[0..take];
        len += 1;
        left -= take;
    }
    if (len == 0) {
        storage[0] = data[0][0..0];
        len = 1;
    }
    return storage[0..len];
}

const Cut = struct { header: []const u8, data: []const []const u8, splat: usize };

/// At most `n` bytes of the write `header`, `data` with its last buffer
/// repeated `splat` times, as a write of the same shape.
fn cutWrite(header: []const u8, data: []const []const u8, splat: usize, n: usize, storage: *[max_vectors][]const u8) Cut {
    if (n <= header.len) {
        storage[0] = "";
        return .{ .header = header[0..n], .data = storage[0..1], .splat = 1 };
    }
    var left = n - header.len;
    var len: usize = 0;
    const last = data.len - 1;
    for (data[0..last]) |buffer| {
        if (left == 0 or len == max_vectors - 1) break;
        const take = @min(buffer.len, left);
        storage[len] = buffer[0..take];
        len += 1;
        left -= take;
    }
    const pattern = data[last];
    var out_splat: usize = 1;
    if (left == 0 or len < last or pattern.len == 0) {
        storage[len] = "";
    } else if (pattern.len <= left) {
        storage[len] = pattern;
        out_splat = @min(splat, left / pattern.len);
    } else {
        storage[len] = if (splat == 0) "" else pattern[0..left];
    }
    return .{ .header = header, .data = storage[0 .. len + 1], .splat = if (splat == 0) 0 else out_splat };
}

// Paths.

const path_capacity = 4096;

/// The calls whose results or arguments change the path table.
const path_calls: CallSet = blk: {
    var set: CallSet = .empty;
    for (.{ "dirOpenDir", "dirCreateDirPathOpen", "dirCreateFile", "dirOpenFile", "dirCreateFileAtomic", "fileClose", "dirClose" }) |name| {
        set.insert(@field(IoCall, name));
    }
    break :blk set;
};

fn opens(comptime name: []const u8) bool {
    inline for (.{ "dirOpenDir", "dirCreateDirPathOpen", "dirCreateFile", "dirOpenFile", "dirCreateFileAtomic" }) |n| {
        if (comptime std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn closes(comptime name: []const u8) bool {
    return comptime std.mem.eql(u8, name, "fileClose") or std.mem.eql(u8, name, "dirClose");
}

fn handleId(handle: anytype) i64 {
    return switch (@typeInfo(@TypeOf(handle))) {
        .pointer, .optional => @bitCast(@as(u64, @intFromPtr(handle))), // safe: a handle's value, kept as a number
        .int => @intCast(handle),
        else => @compileError("a handle is a pointer or an integer"),
    };
}

/// The handle and path of a call: `(dir, sub_path)` slots join the dir's
/// known path to the sub path; a rename, link or symlink names its
/// destination; handle slots look their handle up. Under the lock.
fn subjectOf(f: *FaultIo, comptime name: []const u8, args: anytype, buffer: *[path_capacity]u8) IoEvent.Subject {
    const Args = @TypeOf(args);
    const fields = @typeInfo(Args).@"struct".field_types;
    if (fields.len == 0) return .{};
    const Dir = Io.Dir;
    const File = Io.File;
    if (fields[0] == Dir) {
        const dir: Dir = args[0];
        // A rename or hard link names its destination: (old_dir, old, new_dir, new).
        if (fields.len >= 4 and fields[2] == Dir and fields[3] == []const u8) {
            return f.joined(args[2], args[3], buffer);
        }
        // A symlink names the link: (dir, target, link, flags).
        if (comptime std.mem.eql(u8, name, "dirSymLink")) return f.joined(dir, args[2], buffer);
        if (fields.len >= 2 and fields[1] == []const u8) return f.joined(dir, args[1], buffer);
        return f.known(handleId(dir.handle));
    }
    if (fields[0] == File) return f.known(handleId(args[0].handle));
    if (fields[0] == []const File) return if (args[0].len > 0) f.known(handleId(args[0][0].handle)) else .{};
    if (fields[0] == []const Dir) return if (args[0].len > 0) f.known(handleId(args[0][0].handle)) else .{};
    if (fields[0] == *Dir.Reader) return f.known(handleId(args[0].dir.handle));
    if (fields[0] == *File.MemoryMap) return f.known(handleId(args[0].file.handle));
    if (fields[0] == Io.net.Socket.Handle and !std.mem.startsWith(u8, name, "dir") and std.mem.startsWith(u8, name, "net")) {
        return f.known(handleId(args[0]));
    }
    return .{};
}

fn known(f: *FaultIo, handle: i64) IoEvent.Subject {
    if (!f.options.track_paths) return .{ .handle = handle };
    return .{ .handle = handle, .path = f.paths.get(handle) };
}

fn joined(f: *FaultIo, dir: Io.Dir, sub_path: []const u8, buffer: *[path_capacity]u8) IoEvent.Subject {
    const handle = handleId(dir.handle);
    if (!f.options.track_paths) return .{ .handle = handle, .path = sub_path };
    if (Io.Dir.path.isAbsolute(sub_path) or dir.handle == Io.Dir.cwd().handle) return .{ .handle = handle, .path = sub_path };
    const p = f.paths.get(handle) orelse return .{ .handle = handle, .path = sub_path };
    if (p.len + 1 + sub_path.len > buffer.len) return .{ .handle = handle, .path = sub_path };
    @memcpy(buffer[0..p.len], p);
    buffer[p.len] = '/';
    @memcpy(buffer[p.len + 1 ..][0..sub_path.len], sub_path);
    return .{ .handle = handle, .path = buffer[0 .. p.len + 1 + sub_path.len] };
}

fn remember(f: *FaultIo, comptime name: []const u8, result: Return(name), path: ?[]const u8) void {
    const p = path orelse return;
    const opened = result catch return;
    const handle = if (comptime std.mem.eql(u8, name, "dirCreateFileAtomic")) handleId(opened.file.handle) else handleId(opened.handle);
    f.lock();
    defer f.unlock();
    // ziglint-ignore: Z026 a path that cannot be stored leaves the handle unnamed, nothing worse
    const copy = f.path_arena.allocator().dupe(u8, p) catch return;
    // ziglint-ignore: Z026 as above
    f.paths.put(f.gpa, handle, copy) catch {};
}

fn forget(f: *FaultIo, comptime name: []const u8, args: anytype) void {
    _ = name;
    f.lock();
    defer f.unlock();
    for (args[0]) |handle_owner| _ = f.paths.remove(handleId(handle_owner.handle));
}
