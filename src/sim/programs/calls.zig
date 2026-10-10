//! Process slots of the one simulation, and the file slots for the streams
//! processes are given.
//!
//! `processSpawn` starts a registered program as a simulated process,
//! `childWait` waits for it to end and `childKill` ends it at once; a
//! process's `processReplace` starts another program in its place. The
//! working directory is per process, and per node for the test's own.
//!
//! A simulated process's standard handles (`File.stdin()`, `stdout()`,
//! `stderr()`) are its own streams, so a real `main` reads and writes its
//! pipes unchanged; the test's own standard handles stay the real ones.
//! Pipe ends and the null device answer the file slots as a pipe does:
//! `stat` says `named_pipe`, positional calls are `Unseekable`, and a
//! streaming read or write waits until it can move a byte.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Core = @import("../Core.zig");
const Processes = @import("Model.zig");
const Process = Processes.Process;
const Pipes = @import("Pipes.zig");
const Disk = @import("../fs/Model.zig");
const Routing = @import("../routing.zig").Routing;
const io_call = @import("../../io_call.zig");
const IoCall = io_call.IoCall;

fn digestOf(err: anyerror) u64 {
    return std.hash.Wyhash.hash(0, @errorName(err));
}

fn outside(comptime what: []const u8) noreturn {
    @panic("shakedown: " ++ what ++ " blocks, and was called on a simulation's Io outside its tasks; call it from code Sim.run runs");
}

pub fn supports(comptime name: []const u8) bool {
    return @hasDecl(slots, name);
}

pub fn slot(comptime name: []const u8) @FieldType(Io.VTable, name) {
    return @field(slots, name);
}

// Standard handles.

/// Which standard stream `handle` is: 0, 1 or 2.
fn standardIndex(handle: Io.File.Handle) ?usize {
    if (handle == Io.File.stdout().handle) return 1;
    if (handle == Io.File.stderr().handle) return 2;
    if (handle == Io.File.stdin().handle) return 0;
    return null;
}

/// The file a call from the running task means by `file`: a simulated
/// process's standard handles are its own streams.
pub fn translate(c: *const Core, file: Io.File) Io.File {
    const p = c.processOf() orelse return file;
    const i = standardIndex(file.handle) orelse return file;
    const s = p.stdio[i];
    return if (s.open) s.file else Processes.closed_file;
}

/// The operation with its file translated as `translate` does.
pub fn translateOperation(c: *const Core, operation: Io.Operation) Io.Operation {
    var op = operation;
    switch (op) {
        .file_read_streaming => |*r| r.file = translate(c, r.file),
        .file_write_streaming => |*w| w.file = translate(c, w.file),
        else => {},
    }
    return op;
}

/// Whether the (translated) operation is on a pipe end or the null device.
pub fn isPipe(op: Io.Operation) bool {
    return switch (op) {
        .file_read_streaming => |r| Pipes.owns(r.file.handle),
        .file_write_streaming => |w| Pipes.owns(w.file.handle),
        else => false,
    };
}

/// A pipe operation's result, or null while it would wait. A change wakes
/// every task waiting on a stream.
pub fn perform(c: *Core, op: Io.Operation) ?Io.Operation.Result {
    const pipes = &c.processes.pipes;
    switch (op) {
        .file_read_streaming => |r| {
            const read = pipes.read(r.file.handle, r.data) catch |err| return .{ .file_read_streaming = switch (err) {
                error.BadHandle => error.Unexpected,
                error.NotOpenForReading => error.NotOpenForReading,
                error.EndOfStream => error.EndOfStream,
            } };
            const n = read orelse return null;
            c.wakeIo();
            return .{ .file_read_streaming = n };
        },
        .file_write_streaming => |w| {
            const written = pipes.write(w.file.handle, w.header, w.data, w.splat) catch |err| return .{ .file_write_streaming = switch (err) {
                error.BadHandle => error.Unexpected,
                error.NotOpenForWriting => error.NotOpenForWriting,
                error.BrokenPipe => error.BrokenPipe,
            } };
            const n = written orelse return null;
            c.wakeIo();
            return .{ .file_write_streaming = n };
        },
        else => unreachable, // unreachable: `isPipe` admits only streaming reads and writes
    }
}

