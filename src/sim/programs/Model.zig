//! Simulated processes: the programs a simulation knows by name, and the
//! processes `std.process.spawn` starts from them.
//!
//! A process is a task running its program's `main`, with tasks of its own,
//! its own standard streams, environment, working directory, heap and
//! arena, on the node of the process that spawned it. It ends when `main`
//! returns, or when it is killed: then every task it still has is dropped
//! where it stands, as a process's threads die with it, and what it holds
//! is given back, as an operating system takes back a dead process's
//! descriptors and memory: its pipe ends (a reader on the other side sees
//! the end of the stream), its files and their locks, its sockets, its heap.
//!
//! Process ids are values no system issues: on POSIX, numbers past every
//! system's largest pid, so a raw `kill` on one fails; on Windows, handles
//! user mode cannot resolve.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Pipes = @import("Pipes.zig");
const Heap = @import("Heap.zig");
const NodeId = @import("../net/Model.zig").NodeId;
const Model = @This();

pub const Options = struct {
    /// Bytes a pipe holds before its writer waits: Linux's default.
    pipe_capacity: usize = 64 * 1024,
    /// The environment the test's own process passes to the programs it
    /// spawns without an `environ_map`.
    environ: []const Variable = &.{},
};

pub const Variable = struct { name: []const u8, value: []const u8 };

/// A program's entry: runs `main` with the registered context and the
/// process's `Init`, and returns its exit code.
pub const Entry = *const fn (context: *const anyopaque, init: std.process.Init) u8;

pub const Program = struct {
    /// Matched against the path a spawn names: a name with no separator
    /// matches any path whose last component it is.
    name: []u8,
    entry: Entry,
    context: []align(context_align) u8,
};

pub const context_align = 64;

pub const Term = std.process.Child.Term;

pub const Stream = struct {
    file: Io.File,
    /// Whether the process owns the handle: its pipe ends, its null device,
    /// its copy of a pipe end it was handed. Any other file it was handed
    /// (`StdIo.file`, `.inherit`) stays its parent's.
    owned: bool,
    open: bool = true,
};

pub const Process = struct {
    pid: u32,
    node: NodeId,
    /// The Io its tasks are given: the simulation's, in the process's own
    /// namespace (through the fault part, when the simulation has one).
    io: Io = undefined,
    /// Its working directory: a handle of its own on its node's disk; null
    /// for the disk's root.
    cwd: ?Io.Dir = null,
    program: *const Program,
    term: ?Term = null,
    stdio: [3]Stream,
    /// What the image is made of: argv, its environment block, its path.
    image: std.heap.ArenaAllocator,
    argv: []const [:0]const u8 = &.{},
    exe: []const u8 = &.{},
    /// `Init.environ_map`: the program's to change.
    environ: std.process.Environ.Map,
    /// The environment the process started with, which its children
    /// inherit whatever the program changed since, as on a real system.
    inherited: std.process.Environ.Map,
    /// `Init.arena` and `Init.gpa`: given back when the process ends.
    arena: std.heap.ArenaAllocator,
    heap: Heap,
};

gpa: Allocator,
options: Options,
programs: std.ArrayList(Program) = .empty,
/// Live processes, and ended ones not yet waited for.
processes: std.ArrayList(*Process) = .empty,
pipes: Pipes,
next_pid: u32 = 1,
/// The environment of the test's own process, as children inherit it.
environ: std.process.Environ.Map,

pub fn init(gpa: Allocator, options: Options) error{OutOfMemory}!Model {
    var environ: std.process.Environ.Map = .init(gpa);
    errdefer environ.deinit();
    for (options.environ) |v| try environ.put(v.name, v.value);
    return .{ .gpa = gpa, .options = options, .pipes = .init(gpa, options.pipe_capacity), .environ = environ };
}

pub fn deinit(m: *Model) void {
    for (m.processes.items) |p| m.destroy(p);
    m.processes.deinit(m.gpa);
    for (m.programs.items) |program| {
        m.gpa.free(program.name);
        m.gpa.free(program.context);
    }
    m.programs.deinit(m.gpa);
    m.pipes.deinit();
    m.environ.deinit();
    m.* = undefined;
}

fn destroy(m: *Model, p: *Process) void {
    p.environ.deinit();
    p.inherited.deinit();
    p.image.deinit();
    p.arena.deinit();
    p.heap.deinit();
    m.gpa.destroy(p);
}

