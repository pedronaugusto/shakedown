//! The programs a simulation runs as processes, for code that starts
//! programs through `std.process`: `spawn`, `run`, `Child.wait`, `kill`
//! and `replace` reach the programs registered here, and nothing else.
//!
//! A program is a `main`, written as `std.start` calls one: no parameters,
//! `std.process.Init.Minimal` or `std.process.Init`, returning `void`,
//! `u8` or an error union of those. A real program's `main`
//! registers unchanged, and reads its arguments, environment, standard
//! streams and working directory from the simulation; its `Init.io` is the
//! simulation, its `Init.gpa` and `Init.arena` are given back when it ends.
//! A program that returns an error writes `error: <name>` to its standard
//! error and exits with 1, as `std.start` has it do.
//!
//! What a simulated process cannot do is what does not go through `Io`:
//! `std.process.exit`, `fatal` and `abort` end the real process, the test
//! with it; `std.debug.print` and `std.log` write to the real standard
//! error. A program must return from `main`.
const std = @import("std");
const Io = std.Io;
const Core = @import("Core.zig");
const Processes = @import("programs/Model.zig");
const Pipes = @import("programs/Pipes.zig");
const calls = @import("programs/calls.zig");
const Programs = @This();

pub const Options = Processes.Options;
pub const Variable = Processes.Variable;
/// How a process ended, as `Child.wait` reports it.
pub const Term = Processes.Term;

/// Private: the simulation's process model.
core: *Core,

/// Registers `main` under `name`: a spawn whose path is `name`, or ends in
/// it when `name` has no separator, runs it. `context` is a tuple of the
/// arguments `main` takes before its `Init`, if any, copied here: a fake
/// program reaches the test's state through it. A later registration of a
/// name replaces the earlier one.
pub fn register(p: *Programs, name: []const u8, comptime main: anytype, context: anytype) error{OutOfMemory}!void {
    const Context = @TypeOf(context);
    const Entry = EntryOf(main, Context);
    if (@alignOf(Context) > Processes.context_align) @compileError("a program's context is aligned past " ++ std.fmt.comptimePrint("{d}", .{Processes.context_align}) ++ " bytes");
    try p.core.processes.register(name, Entry.entry, std.mem.asBytes(&context));
}

fn EntryOf(comptime main: anytype, comptime Context: type) type {
    const info = @typeInfo(@TypeOf(main)).@"fn";
    const given = @typeInfo(Context).@"struct".field_names.len;
    const takes = info.param_types.len;
    if (takes != given and takes != given + 1) @compileError("a program's main takes its context's fields, then at most an Init");
    if (info.return_type.? == noreturn) @compileError("a simulated program returns from main: std.process.exit would end the test");
    const Last = if (takes == given + 1) info.param_types[takes - 1].? else void;
    if (Last != void and Last != std.process.Init and Last != std.process.Init.Minimal)
        @compileError("a program's main takes std.process.Init or std.process.Init.Minimal after its context, not " ++ @typeName(Last));
    return struct {
        fn entry(raw: *const anyopaque, init: std.process.Init) u8 {
            const context: *const Context = @ptrCast(@alignCast(raw)); // safe: registered with this context's bytes, aligned for it
            const result = if (Last == std.process.Init)
                @call(.auto, main, context.* ++ .{init})
            else if (Last == std.process.Init.Minimal)
                @call(.auto, main, context.* ++ .{init.minimal})
            else
                @call(.auto, main, context.*);
            return exitCode(result, init);
        }
    };
}

/// What `std.start` makes of what `main` returned.
fn exitCode(result: anytype, init: std.process.Init) u8 {
    const R = @TypeOf(result);
    switch (R) {
        void => return 0,
        u8 => return result,
        else => {},
    }
    if (@typeInfo(R) != .error_union) @compileError("a program's main returns void, u8 or an error union of those, not " ++ @typeName(R));
    const value = result catch |err| {
        var buffer: [128]u8 = undefined;
        const line = std.mem.print(&buffer, "error: {t}\n", .{err}) catch "error\n";
        // glint-ignore: Z026 -- a program's failing report has nowhere to go when its stderr is gone, as in a real process
        std.Io.File.stderr().writeStreamingAll(init.io, line) catch {};
        return 1;
    };
    return switch (@TypeOf(value)) {
        void => 0,
        u8 => value,
        else => @compileError("a program's main returns void, u8 or an error union of those"),
    };
}

// Seams. A package whose own calls start, signal and wait for processes
// past `std.process` (a terminal, a signal, a wait with a deadline) makes
// them here when it is handed a simulation: `Sim.programsOf` finds this
// from its `Io`. Each is a step of the run.

/// A terminal's window, in character cells.
pub const Size = Pipes.Size;

/// A terminal: what its master writes its slave reads, and the other way,
/// and the slave's ends are a terminal to a program (`File.isTty`). Every
/// end is the caller's, closed with `File.close`; a child is handed the
/// slave's as its streams (`StdIo.file`) and keeps its own copies.
pub const Terminal = struct {
    master_read: Io.File,
    master_write: Io.File,
    slave_read: Io.File,
    slave_write: Io.File,
};

/// A pipe the caller owns: its read end and its write end.
pub fn pipe(p: Programs) Pipes.CreateError![2]Io.File {
    return calls.pipe(p.core, @returnAddress());
}

/// A new terminal of window `size`, the caller's.
pub fn terminal(p: Programs, size: Size) Pipes.CreateError!Terminal {
    const t = try calls.terminal(p.core, size, @returnAddress());
    return .{
        .master_read = calls.pipeFile(t.master_read),
        .master_write = calls.pipeFile(t.master_write),
        .slave_read = calls.pipeFile(t.slave_read),
        .slave_write = calls.pipeFile(t.slave_write),
    };
}

/// The window of the terminal `file` is an end of.
pub fn windowSize(p: Programs, file: Io.File) error{ BadHandle, NotTerminalDevice }!Size {
    return calls.windowSize(p.core, file, @returnAddress());
}

pub fn setWindowSize(p: Programs, file: Io.File, size: Size) error{ BadHandle, NotTerminalDevice }!void {
    return calls.setWindowSize(p.core, file, size, @returnAddress());
}

/// Ends `child` as `term` at once, as a signal its program does not catch
/// does; it stays to be waited for.
pub fn end(p: Programs, child: *const std.process.Child, term: Term) void {
    calls.endChild(p.core, child, term, @returnAddress());
}

/// How `child` ended, reaping it, or null while it runs.
pub fn poll(p: Programs, child: *std.process.Child) std.process.Child.WaitError!?Term {
    return calls.poll(p.core, child, @returnAddress());
}

/// `Child.wait` until `timeout`: how `child` ended, reaping it, or null
/// once the time is up.
pub fn waitFor(p: Programs, child: *std.process.Child, timeout: Io.Timeout) std.process.Child.WaitError!?Term {
    return calls.waitFor(p.core, child, timeout, @returnAddress());
}