/// A digest of a pipe operation for the trace: the end, and what came of it.
pub fn operationDigest(op: Io.Operation, result: Io.Operation.Result) u64 {
    var h: std.hash.Wyhash = .init(0x70697065);
    const handle, const outcome = switch (op) {
        .file_read_streaming => |r| .{ r.file.handle, result.file_read_streaming },
        .file_write_streaming => |w| .{ w.file.handle, result.file_write_streaming },
        else => unreachable, // unreachable: `isPipe` admits only streaming reads and writes
    };
    const end: u64 = Pipes.id(handle) orelse std.math.maxInt(u64);
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, end)));
    if (outcome) |n| {
        h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, n)));
    } else |err| h.update(@errorName(err));
    return h.final();
}

/// Closes a file of the simulation's, whichever model holds it.
fn closeAny(c: *Core, file: Io.File) void {
    if (Pipes.owns(file.handle)) {
        c.processes.pipes.close(file.handle);
        c.wakeIo();
        return;
    }
    if (c.disk(c.nodeId())) |disk| {
        disk.model.close(file.handle);
        c.wakeLocks(disk.model);
    }
}

// File slots.

/// Whether `name` is a file slot whose first argument is a file: those
/// reach a pipe through `fileSlot`.
pub fn wrapsFile(comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "fileClose")) return true;
    if (!std.mem.startsWith(u8, name, "file") or std.mem.startsWith(u8, name, "fileMemoryMap")) return false;
    const params = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".param_types;
    return params.len >= 2 and params[1].? == Io.File;
}

fn Return(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?;
}

/// The slot `name` over `inner`, the file system's: a simulated process's
/// standard handles become its streams, and a pipe end is answered here.
pub fn fileSlot(comptime name: []const u8, comptime inner: @FieldType(Io.VTable, name)) @FieldType(Io.VTable, name) {
    if (comptime std.mem.eql(u8, name, "fileClose")) return closeSlot(inner);
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const params = info.param_types;
    const R = info.return_type.?;
    const Body = struct {
        inline fn run(u: ?*anyopaque, file: Io.File, rest: anytype, ret: usize) R {
            const c = Core.of(u);
            const real = translate(c, file);
            if (!Pipes.owns(real.handle)) return @call(.auto, inner, .{ u, real } ++ rest);
            return pipeCall(name, c, real, ret);
        }
    };
    return switch (params.len) {
        2 => &struct {
            fn f(u: ?*anyopaque, file: Io.File) R {
                return Body.run(u, file, .{}, @returnAddress());
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, file: Io.File, a: params[2].?) R {
                return Body.run(u, file, .{a}, @returnAddress());
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, file: Io.File, a: params[2].?, b: params[3].?) R {
                return Body.run(u, file, .{ a, b }, @returnAddress());
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, file: Io.File, a: params[2].?, b: params[3].?, d: params[4].?) R {
                return Body.run(u, file, .{ a, b, d }, @returnAddress());
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, file: Io.File, a: params[2].?, b: params[3].?, d: params[4].?, e: params[5].?) R {
                return Body.run(u, file, .{ a, b, d, e }, @returnAddress());
            }
        }.f,
        7 => &struct {
            fn f(u: ?*anyopaque, file: Io.File, a: params[2].?, b: params[3].?, d: params[4].?, e: params[5].?, g: params[6].?) R {
                return Body.run(u, file, .{ a, b, d, e, g }, @returnAddress());
            }
        }.f,
        else => @compileError("file slot arity unsupported: " ++ name),
    };
}