pub fn register(m: *Model, name: []const u8, entry: Entry, context: []const u8) error{OutOfMemory}!void {
    try m.programs.ensureUnusedCapacity(m.gpa, 1);
    const owned_name = try m.gpa.dupe(u8, name);
    errdefer m.gpa.free(owned_name);
    const owned_context = try m.gpa.alignedAlloc(u8, .fromByteUnits(context_align), context.len);
    @memcpy(owned_context, context);
    // A later registration of a name replaces the earlier one.
    for (m.programs.items) |*program| if (std.mem.eql(u8, program.name, name)) {
        m.gpa.free(program.name);
        m.gpa.free(program.context);
        program.* = .{ .name = owned_name, .entry = entry, .context = owned_context };
        return;
    };
    m.programs.appendAssumeCapacity(.{ .name = owned_name, .entry = entry, .context = owned_context });
}

/// The program `path` names, as a spawn resolves it.
pub fn find(m: *const Model, path: []const u8) ?*const Program {
    for (m.programs.items) |*program| if (std.mem.eql(u8, program.name, path)) return program;
    const base = basename(path);
    for (m.programs.items) |*program| {
        if (std.mem.findAny(u8, program.name, separators) != null) continue;
        if (std.mem.eql(u8, program.name, base)) return program;
    }
    return null;
}

const separators = if (builtin.os.tag == .windows) "/\\" else "/";

fn basename(path: []const u8) []const u8 {
    const at = std.mem.findLastAny(u8, path, separators) orelse return path;
    return path[at + 1 ..];
}

pub fn byPid(m: *const Model, pid: u32) ?*Process {
    for (m.processes.items) |p| if (p.pid == pid) return p;
    return null;
}

pub const MakeError = error{ OutOfMemory, SystemResources };

/// A process record for `program`, not yet running: its Io, streams and
/// working directory are the caller's to set.
pub fn make(m: *Model, program: *const Program, node: NodeId, argv: []const []const u8, exe: []const u8, environ: *const std.process.Environ.Map) MakeError!*Process {
    if (m.next_pid >= max_pid) return error.SystemResources;
    try m.processes.ensureUnusedCapacity(m.gpa, 1);
    const p = try m.gpa.create(Process);
    errdefer m.gpa.destroy(p);
    p.* = .{
        .pid = m.next_pid,
        .node = node,
        .program = program,
        .stdio = @splat(.{ .file = closed_file, .owned = false, .open = false }),
        .image = .init(m.gpa),
        .environ = .init(m.gpa),
        .inherited = .init(m.gpa),
        .arena = .init(m.gpa),
        .heap = .init(m.gpa),
    };
    errdefer {
        p.environ.deinit();
        p.inherited.deinit();
        p.image.deinit();
    }
    try p.environ.putAll(environ);
    try p.inherited.putAll(environ);
    try setImage(p, argv, exe);
    m.next_pid += 1;
    m.processes.appendAssumeCapacity(p);
    return p;
}

/// Copies the image's argv and path into the process's image arena.
pub fn setImage(p: *Process, argv: []const []const u8, exe: []const u8) error{OutOfMemory}!void {
    const a = p.image.allocator();
    const copied = try a.alloc([:0]const u8, argv.len);
    for (copied, argv) |*to, from| to.* = try a.dupeSentinel(u8, from, 0);
    p.argv = copied;
    p.exe = try a.dupe(u8, exe);
}

/// A handle every call rejects: the stream of a process spawned with
/// `StdIo.close`.
pub const closed_file: Io.File = .{ .handle = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1, .flags = .{ .nonblocking = false } };

/// Gives back what an ended process held of its own: its heap and arena,
/// its pipe ends. Its tasks, files and sockets are the simulation's to end.
pub fn release(m: *Model, p: *Process) void {
    m.pipes.closeOwned(p.pid);
    for (&p.stdio) |*s| s.open = false;
    p.cwd = null;
    p.heap.deinit();
    p.heap = .init(m.gpa);
    _ = p.arena.reset(.free_all);
}

/// How a killed process ends, as std's own kill reports it: `SIGTERM` on
/// POSIX, exit code 1 on Windows.
pub fn killed() Term {
    if (builtin.os.tag == .windows) return .{ .exited = 1 };
    return .{ .signal = .TERM };
}

/// Forgets an ended process: its id may be looked up no more.
pub fn reap(m: *Model, p: *Process) void {
    for (m.processes.items, 0..) |item, i| if (item == p) {
        _ = m.processes.orderedRemove(i);
        break;
    };
    m.destroy(p);
}

/// Runs the process's program on its main task, and returns its exit code.
pub fn run(p: *Process) u8 {
    var minimal_args: std.process.Args = .{ .vector = argsVector(p) catch return failedStart(p) };
    _ = &minimal_args;
    const environ_block = environBlock(p) catch return failedStart(p);
    const given: std.process.Init = .{
        .minimal = .{ .args = minimal_args, .environ = .{ .block = environ_block } },
        .arena = &p.arena,
        .gpa = p.heap.allocator(),
        .io = p.io,
        .environ_map = &p.environ,
        .preopens = .empty,
    };
    return p.program.entry(p.program.context.ptr, given);
}

