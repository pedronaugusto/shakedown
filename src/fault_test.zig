//! `FaultIo` from outside: transparent with no plan, every fault kind on
//! the calls it applies to, paths, traces, allocation and seams.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown.zig");
const FaultIo = shakedown.FaultIo;
const IoPlan = shakedown.IoPlan;

/// A small piece of file work: create, write, sync, rename, read back,
/// list, delete. Returns what it read.
fn fileWork(io: Io, dir: Io.Dir, out: []u8) ![]const u8 {
    var file = try dir.createFile(io, "work.tmp", .{ .read = true });
    try file.writePositionalAll(io, "hello, faults", 0);
    try file.sync(io);
    file.close(io);
    try dir.rename("work.tmp", dir, "work.txt", io);
    const read = try dir.readFile(io, "work.txt", out);
    var listed: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |_| listed += 1;
    if (listed != 1) return error.Unexpected;
    try dir.deleteFile(io, "work.txt");
    return read;
}

test "with no plan, FaultIo does what its base does and counts every call" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var plain: [64]u8 = undefined;
    const expected = try fileWork(testing.io, tmp.dir, &plain);

    inline for (.{ .off, .all }) |mode| {
        const fio = try FaultIo.init(testing.allocator, testing.io, .{ .trace = mode });
        defer fio.deinit();
        var through: [64]u8 = undefined;
        try testing.expectEqualStrings(expected, try fileWork(fio.io(), tmp.dir, &through));
        try testing.expectEqual(@as(u64, 1), fio.count(.dirCreateFile));
        try testing.expectEqual(@as(u64, 1), fio.count(.fileSync));
        try testing.expectEqual(@as(u64, 1), fio.count(.dirRename));
        try testing.expectEqual(@as(u64, 1), fio.count(.dirDeleteFile));
        try testing.expect(fio.count(.fileClose) >= 2);
        try testing.expect(fio.steps().peek() >= 8);
        const traced_calls: u64 = if (mode == .off) 0 else fio.steps().peek();
        try testing.expectEqual(traced_calls, fio.trace().len());
    }
}

fn expectFails(comptime call: shakedown.IoCall, err: anyerror, work: anytype) !void {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const plan = [_]IoPlan.Entry{.{ .at = .{ .nth = .{ .call = call, .n = 1 } }, .fault = .{ .fail = err } }};
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan, .trace = .all });
    defer fio.deinit();
    var out: [64]u8 = undefined;
    try testing.expectError(err, work(fio.io(), tmp.dir, &out));
    try testing.expectEqual(@as(usize, 1), fio.fired().len);
    const last = fio.trace().records()[fio.trace().records().len - 1].event;
    try testing.expectEqual(call, last.call);
    try testing.expectEqual(shakedown.IoFault.Tag.fail, last.fault.?);
}

test "fail returns the error at the call it names, on slots and operations" {
    try expectFails(.dirCreateFile, error.AccessDenied, fileWork);
    try expectFails(.fileWritePositional, error.NoSpaceLeft, fileWork);
    try expectFails(.fileSync, error.InputOutput, fileWork);
    try expectFails(.dirRename, error.AccessDenied, fileWork);
    try expectFails(.dirRead, error.SystemResources, fileWork);
}

test "a fault outside the call's error set, or one that cannot apply, is refused" {
    const io = testing.io;
    const gpa = testing.allocator;
    try testing.expectError(error.FaultNotInErrorSet, FaultIo.init(gpa, io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .fail = error.NoSpaceLeft } },
    } }));
    try testing.expectError(error.FaultNotApplicable, FaultIo.init(gpa, io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .futexWaitUncancelable, .n = 1 } }, .fault = .cancel },
    } }));
    try testing.expectError(error.FaultNotApplicable, FaultIo.init(gpa, io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .fileSync, .n = 1 } }, .fault = .{ .short = 1 } },
    } }));
    try testing.expectError(error.FaultNotApplicable, FaultIo.init(gpa, io, .{ .plan = &.{
        .{ .at = .{ .step = 3 }, .fault = .crash },
    } }));
    const fio = try FaultIo.init(gpa, io, .{});
    defer fio.deinit();
    try testing.expectError(error.FaultNotInErrorSet, fio.setPlan(&.{
        .{ .at = .{ .nth = .{ .call = .now, .n = 1 } }, .fault = .{ .fail = error.InputOutput } },
    }));
}