/// `fileClose`: pipe ends close here; a simulated process's standard
/// handle closes its stream, and the file underneath only when the
/// process owns it; a call with neither is the file system's alone.
fn closeSlot(comptime inner: @FieldType(Io.VTable, "fileClose")) @FieldType(Io.VTable, "fileClose") {
    return &struct {
        fn f(u: ?*anyopaque, files: []const Io.File) void {
            const c = Core.of(u);
            const process = c.processOf();
            for (files) |file| {
                if (Pipes.owns(file.handle)) break;
                if (process != null and standardIndex(file.handle) != null) break;
            } else return inner(u, files);
            const e = c.enter(@returnAddress(), true);
            c.touch(Core.Object.pipes, true);
            c.touch(Core.Object.disk(e.node), true);
            var h: std.hash.Wyhash = .init(0);
            const disk = c.disk(e.node);
            for (files) |file| {
                var real = file;
                if (process) |p| if (standardIndex(file.handle)) |i| {
                    const s = &p.stdio[i];
                    if (!s.open) continue;
                    s.open = false;
                    if (!s.owned) continue;
                    real = s.file;
                };
                if (Pipes.id(real.handle)) |end| {
                    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, end)));
                    c.processes.pipes.close(real.handle);
                } else if (disk) |d| d.model.close(real.handle);
            }
            if (disk) |d| c.wakeLocks(d.model);
            c.wakeIo();
            c.record(.fileClose, e, h.final());
        }
    }.f;
}

/// A file slot on a pipe end, as a pipe answers it.
fn pipeCall(comptime name: []const u8, c: *Core, file: Io.File, ret: usize) Return(name) {
    const R = Return(name);
    const call = @field(IoCall, name);
    const e = c.enter(ret, true);
    if (comptime io_call.cancelable(call)) if (e.task) |t| if (Core.cancelPoint(t)) {
        c.record(call, e, digestOf(error.Canceled));
        return error.Canceled;
    };
    c.touch(Core.Object.pipes, true);
    const end: u64 = Pipes.id(file.handle) orelse std.math.maxInt(u64);
    const value: R = pipeAnswer(name, c, file);
    c.record(call, e, std.hash.int(end) ^ switch (@typeInfo(R)) {
        .void => 0,
        .error_union => if (value) |_| 0 else |err| digestOf(err),
        else => 0,
    });
    return value;
}

fn pipeAnswer(comptime name: []const u8, c: *Core, file: Io.File) Return(name) {
    const R = Return(name);
    if (comptime std.mem.eql(u8, name, "fileStat")) {
        const buffered = c.processes.pipes.buffered(file.handle) catch return error.Unexpected;
        const now = c.now(.real);
        return .{
            .inode = @intCast(Pipes.id(file.handle).? + 1),
            .nlink = 1,
            .size = buffered,
            .permissions = .default_file,
            .kind = .named_pipe,
            .atime = null,
            .mtime = now,
            .ctime = now,
            .block_size = 1,
        };
    }
    if (comptime std.mem.eql(u8, name, "fileLength")) {
        _ = c.processes.pipes.end(file.handle) catch return error.Unexpected;
        return 0;
    }
    if (comptime std.mem.eql(u8, name, "fileSync") or std.mem.eql(u8, name, "fileUnlock")) return;
    // A terminal's slave end is a terminal; any other end is not.
    if (comptime std.mem.eql(u8, name, "fileIsTty") or std.mem.eql(u8, name, "fileSupportsAnsiEscapeCodes")) {
        return c.processes.pipes.isTerminal(file.handle) catch false;
    }
    if (comptime std.mem.eql(u8, name, "fileEnableAnsiEscapeCodes")) {
        if (!(c.processes.pipes.isTerminal(file.handle) catch false)) return error.NotTerminalDevice;
        return;
    }
    return fallback(R);
}

