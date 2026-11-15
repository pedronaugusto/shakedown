//! What a fuzzing session found: each property the fuzzer failed, with the
//! tape `check` printed for it, read from the lines `check` and the test
//! runner write; and whether the session crashed or ran nothing, read from
//! the cache it ran on, since Zig exits 0 from a bounded session either way.
const std = @import("std");

pub const Finding = struct {
    /// The test's name as `-Dtest-filter` selects it (the runner's name
    /// without its module prefix).
    filter: []const u8,
    /// The error the property returned.
    err: []const u8,
    /// The tape that replays it (`SHAKEDOWN_TAPE`).
    tape: []const u8,
};

/// The findings in `output`, borrowing from it. A failed test whose output
/// holds no tape (one written without `check`) is not a finding of ours.
pub fn parse(gpa: std.mem.Allocator, output: []const u8) error{OutOfMemory}![]Finding {
    var found: std.ArrayList(Finding) = .empty;
    errdefer found.deinit(gpa);
    var pending: ?struct { err: []const u8, tape: []const u8 } = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const lead = "shakedown: the fuzzer found error.";
        if (std.mem.startsWith(u8, line, lead)) {
            const rest = line[lead.len..];
            const semi = std.mem.findScalar(u8, rest, ';') orelse continue;
            const eq = std.mem.findLast(u8, rest, "SHAKEDOWN_TAPE=") orelse continue;
            pending = .{ .err = rest[0..semi], .tape = rest[eq + "SHAKEDOWN_TAPE=".len ..] };
            continue;
        }
        const test_lead = "error: test '";
        if (std.mem.startsWith(u8, line, test_lead)) {
            const p = pending orelse continue;
            const rest = line[test_lead.len..];
            const close = std.mem.findScalar(u8, rest, '\'') orelse continue;
            const name = rest[0..close];
            const marker = ".test.";
            const filter = if (std.mem.find(u8, name, marker)) |at| name[at + marker.len ..] else name;
            try found.append(gpa, .{ .filter = filter, .err = p.err, .tape = p.tape });
            pending = null;
        }
    }
    return found.toOwnedSlice(gpa);
}

test "a fuzzer's failure reads back as its test, its error and its tape" {
    const output =
        \\Fuzz test: "t.test.check fuzz" (8a52a62fcdc4fec)
        \\shakedown: the fuzzer found error.Found; shrink it with SHAKEDOWN_TAPE=309
        \\failed with error.Found
        \\error: test 't.test.check fuzz' exited with code 1; input saved to '.zig-cache/f/crash'
        \\error: test 'other.test.not ours' exited with code 1
    ;
    const found = try parse(std.testing.allocator, output);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("check fuzz", found[0].filter);
    try std.testing.expectEqualStrings("Found", found[0].err);
    try std.testing.expectEqualStrings("309", found[0].tape);
}

/// A test the session ended with no property's report: a panic, a signal or
/// an exit, as the build runner prints it, fuzzing (`error: test '<name>'
/// terminated with signal ABRT; input saved to '<cache>/f/crash'`) or not
/// (`error: '<name>' terminated with signal ABRT with stderr:`), with the
/// message of the panic the output holds. Borrows from the output.
pub const Crash = struct {
    /// The test's name as `-Dtest-filter` selects it.
    filter: []const u8,
    /// How it ended: `terminated with signal ABRT`, `exited with code 1`.
    term: []const u8,
    /// Whether Zig's fuzzer saved the input it was running (`f/crash`).
    saved: bool,
    /// What the panic said, when the output holds a panic.
    message: ?[]const u8,
    /// The tape the case had drawn when it ended the process, as `check` prints
    /// it on the way out (`crash_lead`): what replays the crash, where the
    /// fuzzer's saved input need not be.
    tape: ?[]const u8 = null,
    /// The panic's message and the stack printed under it, when the output holds them.
    stack: ?[]const u8 = null,
};

/// The line `check` writes when a case ends its process (shakedown's `crash.lead`).
pub const crash_lead = "shakedown: a case ended the process; SHAKEDOWN_TAPE=";

/// The tape of the last case `output` says ended the process.
pub fn crashTape(output: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, crash_lead)) found = line[crash_lead.len..];
    }
    return found;
}

/// The most of a panic's stack a finding keeps.
pub const stack_most = 16 * 1024;

/// The first panic's line and the stack printed under it, up to the next line
/// that is not the panic's (the tape `check` printed, the build runner's account
/// of the ending) and at most `stack_most` bytes.
pub fn panicStack(output: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var at: usize = 0;
    while (at < output.len) {
        const end = std.mem.findScalarPos(u8, output, at, '\n') orelse output.len;
        const line = std.mem.trim(u8, output[at..end], " \r\t");
        if (start) |from| {
            const ends = std.mem.startsWith(u8, line, crash_lead) or std.mem.startsWith(u8, line, "error: ") or
                std.mem.startsWith(u8, line, "failed command:");
            if (ends) return output[from..@min(at, from + stack_most)];
        } else if (panicMessage(line) != null) start = at;
        at = end + 1;
    }
    const from = start orelse return null;
    return output[from..@min(output.len, from + stack_most)];
}

