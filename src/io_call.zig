//! The vocabulary of `FaultIo`: which call was made (`IoCall`), what to do
//! to it (`IoFault`), and what came of it (`IoEvent`).
//!
//! `IoCall` is computed from `Io.VTable` and `Io.Operation` at compile
//! time, so a slot or operation a later Zig adds is a new call with no
//! change here.
const std = @import("std");
const Io = std.Io;

const vtable_names = @typeInfo(Io.VTable).@"struct".field_names;
const operation_names = @typeInfo(Io.Operation).@"union".field_names;
const allocation_names = [_][]const u8{ "alloc", "resize", "remap" };

const call_names = blk: {
    var names: [vtable_names.len - 1 + operation_names.len + allocation_names.len + 1][]const u8 = undefined;
    var i: usize = 0;
    for (vtable_names) |name| {
        if (std.mem.eql(u8, name, "operate")) continue;
        names[i] = name;
        i += 1;
    }
    for (operation_names) |name| {
        names[i] = name;
        i += 1;
    }
    for (allocation_names) |name| {
        names[i] = name;
        i += 1;
    }
    names[i] = "foreign";
    break :blk names;
};

/// Every `Io.VTable` slot except `operate`, named as in std (`.fileSync`,
/// `.dirRename`, ...); every `Io.Operation` tag (`.file_read_streaming`,
/// `.net_read`, ...), which `operate` dispatches on; `.alloc`, `.resize`
/// and `.remap` for `FaultIo.allocator`; and `.foreign` for a seam's own
/// calls.
pub const IoCall = CallEnum();

fn CallEnum() type {
    return @Enum(u8, .exhaustive, &call_names, &std.simd.iota(u8, call_names.len));
}

/// How many calls there are.
pub const call_count = call_names.len;

/// What a call is.
pub const Kind = enum { slot, operation, allocation, foreign };

pub fn kindOf(comptime call: IoCall) Kind {
    const name = @tagName(call);
    if (@hasField(Io.VTable, name)) return .slot;
    if (@hasField(Io.Operation, name)) return .operation;
    if (std.mem.eql(u8, name, "foreign")) return .foreign;
    return .allocation;
}

/// The errors a `fail` fault may give `call`; null when it cannot fail.
pub fn failSet(comptime call: IoCall) ?type {
    const name = @tagName(call);
    return switch (kindOf(call)) {
        .slot => errorSetOf(@typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?),
        .operation => OperationErrors(@FieldType(Io.Operation, name)),
        .allocation => error{OutOfMemory},
        .foreign => anyerror,
    };
}

fn errorSetOf(comptime R: type) ?type {
    return switch (@typeInfo(R)) {
        .error_union => |u| u.error_set,
        .error_set => R,
        else => null,
    };
}

/// An operation fails through `operate`'s own `Canceled` or through the
/// error its result carries.
fn OperationErrors(comptime Op: type) type {
    if (Op == noreturn) return error{Canceled};
    const R = Op.Result;
    switch (@typeInfo(R)) {
        .error_union => |u| return u.error_set || Io.Cancelable,
        .@"struct" => |s| {
            if (s.field_types.len > 0) switch (@typeInfo(s.field_types[0])) {
                .optional => |o| if (@typeInfo(o.child) == .error_set) return o.child || Io.Cancelable,
                else => {},
            };
            return Io.Cancelable;
        },
        else => return Io.Cancelable,
    }
}

fn inSet(comptime E: type, err: anyerror) bool {
    if (E == anyerror) return true;
    const names = @typeInfo(E).error_set.error_names orelse return true;
    inline for (names) |name| {
        if (err == @field(anyerror, name)) return true;
    }
    return false;
}

/// Whether `call` can return `err`.
pub fn canFail(call: IoCall, err: anyerror) bool {
    switch (call) {
        inline else => |c| {
            const set = comptime failSet(c);
            if (set) |E| return inSet(E, err);
            return false;
        },
    }
}

