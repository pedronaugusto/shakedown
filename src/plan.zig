//! `Plan(Call, Fault)`: when calls fail, as data.
//!
//! A plan is a list of entries, each a trigger and a fault. A caller asks
//! the plan about every call it makes, in order; the plan takes a step for
//! it and answers with the fault to inject, or null. The call and fault
//! types are the caller's own: `FaultIo` instantiates it for `IoCall` and
//! `IoFault`, and a package with raw calls of its own instantiates it for
//! those, sharing `FaultIo`'s `Steps` so both kinds of call land in one
//! sequence.
const std = @import("std");
const Match = @import("match.zig").Match;
const Source = @import("Source.zig");
const Steps = @import("Steps.zig");

pub fn Plan(comptime Call: type, comptime Fault: type) type {
    return struct {
        /// Private: the entries, owned by the caller.
        entries: []const Entry,
        /// Private: what the plan was made with.
        options: Options,
        /// Private: how many entries fired so far, `options.fired` holding
        /// the first of them.
        fired_count: usize = 0,

        const Self = @This();

        pub const Entry = struct {
            at: At,
            fault: Fault,
            /// How many matches fire. 0 = every match from the first on.
            times: u32 = 1,
        };

        pub const At = union(enum) {
            /// The n-th call (from 1) matching `call` (null = any call) and
            /// `path`, and as many after it as `times` allows.
            nth: struct { call: ?Call = null, n: u32, path: Match = .any },
            /// The call that takes this step: what a sweep uses.
            step: u64,
            /// Each matching call fires with this probability, drawn from
            /// the plan's `Source`, until `times` have fired.
            chance: struct { call: ?Call = null, path: Match = .any, per_million: u32 },
        };

        pub const Options = struct {
            steps: *Steps,
            /// Required when an entry is `.chance`.
            source: ?*Source = null,
            /// Caller storage, one counter per entry.
            counters: []u32,
            /// Caller storage for `fired`. Entries that fire past its end
            /// are counted but not listed.
            fired: []Fired = &.{},
        };

        pub const Fired = struct { entry: u32, step: u64 };

        /// `entries` and the storage in `options` must outlive the plan.
        pub fn init(entries: []const Entry, options: Options) Self {
            std.debug.assert(options.counters.len >= entries.len);
            for (entries) |entry| {
                if (entry.at == .chance) std.debug.assert(options.source != null);
                if (entry.at == .nth) std.debug.assert(entry.at.nth.n >= 1);
            }
            var p: Self = .{ .entries = entries, .options = options };
            p.reset();
            return p;
        }

        /// Takes a step, then returns the fault of the first entry that
        /// fires for this call, or null. Every entry the call matches
        /// counts it, fired or not. O(entries).
        pub fn decide(p: *Self, call: Call, subject: ?[]const u8) ?Fault {
            return p.decideAt(p.options.steps.take(), call, subject);
        }

        /// `decide` for a step the caller has already taken.
        pub fn decideAt(p: *Self, step: u64, call: Call, subject: ?[]const u8) ?Fault {
            var chosen: ?Fault = null;
            for (p.entries, p.options.counters[0..p.entries.len], 0..) |entry, *counter, i| {
                const fires = switch (entry.at) {
                    .step => |s| s == step,
                    .nth => |nth| fires: {
                        if (!callMatches(nth.call, call) or !nth.path.matches(subject)) break :fires false;
                        counter.* +|= 1;
                        break :fires counter.* >= nth.n and (entry.times == 0 or counter.* - nth.n < entry.times);
                    },
                    .chance => |c| fires: {
                        if (!callMatches(c.call, call) or !c.path.matches(subject)) break :fires false;
                        if (entry.times != 0 and counter.* >= entry.times) break :fires false;
                        if (!p.options.source.?.chance(c.per_million)) break :fires false;
                        counter.* +|= 1;
                        break :fires true;
                    },
                };
                if (!fires or chosen != null) continue;
                chosen = entry.fault;
                if (p.fired_count < p.options.fired.len) {
                    p.options.fired[p.fired_count] = .{ .entry = @intCast(i), .step = step };
                }
                p.fired_count += 1;
            }
            return chosen;
        }

        /// The entries that fired, in order, as far as `Options.fired` holds them.
        pub fn fired(p: *const Self) []const Fired {
            return p.options.fired[0..@min(p.fired_count, p.options.fired.len)];
        }

        /// How many times an entry fired, listed or not.
        pub fn firedCount(p: *const Self) usize {
            return p.fired_count;
        }

        /// Forgets every match and firing. The step counter is the caller's.
        pub fn reset(p: *Self) void {
            @memset(p.options.counters[0..p.entries.len], 0);
            p.fired_count = 0;
        }

        fn callMatches(want: ?Call, call: Call) bool {
            const w = want orelse return true;
            return std.meta.eql(w, call);
        }
    };
}

