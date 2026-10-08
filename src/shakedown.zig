//! Test doubles and deterministic testing for code written against `std.Io`.
//!
//! A test-only dependency: nothing here belongs in a program's production
//! build.

const every = @import("every.zig");

/// An `Io` that overrides some vtable slots and forwards the rest to a base.
pub const Layer = @import("layer.zig").Layer;
/// The override set of a `Layer`: one optional function per `Io.VTable` slot.
pub const Overrides = @import("layer.zig").Overrides;
/// A manual clock over a base `Io`: time moves only when the test moves it.
pub const Clock = @import("Clock.zig");
/// Allocators for tests: `Counting`, `Quarantine` and `NoResize`.
pub const alloc = @import("alloc.zig");
/// Test inputs built at compile time: fuzz corpus entries in
/// `std.testing.Smith`'s input format, and repeated text.
pub const corpus = @import("corpus.zig");
/// The one source of random decisions in a test.
pub const Source = @import("Source.zig");
/// The step counter one run's plans and traces share.
pub const Steps = @import("Steps.zig");
/// A test on a call's subject path.
pub const Match = @import("match.zig").Match;
/// When calls fail, as data: entries of a trigger and a fault.
pub const Plan = @import("plan.zig").Plan;
/// The record of what a run did, step by step, with a rolling hash.
pub const Trace = @import("trace.zig").Trace;
/// Every `Io` call `FaultIo` can count, trace and fault.
pub const IoCall = @import("io_call.zig").IoCall;
/// What `FaultIo` can do to a call.
pub const IoFault = @import("io_call.zig").IoFault;
/// One call through `FaultIo`, as its trace records it.
pub const IoEvent = @import("io_call.zig").IoEvent;
/// `Plan` over `Io` calls.
pub const IoPlan = FaultIo.IoPlan;
/// `Trace` of `Io` calls.
pub const IoTrace = FaultIo.IoTrace;
/// An `Io` that counts, traces and faults every call it forwards.
pub const FaultIo = @import("FaultIo.zig");
/// Every single fault at every step of an operation, with a determinism check.
pub const everyFault = every.fault.everyFault;
/// What `everyFault` tries, and what it keeps when a run fails.
pub const EveryFaultOptions = every.fault.EveryFaultOptions;
/// Why `everyFault` failed.
pub const EveryFaultError = every.fault.EveryFaultError;
/// What `everyFault` did, and how a failing run failed.
pub const EveryFaultReport = every.fault.EveryFaultReport;
/// The fault one of `everyFault`'s runs injected, and where.
pub const Injected = every.fault.Injected;
/// Values drawn from a `Source`, a smaller tape a simpler value.
pub const gen = @import("gen.zig");
/// A recorded run's choices and spans.
pub const Tape = Source.Tape;
/// A property run as many seeded cases, its failures shrunk.
pub const check = @import("check.zig").check;
/// One run of a property's body.
pub const Case = @import("check.zig").Case;
/// How `check` runs a property.
pub const CheckOptions = @import("check.zig").CheckOptions;
/// Why `check` failed.
pub const CheckError = @import("check.zig").CheckError;
/// How a property failed: its minimal tape and its report.
pub const CheckReport = @import("check.zig").CheckReport;
/// One simulated `Io` that owns time, tasks and randomness.
pub const Sim = @import("Sim.zig");
/// One call into a `Sim`, as its trace records it.
pub const SimEvent = Sim.Event;
/// Two runs of one seed must make one run.
pub const expectDeterministic = @import("determinism.zig").expectDeterministic;
/// How `expectDeterministic` runs its body.
pub const DeterminismOptions = @import("determinism.zig").DeterminismOptions;
/// Where two runs of one seed parted.
pub const DeterminismReport = @import("determinism.zig").DeterminismReport;
/// Why `expectDeterministic` failed.
pub const DeterminismError = @import("determinism.zig").DeterminismError;
/// Every std.Io guarantee as a check, run against any Io.
pub const conformance = @import("conformance.zig");
/// A panic handler that names the simulation a panicking task ran in.
pub const panic = Sim.panic;

/// Recover every reachable disk state before each call and after return.
pub const everyCrash = every.crash.everyCrash;
pub const CrashEveryFaultOptions = every.crash.CrashEveryFaultOptions;

/// Named benchmark workloads, resolution-aware measurement and run comparison.
pub const bench = @import("bench.zig");

/// Stateful command generation, replay and postcondition checking.
pub const Machine = @import("Machine.zig").Machine;
/// Bounded model-based checking of concurrent operation histories.
pub const linearizable = @import("linearizable.zig");