test "short reads and writes move at most n bytes, and short(0) moves none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = "0123456789abcdef" });
    const plan = [_]IoPlan.Entry{
        .{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .short = 5 } },
        .{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 2 } }, .fault = .{ .short = 0 } },
        .{ .at = .{ .nth = .{ .call = .fileWritePositional, .n = 1 } }, .fault = .{ .short = 7 } },
    };
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan, .trace = .all });
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.openFile(io, "data", .{ .mode = .read_write });
    defer file.close(io);
    var b: [12]u8 = undefined;
    // One buffer: Windows reads only the first of several, short or not.
    try testing.expectEqual(@as(usize, 5), try file.readPositional(io, &.{&b}, 0));
    try testing.expectEqualStrings("01234", b[0..5]);
    try testing.expectEqual(@as(usize, 0), try file.readPositional(io, &.{&b}, 0));
    try testing.expectEqual(@as(usize, 12), try file.readPositional(io, &.{&b}, 4));
    // Ten bytes cut to seven. One buffer: Windows writes only the first of
    // several; the cutting of headers, buffers and splats is tested in
    // FaultIo.zig.
    try testing.expectEqual(@as(usize, 7), try file.writePositional(io, &.{"HDabcdxxxx"}, 0));
    var check: [16]u8 = undefined;
    _ = try tmp.dir.readFile(testing.io, "data", &check);
    try testing.expectEqualStrings("HDabcdx789abcdef", &check);
    const records = fio.trace().records();
    try testing.expectEqual(@as(u64, 5), records[1].event.outcome.ok);
}

fn writeStreaming(io: Io, file: Io.File, bytes: []const u8) !usize {
    var data = [_][]const u8{bytes};
    return (try io.operate(.{ .file_write_streaming = .{ .file = file, .data = &data } })).file_write_streaming;
}

fn readStreaming(io: Io, file: Io.File, buffer: []u8) !usize {
    var data = [_][]u8{buffer};
    return (try io.operate(.{ .file_read_streaming = .{ .file = file, .data = &data } })).file_read_streaming;
}

test "operations are faulted one by one through operate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = "streaming bytes" });
    const plan = [_]IoPlan.Entry{
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 1 } }, .fault = .{ .short = 0 } },
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 2 } }, .fault = .{ .short = 3 } },
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 3 } }, .fault = .{ .fail = error.InputOutput } },
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 4 } }, .fault = .cancel },
    };
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan });
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.openFile(io, "data", .{});
    defer file.close(io);
    var buffer: [32]u8 = undefined;
    // A streaming read that moves nothing is not the end of the stream.
    try testing.expectEqual(@as(usize, 0), try readStreaming(io, file, &buffer));
    try testing.expectEqual(@as(usize, 3), try readStreaming(io, file, &buffer));
    try testing.expectEqualStrings("str", buffer[0..3]);
    try testing.expectError(error.InputOutput, readStreaming(io, file, &buffer));
    try testing.expectError(error.Canceled, readStreaming(io, file, &buffer));
    try testing.expectEqual(@as(usize, 12), try readStreaming(io, file, &buffer));
    try testing.expectEqual(@as(u64, 5), fio.count(.file_read_streaming));
}

test "cancel lands at a cancelation point, and a concurrent call can be refused" {
    const plan = [_]IoPlan.Entry{
        .{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel },
        .{ .at = .{ .nth = .{ .call = .concurrent, .n = 1 } }, .fault = .{ .fail = error.ConcurrencyUnavailable } },
    };
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan });
    defer fio.deinit();
    const io = fio.io();
    try testing.expectError(error.Canceled, io.sleep(.fromSeconds(60), .awake));
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(Io.sleep, .{ io, .zero, .awake }));
    var task = try io.concurrent(Io.sleep, .{ io, .zero, .awake });
    try task.await(io);
    try testing.expectEqual(@as(u64, 2), fio.count(.concurrent));
}

/// A stat whose result is not kept. A task's result aligned past 8 bytes, as
/// `File.Stat` is, overruns its allocation in 0.17's `Threaded`, so the
/// tasks here return nothing.
fn statFile(io: Io, file: Io.File) Io.File.StatError!void {
    _ = try file.stat(io);
}

