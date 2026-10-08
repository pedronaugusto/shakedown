//! Independent fixtures for stateful traces and concurrent histories.
const std = @import("std");
const t = std.testing;
const sd = @import("shakedown.zig");
const lin = sd.linearizable;

const Stack = struct {
    pub const State = u8;
    pub const Command = enum { push, pop };
    pub const Response = u8;
    pub fn generate(s: *sd.Source, _: State) Command {
        return sd.gen.enumValue(s, Command);
    }
    pub fn precondition(state: State, command: Command) bool {
        return switch (command) {
            .push => state < 8,
            .pop => state > 0,
        };
    }
    pub fn transition(state: State, command: Command) State {
        return switch (command) {
            .push => state + 1,
            .pop => state - 1,
        };
    }
    pub fn postcondition(_: State, _: Command, response: Response, after: State) bool {
        return response == after;
    }
};
const StackDriver = struct {
    pub const Error = error{DriverFailed};
    state: u8 = 0,
    calls: u32 = 0,
    broken: bool = false,
    fail: bool = false,
    pub fn run(self: *StackDriver, _: std.Io, command: Stack.Command) Error!u8 {
        if (self.fail) return error.DriverFailed;
        std.debug.assert(Stack.precondition(self.state, command));
        self.calls += 1;
        self.state = Stack.transition(self.state, command);
        return if (self.broken and command == .pop) 99 else self.state;
    }
};
const Sm = sd.Machine(Stack);

fn stackProperty(_: void, c: *sd.Case) !void {
    var driver: StackDriver = .{};
    var machine: Sm = .init(0);
    machine.run(t.io, c.source, &driver, .{ .average_commands = 8, .max_commands = 128 }) catch |err| switch (err) {
        error.LimitExceeded => return error.Unsatisfiable,
        else => return err,
    };
    try t.expectEqual(driver.state, machine.state);
    try t.expectEqual(driver.calls, machine.completed);
}
test "B6 Machine property shares Case Source and generator vocabulary" {
    try sd.check(t.allocator, {}, stackProperty, .{ .seed = 123, .cases = 100 });
}

test "B6 Machine command replay validates before side effects and retains failure prefix" {
    var driver: StackDriver = .{};
    var machine: Sm = .init(0);
    try t.expectError(error.InvalidTrace, machine.replay(t.io, &driver, &.{ .push, .pop, .pop }, .{}));
    try t.expectEqual(@as(u32, 0), driver.calls);
    try t.expectError(error.TraceFull, machine.replay(t.io, &driver, &.{.push}, .{ .trace = &.{} }));
    try t.expectError(error.LimitExceeded, machine.replay(t.io, &driver, &.{.push}, .{ .max_commands = 0 }));
    var trace: [2]Sm.Step = undefined;
    driver.broken = true;
    try t.expectError(error.PostconditionFailed, machine.replay(t.io, &driver, &.{ .push, .pop }, .{ .trace = &trace }));
    try t.expectEqual(@as(usize, 2), machine.recorded);
    try t.expectEqual(@as(u64, 1), machine.completed);
    try t.expectEqual(@as(u8, 1), machine.state);
    try t.expectEqual(@as(u8, 99), trace[1].response);
}

test "B6 Machine deterministic tape replay and explicit generation exhaustion" {
    const tape = [_]u64{ 999999, 0, 999999, 1, 0 };
    var source = try sd.Source.initRecording(t.allocator, .{ .replay = &tape }, .{});
    defer source.deinit();
    var a: StackDriver = .{};
    var machine: Sm = .init(0);
    try machine.run(t.io, &source, &a, .{});
    try t.expectEqual(@as(u32, 2), a.calls);
    try t.expectEqualSlices(u64, &tape, source.tape().choices);
    source.restart(.{ .replay = &tape });
    var b: StackDriver = .{};
    machine = .init(0);
    try machine.run(t.io, &source, &b, .{});
    try t.expectEqual(a.state, b.state);
    try t.expectEqual(a.calls, b.calls);
    source.restart(.{ .replay = &.{ 999999, 1 } });
    machine = .init(0);
    try t.expectError(error.Unsatisfiable, machine.run(t.io, &source, &b, .{ .max_tries = 1 }));
    source.restart(.{ .replay = &tape });
    try t.expectError(error.LimitExceeded, machine.run(t.io, &source, &b, .{ .max_commands = 0 }));
    source.restart(.{ .replay = &tape });
    b.fail = true;
    try t.expectError(error.DriverFailed, machine.run(t.io, &source, &b, .{}));
    try t.expectEqual(@as(u64, 0), machine.completed);
}

