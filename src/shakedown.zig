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
