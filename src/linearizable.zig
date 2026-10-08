//! Bounded model-based linearizability checking of completed operations.
const std = @import("std");

/// Closed invocation/response intervals: equal timestamps may overlap.
/// Use strictly increasing event ordinals when exact event ordering is known.
/// Input and output data are borrowed and must remain immutable during check.
pub fn Operation(comptime Input: type, comptime Output: type) type {
    return struct {
        invocation: u64,
        input: Input,
        response: ?struct { at: u64, output: Output } = null,
    };
}

pub const Options = struct {
    max_operations: usize = 256,
    /// Candidate examinations, including candidates rejected by ordering.
    max_steps: u64 = 1_000_000,
    /// Bound on allocated workspace and witness payload (allocator overhead excluded).
    max_bytes: usize = 16 * 1024 * 1024,
};
pub const Status = enum { linearizable, violation, unknown };
pub const Limit = enum { operations, memory, search, incomplete_history };
pub const Error = error{ OutOfMemory, InvalidHistory, Canceled };

pub const Result = struct {
    status: Status,
    limit: ?Limit = null,
    steps: u64 = 0,
    max_depth: usize = 0,
    /// Input indices in one legal sequential ordering; empty unless linearizable.
    order: []const usize = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Result) void {
        if (self.allocator) |gpa| gpa.free(self.order);
        self.* = undefined;
    }
};

/// Model declares State, Input, Output and pure
/// step(state, input, output) ?State: null rejects that response. Each state
/// must be an independent value snapshot, with any referenced data immutable.
/// The caller owns model resources; callbacks must terminate and allocate no
/// checker-owned storage. No globals, wall clock or randomness affect search.
///
/// Iterative depth-first search respects response-before-invocation ordering.
/// A candidate is eligible only when its invocation is no later than the first
/// remaining response. Exhausting all legal branches proves violation; budgets
/// and pending calls produce unknown. Pending operations are never silently
/// dropped. Cancellation is checked between candidate examinations.
/// Workspace is O(n * sizeof(State)); native stack usage is independent of n.
// ziglint-ignore: Z023 blocking drivers take Io first; the history type depends on Model
pub fn check(io: std.Io, gpa: std.mem.Allocator, comptime Model: type, initial: Model.State, history: []const Operation(Model.Input, Model.Output), options: Options) Error!Result {
    try io.checkCancel();
    const n = history.len;
    if (n > options.max_operations) return .{ .status = .unknown, .limit = .operations };
    var pending = false;
    for (history) |op| {
        try io.checkCancel();
        if (op.response) |response| {
            if (response.at < op.invocation) return error.InvalidHistory;
        } else pending = true;
    }
    if (pending) return .{ .status = .unknown, .limit = .incomplete_history };
    if (n == 0) return .{ .status = .linearizable };
    const per_op = @sizeOf(Model.State) + @sizeOf(usize) * 2 + @sizeOf(u64) + @sizeOf(bool);
    const extra = @sizeOf(Model.State) + @sizeOf(usize) + @sizeOf(u64);
    if (options.max_bytes < extra or n > (options.max_bytes - extra) / per_op)
        return .{ .status = .unknown, .limit = .memory };

    const states = try gpa.alloc(Model.State, n + 1);
    defer gpa.free(states);
    const cursors = try gpa.alloc(usize, n + 1);
    defer gpa.free(cursors);
    const barriers = try gpa.alloc(u64, n + 1);
    defer gpa.free(barriers);
    const used = try gpa.alloc(bool, n);
    defer gpa.free(used);
    const order = try gpa.alloc(usize, n);
    errdefer gpa.free(order);
    var keep_order = false;
    defer if (!keep_order) gpa.free(order);
    @memset(used, false);
    states[0] = initial;
    cursors[0] = 0;
    barriers[0] = firstResponse(Model, history, used);
    var depth: usize = 0;
    var result: Result = .{ .status = .violation };
    while (true) {
        try io.checkCancel();
        if (depth == n) {
            result.status = .linearizable;
            result.order = order;
            result.allocator = gpa;
            keep_order = true;
            return result;
        }
        if (cursors[depth] == n) {
            if (depth == 0) return result;
            depth -= 1;
            used[order[depth]] = false;
            continue;
        }
        if (result.steps == options.max_steps) {
            result.status = .unknown;
            result.limit = .search;
            return result;
        }
        const candidate = cursors[depth];
        cursors[depth] += 1;
        result.steps += 1;
        if (used[candidate]) continue;
        const op = history[candidate];
        if (op.invocation > barriers[depth]) continue;
        const next = Model.step(states[depth], op.input, op.response.?.output) orelse continue;
        used[candidate] = true;
        order[depth] = candidate;
        depth += 1;
        states[depth] = next;
        cursors[depth] = 0;
        barriers[depth] = firstResponse(Model, history, used);
        result.max_depth = @max(result.max_depth, depth);
    }
}

fn firstResponse(comptime Model: type, history: []const Operation(Model.Input, Model.Output), used: []const bool) u64 {
    var first: u64 = std.math.maxInt(u64);
    for (history, used) |op, done| if (!done) {
        first = @min(first, op.response.?.at);
    };
    return first;
}