const Shrinking = struct {
    calls: u32 = 0,
    fn body(self: *Shrinking, c: *sd.Case) !void {
        var driver: StackDriver = .{ .broken = true };
        var machine: Sm = .init(0);
        defer self.calls = driver.calls;
        try machine.run(t.io, c.source, &driver, .{ .max_tries = 1 });
    }
};
test "B6 Machine shrinking preserves prerequisite commands and same failure" {
    var ctx: Shrinking = .{};
    var report: sd.CheckReport = undefined;
    try t.expectError(error.PropertyFailed, sd.check(t.allocator, &ctx, Shrinking.body, .{
        .regressions = &.{"f423f:0:f423f:1:0"},
        .cases = 0,
        .diagnostics = &report,
    }));
    defer report.deinit();
    try t.expectEqual(error.PostconditionFailed, report.err);
    try t.expectEqual(@as(u32, 2), ctx.calls);
    try t.expect(report.shrink_runs > 0);
    var source = try sd.Source.init(t.allocator, .{ .replay = report.tape });
    defer source.deinit();
    var driver: StackDriver = .{ .broken = true };
    var machine: Sm = .init(0);
    try t.expectError(error.PostconditionFailed, machine.run(t.io, &source, &driver, .{ .max_tries = 1 }));
    try t.expectEqual(@as(u32, 2), driver.calls);
}

test "B6 Machine tape capacity exhaustion discards rather than passes" {
    var source = try sd.Source.initRecording(t.allocator, .{ .replay = &.{ 999999, 0 } }, .{ .max_choices = 1 });
    defer source.deinit();
    var driver: StackDriver = .{};
    var machine: Sm = .init(0);
    try t.expectError(error.Unsatisfiable, machine.run(t.io, &source, &driver, .{}));
    try t.expectEqual(@as(u32, 0), driver.calls);
}

const Register = struct {
    pub const State = u8;
    pub const Input = union(enum) { write: u8, read };
    pub const Output = u8;
    pub fn step(state: State, input: Input, output: Output) ?State {
        return switch (input) {
            .write => |value| if (output == value) value else null,
            .read => if (output == state) state else null,
        };
    }
};
const Op = lin.Operation(Register.Input, Register.Output);
fn expectStatus(comptime Model: type, initial: Model.State, history: []const lin.Operation(Model.Input, Model.Output), status: lin.Status, options: lin.Options) !void {
    var result = try lin.check(t.io, t.allocator, Model, initial, history, options);
    defer result.deinit();
    try t.expectEqual(status, result.status);
    if (status == .linearizable) {
        try t.expectEqual(history.len, result.order.len);
        var state = initial;
        var used: [256]bool = @splat(false);
        for (result.order) |index| {
            try t.expect(!used[index]);
            used[index] = true;
            for (history, 0..) |other, j| {
                if (other.response.?.at < history[index].invocation) try t.expect(used[j]);
            }
            state = Model.step(state, history[index].input, history[index].response.?.output) orelse return error.InvalidWitness;
        }
    } else try t.expectEqual(@as(usize, 0), result.order.len);
}

