//! The parsers of what reaches shakedown from outside: a tape a person
//! pastes (`SHAKEDOWN_TAPE`), the benchmark rows a comparison reads, the test
//! output the fuzz runner takes its findings from. Each takes any bytes and
//! answers or refuses them, and nothing it answers reaches past its input.
const std = @import("std");
const checking = @import("check.zig");
const gen = @import("gen.zig");
const Source = @import("Source.zig");
const bench = @import("bench.zig");
const fuzz = @import("fuzz.zig");

const Case = checking.Case;

test "a tape written as text parses back to its choices, and any other text parses or is refused" {
    const property = struct {
        fn body(_: void, c: *Case) anyerror!void {
            const choices = try gen.slice(c.source, u64, struct {
                fn one(s: *Source) u64 {
                    return gen.int(s, u64);
                }
            }.one, c.gpa, .{ .max_len = 32 });
            const text = try std.fmt.allocPrint(c.gpa, "{f}", .{Source.Tape{ .choices = choices }});
            const back = try Source.Tape.parse(c.gpa, text);
            try std.testing.expectEqualSlices(u64, choices, back);
            var buffer: [96]u8 = undefined;
            const any = gen.mutated(c.source, &buffer, &.{ text, "0:1:ff", " a:b \n" });
            const parsed = Source.Tape.parse(c.gpa, any) catch |err| switch (err) {
                error.InvalidTape => return,
                error.OutOfMemory => return err,
            };
            // What parses is the tape that formats to the same text, spaces aside.
            const again = try std.fmt.allocPrint(c.gpa, "{f}", .{Source.Tape{ .choices = parsed }});
            const reparsed = try Source.Tape.parse(c.gpa, again);
            try std.testing.expectEqualSlices(u64, parsed, reparsed);
        }
    };
    try checking.check(std.testing.allocator, {}, property.body, .{});
}

test "benchmark rows parse or are refused, whatever the bytes" {
    const examples: []const []const u8 = &.{
        "{\"name\":\"row\",\"unit\":\"ns\",\"samples\":[1,2,3]}\n",
        "\n\n",
        "{}\n{\"name\":1}",
    };
    const property = struct {
        fn body(_: void, c: *Case) anyerror!void {
            var buffer: [256]u8 = undefined;
            var run = bench.parse(std.testing.allocator, gen.mutated(c.source, &buffer, examples)) catch |err| switch (err) {
                error.InvalidRun, error.DuplicateRow => return,
                error.OutOfMemory => return err,
            };
            run.deinit();
        }
    };
    try checking.check(std.testing.allocator, {}, property.body, .{});
}

test "the fuzz runner's findings borrow from the test output they are read from" {
    const examples: []const []const u8 = &.{
        "error: 'pkg.test.prop' failed:\n       tape: 1:2:3\n       error.PropertyFailed\n",
        "1/2 pkg.test.prop...FAIL (TestUnexpectedResult)\nSHAKEDOWN_TAPE=0:ff\n",
        "All 3 tests passed.\n",
    };
    const property = struct {
        fn body(_: void, c: *Case) anyerror!void {
            var buffer: [256]u8 = undefined;
            const output = gen.mutated(c.source, &buffer, examples);
            const found = try fuzz.parse(std.testing.allocator, output);
            defer std.testing.allocator.free(found);
            for (found) |finding| {
                for ([_][]const u8{ finding.filter, finding.err, finding.tape }) |part| {
                    if (part.len == 0) continue;
                    const start = @intFromPtr(part.ptr);
                    try std.testing.expect(start >= @intFromPtr(output.ptr) and start + part.len <= @intFromPtr(output.ptr) + output.len);
                }
            }
        }
    };
    try checking.check(std.testing.allocator, {}, property.body, .{});
}
