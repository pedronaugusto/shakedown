//! Swarm testing: per case, a simulation's knobs drawn from the case's
//! source within bounds the test declares, so a run's cases each turn on a
//! different subset of faults and noise and no one has to plan the mix
//! (Groce et al., "Swarm Testing", ISSTA 2012; FoundationDB's randomised
//! knobs). Each knob is two choices: whether it is on in this case, then its
//! value. A choice of 0 is off, the base's own setting, so a failing case
//! shrinks toward the plain configuration and keeps only the knobs its
//! failure needs, at their smallest.
//!
//! Every draw is made when the test asks (`Case.swarm`), from the case's
//! source, so the knobs are on the case's tape with its inputs and replay
//! with it. Nothing about the start of a run is drawn: the clocks start at
//! the base's instants, and only timer lateness and node clock skew vary.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const Source = @import("Source.zig");
const Sim = @import("Sim.zig");

/// The most each knob may draw. A knob whose bound is 0 (or empty) is never
/// drawn and keeps the base's setting.
pub const Swarm = struct {
    /// How many tasks the test starts: drawn in `[min, max]`, shrinking
    /// toward `min`, and handed back for the test to use.
    tasks: Tasks = .{},
    /// Latency added on top of the default link's: its upper end grows by
    /// up to this, so delivery times spread.
    latency: Io.Duration = .zero,
    /// The default link's loss, duplication and reordering, each a chance in
    /// a million up to this.
    loss_per_million: u32 = 0,
    duplicate_per_million: u32 = 0,
    reorder_per_million: u32 = 0,
    /// How late a timer may fire (`Sim.Options.Clock.late`), up to this.
    late: Io.Duration = .zero,
    /// Node clock skew: when on in a case, a node made through
    /// `Swarmed.node` draws its offsets and drift within these
    /// (`Node.Clock.drawn`).
    skew: Sim.Node.Clock.Skew = .{},
    /// Each storage fault's rate on the node-zero disk, up to these.
    storage: Sim.Fs.Faults = .{},
    /// Spurious futex wakes and yields at non-blocking calls, each up to
    /// this many in a million.
    spurious_wake_per_million: u32 = 0,
    yield_per_million: u32 = 0,
    /// What `async` may do, among these, when on; the base's otherwise.
    async_start: []const Sim.AsyncStart = &.{},

    pub const Tasks = struct { min: u32 = 1, max: u32 = 1 };

    /// Whether every bound is one the simulation takes.
    pub fn valid(s: Swarm) bool {
        const rates = [_]u32{ s.loss_per_million, s.duplicate_per_million, s.reorder_per_million, s.storage.rot_per_million, s.storage.latent_error_per_million, s.storage.misdirect_per_million, s.storage.lost_write_per_million, s.storage.sync_lie_per_million, s.spurious_wake_per_million, s.yield_per_million };
        for (rates) |rate| if (rate > 1_000_000) return false;
        return s.tasks.min <= s.tasks.max and s.latency.nanoseconds >= 0 and s.late.nanoseconds >= 0;
    }
};

/// What a case drew: each knob's value, 0 where it is off.
pub const Knobs = struct {
    tasks: u32,
    latency: u64 = 0,
    loss_per_million: u32 = 0,
    duplicate_per_million: u32 = 0,
    reorder_per_million: u32 = 0,
    late: u64 = 0,
    skew: bool = false,
    storage: Sim.Fs.Faults = .{},
    spurious_wake_per_million: u32 = 0,
    yield_per_million: u32 = 0,
    async_start: ?Sim.AsyncStart = null,

    /// The knobs that are on, for the minimal failing case's notes.
    pub fn format(k: Knobs, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("tasks {d}", .{k.tasks});
        if (k.latency != 0) try w.print(", latency +{d} ns", .{k.latency});
        if (k.loss_per_million != 0) try w.print(", loss {d}/M", .{k.loss_per_million});
        if (k.duplicate_per_million != 0) try w.print(", duplicate {d}/M", .{k.duplicate_per_million});
        if (k.reorder_per_million != 0) try w.print(", reorder {d}/M", .{k.reorder_per_million});
        if (k.late != 0) try w.print(", timers late up to {d} ns", .{k.late});
        if (k.skew) try w.writeAll(", node clocks skewed");
        inline for (@typeInfo(Sim.Fs.Faults).@"struct".field_names) |field| {
            const rate = @field(k.storage, field);
            if (rate != 0) try w.print(", {s} {d}", .{ field, rate });
        }
        if (k.spurious_wake_per_million != 0) try w.print(", spurious wakes {d}/M", .{k.spurious_wake_per_million});
        if (k.yield_per_million != 0) try w.print(", yields {d}/M", .{k.yield_per_million});
        if (k.async_start) |start| try w.print(", async {t}", .{start});
    }
};