test "a delay sleeps on the base, which a Clock makes virtual" {
    var clock: shakedown.Clock = .init(testing.io, .{});
    const plan = [_]IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .fileStat, .n = 1 } }, .fault = .{ .delay = .fromSeconds(30) } }};
    const fio = try FaultIo.init(testing.allocator, clock.io(), .{ .plan = &plan });
    defer fio.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Readable: Windows will not stat a file opened only for writing.
    const file = try tmp.dir.createFile(testing.io, "f", .{ .read = true });
    defer file.close(testing.io);
    var task = try fio.io().concurrent(statFile, .{ fio.io(), file });
    try clock.awaitArmed(1, .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } });
    try testing.expectEqual(@as(?Io.Duration, .fromSeconds(30)), clock.advanceToNext());
    _ = try task.await(fio.io());
}

const Probe = struct {
    calls: u32 = 0,
    fn hit(io: Io, ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.calls += 1;
        _ = Io.Timestamp.now(io, .awake);
    }
};

test "a callback runs at its point, on the base, then the call is made" {
    var probe: Probe = .{};
    const plan = [_]IoPlan.Entry{.{
        .at = .{ .nth = .{ .call = .dirCreateFile, .n = 1, .path = .{ .suffix = ".lock" } } },
        .fault = .{ .call = .{ .ctx = &probe, .f = Probe.hit } },
        .times = 0,
    }};
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan });
    defer fio.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = fio.io();
    (try tmp.dir.createFile(io, "a.lock", .{})).close(io);
    (try tmp.dir.createFile(io, "b.txt", .{})).close(io);
    (try tmp.dir.createFile(io, "c.lock", .{})).close(io);
    try testing.expectEqual(@as(u32, 2), probe.calls);
    // The callback's own call went to the base: nothing here counted it.
    try testing.expectEqual(@as(u64, 0), fio.count(.now));
}

test "paths follow opened directories, created files and renames" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = [_]IoPlan.Entry{
        .{ .at = .{ .nth = .{ .call = .fileSync, .n = 1, .path = .{ .exact = "repo/objects/pack.idx" } } }, .fault = .{ .fail = error.InputOutput } },
        .{ .at = .{ .nth = .{ .call = .dirRename, .n = 1, .path = .{ .suffix = "/HEAD" } } }, .fault = .{ .fail = error.AccessDenied } },
    };
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan, .trace = .all });
    defer fio.deinit();
    const io = fio.io();
    try tmp.dir.createDirPath(testing.io, "repo/objects");
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    var objects = try repo.openDir(io, "objects", .{});
    defer objects.close(io);
    const other = try objects.createFile(io, "other.idx", .{});
    try other.sync(io);
    other.close(io);
    const idx = try objects.createFile(io, "pack.idx", .{});
    try testing.expectError(error.InputOutput, idx.sync(io));
    idx.close(io);
    (try repo.createFile(io, "HEAD.lock", .{})).close(io);
    try testing.expectError(error.AccessDenied, repo.rename("HEAD.lock", repo, "HEAD", io));
    var saw_path = false;
    for (fio.trace().records()) |r| {
        if (r.event.call == .fileClose) {
            if (r.event.subject.path) |p| saw_path = saw_path or std.mem.eql(u8, p, "repo/objects/other.idx");
        }
    }
    try testing.expect(saw_path);
}

fn traced(gpa: std.mem.Allocator, dir: Io.Dir) !u64 {
    const fio = try FaultIo.init(gpa, testing.io, .{ .trace = .{ .last = 8 }, .random_seed = 7 });
    defer fio.deinit();
    var out: [64]u8 = undefined;
    _ = try fileWork(fio.io(), dir, &out);
    var bytes: [8]u8 = undefined;
    fio.io().random(&bytes);
    return fio.trace().hash();
}

test "one task's trace hash is the same run after run" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const first = try traced(testing.allocator, tmp.dir);
    for (0..100) |_| try testing.expectEqual(first, try traced(testing.allocator, tmp.dir));
}

