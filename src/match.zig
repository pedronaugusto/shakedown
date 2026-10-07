//! `Match`: which paths a plan entry applies to.
const std = @import("std");

/// A test on a call's subject path. A call with no known path matches
/// only `any`.
pub const Match = union(enum) {
    any,
    exact: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    contains: []const u8,

    pub fn matches(m: Match, subject: ?[]const u8) bool {
        if (m == .any) return true;
        const path = subject orelse return false;
        return switch (m) {
            .any => unreachable, // unreachable: returned above
            .exact => |p| std.mem.eql(u8, path, p),
            .prefix => |p| std.mem.startsWith(u8, path, p),
            .suffix => |p| std.mem.endsWith(u8, path, p),
            .contains => |p| std.mem.find(u8, path, p) != null,
        };
    }
};

test "each form matches what it names, and a missing path matches only any" {
    const path = "repo/objects/pack/a.idx";
    try std.testing.expect(Match.matches(.any, path));
    try std.testing.expect(Match.matches(.any, null));
    try std.testing.expect(Match.matches(.{ .exact = path }, path));
    try std.testing.expect(!Match.matches(.{ .exact = "repo" }, path));
    try std.testing.expect(Match.matches(.{ .prefix = "repo/" }, path));
    try std.testing.expect(!Match.matches(.{ .prefix = "objects" }, path));
    try std.testing.expect(Match.matches(.{ .suffix = ".idx" }, path));
    try std.testing.expect(!Match.matches(.{ .suffix = ".pack" }, path));
    try std.testing.expect(Match.matches(.{ .contains = "/pack/" }, path));
    try std.testing.expect(!Match.matches(.{ .contains = "/tmp/" }, path));
    try std.testing.expect(!Match.matches(.{ .prefix = "" }, null));
}