/// Whether `call` is a cancelation point: it can return `error.Canceled`.
pub fn cancelable(call: IoCall) bool {
    return canFail(call, error.Canceled) and kindAt(call) != .foreign;
}

fn kindAt(call: IoCall) Kind {
    switch (call) {
        inline else => |c| return comptime kindOf(c),
    }
}

/// The calls that move bytes, which a `short` fault cuts.
const short_names = [_][]const u8{
    "fileReadPositional", "fileWritePositional", "fileWriteFileStreaming", "fileWriteFilePositional",
    "netWriteFile",       "file_read_streaming", "file_write_streaming",   "net_read",
    "net_write",
};

/// Whether a `short` fault applies to `call`.
pub fn shortable(call: IoCall) bool {
    inline for (short_names) |name| {
        if (call == @field(IoCall, name)) return true;
    }
    return false;
}

/// The calls whose success leaves the caller something to release or undo:
/// a file, directory, socket, process, task, map or lock. A `fail_after`
/// would leave that with no one to release it, so it is refused there.
const keeps_names = [_][]const u8{
    "concurrent",          "dirCreateDirPathOpen",  "dirOpenDir",          "dirCreateFile",
    "dirCreateFileAtomic", "dirOpenFile",           "fileLock",            "fileTryLock",
    "fileMemoryMapCreate", "processExecutableOpen", "lockStderr",          "tryLockStderr",
    "processSpawn",        "progressParentFile",    "inheritParentDir",    "inheritParentFile",
    "netListenIp",         "netAccept",             "netBindIp",           "netConnectIp",
    "netListenUnix",       "netConnectUnix",        "netSocketCreatePair",
};

/// Whether `call` leaves its caller something to release when it succeeds.
fn keeps(call: IoCall) bool {
    inline for (keeps_names) |name| {
        if (call == @field(IoCall, name)) return true;
    }
    return false;
}

/// The futex waits, which may return with no one waking them.
fn waits(call: IoCall) bool {
    return call == .futexWait or call == .futexWaitUncancelable;
}

/// Why a fault cannot be injected into a call.
pub const FaultRefusal = error{ FaultNotInErrorSet, FaultNotApplicable };

/// What to do to a call.
pub const IoFault = union(enum) {
    /// Returned instead of making the call. It must be in the call's error
    /// set: `FaultIo` refuses a plan where it is not.
    fail: anyerror,
    /// The call is made, and when it succeeds its answer is lost: it
    /// returns this error instead, as a write that reached the disk and
    /// then reported `error.InputOutput`. It must be in the call's error
    /// set, and not `error.Canceled`, which says a call did not happen.
    /// Refused for allocations and for calls that hand back something to
    /// release (a file, a socket, a process, a task, a lock).
    fail_after: anyerror,
    /// Reads and writes: move at most this many bytes, through the real
    /// call. 0 = no progress, without making the call.
    short: u32,
    /// A cancel lands here, as std delivers one: at a cancelation point of
    /// a task whose cancel protection is unblocked, the call returns
    /// `error.Canceled` without being made. Under blocked protection no
    /// cancel can land, and the call is made. `recancel` after it re-arms
    /// it for the task's next cancelation point, as after any cancel.
    cancel,
    /// A futex wait returns at once, woken by no one, as std allows any
    /// futex wait to.
    spurious_wake,
    /// The call never completes: it waits until canceled and returns
    /// `error.Canceled`, as a read of a silent terminal does. An operation
    /// in a `Batch` stays pending until the batch is canceled. Only at a
    /// cancelation point.
    stall,
    /// Sleep this long on the base before the call: virtual time under a
    /// `Clock`, real time otherwise.
    delay: Io.Duration,
    /// Run test code at this point, then make the call, or do to it what
    /// `then` says.
    call: Callback,
    /// Crash the simulated node before the call. Only a simulation can;
    /// `FaultIo` refuses it as `FaultNotApplicable` on any other base.
    crash,

    pub const Callback = struct {
        ctx: *anyopaque,
        /// Called with the base `Io`, so its own calls are neither counted
        /// nor traced, nor faulted.
        f: *const fn (io: Io, ctx: *anyopaque) void,
        /// What happens to the call once `f` has run: null makes it, a
        /// fault is injected as if planned there, checked with the plan.
        then: ?*const IoFault = null,
    };

    pub const Tag = std.meta.Tag(IoFault);

    /// Whether `fault` can be injected into `call`.
    pub fn check(fault: IoFault, call: IoCall) FaultRefusal!void {
        switch (fault) {
            .fail => |err| if (!canFail(call, err)) return error.FaultNotInErrorSet,
            .fail_after => |err| {
                const kind = kindAt(call);
                if (kind == .allocation or keeps(call) or err == error.Canceled) return error.FaultNotApplicable;
                if (!canFail(call, err)) return error.FaultNotInErrorSet;
            },
            .short => if (!shortable(call)) return error.FaultNotApplicable,
            .cancel, .stall => if (!cancelable(call)) return error.FaultNotApplicable,
            .spurious_wake => if (!waits(call)) return error.FaultNotApplicable,
            .delay => if (kindAt(call) == .foreign) return error.FaultNotApplicable,
            .call => |c| {
                if (kindAt(call) == .foreign) return error.FaultNotApplicable;
                if (c.then) |then| try then.check(call);
            },
            .crash => {},
        }
    }
};

