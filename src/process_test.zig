//! Simulated processes from outside: `std.process` spawning registered
//! programs, their pipes, environment, working directory, exit and kill.
const std = @import("std");
const Io = std.Io;
const t = std.testing;
const Sim = @import("Sim.zig");

/// A real program's main: prints its arguments after the first, one a line.
fn echo(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.skip();
    var buffer: [64]u8 = undefined;
    var w = Io.File.stdout().writer(init.io, &buffer);
    while (it.next()) |arg| try w.interface.print("{s}\n", .{arg});
    try w.interface.flush();
}

/// Reads all of stdin and writes it back upper-cased; then says on stderr
/// how many bytes it read, and exits with that count modulo 256.
fn upper(init: std.process.Init) !u8 {
    var buffer: [256]u8 = undefined;
    var r = Io.File.stdin().reader(init.io, &buffer);
    const all = try r.interface.allocRemaining(init.gpa, .unlimited);
    defer init.gpa.free(all);
    for (all) |*c| c.* = std.ascii.toUpper(c.*);
    try Io.File.stdout().writeStreamingAll(init.io, all);
    var line: [32]u8 = undefined;
    try Io.File.stderr().writeStreamingAll(init.io, try std.mem.print(&line, "{d}\n", .{all.len}));
    return @truncate(all.len);
}

fn failing() !void {
    return error.AccessDenied;
}

const Run = struct {
    fn echoRun(io: Io) !void {
        const result = try std.process.run(t.allocator, io, .{ .argv = &.{ "/usr/bin/echo", "one", "two words" } });
        defer t.allocator.free(result.stdout);
        defer t.allocator.free(result.stderr);
        try t.expectEqualStrings("one\ntwo words\n", result.stdout);
        try t.expectEqualStrings("", result.stderr);
        try t.expect(result.term.success());
    }
};

test "std.process.run runs a registered program and collects its output" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("echo", echo, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Run.echoRun, .{sim.io()}));
}

fn pipeThrough(io: Io, input: []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = &.{"upper"}, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    // The writer and the reader run as tasks of their own, so a pipe that
    // fills in either direction cannot stall the other.
    const Writer = struct {
        fn write(io_: Io, stdin: Io.File, bytes: []const u8) !void {
            try stdin.writeStreamingAll(io_, bytes);
        }
    };
    var writing = try io.concurrent(Writer.write, .{ io, child.stdin.?, input });
    var buffer: [256]u8 = undefined;
    var r = child.stdout.?.reader(io, &buffer);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(t.allocator);
    // The writer closes stdin once done, so the child reads to the end.
    try writing.await(io);
    child.stdin.?.close(io);
    child.stdin = null;
    try r.interface.appendRemainingUnlimited(t.allocator, &got);
    var e_buffer: [64]u8 = undefined;
    var er = child.stderr.?.reader(io, &e_buffer);
    const said = try er.interface.allocRemaining(t.allocator, .unlimited);
    defer t.allocator.free(said);
    const term = try child.wait(io);
    try t.expectEqual(input.len, got.items.len);
    for (input, got.items) |a, b| try t.expectEqual(std.ascii.toUpper(a), b);
    var line: [32]u8 = undefined;
    try t.expectEqualStrings(try std.mem.print(&line, "{d}\n", .{input.len}), said);
    try t.expectEqual(Sim.Programs.Term{ .exited = @truncate(input.len) }, term);
}

test "a child's stdin and stdout are pipes that carry a megabyte through a small buffer" {
    const input = try t.allocator.alloc(u8, 1 << 20);
    defer t.allocator.free(input);
    var prng: std.Random.DefaultPrng = .init(1);
    for (input) |*c| c.* = 'a' + prng.random().uintLessThan(u8, 26);
    for (0..3) |seed| {
        const sim = try Sim.init(t.allocator, .{ .seed = seed, .watchdog = null, .programs = .{ .pipe_capacity = 4096 } });
        defer sim.deinit();
        try sim.programs().register("upper", upper, .{});
        try t.expectEqual(Sim.Outcome.finished, sim.run(pipeThrough, .{ sim.io(), input }));
    }
}

