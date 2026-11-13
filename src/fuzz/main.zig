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
        const ran = findings.judge(before, try findings.Cache.read(io, cache_dir));
        if (failures.len == 0 and (!result.term.success() or ran == .crashed)) {
            try say(io, "shakedown-fuzz: the session failed with nothing check reported:\n{s}\n", .{tail(output)});
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
    var environ = try parent.clone(a);
    try environ.put("SHAKEDOWN_TAPE", f.tape);
    const result = try std.process.run(a, io, .{
        .argv = try std.mem.concat(a, []const u8, &.{ try o.build(a), &.{ o.step, try a.print("-Dtest-filter={s}", .{f.filter}), "--cache-dir", cache }, o.build_args }),
        .cwd = .{ .path = package },
        .environ_map = &environ,
    });
    const output = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr });
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "tape: ")) return trimmed["tape: ".len..];
    }
    return f.tape;
}

fn record(a: std.mem.Allocator, io: Io, dir: []const u8, f: findings.Finding, minimal: []const u8) !void {
    const file_name = try a.alloc(u8, f.filter.len);
    for (file_name, f.filter) |*to, c| to.* = if (std.ascii.isAlphanumeric(c)) c else '-';
    const path = try a.print("{s}/{s}.txt", .{ dir, file_name });
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