test "seeded randomness repeats, and differs between seeds" {
    var draws: [3][16]u8 = undefined;
    for (&draws, [_]u64{ 1, 1, 2 }) |*d, seed| {
        const fio = try FaultIo.init(testing.allocator, testing.io, .{ .random_seed = seed });
        defer fio.deinit();
        fio.io().random(d[0..8]);
        try fio.io().randomSecure(d[8..]);
    }
    try testing.expectEqualSlices(u8, &draws[0], &draws[1]);
    try testing.expect(!std.mem.eql(u8, &draws[0], &draws[2]));
}

test "a seeded draw of any length is the start of a longer one" {
    var long: [64]u8 = undefined;
    {
        const fio = try FaultIo.init(testing.allocator, testing.io, .{ .random_seed = 3 });
        defer fio.deinit();
        fio.io().random(&long);
    }
    for ([_]usize{ 1, 7, 8, 9, 13, 63 }) |len| {
        const fio = try FaultIo.init(testing.allocator, testing.io, .{ .random_seed = 3 });
        defer fio.deinit();
        var short: [64]u8 = undefined;
        fio.io().random(short[0..len]);
        try testing.expectEqualSlices(u8, long[0..len], short[0..len]);
    }
    // Not one byte repeated over the whole draw: every byte was filled.
    var seen: std.bit_set.Static(256) = .empty;
    for (long) |b| seen.set(b);
    try testing.expect(seen.count() > 32);
}

test "allocations go through the same plan, trace and counts" {
    const plan = [_]IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .alloc, .n = 3 } }, .fault = .{ .fail = error.OutOfMemory } }};
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan, .trace = .all });
    defer fio.deinit();
    const gpa = try fio.allocator(testing.allocator);
    const a = try gpa.alloc(u8, 10);
    defer gpa.free(a);
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    try testing.expectError(error.OutOfMemory, gpa.alloc(u8, 10));
    try testing.expectEqual(@as(u64, 3), fio.count(.alloc));
    const last = fio.trace().records()[fio.trace().records().len - 1].event;
    try testing.expectEqual(shakedown.IoCall.alloc, last.call);
    try testing.expectEqual(@as(anyerror, error.OutOfMemory), last.outcome.err);
}

test "allocator is one shim per child, and refuses with OutOfMemory when it cannot make one" {
    var counting: shakedown.alloc.Counting = .init(testing.allocator);
    const fio = try FaultIo.init(counting.allocator(), testing.io, .{});
    defer fio.deinit();
    const first = try fio.allocator(testing.allocator);
    const made = counting.allocations;
    // Asking again for the same child, in a loop, makes nothing new.
    for (0..100) |_| {
        const again = try fio.allocator(testing.allocator);
        try testing.expect(again.ptr == first.ptr and again.vtable == first.vtable);
    }
    try testing.expectEqual(made, counting.allocations);
    // Another child is another shim.
    var other: shakedown.alloc.Counting = .init(testing.allocator);
    const second = try fio.allocator(other.allocator());
    try testing.expect(second.ptr != first.ptr);
    const bytes = try second.alloc(u8, 4);
    second.free(bytes);
    try testing.expectEqual(@as(u64, 1), other.allocations);

    // With nothing left to allocate from, the shim is refused, not a panic.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const tight = try FaultIo.init(failing.allocator(), testing.io, .{});
    defer tight.deinit();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, tight.allocator(testing.allocator));
}

const Raw = enum { barrier, rename_noreplace };