const TestCall = enum { open, read, sync };
const TestPlan = Plan(TestCall, u8);

test "nth fires on the n-th matching call, and as many after it as times says" {
    var steps: Steps = .init();
    var counters: [2]u32 = undefined;
    var fired: [8]TestPlan.Fired = undefined;
    const entries = [_]TestPlan.Entry{
        .{ .at = .{ .nth = .{ .call = .read, .n = 2 } }, .fault = 1, .times = 2 },
        .{ .at = .{ .nth = .{ .call = .sync, .n = 1, .path = .{ .suffix = ".lock" } } }, .fault = 2, .times = 0 },
    };
    var plan: TestPlan = .init(&entries, .{ .steps = &steps, .counters = &counters, .fired = &fired });
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.read, "a"));
    try std.testing.expectEqual(@as(?u8, 1), plan.decide(.read, "a"));
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.open, "a"));
    try std.testing.expectEqual(@as(?u8, 1), plan.decide(.read, "b"));
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.read, "a"));
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.sync, "x"));
    try std.testing.expectEqual(@as(?u8, 2), plan.decide(.sync, "x.lock"));
    try std.testing.expectEqual(@as(?u8, 2), plan.decide(.sync, "y.lock"));
    try std.testing.expectEqualSlices(TestPlan.Fired, &.{
        .{ .entry = 0, .step = 1 }, .{ .entry = 0, .step = 3 }, .{ .entry = 1, .step = 6 }, .{ .entry = 1, .step = 7 },
    }, plan.fired());
    plan.reset();
    try std.testing.expectEqual(@as(usize, 0), plan.fired().len);
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.read, "a"));
}

test "a step entry fires at exactly its step, and the first firing entry wins" {
    var steps: Steps = .init();
    var counters: [2]u32 = undefined;
    const entries = [_]TestPlan.Entry{
        .{ .at = .{ .step = 2 }, .fault = 7 },
        .{ .at = .{ .nth = .{ .n = 3 } }, .fault = 8 },
    };
    var plan: TestPlan = .init(&entries, .{ .steps = &steps, .counters = &counters });
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.open, null));
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.read, null));
    // Step 2 is also the third call: the first entry's fault is the one
    // injected and listed, and the second entry's match is spent.
    try std.testing.expectEqual(@as(?u8, 7), plan.decide(.sync, null));
    try std.testing.expectEqual(@as(usize, 1), plan.firedCount());
    try std.testing.expectEqual(@as(?u8, null), plan.decide(.sync, null));
}

test "chance entries draw from the source, so a seed repeats them" {
    var outcomes: [2][64]bool = undefined;
    for (&outcomes) |*run| {
        var source: Source = try .init(std.testing.allocator, .{ .prng = 99 });
        defer source.deinit();
        var steps: Steps = .init();
        var counters: [1]u32 = undefined;
        const entries = [_]TestPlan.Entry{.{ .at = .{ .chance = .{ .call = .read, .per_million = 300_000 } }, .fault = 3, .times = 0 }};
        var plan: TestPlan = .init(&entries, .{ .steps = &steps, .counters = &counters, .source = &source });
        for (run) |*o| o.* = plan.decide(.read, null) != null;
    }
    try std.testing.expectEqualSlices(bool, &outcomes[0], &outcomes[1]);
    const hits = std.mem.count(bool, &outcomes[0], &.{true});
    try std.testing.expect(hits > 5 and hits < 40);
}

test "a plan with a seam's own call type shares the step sequence" {
    const Raw = enum { barrier, rename };
    var steps: Steps = .init();
    var counters: [1]u32 = undefined;
    const RawPlan = Plan(Raw, anyerror);
    const entries = [_]RawPlan.Entry{.{ .at = .{ .step = 1 }, .fault = error.InputOutput }};
    var plan: RawPlan = .init(&entries, .{ .steps = &steps, .counters = &counters });
    _ = steps.take(); // a call made elsewhere takes step 0
    try std.testing.expectEqual(@as(?anyerror, error.InputOutput), plan.decide(.barrier, null));
}