const Failing = struct {
    fn run(io: Io) !void {
        const result = try std.process.run(t.allocator, io, .{ .argv = &.{"fails"} });
        defer t.allocator.free(result.stdout);
        defer t.allocator.free(result.stderr);
        try t.expectEqualStrings("error: AccessDenied\n", result.stderr);
        try t.expectEqual(Sim.Programs.Term{ .exited = 1 }, result.term);
        try t.expectError(error.FileNotFound, std.process.spawn(io, .{ .argv = &.{"missing"} }));
    }
};

test "a program that returns an error says so on stderr and exits with 1; an unknown one is not found" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("fails", failing, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Failing.run, .{sim.io()}));
}

/// Writes the values of the variables its arguments name, or `-` for one
/// that is not set.
fn printEnv(init: std.process.Init) !void {
    var buffer: [128]u8 = undefined;
    var w = Io.File.stdout().writer(init.io, &buffer);
    for (1..argCount(init)) |i| {
        const name = argAt(init, i);
        try w.interface.print("{s}={s}\n", .{ name, init.environ_map.get(name) orelse "-" });
    }
    try w.interface.flush();
}

fn argCount(init: std.process.Init) usize {
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator()) catch return 0;
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn argAt(init: std.process.Init, index: usize) []const u8 {
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator()) catch return "";
    var i: usize = 0;
    while (it.next()) |arg| : (i += 1) if (i == index) return arg;
    return "";
}

const Environment = struct {
    fn run(io: Io) !void {
        const inherited = try std.process.run(t.allocator, io, .{ .argv = &.{ "env", "HOME", "USER" } });
        defer t.allocator.free(inherited.stdout);
        defer t.allocator.free(inherited.stderr);
        try t.expectEqualStrings("HOME=/home/sim\nUSER=-\n", inherited.stdout);
        var map: std.process.Environ.Map = .init(t.allocator);
        defer map.deinit();
        try map.put("USER", "test");
        const given = try std.process.run(t.allocator, io, .{ .argv = &.{ "env", "HOME", "USER" }, .environ_map = &map });
        defer t.allocator.free(given.stdout);
        defer t.allocator.free(given.stderr);
        try t.expectEqualStrings("HOME=-\nUSER=test\n", given.stdout);
    }
};

test "a child inherits the test's environment, or gets the one it is given" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .programs = .{ .environ = &.{.{ .name = "HOME", .value = "/home/sim" }} } });
    defer sim.deinit();
    try sim.programs().register("env", printEnv, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Environment.run, .{sim.io()}));
}

/// Writes its working directory to a file named by its first argument, in
/// that directory, and moves into the directory its second names.
fn whereAmI(init: std.process.Init) !void {
    var path: [256]u8 = undefined;
    const n = try std.process.currentPath(init.io, &path);
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = argAt(init, 1), .data = path[0..n] });
    try std.process.setCurrentPath(init.io, argAt(init, 2));
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "moved", .data = "yes" });
}

const Directories = struct {
    fn run(io: Io) !void {
        try Io.Dir.cwd().createDirPath(io, "work/inner");
        var child = try std.process.spawn(io, .{ .argv = &.{ "where", "here", "inner" }, .cwd = .{ .path = "work" } });
        try t.expect((try child.wait(io)).success());
        var path: [256]u8 = undefined;
        const n = try std.process.currentPath(io, &path);
        try t.expectEqualStrings("/", path[0..n]);
    }
};

test "a child runs in its own working directory, and changing it changes only its own" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("where", whereAmI, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Directories.run, .{sim.io()}));
    const here = try sim.fs().read(t.allocator, "work/here");
    defer t.allocator.free(here);
    try t.expectEqualStrings("/work", here);
    const moved = try sim.fs().read(t.allocator, "work/inner/moved");
    defer t.allocator.free(moved);
    try t.expectEqualStrings("yes", moved);
}

const Recorder = struct {
    calls: u32 = 0,
    last: [32]u8 = undefined,
    last_len: usize = 0,
};