test "a seam's calls share the step sequence and the plan" {
    const plan = [_]IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .foreign, .n = 2 } }, .fault = .{ .fail = error.InputOutput } }};
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan, .trace = .all });
    defer fio.deinit();
    _ = Io.Timestamp.now(fio.io(), .awake);
    const first = fio.beginForeign(Raw, .barrier, "a/b");
    try testing.expectEqual(@as(?shakedown.IoFault, null), first.fault);
    fio.endForeign(first, .{ .ok = 0 });
    const second = fio.beginForeign(Raw, .rename_noreplace, "a/c");
    try testing.expectEqual(@as(anyerror, error.InputOutput), second.fault.?.fail);
    fio.endForeign(second, .{ .err = error.InputOutput });
    fio.recordForeign(Raw, .barrier, null, .{ .ok = 0 });

    // A seam's own plan over its own call type, on the same steps.
    var counters: [1]u32 = undefined;
    const RawPlan = shakedown.Plan(Raw, anyerror);
    var raw_plan: RawPlan = .init(&.{.{ .at = .{ .step = 4 }, .fault = error.NoSpaceLeft }}, .{ .steps = fio.steps(), .counters = &counters });
    try testing.expectEqual(@as(?anyerror, error.NoSpaceLeft), raw_plan.decide(.barrier, null));

    const records = fio.trace().records();
    try testing.expectEqual(@as(usize, 4), records.len);
    for (records, 0..) |r, step| try testing.expectEqual(@as(u64, step), r.step);
    try testing.expectEqual(@as(u32, @backingInt(Raw.rename_noreplace)), records[2].event.foreign.?.call);
    try testing.expectEqual(@as(u64, 3), fio.count(.foreign));
    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try fio.trace().format(&text.writer);
    try testing.expect(std.mem.find(u8, text.written(), "rename_noreplace") == null);
    try testing.expect(std.mem.find(u8, text.written(), "fault_test.Raw#1 a/c -> error.InputOutput [fail]") != null);
}

test "a layer over FaultIo forwards to it, as airlock's hooked Io does" {
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .fileSync, .n = 1 } }, .fault = .{ .fail = error.InputOutput } },
    } });
    defer fio.deinit();
    var hooked: Hooked = .init(fio.io(), .{});
    const io = hooked.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "x", .{});
    defer file.close(io);
    try testing.expectError(error.InputOutput, file.sync(io));
    try testing.expectEqual(@as(u32, 1), hooked.state.syncs);
    try testing.expectEqual(@as(u64, 1), fio.count(.dirCreateFile));
}

const Hooked = shakedown.Layer(struct { syncs: u32 = 0 }, .{ .fileSync = hookedSync });

/// As airlock's production `hookedSync`: a std-level sync goes through to
/// the base, here a `FaultIo`, after the hook has seen it.
fn hookedSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    const l = Hooked.of(userdata);
    l.state.syncs += 1;
    return file.sync(l.base);
}

test "every vtable slot is wrapped, so no call reaches the base unseen" {
    inline for (@typeInfo(Io.VTable).@"struct".field_names) |name| {
        const ours: *const anyopaque = @ptrCast(@field(FaultIo.vtable, name));
        const theirs: *const anyopaque = @ptrCast(@field(testing.io.vtable.*, name));
        try testing.expect(ours != theirs);
    }
    const fio = try FaultIo.init(testing.allocator, testing.io, .{});
    defer fio.deinit();
    try testing.expect(fio.io().vtable == &FaultIo.vtable);
}

test "with no plan and no trace, calls allocate nothing" {
    var counting: shakedown.alloc.Counting = .init(testing.allocator);
    const fio = try FaultIo.init(counting.allocator(), testing.io, .{ .track_paths = false });
    defer fio.deinit();
    const warm = counting.allocations;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var out: [64]u8 = undefined;
    for (0..10) |_| _ = try fileWork(fio.io(), tmp.dir, &out);
    try testing.expectEqual(warm, counting.allocations);
    try testing.expect(fio.count(.dirCreateFile) == 10);
}

test "a lost answer makes the call, then fails it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = [_]IoPlan.Entry{
        .{ .at = .{ .nth = .{ .call = .fileWritePositional, .n = 1 } }, .fault = .{ .fail_after = error.InputOutput } },
        .{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .{ .fail_after = error.NoSpaceLeft } },
        .{ .at = .{ .nth = .{ .call = .dirRename, .n = 1 } }, .fault = .{ .fail_after = error.AccessDenied } },
    };
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &plan, .trace = .all });
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.createFile(io, "a", .{ .read = true });
    try testing.expectError(error.NoSpaceLeft, writeStreaming(io, file, "written"));
    try testing.expectError(error.InputOutput, file.writePositional(io, &.{" too"}, 7));
    file.close(io);
    try testing.expectError(error.AccessDenied, tmp.dir.rename("a", tmp.dir, "b", io));
    // Every one of them happened.
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("written too", try tmp.dir.readFile(testing.io, "b", &buffer));
    var lost: usize = 0;
    for (fio.trace().records()) |r| if (r.event.fault) |tag| {
        try testing.expectEqual(shakedown.IoFault.Tag.fail_after, tag);
        try testing.expect(r.event.outcome == .err);
        lost += 1;
    };
    try testing.expectEqual(@as(usize, 3), lost);
    // Nothing is left to release when it is refused: an open, a lock, a task.
    try testing.expectError(error.FaultNotApplicable, fio.setPlan(&.{
        .{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .{ .fail_after = error.AccessDenied } },
    }));
}

