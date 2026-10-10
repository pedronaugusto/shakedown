//! What a fuzzing session's output says it found: each property the fuzzer
//! failed, with the tape `check` printed for it, read from the lines
//! `check` and the test runner write.
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