/// One call through `FaultIo`, as its trace records it.
pub const IoEvent = struct {
    call: IoCall,
    /// The handle and path the call was about, when known. Paths need
    /// `FaultIo.Options.track_paths`.
    subject: Subject = .{},
    outcome: Outcome = .{ .ok = 0 },
    /// The fault injected into this call, if any.
    fault: ?IoFault.Tag = null,
    /// Set for events a seam recorded with `FaultIo.recordForeign`.
    foreign: ?Foreign = null,

    pub const Subject = struct { handle: i64 = -1, path: ?[]const u8 = null };
    /// `ok` carries the bytes moved, or 0 for calls that move none.
    pub const Outcome = union(enum) { ok: u64, err: anyerror };
    pub const Foreign = struct { domain: [:0]const u8, call: u32 };

    /// Everything but the handle: handle numbers are the system's to
    /// choose and may differ between two runs that did the same thing.
    pub fn hash(e: IoEvent, hasher: *std.hash.Wyhash) void {
        std.hash.autoHash(hasher, e.call);
        std.hash.autoHashStrat(hasher, e.subject.path, .Deep);
        std.hash.autoHash(hasher, e.outcome);
        std.hash.autoHash(hasher, e.fault);
        if (e.foreign) |f| {
            hasher.update(f.domain);
            std.hash.autoHash(hasher, f.call);
        }
    }

    pub fn format(e: IoEvent, w: *Io.Writer) Io.Writer.Error!void {
        if (e.foreign) |f| {
            try w.print("{s}#{d}", .{ f.domain, f.call });
        } else {
            try w.print("{t}", .{e.call});
        }
        if (e.subject.path) |p| {
            try w.print(" {s}", .{p});
        } else if (e.subject.handle != -1) {
            try w.print(" #{d}", .{e.subject.handle});
        }
        switch (e.outcome) {
            .ok => |n| try w.print(" -> {d}", .{n}),
            .err => |err| try w.print(" -> error.{t}", .{err}),
        }
        if (e.fault) |f| try w.print(" [{t}]", .{f});
    }
};

