//! Continuous fuzzing, off the landing path: a package's `check` properties
//! under Zig's fuzzer for as long as it is given, its corpora kept outside
//! the package, every failure shrunk to a tape and written down as the
//! regression to commit.
//!
//!     shakedown-fuzz --package ../relic --store ~/fuzz --limit 50M --sessions 4
//!
//! `--build-arg` (repeated) gives each session's build an argument of the package's build,
//! as preflight's fuzz steps give theirs `-Dci-fuzzing=true`, which builds the fuzzed tests the
//! way Zig's fuzzer reads their coverage.
//!
//! Each session runs `zig build <step> --fuzz=<limit>` in the package (the
//! step `test` unless `--step` names one whose every test binary has a
//! property, since the fuzzer refuses a binary with none) with
//! `<store>/<package>/cache` as its cache, which holds the fuzzer's corpora
//! from session to session. A property that fails prints its tape; the
//! runner replays it (`SHAKEDOWN_TAPE`, which `check` shrinks) and writes
//! `<store>/<package>/findings/<test>.txt`: the test, the error, the tape the
//! fuzzer found and the minimal one, for the property's `.regressions`.
const std = @import("std");
const Io = std.Io;
const findings = @import("fuzz_findings");

const Options = struct {
    package: []const u8 = ".",
    store: ?[]const u8 = null,
    limit: []const u8 = "10M",
    filter: ?[]const u8 = null,
    step: []const u8 = "test",
    sessions: u32 = 1,
    zig: []const u8 = "zig",
    /// bay, for a package developed with it: the step is then its development build's.
    bay: ?[]const u8 = null,
    /// Arguments every build of the step is given (`--build-arg`, repeated): the package's
    /// build options, as `-Dci-fuzzing=true`.
    build_args: []const []const u8 = &.{},

    /// The command that builds the package's step: `bay dev`, or `zig build`.
    fn build(o: Options, a: std.mem.Allocator) ![]const []const u8 {
        return if (o.bay) |bay| a.dupe([]const u8, &.{ bay, "dev" }) else a.dupe([]const u8, &.{ o.zig, "build" });
    }
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const options = parse(a, try init.minimal.args.toSlice(a)) catch {
        try say(io, "usage: shakedown-fuzz [--package dir] [--store dir] [--limit 10M] [--step test] [--filter test] [--sessions n] [--zig path] [--bay path] [--build-arg arg]...\n", .{});
        return 2;
    };
    const package = try Io.Dir.cwd().realPathFileAlloc(io, options.package, a);
    const name = std.fs.path.basename(package);
    const store_root = options.store orelse try std.fs.path.join(a, &.{ init.environ_map.get("HOME") orelse "/tmp", "shakedown-fuzz" });
    const store = try std.fs.path.join(a, &.{ store_root, name });
    const cache = try std.fs.path.join(a, &.{ store, "cache" });
    const found_dir = try std.fs.path.join(a, &.{ store, "findings" });
    try Io.Dir.cwd().createDirPath(io, found_dir);

    var total: usize = 0;
    for (0..options.sessions) |session| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, try options.build(a));
        try argv.appendSlice(a, &.{ options.step, try a.print("--fuzz={s}", .{options.limit}), "--cache-dir", cache });
        try argv.appendSlice(a, options.build_args);
        if (options.filter) |f| try argv.append(a, try a.print("-Dtest-filter={s}", .{f}));
        try say(io, "shakedown-fuzz: {s}, session {d} of {d}\n", .{ name, session + 1, options.sessions });
        try Io.Dir.cwd().createDirPath(io, cache);
        var cache_dir = try Io.Dir.cwd().openDir(io, cache, .{});
        defer cache_dir.close(io);
        const before = try findings.Cache.read(io, cache_dir);
        const result = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = package } });
        const output = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr });
        const failures = try findings.parse(a, output);
        for (failures) |f| {
            const minimal = try shrink(a, io, init.environ_map, options, package, cache, f);
            try record(a, io, found_dir, f, minimal);
            try say(io, "shakedown-fuzz: {s} found error.{s}; minimal tape {s}\n", .{ f.filter, f.err, minimal });
            total += 1;
        }
        // Zig exits 0 from a bounded session whose fuzzer crashed or never started.
        const after = try findings.Cache.read(io, cache_dir);
        const ran = findings.judge(before, after);
        if (failures.len == 0 and (!result.term.success() or ran == .crashed)) {
            // A property that panics ends its process before `check` can print a tape: the
            // input the fuzzer saved is the finding, kept with the panic's message, since the
            // next session's crash would overwrite it.
            if (findings.crash(output)) |c| {
                const path = try keepCrash(a, io, init.environ_map, options, package, cache, found_dir, c);
                try say(io, "shakedown-fuzz: {s} {s}: {s}; its input and message are in {s}\n", .{ c.filter, c.term, c.message orelse "no panic message printed", path });
                total += 1;
                break;
            }
            if (after.uninstrumented > 0) {
                try say(io, "shakedown-fuzz: the session's test binary lists no instrumented code ({d} coverage file(s) in {s}/v with pcs_len 0), which Zig's fuzzer cannot fuzz: the build compiled it without the fuzzer's instrumentation, as the self-hosted x86_64 backend does. Build the fuzzed tests with LLVM: pass the package's option for it with --build-arg (preflight's fuzz steps give -Dci-fuzzing=true since 42a0de4).\n{s}\n", .{ after.uninstrumented, cache, tail(output) });
                return 1;
            }
            try say(io, "shakedown-fuzz: the session failed with nothing check reported:\n{s}\n...\n{s}\n", .{ try notable(a, output), tail(output) });
            return 1;
        }
        if (ran == .idle) {
            try say(io, "shakedown-fuzz: the session ran no input:\n{s}\n", .{tail(output)});
            return 1;
        }
    }
    try say(io, "shakedown-fuzz: {s}: {d} finding(s) in {s}\n", .{ name, total, found_dir });
    return if (total == 0) 0 else 1;
}