/// A fake program: it counts its runs in the test's recorder and keeps its
/// first argument.
fn fake(r: *Recorder, init: std.process.Init) u8 {
    r.calls += 1;
    const arg = argAt(init, 1);
    @memcpy(r.last[0..arg.len], arg);
    r.last_len = arg.len;
    return 3;
}

const Faked = struct {
    fn run(io: Io) !void {
        for (0..3) |_| {
            var child = try std.process.spawn(io, .{ .argv = &.{ "git", "status" }, .stdout = .ignore, .stderr = .close });
            try t.expectEqual(Sim.Programs.Term{ .exited = 3 }, try child.wait(io));
        }
    }
};

test "a fake program reaches the test's state through its registered context" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    var recorder: Recorder = .{};
    try sim.programs().register("git", fake, .{&recorder});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Faked.run, .{sim.io()}));
    try t.expectEqual(@as(u32, 3), recorder.calls);
    try t.expectEqualStrings("status", recorder.last[0..recorder.last_len]);
}

/// Holds a lock on `lock` and a helper task, then sleeps for ever.
fn stubborn(init: std.process.Init) !void {
    const io = init.io;
    const file = try Io.Dir.cwd().createFile(io, "lock", .{ .lock = .exclusive });
    _ = file;
    const leaked = try init.gpa.alloc(u8, 4096);
    _ = leaked;
    const Helper = struct {
        fn forever(io_: Io) Io.Cancelable!void {
            try io_.sleep(.fromSeconds(1 << 30), .awake);
        }
    };
    var helper = try io.concurrent(Helper.forever, .{io});
    _ = &helper;
    try Io.File.stdout().writeStreamingAll(io, "locked\n");
    try io.sleep(.fromSeconds(1 << 30), .awake);
}

const Killing = struct {
    fn run(io: Io) !void {
        var child = try std.process.spawn(io, .{ .argv = &.{"stubborn"}, .stdout = .pipe });
        var buffer: [16]u8 = undefined;
        var r = child.stdout.?.reader(io, &buffer);
        try t.expectEqualStrings("locked", try r.interface.takeDelimiterExclusive('\n'));
        child.kill(io);
        try t.expect(child.id == null and child.stdout == null);
        // Its lock went with it.
        const file = try Io.Dir.cwd().openFile(io, "lock", .{ .lock = .exclusive, .lock_nonblocking = true });
        file.close(io);
    }
};

test "a killed child ends at once with its tasks, and gives back its locks and memory" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("stubborn", stubborn, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Killing.run, .{sim.io()}));
}

/// Replaces itself with `echo`, its arguments passed on.
fn exec(init: std.process.Init) !void {
    var args: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    _ = it.skip();
    args[0] = "echo";
    n = 1;
    while (it.next()) |arg| : (n += 1) args[n] = arg;
    return std.process.replace(init.io, .{ .argv = args[0..n] });
}

const Replacing = struct {
    fn run(io: Io) !void {
        const result = try std.process.run(t.allocator, io, .{ .argv = &.{ "exec", "replaced", "image" } });
        defer t.allocator.free(result.stdout);
        defer t.allocator.free(result.stderr);
        try t.expectEqualStrings("replaced\nimage\n", result.stdout);
        try t.expect(result.term.success());
        try t.expectEqual(error.OperationUnsupported, std.process.replace(io, .{ .argv = &.{"echo"} }));
    }
};

test "a process replaces its image with another program under the same streams" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("echo", echo, .{});
    try sim.programs().register("exec", exec, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Replacing.run, .{sim.io()}));
}

/// Spawns `echo` itself and passes on what it printed.
fn nest(init: std.process.Init) !void {
    const result = try std.process.run(init.gpa, init.io, .{ .argv = &.{ "echo", "nested" } });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try Io.File.stdout().writeStreamingAll(init.io, result.stdout);
}

const Nesting = struct {
    fn run(io: Io) !void {
        const result = try std.process.run(t.allocator, io, .{ .argv = &.{"nest"} });
        defer t.allocator.free(result.stdout);
        defer t.allocator.free(result.stderr);
        try t.expectEqualStrings("nested\n", result.stdout);
    }
};

