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
//! The operations of a `Batch` are calls too: each is counted, stepped,
//! decided and recorded once, when the first await after its submission
//! sees it, whichever await completes it.
//!
//! A cancel `FaultIo` lands is held for its task, as a base holds its own,
//! so `recancel` re-arms it for the task's next cancelation point. A task
//! is the thread it runs on, as on std's `Threaded`, unless the base knows
//! its tasks, as a `Sim` does.
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
/// Private: the calls that leave the fast path, read there without the
/// lock: what `watched` names, and what a cancel this `FaultIo` holds
/// needs.
watching: Watching = .{},
/// Private: what the plan, the trace, the paths and the seed need watched.
watched: Calls = .empty,
/// Private: the calls the plan may fire on.
planned: Calls = .empty,
/// Private: open handle to the path it was opened by.
paths: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,
path_arena: std.heap.ArenaAllocator,
/// Private: `io.random` under `random_seed`, and the draws of `.chance`
/// entries when `Options.source` is null.
random: Source,
/// Private: one shim per child `allocator` was given.
shims: std.ArrayList(*AllocatorShim) = .empty,
/// Private: the tasks holding a cancel this `FaultIo` landed, theirs to
/// re-arm with `recancel`. Under the lock.
cancels: std.ArrayList(Held) = .empty,
/// Private: how many of those are re-armed, read without the lock at a
/// cancelation point.
rearmed: std.atomic.Value(u32) = .init(0),
/// Private: the calling task, and whether its cancel protection is
/// blocked. A simulation sets its own.
tasks: Tasks = .{},
/// Private: how many batches have a state, read without the lock.
batch_count: std.atomic.Value(usize) = .init(0),
/// Private: what is known of each batch an await has seen, the states no
/// batch needs and how many states there are, under the lock; and the state
/// the last lookup found, read without the lock.
batches: std.AutoHashMapUnmanaged(*Io.Batch, *Batched) = .empty,
spare_batches: std.ArrayList(*Batched) = .empty,
batch_states: usize = 0,
last_batch: std.atomic.Value(?*Batched) = .init(null),

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
    f.cancels.deinit(gpa);
    var it = f.batches.valueIterator();
    while (it.next()) |b| b.*.destroy(gpa);
    f.batches.deinit(gpa);
    for (f.spare_batches.items) |b| b.destroy(gpa);
    f.spare_batches.deinit(gpa);
    gpa.destroy(f);
}

/// The `Io` to hand the code under test.
pub fn io(f: *FaultIo) Io {
    return .{ .userdata = f, .vtable = &vtable };
}

/// Replaces the plan and forgets the old one's matches. Not to be called
/// while calls are in flight.
fn hasCrash(fault: IoFault) bool {
    return switch (fault) {
        .crash => true,
        .call => |c| if (c.then) |then| hasCrash(then.*) else false,
        else => false,
    };
}