/// What a pipe answers a call it has no meaning for: `Unseekable` for a
/// position, `Unimplemented` for a copy (the writer then copies by hand),
/// else `Unexpected`, else the first error the call can give.
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
    inline for (.{ "Unseekable", "Unimplemented", "NotTerminalDevice", "Unexpected" }) |preferred| {
        inline for (names) |n| if (comptime std.mem.eql(u8, n, preferred)) return @field(E, n);
    }
    return @field(E, names[0]);
}

// Spawning.

fn pathOf(exe: std.process.ReplaceOptions.Exe, argv: []const []const u8) ?[]const u8 {
    return switch (exe) {
        .detect, .search, .path => if (argv.len > 0) argv[0] else null,
        .explicit => |x| x.path,
        .file => null,
    };
}

/// The process's own handle on `inode`, a directory, as its working
/// directory.
fn openCwd(disk: *Disk, inode: u32, owner: u32) (Disk.Error || error{NotDir})!Io.Dir {
    if (disk.root.nodes.items[inode].kind != .directory) return error.NotDir;
    const file = try disk.openHandle(inode, true, false, false, false);
    disk.setOwner(file.handle, owner);
    return .{ .handle = file.handle };
}

/// The directory a context's working directory resolves to on `disk`.
fn cwdInode(disk: *Disk, ctx: ?*const Core.Context) Disk.Error!u32 {
    const cwd = Core.cwdOf(ctx orelse return 0) orelse return 0;
    return disk.directory(cwd);
}

fn resolveCwd(c: *Core, disk: *Disk, cwd: std.process.Child.Cwd, owner: u32) !?Io.Dir {
    const parent = c.currentContext();
    const inode = switch (cwd) {
        .inherit => if (parent != null and Core.cwdOf(parent.?) != null) try cwdInode(disk, parent) else return null,
        .dir => |d| if (d.handle == Io.Dir.cwd().handle) try cwdInode(disk, parent) else try disk.directory(d),
        .path => |path| try disk.resolve(try cwdInode(disk, parent), path, true),
    };
    return try openCwd(disk, inode, owner);
}

fn mapSpawn(err: anyerror) std.process.SpawnError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SystemResources => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        error.AccessDenied => error.AccessDenied,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.SymLinkLoop => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

fn spawn(c: *Core, e: Core.Call, options: std.process.SpawnOptions, ret: usize) std.process.SpawnError!std.process.Child {
    if (std.process.Child.Id == void) return error.OperationUnsupported;
    const path = pathOf(options.exe, options.argv) orelse return error.InvalidExe;
    const program = c.processes.find(path) orelse return error.FileNotFound;
    const m = &c.processes;
    const parent = c.processOf();
    const environ = options.environ_map orelse if (parent) |p| &p.inherited else &m.environ;
    c.touch(Core.Object.pipes, true);
    const p = try m.make(program, e.node, options.argv, path, environ);
    c.touch(Core.Object.process(p.pid), true);
    errdefer {
        m.pipes.closeOwned(p.pid);
        if (c.disk(e.node)) |disk| disk.model.closeOwned(p.pid);
        m.reap(p);
    }
    const parent_owner = c.ownerOf();
    var parent_ends: [3]?Io.File = .{ null, null, null };
    errdefer for (parent_ends) |end| if (end) |f| m.pipes.close(f.handle);
    for ([_]std.process.SpawnOptions.StdIo{ options.stdin, options.stdout, options.stderr }, 0..) |which, i| {
        p.stdio[i] = switch (which) {
            .inherit => handed(m, translate(c, standardFile(i)), p.pid) catch |err| return mapSpawn(err),
            .file => |f| handed(m, translate(c, f), p.pid) catch |err| return mapSpawn(err),
            .ignore => .{ .file = pipeFile(try m.pipes.nullDevice(p.pid)), .owned = true },
            .close => .{ .file = Processes.closed_file, .owned = false, .open = false },
            .pipe => blk: {
                // The child reads its stdin's read end and writes the
                // write ends of its stdout and stderr.
                const child_reads = i == 0;
                const ends = try m.pipes.create(if (child_reads) p.pid else parent_owner, if (child_reads) parent_owner else p.pid);
                parent_ends[i] = pipeFile(if (child_reads) ends[1] else ends[0]);
                break :blk .{ .file = pipeFile(if (child_reads) ends[0] else ends[1]), .owned = true };
            },
        };
    }
    if (c.disk(e.node)) |disk| {
        p.cwd = resolveCwd(c, disk.model, options.cwd, p.pid) catch |err| return mapSpawn(err);
    }
    const context = try namespace(c, p);
    const t = c.spawn(.{ .program = p }, &.{}, .@"1", 0, .@"1", .ready) catch |err| return mapSpawn(err);
    t.node = e.node;
    t.process = p;
    t.io_context = context;
    t.spawned_at = ret;
    const id = Processes.encodePid(p.pid);
    return .{
        .id = id,
        .thread_handle = if (builtin.os.tag == .windows) id else {},
        .stdin = parent_ends[0],
        .stdout = parent_ends[1],
        .stderr = parent_ends[2],
        .request_resource_usage_statistics = options.request_resource_usage_statistics,
    };
}