test "a process spawns processes of its own" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("echo", echo, .{});
    try sim.programs().register("nest", nest, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Nesting.run, .{sim.io()}));
}

const Waiting = struct {
    fn run(io: Io) !void {
        // stdin stays open, so `upper` waits for it for ever, and so does
        // the test for `upper`.
        var child = try std.process.spawn(io, .{ .argv = &.{"upper"}, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
        _ = try child.wait(io);
    }
};

test "a wait for a child that waits for its parent is a deadlock that names both" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("upper", upper, .{});
    const reports = switch (sim.run(Waiting.run, .{sim.io()})) {
        .deadlock => |r| r,
        else => return error.TestUnexpectedResult,
    };
    var process_waits: usize = 0;
    for (reports) |r| process_waits += @intFromBool(r.waiting == .process);
    try t.expectEqual(@as(usize, 1), process_waits);
    try t.expectEqual(@as(usize, 2), reports.len);
}

fn writeAfterClose(init: std.process.Init) !void {
    // Waits until the reader has gone, then writes into the broken pipe.
    try init.io.sleep(.fromSeconds(1), .awake);
    try Io.File.stdout().writeStreamingAll(init.io, "anyone?");
}

const Broken = struct {
    fn run(io: Io) !void {
        var child = try std.process.spawn(io, .{ .argv = &.{"late"}, .stdout = .pipe, .stderr = .pipe });
        child.stdout.?.close(io);
        child.stdout = null;
        var buffer: [64]u8 = undefined;
        var r = child.stderr.?.reader(io, &buffer);
        try t.expectEqualStrings("error: BrokenPipe", try r.interface.takeDelimiterExclusive('\n'));
        try t.expectEqual(Sim.Programs.Term{ .exited = 1 }, try child.wait(io));
    }
};

test "a write into a pipe whose reader closed fails" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("late", writeAfterClose, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Broken.run, .{sim.io()}));
}

fn traceOf(seed: u64, input: []const u8) !u64 {
    const sim = try Sim.init(t.allocator, .{ .seed = seed, .watchdog = null, .programs = .{ .pipe_capacity = 512 }, .trace = .off });
    defer sim.deinit();
    try sim.programs().register("upper", upper, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(pipeThrough, .{ sim.io(), input }));
    return sim.trace().hash();
}

test "a run with processes repeats from its seed" {
    var input: [5000]u8 = undefined;
    for (&input, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var hashes: [4]u64 = undefined;
    for (&hashes, 0..) |*h, seed| {
        h.* = try traceOf(seed, &input);
        try t.expectEqual(h.*, try traceOf(seed, &input));
    }
    try t.expect(hashes[0] != hashes[1] or hashes[1] != hashes[2]);
}

const Faulted = struct {
    fn run(io: Io) !void {
        try t.expectError(error.SystemResources, std.process.spawn(io, .{ .argv = &.{"echo"} }));
        const result = try std.process.run(t.allocator, io, .{ .argv = &.{ "echo", "after" } });
        defer t.allocator.free(result.stdout);
        defer t.allocator.free(result.stderr);
        try t.expectEqualStrings("after\n", result.stdout);
    }
};

test "a fault plan reaches spawns" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .faults = &.{.{ .at = .{ .nth = .{ .call = .processSpawn, .n = 1 } }, .fault = .{ .fail = error.SystemResources } }} });
    defer sim.deinit();
    try sim.programs().register("echo", echo, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Faulted.run, .{sim.io()}));
}

fn sleeper(woke: *u32, init: std.process.Init) !void {
    try init.io.sleep(.fromSeconds(10), .awake);
    woke.* += 1;
}

const OnNode = struct {
    fn spawnThere(io: Io) !void {
        var child = try std.process.spawn(io, .{ .argv = &.{"sleeper"} });
        _ = try child.wait(io);
    }

    fn run(io: Io, node: *Sim.Node) !void {
        try io.sleep(.fromSeconds(1), .awake);
        node.kill();
        try io.sleep(.fromSeconds(60), .awake);
    }
};