test "B6 linearizable overlap differs from must happen before including equal times" {
    var history = [_]Op{
        .{ .invocation = 1, .input = .{ .write = 1 }, .response = .{ .at = 4, .output = 1 } },
        .{ .invocation = 2, .input = .read, .response = .{ .at = 3, .output = 0 } },
    };
    try expectStatus(Register, 0, &history, .linearizable, .{});
    history[1].invocation = 4;
    history[1].response.?.at = 5;
    try expectStatus(Register, 0, &history, .linearizable, .{});
    history[1].invocation = 5;
    try expectStatus(Register, 0, &history, .violation, .{});
    history[1].response.?.output = 1;
    try expectStatus(Register, 0, &history, .linearizable, .{});
    history[0].response.?.output = 2;
    try expectStatus(Register, 0, &history, .violation, .{});
}

test "B6 linearizable incomplete invalid and bounded search are honest outcomes" {
    const history = [_]Op{.{ .invocation = 1, .input = .{ .write = 1 }, .response = .{ .at = 2, .output = 1 } }};
    try expectStatus(Register, 0, &history, .unknown, .{ .max_operations = 0 });
    try expectStatus(Register, 0, &history, .unknown, .{ .max_bytes = 0 });
    try expectStatus(Register, 0, &history, .unknown, .{ .max_steps = 0 });
    try expectStatus(Register, 0, &history, .linearizable, .{ .max_steps = 1 });
    try expectStatus(Register, 0, &.{}, .linearizable, .{ .max_steps = 0, .max_bytes = 0 });
    try expectStatus(Register, 0, &.{.{ .invocation = 0, .input = .read }}, .unknown, .{});
    try t.expectError(error.InvalidHistory, lin.check(t.io, t.allocator, Register, 0, &.{
        .{ .invocation = 2, .input = .read, .response = .{ .at = 1, .output = 0 } },
    }, .{}));
    const reject = [_]Op{.{ .invocation = 0, .input = .read, .response = .{ .at = 1, .output = 1 } }};
    try expectStatus(Register, 0, &reject, .violation, .{ .max_steps = 1 });
}

// Append sequence and reader cursor fixture, inspired by journal contracts.
// This is independent code: it is not evidence of consumer adoption.
const Journal = struct {
    pub const State = u32;
    pub const Input = enum { append, read };
    pub const Output = u32;
    pub fn step(state: State, input: Input, output: Output) ?State {
        const next = state + @intFromBool(input == .append);
        return if (output == next) next else null;
    }
};
// Prepared records become visible only when remembered; a lookup sees one
// complete revision. An independent fixed-value ledger fixture.
const Ledger = struct {
    pub const State = [2]u8;
    pub const Input = union(enum) { remember: struct { id: u1, revision: u8 }, get: u1 };
    pub const Output = u8;
    pub fn step(state: State, input: Input, output: Output) ?State {
        var next = state;
        switch (input) {
            .remember => |record| {
                if (output != record.revision) return null;
                next[record.id] = record.revision;
            },
            .get => |id| if (output != state[id]) return null,
        }
        return next;
    }
};

test "B6 independent journal readers writers and ledger revisions detect violations" {
    const JOp = lin.Operation(Journal.Input, Journal.Output);
    var journal = [_]JOp{
        .{ .invocation = 0, .input = .append, .response = .{ .at = 4, .output = 1 } },
        .{ .invocation = 1, .input = .append, .response = .{ .at = 3, .output = 2 } },
        .{ .invocation = 5, .input = .read, .response = .{ .at = 6, .output = 2 } },
    };
    try expectStatus(Journal, 0, &journal, .linearizable, .{});
    journal[2].response.?.output = 1;
    try expectStatus(Journal, 0, &journal, .violation, .{});
    const LOp = lin.Operation(Ledger.Input, Ledger.Output);
    var ledger = [_]LOp{
        .{ .invocation = 0, .input = .{ .remember = .{ .id = 0, .revision = 7 } }, .response = .{ .at = 4, .output = 7 } },
        .{ .invocation = 1, .input = .{ .get = 0 }, .response = .{ .at = 3, .output = 0 } },
        .{ .invocation = 5, .input = .{ .get = 0 }, .response = .{ .at = 6, .output = 7 } },
    };
    try expectStatus(Ledger, .{ 0, 0 }, &ledger, .linearizable, .{});
    ledger[2].response.?.output = 0;
    try expectStatus(Ledger, .{ 0, 0 }, &ledger, .violation, .{});
}