/// A file handed to a child: a pipe end becomes the child's own copy, as an
/// inherited descriptor is, so the parent closing its end leaves the
/// child's open; any other stays the parent's.
fn handed(m: *Processes, file: Io.File, pid: u32) (Pipes.CreateError || Pipes.HandleError)!Processes.Stream {
    if (!Pipes.owns(file.handle)) return .{ .file = file, .owned = false };
    return .{ .file = pipeFile(try m.pipes.dup(file.handle, pid)), .owned = true };
}

const Namespace = struct { context: Core.Context, outer: ?Routing = null };

/// The process's Io namespace, kept as long as the simulation: a task's
/// last call may still name it once the process ended.
fn namespace(c: *Core, p: *Process) error{OutOfMemory}!*Core.Context {
    const n = try c.keep.allocator().create(Namespace);
    n.* = .{ .context = .{ .core = c, .node = p.node, .process = p } };
    if (c.fault_io) |f| {
        n.outer = Routing.init(f, .{ .context = &n.context });
        p.io = n.outer.?.io();
    } else p.io = .{ .userdata = &n.context, .vtable = c.vtable };
    return &n.context;
}

fn standardFile(i: usize) Io.File {
    return switch (i) {
        0 => Io.File.stdin(),
        1 => Io.File.stdout(),
        else => Io.File.stderr(),
    };
}

pub fn pipeFile(handle: Io.File.Handle) Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn spawnDigest(child: std.process.Child, argv: []const []const u8) u64 {
    var h: std.hash.Wyhash = .init(0x7370776e);
    const pid: u64 = Processes.decodePid(child.id.?) orelse 0;
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, pid)));
    for (argv) |arg| {
        h.update(arg);
        h.update(&.{0});
    }
    return h.final();
}

fn termDigest(term: Processes.Term) u64 {
    return switch (term) {
        .exited => |code| 0x100 | @as(u64, code),
        .signal, .stopped => 0x200,
        .unknown => |n| 0x300 ^ (@as(u64, n) << 12),
    };
}

/// Closes the parent's ends of a child's streams and forgets its id, as
/// `wait` and `kill` do.
fn cleanup(c: *Core, child: *std.process.Child) void {
    inline for (.{ "stdin", "stdout", "stderr" }) |field| {
        if (@field(child, field)) |f| {
            closeAny(c, f);
            @field(child, field) = null;
        }
    }
    child.id = null;
    if (builtin.os.tag == .windows) child.thread_handle = undefined;
}

fn processOfChild(c: *Core, child: *const std.process.Child) ?*Process {
    const pid = Processes.decodePid(child.id orelse return null) orelse return null;
    return c.processes.byPid(pid);
}

