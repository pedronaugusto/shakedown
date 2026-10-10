//! Continuous fuzzing, off the landing path: a package's `check` properties
//! under Zig's fuzzer for as long as it is given, its corpora kept outside
//! the package, every failure shrunk to a tape and written down as the
//! regression to commit.
//!
//!     shakedown-fuzz --package ../relic --store ~/fuzz --limit 50M --sessions 4
//!
//! Each session runs `zig build test --fuzz=<limit>` in the package with
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
    sessions: u32 = 1,
    zig: []const u8 = "zig",
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const options = parse(try init.minimal.args.toSlice(a)) catch {
        try say(io, "usage: shakedown-fuzz [--package dir] [--store dir] [--limit 10M] [--filter test] [--sessions n] [--zig path]\n", .{});
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
        try argv.appendSlice(a, &.{ options.zig, "build", "test", try a.print("--fuzz={s}", .{options.limit}), "--cache-dir", cache });
        if (options.filter) |f| try argv.append(a, try a.print("-Dtest-filter={s}", .{f}));
        try say(io, "shakedown-fuzz: {s}, session {d} of {d}\n", .{ name, session + 1, options.sessions });
        const result = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = package } });
        const output = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr });
        const failures = try findings.parse(a, output);
        for (failures) |f| {
            const minimal = try shrink(a, io, init.environ_map, options, package, cache, f);
            try record(a, io, found_dir, f, minimal);
            try say(io, "shakedown-fuzz: {s} found error.{s}; minimal tape {s}\n", .{ f.filter, f.err, minimal });
            total += 1;
        }
        if (failures.len == 0 and !result.term.success()) {
            try say(io, "shakedown-fuzz: the session failed with nothing check reported:\n{s}\n", .{tail(output)});
            return 1;
        }
    }
    try say(io, "shakedown-fuzz: {s}: {d} finding(s) in {s}\n", .{ name, total, found_dir });
    return if (total == 0) 0 else 1;
}

fn parse(args: []const [:0]const u8) !Options {
    var o: Options = .{};
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
        } else if (std.mem.eql(u8, arg, "--sessions")) {
            o.sessions = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--zig")) {
            o.zig = value;
        } else return error.Usage;
        i += 1;
    }
    return o;
}

/// The finding's test replayed on its tape, which `check` shrinks: the
/// minimal tape it reports, or the found one when it reports none.
fn shrink(a: std.mem.Allocator, io: Io, parent: *const std.process.Environ.Map, o: Options, package: []const u8, cache: []const u8, f: findings.Finding) ![]const u8 {
    var environ = try parent.clone(a);
    try environ.put("SHAKEDOWN_TAPE", f.tape);
    const result = try std.process.run(a, io, .{
        .argv = &.{ o.zig, "build", "test", try a.print("-Dtest-filter={s}", .{f.filter}), "--cache-dir", cache },
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