/// Writes through every cancel point it meets, with cancel protection
/// blocked around the first write and not around the second: on a task of
/// its own, since a task is what has a protection to block.
fn writeProtected(io: Io, file: Io.File) !void {
    const was = io.swapCancelProtection(.blocked);
    file.writePositionalAll(io, "kept", 0) catch |err| switch (err) {
        error.Canceled => return error.TestUnexpectedResult,
        else => return err,
    };
    _ = io.swapCancelProtection(was);
    try testing.expectError(error.Canceled, file.writePositionalAll(io, "lost", 4));
}

test "a cancel lands only where cancel protection lets one land" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .trace = .all, .plan = &.{
        .{ .at = .{ .nth = .{ .call = .fileWritePositional, .n = 1 } }, .fault = .cancel, .times = 0 },
    } });
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.createFile(testing.io, "f", .{ .read = true });
    defer file.close(testing.io);
    var task = try io.concurrent(writeProtected, .{ io, file });
    try task.await(io);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("kept", try tmp.dir.readFile(testing.io, "f", &buffer));
    // The trace says which write a cancel landed on: the second only.
    var landed: [2]bool = undefined;
    var writes: usize = 0;
    for (fio.trace().records()) |r| if (r.event.call == .fileWritePositional) {
        landed[writes] = r.event.fault != null;
        writes += 1;
    };
    try testing.expectEqual(@as(usize, 2), writes);
    try testing.expectEqual([2]bool{ false, true }, landed);
}

/// Takes a cancel at a sleep, re-arms it as std's own `Queue` does when it
/// reports progress first, and meets it again at the next point the
/// protection lets it land.
fn recancelAfterFault(io: Io) !void {
    try testing.expectError(error.Canceled, io.sleep(.fromSeconds(60), .awake));
    io.recancel();
    const was = io.swapCancelProtection(.blocked);
    try io.checkCancel();
    _ = io.swapCancelProtection(was);
    try testing.expectError(error.Canceled, io.checkCancel());
    // Delivered: it does not land twice.
    try io.checkCancel();
}

test "recancel re-arms a cancel the plan landed" {
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel },
    } });
    defer fio.deinit();
    const io = fio.io();
    var task = try io.concurrent(recancelAfterFault, .{io});
    try task.await(io);
    try testing.expectEqual(@as(u64, 1), fio.count(.recancel));
}

/// Puts two items in a queue with room for one: the first goes in, then
/// the wait for room takes a cancel, and the put reports its progress and
/// re-arms the cancel.
fn putTwo(io: Io, queue: *Io.Queue(u8)) !void {
    try testing.expectEqual(@as(usize, 1), try queue.put(io, &.{ 1, 2 }, 2));
    try testing.expectError(error.Canceled, io.checkCancel());
}

test "std's Queue re-arms a cancel the plan landed in its wait" {
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .futexWait, .n = 1 } }, .fault = .cancel },
    } });
    defer fio.deinit();
    const io = fio.io();
    var room: [1]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&room);
    var task = try io.concurrent(putTwo, .{ io, &queue });
    try task.await(io);
    try testing.expectEqual(@as(u8, 1), try queue.getOne(io));
}

fn waitOnce(io: Io, word: *const std.atomic.Value(u32)) Io.Cancelable!void {
    try io.futexWait(u32, &word.raw, 0);
}

test "a spurious wake returns a futex wait at once, with no one waking it" {
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .trace = .all, .plan = &.{
        .{ .at = .{ .nth = .{ .call = .futexWait, .n = 1 } }, .fault = .spurious_wake },
        .{ .at = .{ .nth = .{ .call = .futexWaitUncancelable, .n = 1 } }, .fault = .spurious_wake },
    } });
    defer fio.deinit();
    const io = fio.io();
    const word: std.atomic.Value(u32) = .init(0);
    try waitOnce(io, &word);
    io.futexWaitUncancelable(u32, &word.raw, 0);
    try testing.expectEqual(@as(u64, 1), fio.count(.futexWait));
    try testing.expectEqual(shakedown.IoFault.Tag.spurious_wake, fio.trace().records()[0].event.fault.?);
    try testing.expectError(error.FaultNotApplicable, fio.setPlan(&.{
        .{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .spurious_wake },
    }));
}