const slots = struct {
    pub fn processSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        if (e.task) |t| if (Core.cancelPoint(t)) {
            c.record(.processSpawn, e, digestOf(error.Canceled));
            return error.Canceled;
        };
        const child = spawn(c, e, options, @returnAddress()) catch |err| {
            c.record(.processSpawn, e, digestOf(err));
            return err;
        };
        c.record(.processSpawn, e, spawnDigest(child, options.argv));
        return child;
    }

    pub fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), false);
        const t = e.task orelse outside("Child.wait");
        if (Core.cancelPoint(t)) {
            c.record(.childWait, e, digestOf(error.Canceled));
            return error.Canceled;
        }
        const p = processOfChild(c, child) orelse {
            c.record(.childWait, e, digestOf(error.Unexpected));
            return error.Unexpected;
        };
        c.touch(Core.Object.process(p.pid), true);
        while (p.term == null) {
            if (c.block(t, .{ .process = p.pid }, true) == .canceled) {
                c.record(.childWait, e, digestOf(error.Canceled));
                return error.Canceled;
            }
        }
        const term = p.term.?;
        reapChild(c, child, p);
        c.record(.childWait, e, termDigest(term));
        return term;
    }

    pub fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        c.touch(Core.Object.pipes, true);
        if (processOfChild(c, child)) |p| {
            c.touch(Core.Object.process(p.pid), true);
            c.endProcess(p, Processes.killed());
            c.processes.reap(p);
        }
        cleanup(c, child);
        c.record(.childKill, e, 0);
    }

    pub fn processReplace(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const err = replace(c, e, options);
        c.record(.processReplace, e, digestOf(err));
        return err;
    }

    pub fn processCurrentPath(userdata: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const n = currentPath(c, buffer) catch |err| {
            c.record(.processCurrentPath, e, digestOf(err));
            return err;
        };
        c.record(.processCurrentPath, e, std.hash.Wyhash.hash(0, buffer[0..n]));
        return n;
    }

    pub fn processSetCurrentDir(userdata: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        setCurrent(c, .{ .dir = dir }) catch |err| {
            c.record(.processSetCurrentDir, e, digestOf(err));
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.NotDir => error.NotDir,
                error.AccessDenied => error.AccessDenied,
                error.NameTooLong => error.NameTooLong,
                error.BadPathName => error.BadPathName,
                else => error.Unexpected,
            };
        };
        c.record(.processSetCurrentDir, e, 0);
    }

    pub fn processSetCurrentPath(userdata: ?*anyopaque, path: []const u8) std.process.SetCurrentPathError!void {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        setCurrent(c, .{ .path = path }) catch |err| {
            c.record(.processSetCurrentPath, e, digestOf(err));
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.NotDir => error.NotDir,
                error.AccessDenied => error.AccessDenied,
                error.NameTooLong => error.NameTooLong,
                error.BadPathName => error.BadPathName,
                error.SymLinkLoop => error.SymLinkLoop,
                error.OutOfMemory => error.SystemResources,
                else => error.Unexpected,
            };
        };
        c.record(.processSetCurrentPath, e, std.hash.Wyhash.hash(0, path));
    }

    pub fn processExecutablePath(userdata: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
        const c = Core.of(userdata);
        const e = c.enter(@returnAddress(), true);
        const p = c.processOf() orelse {
            c.record(.processExecutablePath, e, digestOf(error.OperationUnsupported));
            return error.OperationUnsupported;
        };
        if (p.exe.len > buffer.len) {
            c.record(.processExecutablePath, e, digestOf(error.NameTooLong));
            return error.NameTooLong;
        }
        @memcpy(buffer[0..p.exe.len], p.exe);
        c.record(.processExecutablePath, e, std.hash.Wyhash.hash(0, p.exe));
        return p.exe.len;
    }
};