// Independent exhaustive permutations: enumerate whole orders first, then
// check every pair's real-time ordering and replay. No eligibility pruning.
fn oracle(history: []const Op, order: []usize, depth: usize) bool {
    if (depth == history.len) {
        for (order, 0..) |index, i| for (order[i + 1 ..]) |later| {
            if (history[later].response.?.at < history[index].invocation) return false;
        };
        var state: u8 = 0;
        for (order) |index| state = Register.step(state, history[index].input, history[index].response.?.output) orelse return false;
        return true;
    }
    for (0..history.len) |index| {
        var duplicate = false;
        for (order[0..depth]) |before| if (before == index) {
            duplicate = true;
        };
        if (duplicate) continue;
        order[depth] = index;
        if (oracle(history, order, depth + 1)) return true;
    }
    return false;
}
fn historyProperty(_: void, c: *sd.Case) !void {
    var history: [5]Op = undefined;
    for (&history) |*op| {
        const invocation = c.source.below(8);
        op.* = .{
            .invocation = invocation,
            .input = if (sd.gen.boolean(c.source)) .{ .write = @intCast(c.source.below(2)) } else .read,
            .response = .{ .at = invocation + c.source.below(5), .output = @intCast(c.source.below(2)) },
        };
    }
    var order: [5]usize = undefined;
    const expected: lin.Status = if (oracle(&history, &order, 0)) .linearizable else .violation;
    try expectStatus(Register, 0, &history, expected, .{});
}
test "B6 linearizable matches independent exhaustive oracle over seeded histories" {
    try sd.check(t.allocator, {}, historyProperty, .{ .seed = 52, .cases = 400 });
}

fn allocationWork(gpa: std.mem.Allocator) !void {
    var no_resize: sd.alloc.NoResize = .init(gpa);
    const history = [_]Op{
        .{ .invocation = 0, .input = .{ .write = 1 }, .response = .{ .at = 4, .output = 1 } },
        .{ .invocation = 1, .input = .read, .response = .{ .at = 3, .output = 0 } },
    };
    var result = try lin.check(t.io, no_resize.allocator(), Register, 0, &history, .{});
    defer result.deinit();
    try t.expectEqual(lin.Status.linearizable, result.status);
}
test "B6 linearizable allocation failure releases every workspace and witness" {
    try t.checkAllAllocationFailures(t.allocator, allocationWork, .{});
}

const Cancel = struct {
    calls: usize = 0,
    after: usize,
    fn checkCancel(ctx: ?*anyopaque) std.Io.Cancelable!void {
        const self: *Cancel = @ptrCast(@alignCast(ctx.?)); // safe: Layer pairs this callback with Cancel state
        self.calls += 1;
        if (self.calls >= self.after) return error.Canceled;
    }
};
test "B6 checker and Machine honor cancellation before and during work" {
    const Layer = sd.Layer(Cancel, .{ .checkCancel = Cancel.checkCancel });
    var layer: Layer = .init(t.io, .{ .after = 1 });
    const history = [_]Op{.{ .invocation = 0, .input = .read, .response = .{ .at = 1, .output = 0 } }};
    try t.expectError(error.Canceled, lin.check(layer.io(), t.allocator, Register, 0, &history, .{}));
    layer.state = .{ .after = 3 };
    try t.expectError(error.Canceled, lin.check(layer.io(), t.allocator, Register, 0, &history, .{}));
    layer.state = .{ .after = 1 };
    var driver: StackDriver = .{};
    var machine: Sm = .init(0);
    try t.expectError(error.Canceled, machine.replay(layer.io(), &driver, &.{.push}, .{}));
    try t.expectEqual(@as(u32, 0), driver.calls);
    layer.state = .{ .after = 3 };
    try t.expectError(error.Canceled, machine.replay(layer.io(), &driver, &.{ .push, .pop }, .{}));
    try t.expectEqual(@as(u32, 0), driver.calls);
}
