//! Test doubles and deterministic testing for code written against `std.Io`.
//!
//! A test-only dependency: nothing here belongs in a program's production
//! build.

/// An `Io` that overrides some vtable slots and forwards the rest to a base.
pub const Layer = @import("layer.zig").Layer;
/// The override set of a `Layer`: one optional function per `Io.VTable` slot.
pub const Overrides = @import("layer.zig").Overrides;
/// A manual clock over a base `Io`: time moves only when the test moves it.
pub const Clock = @import("Clock.zig");
/// Allocators for tests: `Counting` and `Quarantine`.
pub const alloc = @import("alloc.zig");
/// Fuzz corpus entries in `std.testing.Smith`'s input format.
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
pub const everyFault = @import("every_fault.zig").everyFault;
/// What `everyFault` tries, and what it keeps when a run fails.
pub const EveryFaultOptions = @import("every_fault.zig").EveryFaultOptions;
/// Why `everyFault` failed.
pub const EveryFaultError = @import("every_fault.zig").EveryFaultError;
/// What `everyFault` did, and how a failing run failed.
pub const EveryFaultReport = @import("every_fault.zig").EveryFaultReport;
/// The fault one of `everyFault`'s runs injected, and where.
pub const Injected = @import("every_fault.zig").Injected;
