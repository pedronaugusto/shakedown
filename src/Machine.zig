//! Stateful commands over the same choice tape as property inputs and schedules.
const std = @import("std");
const Source = @import("Source.zig");

/// Model declares State, Command, Response, GenerateError, generate(gpa, source, state),
/// precondition(state, command), transition(state, command), and
/// postcondition(before, command, response, after). State is a value snapshot;
/// borrowed data must remain immutable. Generation may draw only from Source.
/// Generated argument storage belongs to the supplied allocator's lifetime;
/// use a Case arena, or a caller-owned arena cleaned up even on generator error.
/// Driver declares Error and run(io, command) Error!Response. The caller owns
/// driver setup, cleanup and any response storage, including on failure.
pub fn Machine(comptime Model: type) type {
    return struct {
        const Self = @This();
        pub const Step = struct { command: Model.Command, response: Model.Response };
        pub const Options = struct {
            average_commands: u32 = 32,
            max_commands: u32 = 256,
            /// Rejection sampling has a deterministic bound per command.
            max_tries: u32 = 100,
            /// Optional borrowed output, filled only for executed commands.
            /// Responses are shallow copies; the caller keeps their data alive.
            trace: ?[]Step = null,
        };
        pub const Error = error{ Unsatisfiable, PostconditionFailed, InvalidTrace, LimitExceeded, TraceFull, Canceled };

        state: Model.State,
        /// Successful transitions, including earlier calls on this machine.
        completed: u64 = 0,
        /// Executed commands written by the most recent call, including a
        /// command whose postcondition failed. The state stays at its predecessor.
        recorded: usize = 0,

        pub fn init(initial: Model.State) Self {
            return .{ .state = initial };
        }

        /// Draw a bounded trace. Use case.source inside check: command spans,
        /// arguments and driver schedule choices then shrink together. Invalid
        /// generated commands are retried; exhaustion discards the case through
        /// check's Unsatisfiable vocabulary. A length bound is an explicit error,
        /// never a successful truncated trace. No storage is allocated here.
        pub fn run(self: *Self, io: std.Io, gpa: std.mem.Allocator, source: *Source, driver: anytype, options: Options) (Error || Model.GenerateError || @TypeOf(driver.*).Error)!void {
            self.recorded = 0;
            var count: u32 = 0;
            while (true) {
                try io.checkCancel();
                const mark = source.begin();
                defer source.end(mark);
                const more = source.more(options.average_commands);
                if (source.overrun()) return error.Unsatisfiable;
                if (!more) return;
                if (count == options.max_commands) return error.LimitExceeded;
                const command = try self.draw(io, gpa, source, options.max_tries);
                try self.execute(io, driver, command, options.trace);
                count += 1;
            }
        }

        fn draw(self: *const Self, io: std.Io, gpa: std.mem.Allocator, source: *Source, tries: u32) (Error || Model.GenerateError)!Model.Command {
            for (0..tries) |_| {
                try io.checkCancel();
                const command = try Model.generate(gpa, source, self.state);
                if (source.overrun()) return error.Unsatisfiable;
                if (Model.precondition(self.state, command)) return command;
            }
            return error.Unsatisfiable;
        }

        /// Validate the entire trace against the model before executing any
        /// command. Deleting a prerequisite is InvalidTrace, so a caller can
        /// discard that shrink candidate rather than accept a different failure.
        /// Validation and execution use the same initial state and pure rules.
        pub fn replay(self: *Self, io: std.Io, driver: anytype, commands: []const Model.Command, options: Options) (Error || @TypeOf(driver.*).Error)!void {
            self.recorded = 0;
            if (commands.len > options.max_commands) return error.LimitExceeded;
            if (options.trace) |trace| if (trace.len < commands.len) return error.TraceFull;
            var state = self.state;
            for (commands) |command| {
                try io.checkCancel();
                if (!Model.precondition(state, command)) return error.InvalidTrace;
                state = Model.transition(state, command);
            }
            for (commands) |command| try self.execute(io, driver, command, options.trace);
        }

        fn execute(self: *Self, io: std.Io, driver: anytype, command: Model.Command, trace: ?[]Step) (Error || @TypeOf(driver.*).Error)!void {
            try io.checkCancel();
            if (trace) |out| if (self.recorded == out.len) return error.TraceFull;
            const response = try driver.run(io, command);
            if (trace) |out| out[self.recorded] = .{ .command = command, .response = response };
            self.recorded += 1;
            const after = Model.transition(self.state, command);
            if (!Model.postcondition(self.state, command, response, after)) return error.PostconditionFailed;
            self.state = after;
            self.completed += 1;
        }
    };
}