/// Waits on a word no one wakes until `deadline`, looking at the clock
/// after every wake, as a wait loop that tolerates spurious wakes does.
fn waitUntil(io: Io, deadline: Io.Timestamp) Io.Cancelable!void {
    const word: u32 = 0;
    while (Io.Timestamp.now(io, .awake).compare(.lt, deadline)) {
        try io.futexWaitTimeout(u32, &word, 0, .{ .deadline = .{ .raw = deadline, .clock = .awake } });
    }
}

/// Each wait wakes spuriously ten milliseconds of the clock later: as a
/// wait loop under a busy scheduler sees it.
const Late = struct {
    clock: *shakedown.Clock,

    fn pass(_: Io, ctx: *anyopaque) void {
        const late: *Late = @ptrCast(@alignCast(ctx)); // safe: the plan hands this test's Late as the context
        late.clock.advance(.fromMilliseconds(10));
    }
};

test "a callback runs, then what it leads to happens to the call" {
    var clock: shakedown.Clock = .init(testing.io, .{});
    var late: Late = .{ .clock = &clock };
    const fio = try FaultIo.init(testing.allocator, clock.io(), .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .futexWait, .n = 1 } },
        .fault = .{ .call = .{ .ctx = &late, .f = Late.pass, .then = &.spurious_wake } },
        .times = 0,
    }} });
    defer fio.deinit();
    const io = fio.io();
    const start = clock.read(.awake);
    try waitUntil(io, start.addDuration(.fromMilliseconds(30)));
    try testing.expectEqual(@as(u64, 3), fio.count(.futexWait));
    try testing.expectEqual(Io.Duration.fromMilliseconds(30), start.durationTo(clock.read(.awake)));

    // A callback that also fails the call: it sees the moment, then the
    // call is refused.
    var probe: Probe = .{};
    try fio.setPlan(&.{.{
        .at = .{ .nth = .{ .call = .concurrent, .n = 1 } },
        .fault = .{ .call = .{ .ctx = &probe, .f = Probe.hit, .then = &.{ .fail = error.ConcurrencyUnavailable } } },
    }});
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(Io.sleep, .{ io, .zero, .awake }));
    try testing.expectEqual(@as(u32, 1), probe.calls);
    // What it leads to is checked with the plan.
    try testing.expectError(error.FaultNotInErrorSet, fio.setPlan(&.{.{
        .at = .{ .nth = .{ .call = .concurrent, .n = 1 } },
        .fault = .{ .call = .{ .ctx = &probe, .f = Probe.hit, .then = &.{ .fail = error.InputOutput } } },
    }}));
}

fn readStalled(io: Io, file: Io.File) !void {
    var buffer: [8]u8 = undefined;
    _ = try file.readPositional(io, &.{&buffer}, 0);
}

test "a stalled call waits until a cancel ends it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = "ready" });
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .stall },
    } });
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.openFile(testing.io, "data", .{});
    defer file.close(testing.io);
    var task = try io.concurrent(readStalled, .{ io, file });
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expectError(error.FaultNotApplicable, fio.setPlan(&.{
        .{ .at = .{ .nth = .{ .call = .fileClose, .n = 1 } }, .fault = .stall },
    }));
}

/// A batch of reads of `file`, one per buffer, awaited once.
fn readBatch(io: Io, file: Io.File, buffers: [][4]u8, results: []anyerror!usize) !void {
    var storage: [4]Io.Operation.Storage = undefined;
    var datas: [4][1][]u8 = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    for (buffers, 0..) |*b, i| {
        datas[i] = .{b};
        batch.addAt(@intCast(i), .{ .file_read_streaming = .{ .file = file, .data = &datas[i] } });
    }
    var left = buffers.len;
    while (left > 0) {
        try batch.awaitAsync(io);
        while (batch.next()) |done| {
            results[done.index] = done.result.file_read_streaming;
            left -= 1;
        }
    }
}