fn currentPath(c: *Core, buffer: []u8) std.process.CurrentPathError!usize {
    const disk = c.disk(c.nodeId()) orelse return error.Unexpected;
    const inode = cwdInode(disk.model, c.currentContext()) catch return error.CurrentDirUnlinked;
    return disk.model.realPath(inode, buffer) catch |err| switch (err) {
        error.NameTooLong => error.NameTooLong,
        error.FileNotFound => error.CurrentDirUnlinked,
        else => error.Unexpected,
    };
}

fn setCurrent(c: *Core, to: std.process.Child.Cwd) !void {
    const disk = (c.disk(c.nodeId()) orelse return error.FileNotFound).model;
    const ctx = c.currentContext() orelse &c.context;
    const dir = (try resolveCwd(c, disk, to, c.ownerOf())).?;
    const slot_ = if (ctx.process) |p| &p.cwd else &ctx.cwd;
    if (slot_.*) |old| disk.close(old.handle);
    slot_.* = dir;
}

/// `processReplace` from a simulated process: another program takes its
/// place under the same id and streams, on a fresh task, with a fresh heap;
/// every task the process had, the caller included, ends where it stands.
/// From the test's own process there is nothing to replace.
fn replace(c: *Core, e: Core.Call, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const p = c.processOf() orelse return error.OperationUnsupported;
    const t = e.task orelse return error.OperationUnsupported;
    const path = pathOf(options.exe, options.argv) orelse return error.InvalidExe;
    const program = c.processes.find(path) orelse return error.FileNotFound;
    // The new image is copied before the old one is let go: the arguments
    // may live in it.
    var image: std.heap.ArenaAllocator = .init(c.processes.gpa);
    var environ: std.process.Environ.Map = .init(c.processes.gpa);
    var adopted = false;
    defer if (!adopted) {
        environ.deinit();
        image.deinit();
    };
    environ.putAll(options.environ_map orelse &p.environ) catch return error.SystemResources;
    const old = p.image;
    p.image = image;
    Processes.setImage(p, options.argv, path) catch {
        image = p.image;
        p.image = old;
        return error.SystemResources;
    };
    const fresh = c.spawn(.{ .program = p }, &.{}, .@"1", 0, .@"1", .ready) catch {
        image = p.image;
        p.image = old;
        return error.SystemResources;
    };
    adopted = true;
    var old_image = old;
    old_image.deinit();
    p.environ.deinit();
    p.environ = environ;
    p.inherited.deinit();
    p.inherited = p.environ.clone(c.processes.gpa) catch .init(c.processes.gpa);
    p.program = program;
    p.heap.deinit();
    p.heap = .init(c.processes.gpa);
    _ = p.arena.reset(.free_all);
    fresh.node = p.node;
    fresh.process = p;
    fresh.io_context = t.io_context;
    fresh.spawned_at = t.spawned_at;
    for (c.tasks.items) |other| if (other.process == p and other != t and other != fresh) c.drop(other);
    c.record(.processReplace, e, 0);
    c.retire(t);
}

// Seams: what a package whose own calls start, signal and wait for
// processes (a terminal, a signal, a wait with a deadline) asks of the
// simulation in their place. Each is a step of the run, as an Io call is.

/// A pipe the calling process (or the test) owns: its read and write ends.
pub fn pipe(c: *Core, ret: usize) Pipes.CreateError![2]Io.File {
    const e = c.enter(ret, true);
    c.touch(Core.Object.pipes, true);
    const ends = c.processes.pipes.create(c.ownerOf(), c.ownerOf()) catch |err| {
        c.record(.foreign, e, digestOf(err));
        return err;
    };
    c.record(.foreign, e, std.hash.int(@as(u64, Pipes.id(ends[0]).?)));
    return .{ pipeFile(ends[0]), pipeFile(ends[1]) };
}

/// A terminal the calling process (or the test) owns.
pub fn terminal(c: *Core, size: Pipes.Size, ret: usize) Pipes.CreateError!Pipes.Terminal {
    const e = c.enter(ret, true);
    c.touch(Core.Object.pipes, true);
    const t = c.processes.pipes.terminal(c.ownerOf(), size) catch |err| {
        c.record(.foreign, e, digestOf(err));
        return err;
    };
    c.record(.foreign, e, std.hash.int(@as(u64, Pipes.id(t.master_read).?)));
    return t;
}

