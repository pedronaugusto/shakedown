//! Node zero's simulated disk. The owning Sim controls its lifetime.
//! Snapshots and crash states own references, released with deinit.
const std = @import("std");
const Io = std.Io;
const Model = @import("fs/Model.zig");
const Fs = @This();

pub const Options = Model.Options;
pub const Durability = Model.Durability;
pub const CrashPolicy = Model.CrashPolicy;
pub const Flush = Model.Flush;
pub const Snapshot = Model.Snapshot;
pub const CrashStateIterator = Model.CrashStateIterator;
pub const SetupError = Model.Error;
pub const ReadError = Model.Error;
pub const StorageError = Model.Error;
pub const FlushError = Model.Error;
pub const CrashError = error{OutOfMemory};

/// Private: the tree, handles, images and persistence journal owned by this Sim.
model: *Model,
/// Private: the owning simulation's real clock, installed after Core reaches its final address.
clock: ?*const i64 = null,
/// Private: the owning simulation's step around a raw sync, installed with
/// `clock`, so a sync a task makes is a step of the run.
stepper: ?Stepper = null,

/// Private: how the owning simulation makes a raw sync one of its steps.
pub const Stepper = struct {
    core: *anyopaque,
    flush: *const fn (core: *anyopaque, fs: *Fs, handle: Io.File.Handle, kind: Flush, dir: bool) FlushError!void,
};

fn setTime(fs: *Fs) void {
    if (fs.clock) |clock| fs.model.at = .fromNanoseconds(clock.*);
}

/// Create a durable setup file, including any missing parents.
pub fn write(fs: *Fs, path: []const u8, bytes: []const u8) SetupError!void {
    fs.setTime();
    return fs.model.write(path, bytes);
}
/// Create durable setup directories, including any missing parents.
pub fn mkdir(fs: *Fs, path: []const u8) SetupError!void {
    fs.setTime();
    return fs.model.mkdir(path);
}
pub fn read(fs: *Fs, gpa: std.mem.Allocator, path: []const u8) ReadError![]u8 {
    return fs.model.read(gpa, path);
}
/// Power loss invalidates handles and locks. Allocation failure leaves storage intact.
pub fn crash(fs: *Fs, policy: CrashPolicy) CrashError!void {
    return fs.model.crash(policy);
}
/// Increasing retained-effect count; distinct persisted states, up to limit.
pub fn crashStates(fs: *Fs, limit: u32) error{OutOfMemory}!CrashStateIterator {
    return fs.model.crashStates(limit);
}
/// O(1). Release once with Snapshot.deinit; restore borrows the reference.
pub fn snapshot(fs: *Fs) error{OutOfMemory}!Snapshot {
    return fs.model.snapshot();
}
/// Restore storage only, invalidating handles and locks. The allocator must match.
pub fn restore(fs: *Fs, snap: Snapshot) void {
    fs.model.restore(snap);
}
pub fn corrupt(fs: *Fs, path: []const u8, offset: u64, len: u32) StorageError!void {
    return fs.model.corrupt(path, offset, len);
}
pub fn failReads(fs: *Fs, path: []const u8, offset: u64, len: u32) StorageError!void {
    return fs.model.failReads(path, offset, len);
}
pub fn misdirectNextWrite(fs: *Fs, path: []const u8, to_offset: u64) StorageError!void {
    return fs.model.misdirectNextWrite(path, to_offset);
}
/// Raw durability for seams: a device flush covers earlier writeouts on this disk.
/// Made by a simulated task, it is a step of the run like any `Io` call: a
/// place the schedule may switch, a crash point, and a record in the trace.
pub fn flush(fs: *Fs, handle: Io.File.Handle, kind: Flush) FlushError!void {
    if (fs.stepper) |s| return s.flush(s.core, fs, handle, kind, false);
    return fs.model.flush(handle, kind);
}
/// `flush` of a directory handle.
pub fn flushDir(fs: *Fs, handle: Io.Dir.Handle, kind: Flush) FlushError!void {
    if (fs.stepper) |s| return s.flush(s.core, fs, handle, kind, true);
    return fs.model.flushDir(handle, kind);
}
/// Private: the sync itself, at the simulation's current time.
pub fn flushNow(fs: *Fs, handle: Io.File.Handle, kind: Flush, dir: bool) FlushError!void {
    fs.setTime();
    return if (dir) fs.model.flushDir(handle, kind) else fs.model.flush(handle, kind);
}
pub fn dump(fs: *const Fs, w: *Io.Writer) Io.Writer.Error!void {
    return fs.model.dump(w);
}
