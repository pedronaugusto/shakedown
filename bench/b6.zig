//! Deterministic stateful trace and model search costs, including setup/cleanup.
const std = @import("std");
const sd = @import("shakedown");
const measuring = sd.bench;
const lin = sd.linearizable;

pub const Model = struct {
    pub const State = u32;
    pub const Input = enum { increment, read };
    pub const Output = u32;
    pub const Command = Input;
    pub const Response = Output;
    pub const GenerateError = error{};
    pub fn generate(_: std.mem.Allocator, source: *sd.Source, _: State) GenerateError!Command {
        return sd.gen.enumValue(source, Command);
    }
    pub fn precondition(_: State, _: Command) bool {
        return true;
    }
    pub fn transition(state: State, command: Command) State {
        return state + @intFromBool(command == .increment);
    }
    pub fn postcondition(_: State, _: Command, response: Response, after: State) bool {
        return response == after;
    }
    pub fn step(state: State, input: Input, output: Output) ?State {
        const next = transition(state, input);
        return if (output == next) next else null;
    }
};
const Driver = struct {
    pub const Error = error{};
    state: u32 = 0,
    pub fn run(self: *Driver, _: std.Io, command: Model.Command) Driver.Error!Model.Response {
        self.state = Model.transition(self.state, command);
        return self.state;
    }
};
pub const Context = struct { gpa: std.mem.Allocator, io: std.Io, source: sd.Source, sink: u64 = 0 };
pub const Error = lin.Error || sd.Machine(Model).Error || error{UnexpectedResult};
pub fn trace(ctx: *Context, count: u64) Error!void {
    var commands: [64]Model.Command = undefined;
    for (&commands, 0..) |*command, i| command.* = if (i % 2 == 0) .increment else .read;
    for (0..count) |_| {
        var driver: Driver = .{};
        var machine: sd.Machine(Model) = .init(0);
        try machine.replay(ctx.io, &driver, &commands, .{});
        ctx.sink +%= machine.completed + machine.state;
    }
}
pub fn generate(ctx: *Context, count: u64) Error!void {
    for (0..count) |_| {
        ctx.source.restart(.{ .prng = 61 });
        var driver: Driver = .{};
        var machine: sd.Machine(Model) = .init(0);
        try machine.run(ctx.io, ctx.gpa, &ctx.source, &driver, .{ .average_commands = 16 });
        if (machine.completed == 0) return error.UnexpectedResult;
        ctx.sink +%= machine.completed + machine.state;
    }
}
pub fn search(ctx: *Context, count: u64) Error!void {
    const Op = lin.Operation(Model.Input, Model.Output);
    // Reads all overlap, but no increment exists to explain the final response.
    // Every prefix is legal; naive search repeats equivalent permutations.
    var history: [9]Op = undefined;
    for (&history) |*op| op.* = .{ .invocation = 0, .input = .read, .response = .{ .at = 10, .output = 0 } };
    history[8].response.?.output = 1;
    for (0..count) |_| {
        var result = try lin.check(ctx.io, ctx.gpa, Model, 0, &history, .{});
        defer result.deinit();
        if (result.status != .violation) return error.UnexpectedResult;
        ctx.sink +%= result.steps;
    }
}
pub fn ordered(ctx: *Context, count: u64) Error!void {
    const Op = lin.Operation(Model.Input, Model.Output);
    var history: [64]Op = undefined;
    for (&history, 0..) |*op, i| op.* = .{ .invocation = i * 2, .input = .increment, .response = .{ .at = i * 2 + 1, .output = @intCast(i + 1) } };
    for (0..count) |_| {
        var result = try lin.check(ctx.io, ctx.gpa, Model, 0, &history, .{});
        defer result.deinit();
        if (result.status != .linearizable) return error.UnexpectedResult;
        ctx.sink +%= result.steps;
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var ctx: Context = .{ .gpa = init.gpa, .io = init.io, .source = try .init(init.gpa, .{ .prng = 61 }) };
    defer ctx.source.deinit();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const rows = [_]measuring.Row(Context, Error){
        .{ .name = "model/trace-64", .unit = "trace", .run = trace },
        .{ .name = "model/generate-seed61", .unit = "trace", .run = generate },
        .{ .name = "linearizable/ambiguous-9", .unit = "history", .run = search },
        .{ .name = "linearizable/ordered-64", .unit = "history", .run = ordered },
    };
    try measuring.run(Error, init.gpa, init.io, &output.interface, &ctx, &rows, .{ .commit = @import("bench_options").commit }, .{ .smoke = smoke });
    std.mem.doNotOptimizeAway(ctx.sink);
}