pub fn windowSize(c: *Core, file: Io.File, ret: usize) error{ BadHandle, NotTerminalDevice }!Pipes.Size {
    const e = c.enter(ret, true);
    c.touch(Core.Object.pipes, false);
    const size = c.processes.pipes.windowSize(translate(c, file).handle);
    c.record(.foreign, e, if (size) |s| (@as(u64, s.rows) << 16) | s.cols else |err| digestOf(err));
    return size;
}

pub fn setWindowSize(c: *Core, file: Io.File, size: Pipes.Size, ret: usize) error{ BadHandle, NotTerminalDevice }!void {
    const e = c.enter(ret, true);
    c.touch(Core.Object.pipes, true);
    const result = c.processes.pipes.setWindowSize(translate(c, file).handle, size);
    c.wakeIo();
    c.record(.foreign, e, if (result) |_| (@as(u64, size.rows) << 16) | size.cols else |err| digestOf(err));
    return result;
}

/// Ends a child as `term` at once, as a signal its program does not catch
/// does; a child that already ended is left as it ended. The child stays
/// to be waited for.
pub fn endChild(c: *Core, child: *const std.process.Child, term: Processes.Term, ret: usize) void {
    const e = c.enter(ret, true);
    c.touch(Core.Object.pipes, true);
    if (processOfChild(c, child)) |p| {
        c.touch(Core.Object.process(p.pid), true);
        c.endProcess(p, term);
    }
    c.record(.childKill, e, termDigest(term));
}

/// How a child ended, reaping it, or null while it runs: a wait that does
/// not wait.
pub fn poll(c: *Core, child: *std.process.Child, ret: usize) std.process.Child.WaitError!?Processes.Term {
    const e = c.enter(ret, true);
    const p = processOfChild(c, child) orelse {
        c.record(.childWait, e, digestOf(error.Unexpected));
        return error.Unexpected;
    };
    c.touch(Core.Object.process(p.pid), true);
    const term = p.term orelse {
        c.record(.childWait, e, 0);
        return null;
    };
    reapChild(c, child, p);
    c.record(.childWait, e, termDigest(term));
    return term;
}

/// `Child.wait` until `timeout`: how the child ended, reaping it, or null
/// once the time is up and it still runs.
pub fn waitFor(c: *Core, child: *std.process.Child, timeout: Io.Timeout, ret: usize) std.process.Child.WaitError!?Processes.Term {
    const e = c.enter(ret, false);
    const t = e.task orelse outside("Child.wait");
    if (Core.cancelPoint(t)) {
        c.record(.childWait, e, digestOf(error.Canceled));
        return error.Canceled;
    }
    const p = processOfChild(c, child) orelse {
        c.record(.childWait, e, digestOf(error.Unexpected));
        return error.Unexpected;
    };
    c.touch(Core.Object.process(p.pid), true);
    const deadline = c.deadline(timeout);
    while (p.term == null) {
        switch (deadline) {
            .due => break,
            .at => |at| c.arm(t, at.clock, at.ns),
            .never => {},
        }
        switch (c.block(t, .{ .process = p.pid }, true)) {
            .canceled => {
                c.record(.childWait, e, digestOf(error.Canceled));
                return error.Canceled;
            },
            .timeout => break,
            else => {},
        }
    }
    const term = p.term orelse {
        c.record(.childWait, e, 0);
        return null;
    };
    reapChild(c, child, p);
    c.record(.childWait, e, termDigest(term));
    return term;
}

/// What `wait` does once the child has ended: its streams closed, its id
/// forgotten, the process gone.
fn reapChild(c: *Core, child: *std.process.Child, p: *Process) void {
    cleanup(c, child);
    c.processes.reap(p);
}