test "a batch's operations are calls, each counted and decided once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = "0123456789abcdef" });
    const fio = try FaultIo.init(testing.allocator, testing.io, .{ .trace = .all, .plan = &.{
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 2 } }, .fault = .{ .fail = error.InputOutput } },
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 3 } }, .fault = .{ .short = 1 } },
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 4 } }, .fault = .{ .fail_after = error.InputOutput } },
    } });
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.openFile(testing.io, "data", .{});
    defer file.close(testing.io);
    var buffers: [4][4]u8 = undefined;
    var results: [4]anyerror!usize = undefined;
    try readBatch(io, file, &buffers, &results);
    try testing.expectEqual(@as(u64, 4), fio.count(.file_read_streaming));
    try testing.expectEqual(@as(usize, 4), try results[0]);
    try testing.expectError(error.InputOutput, results[1]);
    try testing.expectEqual(@as(usize, 1), try results[2]);
    try testing.expectError(error.InputOutput, results[3]);
    try testing.expectEqual(@as(u64, 1), fio.count(.batchCancel));
    // Five bytes were read: four, then one; the lost answer read its four.
    var rest: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 7), try file.readStreaming(testing.io, &.{&rest}));
}

/// A wait on a read that never answers, with a deadline: what a terminal's
/// input pump does when no one types.
fn waitSilent(io: Io, file: Io.File, timeout: Io.Timeout) !void {
    var buffer: [8]u8 = undefined;
    var data = [_][]u8{&buffer};
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    batch.addAt(0, .{ .file_read_streaming = .{ .file = file, .data = &data } });
    try batch.awaitConcurrent(io, timeout);
}

test "a stalled batched read is kept from the base, and the await times out on the clock" {
    var clock: shakedown.Clock = .init(testing.io, .{ .advance = .{ .auto = .{} } });
    const fio = try FaultIo.init(testing.allocator, clock.io(), .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 1 } }, .fault = .stall, .times = 0 },
    } });
    defer fio.deinit();
    const io = fio.io();
    // No descriptor: the read never reaches the system.
    const nothing: Io.File = .{ .handle = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1, .flags = .{ .nonblocking = false } };
    const start = clock.read(.awake);
    try testing.expectError(error.Timeout, waitSilent(io, nothing, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    try testing.expectEqual(Io.Duration.fromMilliseconds(20), start.durationTo(clock.read(.awake)));
    try testing.expectEqual(@as(u64, 1), fio.count(.file_read_streaming));
    try testing.expectEqual(@as(u64, 1), fio.count(.batchAwaitConcurrent));
    try testing.expectEqual(@as(u64, 1), fio.count(.batchCancel));
}

test "an operation still pending at a second await is not counted again, and one called off is forgotten" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // a pipe read is not a pollable batch operation there
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = "ready" });
    const fio = try FaultIo.init(testing.allocator, testing.io, .{});
    defer fio.deinit();
    const io = fio.io();
    const file = try tmp.dir.openFile(testing.io, "data", .{});
    defer file.close(testing.io);
    const fds = try Io.Threaded.pipe2(.{});
    const silent: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer silent.close(testing.io);
    defer (Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } }).close(testing.io);
    var ready: [8]u8 = undefined;
    var never: [8]u8 = undefined;
    var ready_data = [_][]u8{&ready};
    var never_data = [_][]u8{&never};
    var storage: [2]Io.Operation.Storage = undefined;
    const now: Io.Timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } };
    for (0..2) |round| {
        // The same batch, made again where it was.
        var batch: Io.Batch = .init(&storage);
        batch.addAt(0, .{ .file_read_streaming = .{ .file = silent, .data = &never_data } });
        batch.addAt(1, .{ .file_read_streaming = .{ .file = file, .data = &ready_data } });
        try batch.awaitConcurrent(io, .none);
        try testing.expectEqual(@as(u32, 1), batch.next().?.index);
        try testing.expectError(error.Timeout, batch.awaitConcurrent(io, now));
        batch.cancel(io);
        try testing.expectEqual(@as(u64, 2 * (round + 1)), fio.count(.file_read_streaming));
    }
}
