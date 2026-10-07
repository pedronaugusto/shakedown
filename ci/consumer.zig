//! What a project that depends on shakedown and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch, so shakedown's
//! build.zig must work without any of its own CI dependencies.
const std = @import("std");
const shakedown = @import("shakedown");

pub fn main() void {
    _ = &shakedown.Clock.init;
    _ = &shakedown.Layer(struct { unused: u8 = 0 }, .{}).init;
    _ = &shakedown.alloc.Counting.init;
    _ = &shakedown.Sim.init;
    _ = &shakedown.Source.initRecording;
    _ = std;
}