test "every vtable slot but operate, every operation and the allocator calls are calls" {
    inline for (vtable_names) |name| {
        if (comptime std.mem.eql(u8, name, "operate")) continue;
        try std.testing.expectEqual(Kind.slot, kindOf(@field(IoCall, name)));
    }
    inline for (operation_names) |name| try std.testing.expectEqual(Kind.operation, kindOf(@field(IoCall, name)));
    try std.testing.expectEqual(Kind.allocation, kindOf(.alloc));
    try std.testing.expectEqual(Kind.foreign, kindOf(.foreign));
    try std.testing.expect(!@hasField(IoCall, "operate"));
}

test "a fault is checked against the call it targets" {
    try IoFault.check(.{ .fail = error.NoSpaceLeft }, .fileWritePositional);
    try std.testing.expectError(error.FaultNotInErrorSet, IoFault.check(.{ .fail = error.NoSpaceLeft }, .fileReadPositional));
    try IoFault.check(.{ .fail = error.InputOutput }, .file_read_streaming);
    try IoFault.check(.{ .fail = error.Canceled }, .file_read_streaming);
    try IoFault.check(.{ .fail = error.ConnectionResetByPeer }, .net_receive);
    try std.testing.expectError(error.FaultNotInErrorSet, IoFault.check(.{ .fail = error.InputOutput }, .now));
    try IoFault.check(.{ .fail = error.ConcurrencyUnavailable }, .concurrent);
    try IoFault.check(.{ .fail = error.OutOfMemory }, .alloc);
    try IoFault.check(.{ .fail = error.Whatever }, .foreign);
    try IoFault.check(.cancel, .sleep);
    try IoFault.check(.cancel, .net_read);
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.cancel, .futexWaitUncancelable));
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.cancel, .fileClose));
    try IoFault.check(.{ .short = 3 }, .fileReadPositional);
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.{ .short = 3 }, .fileSync));
    try IoFault.check(.crash, .fileSync);
    try IoFault.check(.{ .delay = .fromSeconds(1) }, .fileSync);
}

test "a lost answer needs a call that can fail with it, and leaves nothing unreleased" {
    try IoFault.check(.{ .fail_after = error.InputOutput }, .fileWritePositional);
    try IoFault.check(.{ .fail_after = error.InputOutput }, .file_write_streaming);
    try IoFault.check(.{ .fail_after = error.AccessDenied }, .dirRename);
    try IoFault.check(.{ .fail_after = error.Whatever }, .foreign);
    try std.testing.expectError(error.FaultNotInErrorSet, IoFault.check(.{ .fail_after = error.NoSpaceLeft }, .fileReadPositional));
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.{ .fail_after = error.Canceled }, .fileSync));
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.{ .fail_after = error.OutOfMemory }, .alloc));
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.{ .fail_after = error.AccessDenied }, .dirOpenFile));
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.{ .fail_after = error.SystemResources }, .fileLock));
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.{ .fail_after = error.ConcurrencyUnavailable }, .concurrent));
}

test "a spurious wake is a futex wait's, a stall a cancelation point's, and a callback's follow-up is checked" {
    try IoFault.check(.spurious_wake, .futexWait);
    try IoFault.check(.spurious_wake, .futexWaitUncancelable);
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.spurious_wake, .sleep));
    try IoFault.check(.stall, .file_read_streaming);
    try IoFault.check(.stall, .fileSync);
    try std.testing.expectError(error.FaultNotApplicable, IoFault.check(.stall, .fileClose));
    var ctx: u8 = 0;
    const f = struct {
        fn f(_: Io, _: *anyopaque) void {}
    }.f;
    try IoFault.check(.{ .call = .{ .ctx = &ctx, .f = f, .then = &.{ .fail = error.ConcurrencyUnavailable } } }, .groupConcurrent);
    try std.testing.expectError(error.FaultNotInErrorSet, IoFault.check(.{ .call = .{ .ctx = &ctx, .f = f, .then = &.{ .fail = error.InputOutput } } }, .groupConcurrent));
    try IoFault.check(.{ .call = .{ .ctx = &ctx, .f = f, .then = &.crash } }, .fileSync);
}