pub fn setPlan(f: *FaultIo, entries: []const IoPlan.Entry) InitError!void {
    var planned: Calls = .empty;
    for (entries) |entry| {
        if (hasCrash(entry.fault) and f.tasks.on_crash == null) return error.FaultNotApplicable;
        const call = switch (entry.at) {
            .step => null,
            .nth => |nth| nth.call,
            .chance => |c| c.call,
        };
        if (call) |c| {
            if (entry.fault != .crash) try entry.fault.check(c);
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
    f.watch();
}

/// A set of calls, a bit per call.
const Calls = struct {
    words: [word_count]u64 = @splat(0),

    const word_count = (io_call.call_count + 63) / 64;

    const empty: Calls = .{};

    const full: Calls = blk: {
        var all: Calls = .{};
        for (0..io_call.call_count) |i| all.words[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        break :blk all;
    };

    fn of(comptime names: []const []const u8) Calls {
        var set: Calls = .{};
        for (names) |name| set.insert(@field(IoCall, name));
        return set;
    }

    fn insert(c: *Calls, call: IoCall) void {
        const i: usize = @backingInt(call);
        c.words[i / 64] |= @as(u64, 1) << @intCast(i % 64);
    }

    fn contains(c: Calls, call: IoCall) bool {
        const i: usize = @backingInt(call);
        return c.words[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
    }

    fn setUnion(c: *Calls, other: Calls) void {
        for (&c.words, other.words) |*word, more| word.* |= more;
    }
};

/// `Calls` each call reads without the lock: one word load and a bit test.
const Watching = struct {
    words: [Calls.word_count]std.atomic.Value(u64) = @splat(.init(0)),

    inline fn contains(w: *const Watching, call: IoCall) bool {
        const i: usize = @backingInt(call);
        return w.words[i / 64].load(.monotonic) & (@as(u64, 1) << @intCast(i % 64)) != 0;
    }

    fn set(w: *Watching, calls: Calls) void {
        for (&w.words, calls.words) |*word, value| word.store(value, .monotonic);
    }
};

/// Every cancelation point: where a re-armed cancel may land.
const cancelation_points: Calls = blk: {
    @setEvalBranchQuota(10_000);
    var set: Calls = .empty;
    for (std.enums.values(IoCall)) |call| if (io_call.cancelable(call)) set.insert(call);
    break :blk set;
};

/// Sets what leaves the fast path: `watched`, `recancel` while a task holds
/// a cancel landed here, and every cancelation point while one is re-armed.
/// Under the lock, or with no call in flight.
fn watch(f: *FaultIo) void {
    var calls = f.watched;
    if (f.cancels.items.len > 0) calls.insert(.recancel);
    if (f.rearmed.load(.monotonic) > 0) calls.setUnion(cancelation_points);
    f.watching.set(calls);
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

/// The plan's entries that fired, in order, with the step of each. A fault
/// that could not apply where it fired (a step entry on a call it does not
/// fit, a cancel under blocked protection) is listed and did nothing: the
/// trace records what each call was given.
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
/// is a refusal. Lives as long as the `FaultIo`. The first call for a
/// child makes its shim; every later call for an equal child returns the
/// same allocator and allocates nothing.
pub fn allocator(f: *FaultIo, child: Allocator) Allocator.Error!Allocator {
    f.lock();
    defer f.unlock();
    for (f.shims.items) |s| {
        if (s.child.ptr == child.ptr and s.child.vtable == child.vtable) return .{ .ptr = s, .vtable = &allocator_vtable };
    }
    try f.shims.ensureUnusedCapacity(f.gpa, 1);
    const s = try f.gpa.create(AllocatorShim);
    s.* = .{ .fio = f, .child = child };
    f.shims.appendAssumeCapacity(s);
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
    if (!f.watching.contains(.alloc)) {
        _ = f.steps_.take();
        return s.child.rawAlloc(len, alignment, ret_addr);
    }
    const d = f.decide(.alloc, .{});
    if (refused(f.preludeAnywhere(d.fault))) {
        f.record(d.step, .{ .call = .alloc, .outcome = .{ .err = error.OutOfMemory }, .fault = d.fault.? });
        return null;
    }
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
    if (!f.watching.contains(.resize)) {
        _ = f.steps_.take();
        return s.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    const d = f.decide(.resize, .{});
    if (refused(f.preludeAnywhere(d.fault))) {
        f.record(d.step, .{ .call = .resize, .outcome = .{ .err = error.OutOfMemory }, .fault = d.fault.? });
        return false;
    }
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
    if (!f.watching.contains(.remap)) {
        _ = f.steps_.take();
        return s.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    const d = f.decide(.remap, .{});
    if (refused(f.preludeAnywhere(d.fault))) {
        f.record(d.step, .{ .call = .remap, .outcome = .{ .err = error.OutOfMemory }, .fault = d.fault.? });
        return null;
    }
    const result = s.child.rawRemap(memory, alignment, new_len, ret_addr);
    f.record(d.step, .{
        .call = .remap,
        .outcome = if (result != null) .{ .ok = new_len } else .{ .err = error.OutOfMemory },
        .fault = if (d.fault) |x| x else null,
    });
    return result;
}

/// Whether what is left of an allocation's fault refuses it: the one
/// fault an allocation can be given besides a delay or a callback.
fn refused(fault: ?IoFault) bool {
    const x = fault orelse return false;
    return x == .fail;
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

/// What a fault does before the call: a callback, then what it leads to,
/// or a delay. Returns what is left to do to the call itself, or null to
/// make it. A delay canceled at a cancelation point returns
/// `error.Canceled`; elsewhere the cancel is put back for the next one.
fn prelude(f: *FaultIo, fault: ?IoFault, cancelation_point: bool) Io.Cancelable!?IoFault {
    var next = fault;
    while (next) |x| switch (x) {
        .call => |c| {
            c.f(f.base, c.ctx);
            next = if (c.then) |then| then.* else null;
        },
        .delay => |d| {
            f.base.vtable.sleep(f.base.userdata, .{ .duration = .{ .raw = d, .clock = .awake } }) catch |err| {
                if (cancelation_point) return err;
                f.base.vtable.recancel(f.base.userdata);
            };
            return null;
        },
        .crash => {
            f.tasks.on_crash.?(f.base);
            return null;
        },
        .fail, .fail_after, .short, .cancel, .spurious_wake, .stall => return x,
    };
    return null;
}

/// `prelude` for a call that is no cancelation point: a canceled delay puts
/// the cancel back for the next one, so nothing is returned.
fn preludeAnywhere(f: *FaultIo, fault: ?IoFault) ?IoFault {
    return f.prelude(fault, false) catch unreachable; // unreachable: off a cancelation point, prelude puts the cancel back
}

fn record(f: *FaultIo, step: u64, event: IoEvent) void {
    if (f.options.trace == .off) return;
    const at = f.base.vtable.now(f.base.userdata, .awake);
    f.lock();
    defer f.unlock();
    // glint-ignore: Z026 -- a record that cannot be stored is dropped; the counts and steps still hold
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
    if (comptime std.mem.eql(u8, name, "batchAwaitAsync")) return f.batchAwait(false, args[0], .none);
    if (comptime std.mem.eql(u8, name, "batchAwaitConcurrent")) return f.batchAwait(true, args[0], args[1]);
    if (comptime std.mem.eql(u8, name, "batchCancel")) return f.batchCancel(args[0]);
    const call = comptime @field(IoCall, name);
    _ = f.counts[@backingInt(call)].fetchAdd(1, .monotonic);
    if (!f.watching.contains(call)) {
        _ = f.steps_.take();
        return f.forward(name, args);
    }
    return f.slow(name, args);
}

noinline fn slow(f: *FaultIo, comptime name: []const u8, args: anytype) Return(name) {
    const call = comptime @field(IoCall, name);
    const R = Return(name);
    const cancelation_point = comptime io_call.cancelable(call);
    var path_buffer: [path_capacity]u8 = undefined;
    // One lock for the subject's path and the decision.
    f.lock();
    const subject = f.subjectOf(name, args, &path_buffer);
    const d = f.decideLocked(call, subject);
    // Seeded randomness given no fault: drawn under the same lock.
    if (comptime std.mem.eql(u8, name, "random")) if (d.fault == null and f.options.random_seed != null) {
        f.fillRandomLocked(args[0]);
        f.unlock();
        f.record(d.step, .{ .call = call, .subject = subject });
        return;
    };
    f.unlock();
    var event: IoEvent = .{ .call = call, .subject = subject, .fault = if (d.fault) |x| x else null };
    const fault = f.prelude(d.fault, cancelation_point) catch |err| return f.failed(name, d.step, &event, err);
    // What replaces the call.
    if (fault) |x| switch (x) {
        .fail => |err| return f.failed(name, d.step, &event, err),
        .cancel => if (cancelation_point) {
            if (f.land()) return f.failed(name, d.step, &event, error.Canceled);
            if (d.fault.? == .cancel) event.fault = null;
        },
        .stall => if (cancelation_point) return f.failed(name, d.step, &event, f.stall()),
        .spurious_wake => if (comptime call == .futexWait or call == .futexWaitUncancelable) {
            f.record(d.step, event);
            return;
        },
        .fail_after, .short, .delay, .call, .crash => {},
    };
    // A cancel re-armed for this task lands where the base would deliver it.
    if (cancelation_point and f.rearmedLands()) return f.failed(name, d.step, &event, error.Canceled);
    if (comptime call == .recancel) if (f.rearm()) {
        f.record(d.step, event);
        return;
    };
    // What changes the call.
    if (fault) |x| switch (x) {
        .short => |n| if (comptime cutsSlot(name)) {
            const result = f.cutSlot(name, args, n);
            event.outcome = outcomeOf(R, result);
            f.record(d.step, event);
            return result;
        },
        .fail_after => |err| if (comptime io_call.failSet(call) != null) {
            const result = f.forward(name, args);
            if (succeeded(R, result)) return f.failed(name, d.step, &event, err);
            event.outcome = outcomeOf(R, result);
            f.record(d.step, event);
            return result;
        },
        .fail, .cancel, .stall, .spurious_wake, .delay, .call, .crash => {},
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

/// Records `err` as the outcome of slot `name` and returns it as the slot's
/// return type gives it.
fn failed(f: *FaultIo, comptime name: []const u8, step: u64, event: *IoEvent, err: anyerror) Return(name) {
    event.outcome = .{ .err = err };
    f.record(step, event.*);
    if (comptime io_call.failSet(@field(IoCall, name))) |E| return failAs(Return(name), E, err);
    unreachable; // unreachable: only a call that can fail is failed, as setPlan and decide check
}

fn succeeded(comptime R: type, result: R) bool {
    return switch (@typeInfo(R)) {
        .error_union => if (result) |_| true else |_| false,
        else => true,
    };
}

/// `buffer` from the seeded source, eight bytes a draw.
fn fillRandom(f: *FaultIo, buffer: []u8) void {
    f.lock();
    defer f.unlock();
    f.fillRandomLocked(buffer);
}

fn fillRandomLocked(f: *FaultIo, buffer: []u8) void {
    var rest = buffer;
    while (rest.len > 0) {
        const word: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, f.random.below(std.math.maxInt(u64))));
        const n = @min(rest.len, 8);
        @memcpy(rest[0..n], word[0..n]);
        rest = rest[n..];
    }
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
            if (!f.watching.contains(call)) {
                _ = f.steps_.take();
                return f.base.vtable.operate(f.base.userdata, operation);
            }
            return f.operateSlow(tag, op);
        },
    }
}

noinline fn operateSlow(f: *FaultIo, comptime tag: Io.Operation.Tag, op: @FieldType(Io.Operation, @tagName(tag))) Io.Cancelable!Io.Operation.Result {
    const call = comptime @field(IoCall, @tagName(tag));
    const op_type = @FieldType(Io.Operation, @tagName(tag));
    var event: IoEvent = .{ .call = call, .subject = .{ .handle = operationHandle(op_type, op) } };
    f.lock();
    event.subject.path = f.pathOf(event.subject.handle);
    const d = f.decideLocked(call, event.subject);
    f.unlock();
    if (d.fault) |x| event.fault = x;
    const fault = f.prelude(d.fault, true) catch |err| return f.operationFailed(d.step, &event, err);
    if (fault) |x| switch (x) {
        .cancel => {
            if (f.land()) return f.operationFailed(d.step, &event, error.Canceled);
            if (d.fault.? == .cancel) event.fault = null;
        },
        .fail => |err| {
            event.outcome = .{ .err = err };
            f.record(d.step, event);
            if (err == error.Canceled) return error.Canceled;
            return failedOperation(tag, err);
        },
        .stall => return f.operationFailed(d.step, &event, f.stall()),
        .fail_after, .short, .spurious_wake, .delay, .call, .crash => {},
    };
    if (f.rearmedLands()) return f.operationFailed(d.step, &event, error.Canceled);
    if (fault) |x| switch (x) {
        .short => |n| if (comptime shortOperation(tag)) {
            const result = f.shortOperate(tag, op, n) catch |err| return f.operationFailed(d.step, &event, err);
            event.outcome = operationOutcome(tag, result);
            f.record(d.step, event);
            return result;
        },
        .fail_after => |err| {
            const result = f.base.vtable.operate(f.base.userdata, @unionInit(Io.Operation, @tagName(tag), op)) catch |e| return f.operationFailed(d.step, &event, e);
            event.outcome = operationOutcome(tag, result);
            if (event.outcome == .ok) {
                event.outcome = .{ .err = err };
                f.record(d.step, event);
                return failedOperation(tag, err);
            }
            f.record(d.step, event);
            return result;
        },
        .fail, .cancel, .stall, .spurious_wake, .delay, .call, .crash => {},
    };
    const result = f.base.vtable.operate(f.base.userdata, @unionInit(Io.Operation, @tagName(tag), op)) catch |err| {
        return f.operationFailed(d.step, &event, err);
    };
    event.outcome = operationOutcome(tag, result);
    f.record(d.step, event);
    return result;
}

/// An operation that did not happen: `operate`'s own `error.Canceled`.
fn operationFailed(f: *FaultIo, step: u64, event: *IoEvent, err: Io.Cancelable) Io.Cancelable {
    event.outcome = .{ .err = err };
    f.record(step, event.*);
    return err;
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

// Cancels.

/// A task holding a cancel this `FaultIo` landed, and whether `recancel`
/// re-armed it.
const Held = struct { task: u64, rearmed: bool = false };

/// How a `FaultIo` sees the calling task.
const Tasks = struct {
    /// Internal: installed only by a Sim with an Fs.
    on_crash: ?*const fn (base: Io) void = null,
    /// Which task is calling: its thread, by default.
    id: *const fn (base: Io) u64 = threadOf,
    /// Whether the calling task's cancel protection is blocked: asked of
    /// the base, by default, and put back as it was.
    blocked: *const fn (base: Io) bool = askBase,
};

fn threadOf(_: Io) u64 {
    return std.Thread.getCurrentId();
}

fn askBase(base: Io) bool {
    const was = base.vtable.swapCancelProtection(base.userdata, .blocked);
    _ = base.vtable.swapCancelProtection(base.userdata, was);
    return was == .blocked;
}

/// Lands a planned cancel on the calling task, unless its protection is
/// blocked, and holds it for `recancel`. Returns whether it landed.
fn land(f: *FaultIo) bool {
    if (f.tasks.blocked(f.base)) return false;
    const task = f.tasks.id(f.base);
    f.lock();
    defer f.unlock();
    for (f.cancels.items) |*h| if (h.task == task) {
        if (h.rearmed) {
            h.rearmed = false;
            if (f.rearmed.fetchSub(1, .monotonic) == 1) f.watch();
        }
        return true;
    };
    // A cancel that could not be held could not be re-armed: it does not land.
    f.cancels.append(f.gpa, .{ .task = task }) catch return false;
    if (f.cancels.items.len == 1) f.watch();
    return true;
}

/// At `recancel`: re-arms the cancel the calling task holds from this
/// `FaultIo`. Returns false when it holds none, and the base's is the one
/// to re-arm.
fn rearm(f: *FaultIo) bool {
    const task = f.tasks.id(f.base);
    f.lock();
    defer f.unlock();
    for (f.cancels.items) |*h| if (h.task == task and !h.rearmed) {
        h.rearmed = true;
        if (f.rearmed.fetchAdd(1, .monotonic) == 0) f.watch();
        return true;
    };
    return false;
}

/// At a cancelation point: whether the calling task's re-armed cancel
/// lands here, unless its protection is blocked.
fn rearmedLands(f: *FaultIo) bool {
    if (f.rearmed.load(.monotonic) == 0) return false;
    const task = f.tasks.id(f.base);
    const index = index: {
        f.lock();
        defer f.unlock();
        for (f.cancels.items, 0..) |h, i| if (h.task == task and h.rearmed) break :index i;
        return false;
    };
    if (f.tasks.blocked(f.base)) return false;
    // Only the task itself changes its entry, and entries are never
    // removed, so its index still holds it.
    f.lock();
    defer f.unlock();
    f.cancels.items[index].rearmed = false;
    if (f.rearmed.fetchSub(1, .monotonic) == 1) f.watch();
    return true;
}

/// A stalled call's wait: on the base, until a cancel ends it.
fn stall(f: *FaultIo) Io.Cancelable {
    if (f.rearmedLands()) return error.Canceled;
    const never: u32 = 0;
    while (true) f.base.vtable.futexWait(f.base.userdata, &never, 0, .none) catch return error.Canceled;
}

// Batches.

/// How many batches keep their state once canceled, so that one made again
/// at the same place finds its own.
const kept_batches = 16;

/// What `FaultIo` knows of one batch: per operation, by its index in the
/// batch's storage, whether an await decided it and what is left to do to
/// it.
///
/// Only the task using a batch reads or changes its state, as only one
/// task uses a batch at a time. A state is never freed before the
/// `FaultIo`: one its batch no longer needs is kept for another, so a task
/// that finds it through `last` may read which batch it is for at any time.
const Batched = struct {
    /// The batch it is for, null while it is spare. Set under the lock.
    batch: std.atomic.Value(?*Io.Batch) = .init(null),
    storage: []Io.Operation.Storage,
    ops: []Op,
    /// A short operation's cut buffers, alive until it completes: made the
    /// first time an index is cut, and kept with the state.
    cuts: []?*Buffers,
    /// Bumped by every await; an operation decided by this one carries it.
    round: u64 = 0,

    const Op = struct {
        decided: bool = false,
        /// Kept from the base until the batch is canceled.
        stalled: bool = false,
        /// A lost answer, given when the operation completes.
        after: ?anyerror = null,
        /// The await that decided it, its step, its path and what the plan
        /// gave it.
        round: u64 = 0,
        step: u64 = 0,
        path: ?[]const u8 = null,
        fault: ?IoFault = null,
    };

    const Buffers = union { reads: [max_vectors][]u8, writes: [max_vectors][]const u8 };

    fn fits(state: *const Batched, b: *Io.Batch) bool {
        return state.storage.ptr == b.storage.ptr and state.ops.len == b.storage.len;
    }

    /// Takes the state for `b`, every operation undecided.
    fn adopt(state: *Batched, b: *Io.Batch) void {
        state.storage = b.storage;
        @memset(state.ops, .{});
        state.batch.store(b, .release);
    }

    fn destroy(state: *Batched, gpa: Allocator) void {
        for (state.cuts) |cut| if (cut) |buffers| gpa.destroy(buffers);
        gpa.free(state.cuts);
        gpa.free(state.ops);
        gpa.destroy(state);
    }
};

/// The state of `b`, made on its first await when `make` says so; null
/// when it cannot be had, and the batch's operations then reach the base
/// undecided. The state the last lookup found is had without the lock.
fn batchOf(f: *FaultIo, b: *Io.Batch, make: bool) ?*Batched {
    if (f.last_batch.load(.acquire)) |last| {
        // `last` may be another task's batch's, or spare; it is this
        // batch's only if it says so, and then only this task changes it.
        if (last.batch.load(.acquire) == b and last.fits(b)) return last;
    }
    f.lock();
    defer f.unlock();
    const state = if (make) f.batchEntry(b) orelse return null else f.batches.get(b) orelse return null;
    f.last_batch.store(state, .release);
    return state;
}

/// Under the lock.
fn batchEntry(f: *FaultIo, b: *Io.Batch) ?*Batched {
    const entry = f.batches.getOrPut(f.gpa, b) catch return null;
    if (entry.found_existing) {
        const state = entry.value_ptr.*;
        if (state.fits(b)) return state;
        // Another batch where one that was never canceled was.
        f.retire(state);
        const replacement = f.spareFor(b) orelse {
            f.batches.removeByPtr(entry.key_ptr);
            f.batch_count.store(f.batches.count(), .monotonic);
            return null;
        };
        replacement.adopt(b);
        entry.value_ptr.* = replacement;
        return replacement;
    }
    const state = f.spareFor(b) orelse {
        f.batches.removeByPtr(entry.key_ptr);
        return null;
    };
    state.adopt(b);
    entry.value_ptr.* = state;
    f.batch_count.store(f.batches.count(), .monotonic);
    return state;
}

/// A spare state that fits `b`, or a new one. Under the lock.
fn spareFor(f: *FaultIo, b: *Io.Batch) ?*Batched {
    for (f.spare_batches.items, 0..) |spare, i| {
        if (spare.ops.len == b.storage.len) return f.spare_batches.swapRemove(i);
    }
    // A state cannot be freed while the `FaultIo` lives, so there is room
    // for every one among the spares before it is made.
    f.spare_batches.ensureTotalCapacity(f.gpa, f.batch_states + 1) catch return null;
    const state = f.gpa.create(Batched) catch return null;
    const ops = f.gpa.alloc(Batched.Op, b.storage.len) catch {
        f.gpa.destroy(state);
        return null;
    };
    const cuts = f.gpa.alloc(?*Batched.Buffers, b.storage.len) catch {
        f.gpa.free(ops);
        f.gpa.destroy(state);
        return null;
    };
    @memset(cuts, null);
    state.* = .{ .storage = b.storage, .ops = ops, .cuts = cuts };
    f.batch_states += 1;
    return state;
}

/// Puts a state no batch needs among the spares. Under the lock.
fn retire(f: *FaultIo, state: *Batched) void {
    state.batch.store(null, .release);
    if (f.last_batch.load(.monotonic) == state) f.last_batch.store(null, .release);
    // Room was made for every state when it was made.
    f.spare_batches.appendAssumeCapacity(state);
}

fn AwaitError(comptime concurrent: bool) type {
    return if (concurrent) Io.Batch.AwaitConcurrentError else Io.Cancelable;
}

/// An await: each operation the batch holds that no await has seen is a
/// call, decided in submission order; then the await, itself a call,
/// waits on the base for what the base may complete.
fn batchAwait(f: *FaultIo, comptime concurrent: bool, b: *Io.Batch, timeout: Io.Timeout) AwaitError(concurrent)!void {
    const call: IoCall = if (concurrent) .batchAwaitConcurrent else .batchAwaitAsync;
    _ = f.counts[@backingInt(call)].fetchAdd(1, .monotonic);
    const state = f.batchOf(b, true);
    const work = if (state) |s| f.takeOperations(b, s) else false;
    const d: Decision = if (f.watching.contains(call)) f.decide(call, .{}) else .{ .step = f.steps_.take(), .fault = null };
    var lands = if (work) f.applyOperations(b, state.?) else false;
    var event: IoEvent = .{ .call = call, .fault = if (d.fault) |x| x else null };
    const fault = f.prelude(d.fault, true) catch |err| return f.awaitFailed(concurrent, d.step, &event, err);
    if (fault) |x| switch (x) {
        .fail => |err| return f.awaitFailed(concurrent, d.step, &event, err),
        .cancel => lands = true,
        .stall => return f.awaitFailed(concurrent, d.step, &event, f.stall()),
        .fail_after, .short, .spurious_wake, .delay, .call, .crash => {},
    };
    if (lands) {
        if (f.land()) return f.awaitFailed(concurrent, d.step, &event, error.Canceled);
        if (d.fault != null and d.fault.? == .cancel) event.fault = null;
    }
    if (f.rearmedLands()) return f.awaitFailed(concurrent, d.step, &event, error.Canceled);
    const result = f.awaitBase(concurrent, b, state, timeout);
    if (state) |s| finished(b, s);
    event.outcome = if (result) |_| .{ .ok = 0 } else |err| .{ .err = err };
    f.record(d.step, event);
    return result;
}

fn awaitFailed(f: *FaultIo, comptime concurrent: bool, step: u64, event: *IoEvent, err: anyerror) AwaitError(concurrent) {
    event.outcome = .{ .err = err };
    f.record(step, event.*);
    const E = AwaitError(concurrent);
    return failAs(E, E, err);
}

/// Counts, steps and decides each submitted operation no await has
/// decided, as if it were operated alone. Returns whether any of them
/// needs `applyOperations`: a fault, or a record to make.
fn takeOperations(f: *FaultIo, b: *Io.Batch, state: *Batched) bool {
    state.round += 1;
    var work = false;
    var index = b.submitted.head;
    while (index != .none) {
        const i = index.toIndex();
        const submission = &b.storage[i].submission;
        index = submission.node.next;
        const op = &state.ops[i];
        if (op.decided) continue;
        switch (submission.operation) {
            inline else => |o, tag| {
                const call = comptime @field(IoCall, @tagName(tag));
                _ = f.counts[@backingInt(call)].fetchAdd(1, .monotonic);
                op.* = .{ .decided = true, .round = state.round };
                if (f.watching.contains(call)) {
                    const handle = operationHandle(@TypeOf(o), o);
                    f.lock();
                    defer f.unlock();
                    op.path = f.pathOf(handle);
                    const d = f.decideLocked(call, .{ .handle = handle, .path = op.path });
                    op.step = d.step;
                    op.fault = d.fault;
                    work = true;
                } else op.step = f.steps_.take();
            },
        }
    }
    return work;
}

/// What this await's decisions do to its operations, and their records. A
/// failure or a short read of nothing completes an operation here;
/// anything else leaves it for the base, or keeps it from the base.
/// Returns whether one asked for a cancel, which lands on the await, since
/// a batched operation has no `Canceled` of its own.
fn applyOperations(f: *FaultIo, b: *Io.Batch, state: *Batched) bool {
    var lands = false;
    var previous: Io.Operation.OptionalIndex = .none;
    var index = b.submitted.head;
    while (index != .none) {
        const i = index.toIndex();
        const next = b.storage[i].submission.node.next;
        const op = &state.ops[i];
        if (op.round != state.round) {
            previous = index;
            index = next;
            continue;
        }
        switch (f.applyOperation(&b.storage[i], op, &state.cuts[i])) {
            .submitted => previous = index,
            .cancel => {
                lands = true;
                previous = index;
            },
            .completed => |result| {
                unlinkSubmitted(b, previous, index);
                appendCompleted(b, index, result);
            },
        }
        index = next;
    }
    return lands;
}

const Applied = union(enum) { submitted, cancel, completed: Io.Operation.Result };

fn applyOperation(f: *FaultIo, storage: *Io.Operation.Storage, op: *Batched.Op, cut: *?*Batched.Buffers) Applied {
    switch (storage.submission.operation) {
        inline else => |o, tag| {
            const call = comptime @field(IoCall, @tagName(tag));
            var event: IoEvent = .{
                .call = call,
                .subject = .{ .handle = operationHandle(@TypeOf(o), o), .path = op.path },
                .fault = if (op.fault) |x| x else null,
            };
            defer f.record(op.step, event);
            const fault = f.preludeAnywhere(op.fault) orelse return .submitted;
            switch (fault) {
                .cancel => return .cancel,
                .fail => |err| {
                    if (err == error.Canceled) return .cancel;
                    event.outcome = .{ .err = err };
                    return .{ .completed = failedOperation(tag, err) };
                },
                .fail_after => |err| op.after = err,
                .stall => op.stalled = true,
                .short => |n| if (comptime shortOperation(tag)) {
                    if (n == 0) return .{ .completed = noProgress(tag) };
                    const buffers = cut.* orelse made: {
                        // A cut that cannot be held is not made: the
                        // operation moves what it would have.
                        const made = f.gpa.create(Batched.Buffers) catch return .submitted;
                        cut.* = made;
                        break :made made;
                    };
                    storage.submission.operation = cutOperation(tag, o, n, buffers);
                },
                .spurious_wake, .delay, .call, .crash => {},
            }
            return .submitted;
        },
    }
}

/// The wait itself. Stalled operations are kept from the base and put
/// back after; an await with nothing the base could complete waits out its
/// timeout, or until canceled, as an await on silent operations does.
fn awaitBase(f: *FaultIo, comptime concurrent: bool, b: *Io.Batch, state: ?*Batched, timeout: Io.Timeout) AwaitError(concurrent)!void {
    var kept: Io.Operation.List = .empty;
    if (state) |s| keepStalled(b, s, &kept);
    defer putBack(b, &kept);
    const completed = b.completed.head != .none;
    if (b.submitted.head == .none and kept.head != .none) {
        if (completed) return;
        if (!concurrent or timeout == .none) return f.stall();
        try f.base.vtable.sleep(f.base.userdata, timeout);
        return error.Timeout;
    }
    if (!concurrent) {
        // What a fault completed is enough; the rest waits for the next
        // await.
        if (completed) return;
        return f.base.vtable.batchAwaitAsync(f.base.userdata, b);
    }
    if (completed) {
        f.base.vtable.batchAwaitConcurrent(f.base.userdata, b, .{ .duration = .{ .raw = .zero, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
        return;
    }
    return f.base.vtable.batchAwaitConcurrent(f.base.userdata, b, timeout);
}

/// The completions, each given what its decision left for it, and
/// forgotten as decided: its index may be submitted again.
fn finished(b: *Io.Batch, state: *Batched) void {
    var index = b.completed.head;
    while (index != .none) {
        const i = index.toIndex();
        const completion = &b.storage[i].completion;
        const op = &state.ops[i];
        if (op.decided) {
            if (op.after) |err| completion.result = lostAnswer(completion.result, err);
            op.* = .{};
        }
        index = completion.node.next;
    }
}

/// Forgets what was decided of the operations a cancel called off.
fn forgetUnused(b: *Io.Batch, state: *Batched) void {
    var index = b.unused.head;
    while (index != .none) {
        const i = index.toIndex();
        state.ops[i] = .{};
        index = b.storage[i].unused.next;
    }
}

/// A batch's cancel, a call of its own; then the lost answers of what
/// completed meanwhile.
fn batchCancel(f: *FaultIo, b: *Io.Batch) void {
    _ = f.counts[@backingInt(IoCall.batchCancel)].fetchAdd(1, .monotonic);
    if (!f.watching.contains(.batchCancel)) {
        _ = f.steps_.take();
        f.base.vtable.batchCancel(f.base.userdata, b);
    } else {
        const d = f.decide(.batchCancel, .{});
        _ = f.preludeAnywhere(d.fault);
        f.base.vtable.batchCancel(f.base.userdata, b);
        f.record(d.step, .{ .call = .batchCancel, .fault = if (d.fault) |x| x else null });
    }
    // What completed while it was called off may owe a lost answer, and
    // what it called off is forgotten: its index may be submitted again.
    if (f.batch_count.load(.monotonic) == 0) return;
    const state = f.batchOf(b, false) orelse return;
    finished(b, state);
    forgetUnused(b, state);
    // Past the states kept, the batch's goes now: it may be gone for good.
    if (f.batch_count.load(.monotonic) <= kept_batches) return;
    f.lock();
    defer f.unlock();
    if (f.batches.fetchRemove(b)) |entry| f.retire(entry.value);
    f.batch_count.store(f.batches.count(), .monotonic);
}

fn lostAnswer(result: Io.Operation.Result, err: anyerror) Io.Operation.Result {
    switch (result) {
        inline else => |_, tag| {
            if (operationOutcome(tag, result) == .ok) return failedOperation(tag, err);
            return result;
        },
    }
}

fn unlinkSubmitted(b: *Io.Batch, previous: Io.Operation.OptionalIndex, index: Io.Operation.OptionalIndex) void {
    const next = b.storage[index.toIndex()].submission.node.next;
    switch (previous) {
        .none => b.submitted.head = next,
        else => b.storage[previous.toIndex()].submission.node.next = next,
    }
    if (b.submitted.tail == index) b.submitted.tail = previous;
}

fn appendCompleted(b: *Io.Batch, index: Io.Operation.OptionalIndex, result: Io.Operation.Result) void {
    switch (b.completed.tail) {
        .none => b.completed.head = index,
        else => |tail| b.storage[tail.toIndex()].completion.node.next = index,
    }
    b.storage[index.toIndex()] = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
    b.completed.tail = index;
}

/// Moves the stalled operations out of the submitted list into `kept`, in
/// order.
fn keepStalled(b: *Io.Batch, state: *Batched, kept: *Io.Operation.List) void {
    var previous: Io.Operation.OptionalIndex = .none;
    var index = b.submitted.head;
    while (index != .none) {
        const next = b.storage[index.toIndex()].submission.node.next;
        if (state.ops[index.toIndex()].stalled) {
            unlinkSubmitted(b, previous, index);
            b.storage[index.toIndex()].submission.node.next = .none;
            switch (kept.tail) {
                .none => kept.head = index,
                else => |tail| b.storage[tail.toIndex()].submission.node.next = index,
            }
            kept.tail = index;
        } else previous = index;
        index = next;
    }
}

/// Puts the kept operations back at the head of the submitted list.
fn putBack(b: *Io.Batch, kept: *Io.Operation.List) void {
    if (kept.head == .none) return;
    b.storage[kept.tail.toIndex()].submission.node.next = b.submitted.head;
    if (b.submitted.head == .none) b.submitted.tail = kept.tail;
    b.submitted.head = kept.head;
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
    if (n == 0) return noProgress(tag);
    var buffers: Batched.Buffers = undefined;
    return f.base.vtable.operate(f.base.userdata, cutOperation(tag, op, n, &buffers));
}

/// What a read or write that moved nothing returns: not the end of a
/// stream.
fn noProgress(comptime tag: Io.Operation.Tag) Io.Operation.Result {
    if (tag == .net_read) return @unionInit(Io.Operation.Result, "net_read", .{ .data_len = 0 });
    return @unionInit(Io.Operation.Result, @tagName(tag), 0);
}

/// The operation cut to at most `n` bytes, its buffers in `buffers`.
fn cutOperation(comptime tag: Io.Operation.Tag, op: @FieldType(Io.Operation, @tagName(tag)), n: u32, buffers: *Batched.Buffers) Io.Operation {
    var cut = op;
    switch (tag) {
        .file_read_streaming, .net_read => {
            buffers.* = .{ .reads = undefined };
            cut.data = cutReads([]u8, op.data, n, &buffers.reads);
        },
        .file_write_streaming, .net_write => {
            buffers.* = .{ .writes = undefined };
            const c = cutWrite(op.header, op.data, op.splat, n, &buffers.writes);
            cut.header = c.header;
            cut.data = c.data;
            cut.splat = c.splat;
        },
        else => unreachable, // unreachable: shortOperation admits only these
    }
    return @unionInit(Io.Operation, @tagName(tag), cut);
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
const path_calls: Calls = .of(&.{ "dirOpenDir", "dirCreateDirPathOpen", "dirCreateFile", "dirOpenFile", "dirCreateFileAtomic", "fileClose", "dirClose" });

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

/// The path `handle` was opened by, when paths are tracked. Under the lock.
fn pathOf(f: *FaultIo, handle: i64) ?[]const u8 {
    if (!f.options.track_paths or handle == -1) return null;
    return f.paths.get(handle);
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
    const copy = f.path_arena.allocator().dupe(u8, p) catch return;
    // glint-ignore: Z026 -- a path that cannot be stored leaves the handle unnamed, nothing worse
    f.paths.put(f.gpa, handle, copy) catch {};
}

fn forget(f: *FaultIo, comptime name: []const u8, args: anytype) void {
    _ = name;
    f.lock();
    defer f.unlock();
    for (args[0]) |handle_owner| _ = f.paths.remove(handleId(handle_owner.handle));
}

test "a short read keeps the first n bytes of its buffers" {
    var a: [4]u8 = undefined;
    var b: [12]u8 = undefined;
    var storage: [max_vectors][]u8 = undefined;
    const cut = cutReads([]u8, &.{ &a, &b }, 5, &storage);
    try std.testing.expectEqual(@as(usize, 2), cut.len);
    try std.testing.expectEqual(@as(usize, 4), cut[0].len);
    try std.testing.expectEqual(@as(usize, 1), cut[1].len);
    try std.testing.expectEqual(@as(usize, 3), cutReads([]u8, &.{ &a, &b }, 3, &storage)[0].len);
}

test "a short write keeps the first n bytes of header, buffers and splat" {
    var storage: [max_vectors][]const u8 = undefined;
    // "HD" ++ "ab" ++ "cd" ++ "x" * 4, cut to 7: HD ab cd x.
    var cut = cutWrite("HD", &.{ "ab", "cd", "x" }, 4, 7, &storage);
    try std.testing.expectEqualStrings("HD", cut.header);
    try std.testing.expectEqual(@as(usize, 3), cut.data.len);
    try std.testing.expectEqual(@as(usize, 1), cut.splat);
    // Inside the header.
    cut = cutWrite("HEADER", &.{"body"}, 1, 3, &storage);
    try std.testing.expectEqualStrings("HEA", cut.header);
    try std.testing.expectEqualStrings("", cut.data[0]);
    // A pattern splatted ten times, cut to two and a half repeats.
    cut = cutWrite("", &.{"ab"}, 10, 5, &storage);
    try std.testing.expectEqualStrings("ab", cut.data[0]);
    try std.testing.expectEqual(@as(usize, 2), cut.splat);
    // A pattern longer than what is left is cut once.
    cut = cutWrite("", &.{"abcdef"}, 3, 4, &storage);
    try std.testing.expectEqualStrings("abcd", cut.data[0]);
    try std.testing.expectEqual(@as(usize, 1), cut.splat);
}