test "a node that goes down takes its processes with it" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    var woke: u32 = 0;
    try sim.programs().register("sleeper", sleeper, .{&woke});
    const node = try sim.node("b", .{});
    try node.restart(OnNode.spawnThere, .{node.io()});
    try t.expectEqual(Sim.Outcome.finished, sim.run(OnNode.run, .{ sim.io(), node }));
    try t.expectEqual(@as(u32, 0), woke);
}

test "processes need no disk" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null, .fs = null });
    defer sim.deinit();
    try sim.programs().register("echo", echo, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Run.echoRun, .{sim.io()}));
}

/// Says whether its streams are a terminal, then echoes a line it reads.
fn termEcho(init: std.process.Init) !void {
    const out = Io.File.stdout();
    var line: [64]u8 = undefined;
    const tty = try out.isTty(init.io);
    try out.writeStreamingAll(init.io, if (tty) "tty\n" else "pipe\n");
    var buffer: [64]u8 = undefined;
    var r = Io.File.stdin().reader(init.io, &buffer);
    const got = try r.interface.takeDelimiterInclusive('\n');
    try out.writeStreamingAll(init.io, try std.mem.print(&line, "echo {s}", .{got}));
}

/// Never ends on its own.
fn forever(init: std.process.Init) !void {
    while (true) try init.io.sleep(.fromSeconds(1), .awake);
}

const Seams = struct {
    fn onTerminal(io: Io, programs: Sim.Programs) !void {
        const term = try programs.terminal(.{ .rows = 24, .cols = 80 });
        defer term.master_read.close(io);
        defer term.master_write.close(io);
        var child = try std.process.spawn(io, .{ .argv = &.{"term-echo"}, .stdin = .{ .file = term.slave_read }, .stdout = .{ .file = term.slave_write }, .stderr = .{ .file = term.slave_write } });
        // The child holds copies of the slave's ends: the test's can go,
        // and the master reads to the end once the child ends.
        term.slave_read.close(io);
        term.slave_write.close(io);
        try term.master_write.writeStreamingAll(io, "hi\n");
        try programs.setWindowSize(term.master_write, .{ .rows = 50, .cols = 132 });
        try t.expectEqual(@as(u16, 132), (try programs.windowSize(term.master_read)).cols);
        var buffer: [64]u8 = undefined;
        var r = term.master_read.reader(io, &buffer);
        const all = try r.interface.allocRemaining(t.allocator, .unlimited);
        defer t.allocator.free(all);
        try t.expectEqualStrings("tty\necho hi\n", all);
        try t.expect((try child.wait(io)).success());
    }

    fn endAndWait(io: Io, programs: Sim.Programs) !void {
        var child = try std.process.spawn(io, .{ .argv = &.{"forever"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        try t.expectEqual(@as(?Sim.Programs.Term, null), try programs.poll(&child));
        const before = io.vtable.now(io.userdata, .awake);
        try t.expectEqual(@as(?Sim.Programs.Term, null), try programs.waitFor(&child, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }));
        const after = io.vtable.now(io.userdata, .awake);
        try t.expectEqual(@as(i96, std.time.ns_per_s * 5), after.nanoseconds - before.nanoseconds);
        programs.end(&child, .{ .exited = 3 });
        const ended = try programs.waitFor(&child, .none);
        try t.expectEqual(Sim.Programs.Term{ .exited = 3 }, ended.?);
    }
};

test "a seam's terminal: a child on it sees a terminal, and the master reads it to the end" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("term-echo", termEcho, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Seams.onTerminal, .{ sim.io(), Sim.programsOf(sim.io()).? }));
}

test "a seam's end and timed wait: a child polled, waited for past a deadline, ended and reaped" {
    const sim = try Sim.init(t.allocator, .{ .watchdog = null });
    defer sim.deinit();
    try sim.programs().register("forever", forever, .{});
    try t.expectEqual(Sim.Outcome.finished, sim.run(Seams.endAndWait, .{ sim.io(), sim.programs().* }));
    try t.expectEqual(@as(?Sim.Programs, null), Sim.programsOf(t.io));
}