fn parse(a: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var build_args: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (i + 1 >= args.len) return error.Usage;
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "--package")) {
            o.package = value;
        } else if (std.mem.eql(u8, arg, "--store")) {
            o.store = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            o.limit = value;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            o.filter = value;
        } else if (std.mem.eql(u8, arg, "--step")) {
            o.step = value;
        } else if (std.mem.eql(u8, arg, "--sessions")) {
            o.sessions = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--zig")) {
            o.zig = value;
        } else if (std.mem.eql(u8, arg, "--bay")) {
            o.bay = value;
        } else if (std.mem.eql(u8, arg, "--build-arg")) {
            try build_args.append(a, value);
        } else return error.Usage;
        i += 1;
    }
    o.build_args = build_args.items;
    return o;
}

test "each --build-arg reaches the step's build, in order; an unknown flag is a usage error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try parse(a, &.{ "shakedown-fuzz", "--step", "wire", "--build-arg", "-Dci-fuzzing=true", "--limit", "1K", "--build-arg", "-Dsuite=full" });
    try std.testing.expectEqualStrings("wire", o.step);
    try std.testing.expectEqualStrings("1K", o.limit);
    try std.testing.expectEqual(@as(usize, 2), o.build_args.len);
    try std.testing.expectEqualStrings("-Dci-fuzzing=true", o.build_args[0]);
    try std.testing.expectEqualStrings("-Dsuite=full", o.build_args[1]);
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, &.{"shakedown-fuzz"})).build_args.len);
    try std.testing.expectError(error.Usage, parse(a, &.{ "shakedown-fuzz", "--fuzz-arg", "x" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "shakedown-fuzz", "--build-arg" }));
}

/// The finding's test replayed on its tape, which `check` shrinks: the
/// minimal tape it reports, or the found one when it reports none.
fn shrink(a: std.mem.Allocator, io: Io, parent: *const std.process.Environ.Map, o: Options, package: []const u8, cache: []const u8, f: findings.Finding) ![]const u8 {
    const output = (try replay(a, io, parent, o, package, cache, f.filter, f.tape)).output;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "tape: ")) return trimmed["tape: ".len..];
    }
    return f.tape;
}

/// The test `filter` run once outside the fuzzer on `tape` (`SHAKEDOWN_TAPE`): its output,
/// and whether it failed.
fn replay(a: std.mem.Allocator, io: Io, parent: *const std.process.Environ.Map, o: Options, package: []const u8, cache: []const u8, filter: []const u8, tape: []const u8) !struct { output: []const u8, failed: bool } {
    var environ = try parent.clone(a);
    try environ.put("SHAKEDOWN_TAPE", tape);
    const result = try std.process.run(a, io, .{
        .argv = try std.mem.concat(a, []const u8, &.{ try o.build(a), &.{ o.step, try a.print("-Dtest-filter={s}", .{filter}), "--cache-dir", cache }, o.build_args }),
        .cwd = .{ .path = package },
        .environ_map = &environ,
    });
    return .{ .output = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr }), .failed = !result.term.success() };
}

/// The most of a crash's input a finding writes out, as hex.
const kept_input_most = 64 * 1024;