/// A process that cannot be given its arguments or environment ends as
/// one that could not start: with 127, as a shell reports it.
fn failedStart(p: *Process) u8 {
    _ = p;
    return 127;
}

fn argsVector(p: *Process) error{ OutOfMemory, InvalidWtf8 }!std.process.Args.Vector {
    const Vector = std.process.Args.Vector;
    const a = p.image.allocator();
    if (Vector == []const [*:0]const u8) {
        const v = try a.alloc([*:0]const u8, p.argv.len);
        for (v, p.argv) |*to, from| to.* = from.ptr;
        return v;
    }
    if (Vector == []const u16) return commandLine(a, p.argv);
    return {};
}

fn environBlock(p: *Process) error{OutOfMemory}!std.process.Environ.Block {
    const Block = std.process.Environ.Block;
    if (Block == std.process.Environ.PosixBlock) return p.environ.createPosixBlock(p.image.allocator(), .{});
    // Elsewhere the block is the real process's own: the simulated one is
    // in `Init.environ_map`.
    return .empty;
}

/// `argv` as one Windows command line, quoted as the C runtime and
/// `CommandLineToArgvW` read it back.
pub fn commandLine(a: Allocator, argv: []const [:0]const u8) error{ OutOfMemory, InvalidWtf8 }![]const u16 {
    var line: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try line.append(a, ' ');
        if (arg.len > 0 and std.mem.findAny(u8, arg, " \t\n\x0b\"") == null) {
            try line.appendSlice(a, arg);
            continue;
        }
        try line.append(a, '"');
        var backslashes: usize = 0;
        for (arg) |ch| {
            if (ch == '\\') {
                backslashes += 1;
                continue;
            }
            const doubled = if (ch == '"') 2 * backslashes + 1 else backslashes;
            try line.appendNTimes(a, '\\', doubled);
            backslashes = 0;
            try line.append(a, ch);
        }
        try line.appendNTimes(a, '\\', 2 * backslashes);
        try line.append(a, '"');
    }
    return std.unicode.wtf8ToWtf16LeAlloc(a, line.items) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.InvalidWtf8,
    };
}

// Process ids.

const posix_pid_base: i32 = 0x4000_0000;
const max_pid: u32 = 0x2000_0000;
/// Below the pipes' handles (`Pipes.zig`).
const windows_base: usize = std.math.maxInt(usize) - 0x1_7fff_ffff;

pub fn encodePid(pid: u32) std.process.Child.Id {
    const Id = std.process.Child.Id;
    if (Id == void) return {};
    if (builtin.os.tag == .windows) return @ptrFromInt(windows_base + @as(usize, pid) * 4); // safe: a kernel-mode value user-mode calls cannot resolve, never dereferenced
    return posix_pid_base + @as(i32, @intCast(pid));
}

pub fn decodePid(id: std.process.Child.Id) ?u32 {
    const Id = std.process.Child.Id;
    if (Id == void) return null;
    if (builtin.os.tag == .windows) {
        const value = @intFromPtr(id); // safe: an opaque handle, never dereferenced
        if (value < windows_base or value % 4 != 0) return null;
        const pid = (value - windows_base) / 4;
        return if (pid > 0 and pid < max_pid) @intCast(pid) else null;
    }
    if (id <= posix_pid_base) return null;
    const pid: u32 = @intCast(id - posix_pid_base);
    return if (pid < max_pid) pid else null;
}

test "a Windows command line reads back as the arguments it was made of" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "prog", "two words", "", "quote\"d", "trailing\\", "back\\\\\"slash", "plain\\path", "tab\there" };
    const line = try commandLine(a, &argv);
    // Read back by std's own parser of Windows command lines.
    var it: std.process.Args.Iterator.Windows = try .init(a, line);
    for (argv) |arg| try std.testing.expectEqualStrings(arg, it.next().?);
    try std.testing.expect(it.next() == null);
}

test "a program is found by its name or by a path ending in it" {
    var m: Model = try .init(std.testing.allocator, .{});
    defer m.deinit();
    const entry: Entry = struct {
        fn f(_: *const anyopaque, _: std.process.Init) u8 {
            return 0;
        }
    }.f;
    try m.register("git", entry, &.{});
    try m.register("/opt/tool", entry, &.{});
    try std.testing.expect(m.find("git") != null);
    try std.testing.expect(m.find("/usr/bin/git") != null);
    try std.testing.expect(m.find("/opt/tool") != null);
    try std.testing.expect(m.find("tool") == null);
    try std.testing.expect(m.find("gitk") == null);
}

test "process ids round-trip and are no system's" {
    if (std.process.Child.Id == void) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?u32, 7), decodePid(encodePid(7)));
    if (builtin.os.tag != .windows) try std.testing.expectEqual(@as(?u32, null), decodePid(1234));
}
