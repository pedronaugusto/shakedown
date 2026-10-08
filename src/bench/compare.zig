//! Compare two JSONL runs; flags describe observed noise, never exit status.
const std = @import("std");
const bench = @import("measuring");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) {
        var a = try bench.parse(init.gpa, @embedFile("fixtures/before.jsonl"));
        defer a.deinit();
        var b = try bench.parse(init.gpa, @embedFile("fixtures/after.jsonl"));
        defer b.deinit();
        try report(init.gpa, &stdout.interface, a, b);
    } else {
        if (args.len != 3) return error.ExpectedTwoRuns;
        const before = try Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(64 * 1024 * 1024));
        defer init.gpa.free(before);
        const after = try Io.Dir.cwd().readFileAlloc(init.io, args[2], init.gpa, .limited(64 * 1024 * 1024));
        defer init.gpa.free(after);
        var a = try bench.parse(init.gpa, before);
        defer a.deinit();
        var b = try bench.parse(init.gpa, after);
        defer b.deinit();
        try report(init.gpa, &stdout.interface, a, b);
    }
    try stdout.interface.flush();
}

fn report(gpa: std.mem.Allocator, writer: *Io.Writer, before: bench.Run, after: bench.Run) !void {
    for (before.rows.items) |a| {
        var found = false;
        for (after.rows.items) |b| {
            if (!std.mem.eql(u8, a.value.row, b.value.row)) continue;
            found = true;
            const change = try bench.compare(gpa, a.value, b.value);
            try std.json.Stringify.value(change, .{}, writer);
            try writer.writeByte('\n');
            break;
        }
        if (!found) {
            try std.json.Stringify.value(.{ .row = a.value.row, .status = "removed" }, .{}, writer);
            try writer.writeByte('\n');
        }
    }
    for (after.rows.items) |b| {
        var found = false;
        for (before.rows.items) |a| if (std.mem.eql(u8, a.value.row, b.value.row)) {
            found = true;
            break;
        };
        if (!found) {
            try std.json.Stringify.value(.{ .row = b.value.row, .status = "added" }, .{}, writer);
            try writer.writeByte('\n');
        }
    }
}