/// Writes the finding of a test the session ended (`c`): its message, the input the fuzzer
/// saved (`<cache>/f/crash`), as hex and as the tape that replays it, and whether a replay of
/// that tape outside the fuzzer ends the same way. Its first lines are the ones `record`
/// writes, which preflight's fuzz step reads; a crash is not shrunk, since it ends the process
/// that would shrink it. Returns the finding's path.
fn keepCrash(a: std.mem.Allocator, io: Io, parent: *const std.process.Environ.Map, o: Options, package: []const u8, cache: []const u8, dir: []const u8, c: findings.Crash) ![]const u8 {
    const saved_path = try std.fs.path.join(a, &.{ cache, "f", "crash" });
    const input: ?[]const u8 = if (!c.saved) null else Io.Dir.cwd().readFileAlloc(io, saved_path, a, .unlimited) catch |err| input: {
        try say(io, "shakedown-fuzz: the input Zig saved at {s} cannot be read: {t}\n", .{ saved_path, err });
        break :input null;
    };
    const tape: ?[]const u8 = if (input) |bytes| try findings.tapeText(a, bytes) else null;
    var message = c.message;
    var again: []const u8 = "not replayed: Zig saved no input";
    if (tape) |t| {
        const replayed = try replay(a, io, parent, o, package, cache, c.filter, t);
        if (message == null) message = findings.panicMessage(replayed.output);
        again = if (!replayed.failed) "passes: the crash did not repeat outside the fuzzer" else if (findings.crash(replayed.output)) |r| try a.print("{s} again", .{r.term}) else "fails again";
    }
    const shown = try printable(a, message orelse "no panic message printed");
    const found = tape orelse "none: Zig saved no input";
    var text: std.ArrayList(u8) = .empty;
    try text.print(a,
        \\test: {s}
        \\error: crash, {s}: {s}
        \\found: {s}
        \\minimal: {s}
        \\keep it: add "{s}" to the property's `.regressions` (a crash is not shrunk: it ends the process that would shrink it)
        \\replay: SHAKEDOWN_TAPE="{s}" with -Dtest-filter, outside the fuzzer: {s}
        \\
    , .{ c.filter, c.term, shown, found, found, found, found, again });
    if (input) |bytes| {
        // The process ended before its property drew anything (riverrun's crash): the tape
        // above is empty, which replays it as the empty input, every draw its least.
        if (bytes.len == 0) try text.appendSlice(a, "input: 0 bytes, the empty input: the empty tape \"\" replays it\n");
        const kept = bytes[0..@min(bytes.len, kept_input_most)];
        if (kept.len > 0) {
            try text.print(a, "input: {d} bytes{s}, as the fuzzer saved them: {x}\n", .{ bytes.len, if (kept.len < bytes.len) " (the first 64 KiB)" else "", kept });
        }
    }
    const path = try findingPath(a, dir, c.filter);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
    return path;
}

/// `text` on one line of plain bytes, at most 512 of them: a panic's message is the
/// program's, and a finding's lines hold no control bytes.
fn printable(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try a.dupe(u8, text[0..@min(text.len, 512)]);
    for (out) |*c| if (c.* < 32 or c.* == 127) {
        c.* = '?';
    };
    return out;
}

/// The lines of a session's output that say what went wrong (panics and errors), which the
/// output's tail can have cut off behind a long stack trace: at most 40.
fn notable(a: std.mem.Allocator, output: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var kept: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const telling = std.mem.startsWith(u8, line, "error:") or std.mem.find(u8, line, "panic: ") != null;
        if (!telling) continue;
        try out.appendSlice(a, line);
        try out.append(a, '\n');
        kept += 1;
        if (kept == 40) break;
    }
    return out.items;
}

test "the lines that tell a session's failure are kept ahead of its tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = "info: fork\nthread 7 panic: integer overflow\n  frame\nerror: test 'a.test.b' terminated with signal ABRT\nfailed command: x\n";
    try std.testing.expectEqualStrings("thread 7 panic: integer overflow\nerror: test 'a.test.b' terminated with signal ABRT\n", try notable(arena.allocator(), output));
    try std.testing.expectEqualStrings("tab ? and bell ?", try printable(arena.allocator(), "tab \t and bell \x07"));
}

fn findingPath(a: std.mem.Allocator, dir: []const u8, filter: []const u8) ![]const u8 {
    const file_name = try a.alloc(u8, filter.len);
    for (file_name, filter) |*to, c| to.* = if (std.ascii.isAlphanumeric(c)) c else '-';
    return a.print("{s}/{s}.txt", .{ dir, file_name });
}

fn record(a: std.mem.Allocator, io: Io, dir: []const u8, f: findings.Finding, minimal: []const u8) !void {
    const path = try findingPath(a, dir, f.filter);
    const text = try a.print(
        \\test: {s}
        \\error: {s}
        \\found: {s}
        \\minimal: {s}
        \\keep it: add "{s}" to the property's `.regressions`
        \\
    , .{ f.filter, f.err, f.tape, minimal, minimal });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn tail(output: []const u8) []const u8 {
    return output[output.len -| 4000..];
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buffer);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