/// A case's configuration: the options its simulation takes, and the knobs
/// they came from.
pub const Drawn = struct {
    options: Sim.Options,
    knobs: Knobs,
};

/// The base, unchanged, with the fewest tasks: what every knob at 0 gives,
/// and what a sweep's runs take, drawing nothing.
pub fn plain(base: Sim.Options, bounds: Swarm) Drawn {
    return .{ .options = base, .knobs = .{ .tasks = bounds.tasks.min } };
}

/// Draws each knob from `source`, in a fixed order, within `bounds`.
pub fn draw(source: *Source, base: Sim.Options, bounds: Swarm) Drawn {
    aegis.assert.invariant(bounds.valid(), "a swarm's bounds are ones the simulation takes");
    var options = base;
    var k: Knobs = .{ .tasks = bounds.tasks.min + @as(u32, @intCast(source.below(bounds.tasks.max - bounds.tasks.min))) }; // safe: below(n) is at most n, a u32 difference
    if (options.net) |*net| {
        const link = &net.default_link;
        k.latency = knob(source, nanos(bounds.latency));
        if (k.latency != 0) link.latency = widened(link.latency, k.latency);
        k.loss_per_million = drawRate(source, bounds.loss_per_million, &link.loss_per_million);
        k.duplicate_per_million = drawRate(source, bounds.duplicate_per_million, &link.duplicate_per_million);
        k.reorder_per_million = drawRate(source, bounds.reorder_per_million, &link.reorder_per_million);
    }
    k.late = knob(source, nanos(bounds.late));
    if (k.late != 0) options.clock.late = .fromNanoseconds(k.late);
    k.skew = !std.meta.eql(bounds.skew, Sim.Node.Clock.Skew{}) and source.below(1) == 1;
    if (options.fs) |*fs| {
        inline for (@typeInfo(Sim.Fs.Faults).@"struct".field_names) |field| {
            @field(k.storage, field) = drawRate(source, @field(bounds.storage, field), &@field(fs.faults, field));
        }
    }
    k.spurious_wake_per_million = drawRate(source, bounds.spurious_wake_per_million, &options.spurious_wake_per_million);
    k.yield_per_million = drawRate(source, bounds.yield_per_million, &options.yield_per_million);
    if (bounds.async_start.len != 0 and source.below(1) == 1) {
        k.async_start = bounds.async_start[source.below(bounds.async_start.len - 1)];
        options.async_start = k.async_start.?;
    }
    return .{ .options = options, .knobs = k };
}

/// A knob up to `max`: off (0), or on and in `[1, max]`, drawn leaning to
/// the edges as `Source.integer` draws.
fn knob(source: *Source, max: u64) u64 {
    if (max == 0) return 0;
    if (source.below(1) == 0) return 0;
    return 1 + source.integer(max - 1);
}

/// A rate knob: when on, it replaces `into`'s base value.
fn drawRate(source: *Source, max: u32, into: *u32) u32 {
    const drawn: u32 = @intCast(knob(source, max)); // safe: a knob is at most its u32 bound
    if (drawn != 0) into.* = drawn;
    return drawn;
}

/// A duration bound in nanoseconds, as far as a u64 holds.
fn nanos(d: Io.Duration) u64 {
    return std.math.cast(u64, d.nanoseconds) orelse std.math.maxInt(u64);
}

/// `latency` with its upper end `extra` nanoseconds later.
fn widened(latency: Sim.Net.Dist, extra: u64) Sim.Net.Dist {
    const more: i96 = extra;
    return switch (latency) {
        .fixed => |d| .{ .uniform = .{ .min = d, .max = .fromNanoseconds(d.nanoseconds +| more) } },
        .uniform => |u| .{ .uniform = .{ .min = u.min, .max = .fromNanoseconds(u.max.nanoseconds +| more) } },
        .exponential => |e| .{ .exponential = .{ .mean = .fromNanoseconds(e.mean.nanoseconds +| more) } },
    };
}

/// A case's swarmed simulation (`Case.swarm`).
pub const Swarmed = struct {
    sim: *Sim,
    /// How many tasks to start.
    tasks: u32,
    knobs: Knobs,
    /// The bounds node clocks draw within when skew is on.
    skew: Sim.Node.Clock.Skew,

    /// A node of the simulation; its clocks drawn within the swarm's skew
    /// when this case turned skew on, as `options` say otherwise.
    pub fn node(s: Swarmed, name: []const u8, options: Sim.Node.Options) error{OutOfMemory}!*Sim.Node {
        var with = options;
        if (s.knobs.skew) with.clock = .{ .drawn = s.skew };
        return s.sim.node(name, with);
    }
};