/// The first test `output` names as ended, if any.
pub fn crash(output: []const u8) ?Crash {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const rest = for ([_][]const u8{ "error: test '", "error: '" }) |lead| {
            if (std.mem.startsWith(u8, line, lead)) break line[lead.len..];
        } else continue;
        // The name ends where the build runner's account of the ending begins.
        var end: ?usize = null;
        for ([_][]const u8{ "' exited with ", "' terminated ", "' stopped with " }) |verb| {
            const at = std.mem.find(u8, rest, verb) orelse continue;
            if (end == null or at < end.?) end = at;
        }
        const close = end orelse continue;
        const name = rest[0..close];
        const after = rest[close + 2 ..];
        const semi = std.mem.findScalar(u8, after, ';');
        const marker = ".test.";
        return .{
            .filter = if (std.mem.find(u8, name, marker)) |at| name[at + marker.len ..] else name,
            .term = withoutSuffix(if (semi) |s| after[0..s] else after, " with stderr:"),
            .saved = semi != null and std.mem.find(u8, after[semi.?..], "input saved to") != null,
            .message = panicMessage(output),
            .tape = crashTape(output),
            .stack = panicStack(output),
        };
    }
    return null;
}

fn withoutSuffix(text: []const u8, suffix: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, text, suffix)) text[0 .. text.len - suffix.len] else text;
}

/// The message of the first panic `output` holds: `panic: <message>` or
/// `thread <id> panic: <message>`, as `std.debug` prints it.
pub fn panicMessage(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const lead = "panic: ";
        if (std.mem.startsWith(u8, line, lead)) return line[lead.len..];
        if (!std.mem.startsWith(u8, line, "thread ")) continue;
        const at = std.mem.find(u8, line, " " ++ lead) orelse continue;
        const id = line["thread ".len..at];
        const numbered = id.len > 0 and for (id) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true;
        if (numbered) return line[at + 1 + lead.len ..];
    }
    return null;
}

