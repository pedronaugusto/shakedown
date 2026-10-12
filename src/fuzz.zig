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

/// What the fuzzer has left in a session's cache: the runs its coverage files
/// (`v/<id>`, each headed by `std.Build.abi.fuzz.SeenPcsHeader`) count, and
/// when it last saved a crashing input to `f/crash`.
pub const Cache = struct {
    runs: u64 = 0,
    crash: ?std.Io.Timestamp = null,

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
            // A file the fuzzer is still creating holds no header yet, and counts no runs.
            reader.interface.readSliceAll(std.mem.asBytes(&header)) catch continue;
            found.runs += header.n_runs;
        }
        return found;
    }
};

pub const Session = enum { ran, crashed, idle };

/// A crash saved during the session, and a session that ran no input.
pub fn judge(before: Cache, after: Cache) Session {
    if (after.crash) |saved| {
        const earlier = before.crash orelse return .crashed;
        if (saved.nanoseconds != earlier.nanoseconds) return .crashed;
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
}
