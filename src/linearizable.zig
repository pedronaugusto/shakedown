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
    /// Failed (placed-set, model-state) memo entries. Zero disables caching.
    /// Capacity is reduced to fit max_bytes; a full cache only costs speed.
    max_cache_entries: usize = 1024,
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
    cache_hits: u64 = 0,
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
/// Failed states are memoized with exact placed sets and Model.equal, or
/// std.meta.eql for value models. Equal states must admit the same future
/// responses. Hash collisions are confirmed by equality; a full cache cannot
/// change correctness. Workspace is O(n * sizeof(State) + cache * (n +
/// sizeof(State))); native stack usage is independent of n.
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
    var keep_order = false;
    defer if (!keep_order) gpa.free(order);
    const base_bytes = n * per_op + extra;
    const cache_entry_bytes = @sizeOf(Cache(Model).Entry) + n;
    const capacity = @min(options.max_cache_entries, (options.max_bytes - base_bytes) / cache_entry_bytes);
    var cache = Cache(Model).init(capacity, n);
    defer cache.deinit(gpa);
    var placed_hash: u64 = 0;
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
            try cache.insert(gpa, states[depth], used, placed_hash);
            depth -= 1;
            used[order[depth]] = false;
            placed_hash ^= choiceHash(order[depth]);
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
        const next_hash = placed_hash ^ choiceHash(candidate);
        if (cache.contains(next, used, next_hash)) {
            used[candidate] = false;
            result.cache_hits += 1;
            continue;
        }
        placed_hash = next_hash;
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

// A stable, order-independent fingerprint of the placed operation indices.
// Hash matches are always confirmed with the exact set and model equality.
fn choiceHash(index: usize) u64 {
    var x = @as(u64, @intCast(index)) +% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn Cache(comptime Model: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { occupied: bool = false, hash: u64 = 0, state: Model.State = undefined };
        entries: []Entry,
        masks: []bool,
        width: usize,
        capacity: usize,

        fn init(capacity: usize, width: usize) Self {
            return .{ .entries = &.{}, .masks = &.{}, .width = width, .capacity = capacity };
        }
        fn allocate(self: *Self, gpa: std.mem.Allocator) Error!void {
            const entries = try gpa.alloc(Entry, self.capacity);
            errdefer gpa.free(entries);
            const masks = try gpa.alloc(bool, self.capacity * self.width);
            for (entries) |*entry| entry.* = .{};
            self.entries = entries;
            self.masks = masks;
        }
        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.entries);
            gpa.free(self.masks);
        }
        fn equal(a: Model.State, b: Model.State) bool {
            if (@hasDecl(Model, "equal")) return Model.equal(a, b);
            return std.meta.eql(a, b);
        }
        fn mask(self: *const Self, index: usize) []bool {
            return self.masks[index * self.width ..][0..self.width];
        }
        fn contains(self: *const Self, state: Model.State, used: []const bool, hash: u64) bool {
            if (self.entries.len == 0) return false;
            var index: usize = @intCast(hash % self.entries.len);
            for (0..self.entries.len) |_| {
                const entry = self.entries[index];
                if (!entry.occupied) return false;
                if (entry.hash == hash and std.mem.eql(bool, self.mask(index), used) and equal(entry.state, state)) return true;
                index = if (index + 1 == self.entries.len) 0 else index + 1;
            }
            return false;
        }
        fn insert(self: *Self, gpa: std.mem.Allocator, state: Model.State, used: []const bool, hash: u64) Error!void {
            if (self.capacity == 0) return;
            if (self.entries.len == 0) try self.allocate(gpa);
            var index: usize = @intCast(hash % self.entries.len);
            for (0..self.entries.len) |_| {
                const entry = &self.entries[index];
                if (!entry.occupied) {
                    entry.* = .{ .occupied = true, .hash = hash, .state = state };
                    @memcpy(self.mask(index), used);
                    return;
                }
                if (entry.hash == hash and std.mem.eql(bool, self.mask(index), used) and equal(entry.state, state)) return;
                index = if (index + 1 == self.entries.len) 0 else index + 1;
            }
        }
    };
}