/// The tape `check` replays an input the fuzzer saved as: each 8 little-endian
/// bytes one choice, as `corpus.fromTape` writes them (a `check` property draws
/// nothing else). Bytes past the last whole choice are dropped; the empty input
/// is the empty tape, every draw its least. Owned by the caller.
pub fn tapeText(gpa: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var i: usize = 0;
    while (i + 8 <= input.len) : (i += 8) {
        if (i > 0) out.writer.writeByte(':') catch return error.OutOfMemory;
        out.writer.print("{x}", .{std.mem.readInt(u64, input[i..][0..8], .little)}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

test "a test the session ended reads back as its name, its ending, its saved input and its panic" {
    const output =
        \\info: fork matched 1 shakedown packages
        \\thread 4242 panic: index out of bounds: index 3, len 2
        \\src/tools/whole_test.zig:347:24: 0x1045f4fbf in test.any text (riverrun-tools-tests)
        \\error: test 'tools.whole_test.test.any text, or diagnostics; never a crash' terminated with signal ABRT; input saved to '/s/cache/f/crash'
        \\failed command: riverrun-tools-tests --listen=-
    ;
    const c = crash(output).?;
    try std.testing.expectEqualStrings("any text, or diagnostics; never a crash", c.filter);
    try std.testing.expectEqualStrings("terminated with signal ABRT", c.term);
    try std.testing.expect(c.saved);
    try std.testing.expectEqualStrings("index out of bounds: index 3, len 2", c.message.?);

    const unsaved = crash("panic: reached unreachable code\nerror: test 'm.test.t' exited with code 3\n").?;
    try std.testing.expectEqualStrings("t", unsaved.filter);
    try std.testing.expectEqualStrings("exited with code 3", unsaved.term);
    try std.testing.expect(!unsaved.saved);
    try std.testing.expectEqualStrings("reached unreachable code", unsaved.message.?);

    // A test that crashed outside the fuzzer, as a replay's does.
    const replayed = crash("error: 'm.test.t' terminated with signal ABRT with stderr:\n       thread 1 panic: past 40000\n").?;
    try std.testing.expectEqualStrings("t", replayed.filter);
    try std.testing.expectEqualStrings("terminated with signal ABRT", replayed.term);
    try std.testing.expect(!replayed.saved);
    try std.testing.expectEqualStrings("past 40000", replayed.message.?);

    // Under Zig's fuzzer the saved input can be empty while the case drew (riverrun's
    // proof property): the tape `check` printed on the way out is the one that replays it.
    const drawn =
        \\thread 9 panic: reached unreachable code
        \\src/proof.zig:12:5: 0x1 in walk (riverrun-tests)
        \\    unreachable;
        \\    ^
        \\shakedown: a case ended the process; SHAKEDOWN_TAPE=3:0:ff87
        \\error: test 'proof.test.the proof' terminated with signal ABRT; input saved to '/s/f/crash'
        \\failed command: riverrun-tests --listen=-
    ;
    const d = crash(drawn).?;
    try std.testing.expectEqualStrings("3:0:ff87", d.tape.?);
    try std.testing.expectEqualStrings("thread 9 panic: reached unreachable code\nsrc/proof.zig:12:5: 0x1 in walk (riverrun-tests)\n    unreachable;\n    ^\n", d.stack.?);
    try std.testing.expectEqual(@as(?[]const u8, null), c.tape);

    try std.testing.expectEqual(@as(?Crash, null), crash("error: step run test failed\nthread x panic: no\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), panicMessage("thread  panic: no id\nthreads panic: none\n"));
}

test "a saved input reads as the tape that replays it" {
    const gpa = std.testing.allocator;
    const empty = try tapeText(gpa, "");
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", empty);
    var input: [8 * 2 + 3]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], 0x2a, .little);
    std.mem.writeInt(u64, input[8..16], 0xdead_beef_0001, .little);
    const text = try tapeText(gpa, &input);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("2a:deadbeef0001", text);
}

/// What the fuzzer has left in a session's cache: the runs its coverage files
/// (`v/<id>`, each headed by `std.Build.abi.fuzz.SeenPcsHeader`) count, when
/// it last saved a crashing input to `f/crash`, and how many coverage files
/// list no instrumented code at all (`pcs_len` 0), which Zig's build runner
/// refuses as corrupted: a test binary its backend built without the
/// instrumentation the fuzzer reads, as the self-hosted x86_64 backend does.
pub const Cache = struct {
    runs: u64 = 0,
    crash: ?std.Io.Timestamp = null,
    uninstrumented: u32 = 0,

    pub fn read(io: std.Io, dir: std.Io.Dir) !Cache {
        var found: Cache = .{};
        if (dir.statFile(io, "f/crash", .{})) |stat| {
            found.crash = stat.mtime;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        var coverage = dir.openDir(io, "v", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return found,
            else => return err,
        };
        defer coverage.close(io);
        var entries = coverage.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file) continue;
            var file = try coverage.openFile(io, entry.name, .{});
            defer file.close(io);
            var buffer: [@sizeOf(std.Build.abi.fuzz.SeenPcsHeader)]u8 = undefined;
            var reader = file.reader(io, &buffer);
            var header: std.Build.abi.fuzz.SeenPcsHeader = undefined;
            reader.interface.readSliceAll(std.mem.asBytes(&header)) catch |err| switch (err) {
                // A file the fuzzer is still writing has no header, and no runs.
                error.EndOfStream => continue,
                error.ReadFailed => return reader.err.?,
            };
            found.runs += header.n_runs;
            if (header.pcs_len == 0) found.uninstrumented += 1;
        }
        return found;
    }
};

pub const Session = enum { ran, crashed, idle };

/// A crash saved during the session, and a session that ran no input.
pub fn judge(before: Cache, after: Cache) Session {
    if (after.crash) |saved| {
        const earlier = before.crash orelse return .crashed;
        if (!saved.compare(.eq, earlier)) return .crashed;
    }
    return if (after.runs > before.runs) .ran else .idle;
}

test "a crash saved during the session is one, a crash from before is not" {
    const old: std.Io.Timestamp = .{ .nanoseconds = 1 };
    const new: std.Io.Timestamp = .{ .nanoseconds = 2 };
    try std.testing.expectEqual(Session.crashed, judge(.{}, .{ .runs = 10, .crash = new }));
    try std.testing.expectEqual(Session.crashed, judge(.{ .crash = old }, .{ .runs = 10, .crash = new }));
    try std.testing.expectEqual(Session.ran, judge(.{ .runs = 4, .crash = old }, .{ .runs = 10, .crash = old }));
    try std.testing.expectEqual(Session.idle, judge(.{ .runs = 10 }, .{ .runs = 10 }));
}

test "a cache reads as its coverage files' runs and its saved crash" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(Cache{}, try Cache.read(io, tmp.dir));
    try tmp.dir.createDirPath(io, "v");
    for ([_]usize{ 7, 35 }, [_][]const u8{ "v/1a", "v/2b" }) |runs, name| {
        const header: std.Build.abi.fuzz.SeenPcsHeader = .{ .n_runs = runs, .unique_runs = 1, .pcs_len = 1 };
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = std.mem.asBytes(&header) });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "v/partial", .data = "x" });
    try tmp.dir.createDirPath(io, "f");
    try tmp.dir.writeFile(io, .{ .sub_path = "f/crash", .data = "input" });
    const found = try Cache.read(io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 42), found.runs);
    try std.testing.expect(found.crash != null);
    try std.testing.expectEqual(@as(u32, 0), found.uninstrumented);
    // A binary built without the fuzzer's instrumentation (gantry's run 43684532407).
    const blind: std.Build.abi.fuzz.SeenPcsHeader = .{ .n_runs = 0, .unique_runs = 0, .pcs_len = 0 };
    try tmp.dir.writeFile(io, .{ .sub_path = "v/3c", .data = std.mem.asBytes(&blind) });
    try std.testing.expectEqual(@as(u32, 1), (try Cache.read(io, tmp.dir)).uninstrumented);
}
