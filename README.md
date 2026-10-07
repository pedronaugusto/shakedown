# shakedown

shakedown is a set of test doubles for Zig code written against `std.Io`. A
`Clock` moves time only when the test moves it, a `FaultIo` counts, traces and
fails any `Io` call by plan, `everyFault` injects every single fault at every
step of an operation, a `Layer` overrides some `Io` slots and forwards the rest,
and three allocators count memory, quarantine it, or refuse to resize it.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/shakedown`, mark the dependency `.lazy = true`
in `build.zig.zon`, and add the `shakedown` module only to your test modules'
imports. It is a test dependency: production code never imports it.

## Usage

[examples/usage.zig](examples/usage.zig) tests a retry loop that backs off one second, then two.
The task sleeps on the clock, and the test lets exactly each backoff pass. A
`FaultIo` then fails the first sync of a file whose path ends in `.lock`.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const shakedown = @import("shakedown");

var clock: shakedown.Clock = .init(init.io, .{});
const io = clock.io();
const start = Io.Timestamp.now(io, .awake);

var attempts: std.atomic.Value(u32) = .init(0);
var task = try io.concurrent(retry, .{ io, 3, &attempts });

// Wait until the task sleeps, then let exactly its backoff pass. Both
// waits share one deadline in real time, on the base.
const patience: Io.Timeout = .{ .deadline = .fromNow(init.io, .{ .raw = .fromSeconds(10), .clock = .awake }) };
try clock.awaitArmed(1, patience);
clock.advance(.fromSeconds(1));
try clock.awaitArmed(1, patience);
std.debug.assert(clock.advanceToNext().?.nanoseconds == 2 * std.time.ns_per_s);
try task.await(io);

std.debug.assert(attempts.load(.acquire) == 3);
std.debug.assert(start.durationTo(.now(io, .awake)).nanoseconds == 3 * std.time.ns_per_s);

// An allocator that counts, for a test that bounds what code allocates.
var counting: shakedown.alloc.Counting = .init(std.heap.page_allocator);
const gpa = counting.allocator();
const bytes = try gpa.alloc(u8, 100);
gpa.free(bytes);
std.debug.assert(counting.peak_bytes == 100);
std.debug.assert(counting.live_bytes == 0);

// Fail the first sync of a file whose path ends in ".lock", and count
// every call on the way.
const dir = try Io.Dir.cwd().createDirPathOpen(init.io, ".zig-cache/shakedown-example", .{});
defer dir.close(init.io);
const fio = try shakedown.FaultIo.init(init.gpa, init.io, .{ .plan = &.{.{
    .at = .{ .nth = .{ .call = .fileSync, .n = 1, .path = .{ .suffix = ".lock" } } },
    .fault = .{ .fail = error.InputOutput },
}} });
defer fio.deinit();
const lock = try dir.createFile(fio.io(), "HEAD.lock", .{});
defer lock.close(fio.io());
if (lock.sync(fio.io())) |_| unreachable else |err| std.debug.assert(err == error.InputOutput);
std.debug.assert(fio.count(.fileSync) == 1);
```
<!-- END GENERATED -->

## Design

Every double is an `Io` built with `Layer(State, overrides)`. A layer's
userdata is its own `state`, and every slot it does not override is forwarded
to its base `Io` with the base's own userdata. Doubles therefore keep their
state in a value instead of a global, and they stack: a `Clock` over
`std.testing.io`, a counting layer over the clock, or the other way round. The
override set is computed from `Io.VTable`, so a slot a later Zig adds is
forwarded with no change here. `io.vtable == &L.vtable` tells whether an `Io`
is a layer of exactly type `L`, and `L.of(userdata)` recovers it inside an
override.

`Clock` owns `now`, `clockResolution` and `sleep`, the timed forms of
`futexWait` and `batchAwaitConcurrent`, and the timeout of `netConnectIp`.
Everything that waits on a timeout goes through those slots: `Io.sleep`,
`Event.waitTimeout`, `Condition` and `Semaphore` timeouts, `Batch` waits and
`operateTimeout`. The awake, boot and real clocks are kept apart. `advance`
moves all three, `suspendFor` moves boot and real but not awake, as a machine
that sleeps does, and `stepReal` moves real time alone, backwards too. The CPU
clocks stay frozen unless `Options.cpu` hands them to the base. Timers fire in
the order the clocks reach them, ties in the order they were armed.

A waiter blocks on the base until its timer fires or its wait is woken, so the
base must keep real time: `std.testing.io` or a `Threaded` of the test's own.
A timer lives on the waiter's stack and the clock allocates nothing. A sleep
waits on its own futex word, which only a firing sets. A timed futex wait
re-checks its timer every `Options.recheck` of real time, 1 ms by default,
because the base computes its own deadlines: a timeout reaches its waiter at
most that late, and a wake from the code under test reaches it at once.
`awaitArmed(n, timeout)` blocks until `n` timers are armed. It is the barrier a
test takes before `advance` when the waiter runs on another task. Its
`Io.Timeout` is read on the base, so one deadline can bound several waits.

`alloc.Counting` counts allocations, frees, resizes, remaps and refusals, and
the bytes live, at their peak and in total. Its counts are plain fields, so it
serves one thread. `alloc.Quarantine` maps every allocation on its own pages and
never hands an address out twice. A free returns the pages to the system and
leaves the range reserved with no access, so a use after free faults at once.
With `guard = .after` the block ends at an inaccessible page, so a one-byte
overflow faults too. Resizes are refused unless the length stays the same, so a
growth moves the block and the old range is quarantined. Each call is a system
call: it is for soak runs and test suites, not for timing. `alloc.NoResize`
refuses every resize and remap, so each growth is an allocation in every run.
`std.testing.checkAllAllocationFailures` counts a first run's allocations and
then fails each in turn; over `std.testing.allocator` alone, a growth is a resize
in place in one run and an allocation in another, and the count moves.

`FaultIo` wraps every `Io` slot and every `operate` operation, by code generated
from `Io.VTable` and `Io.Operation`, and forwards each call to its base. Each
call takes a step from the run's `Steps` and is counted. A plan is a list of
entries, each a trigger and a fault: the n-th call matching a call and a path
(`Match`: exact, prefix, suffix or contains), the call at a given step, or each
matching call with a seeded chance. A fault returns an error from the call's own
error set, cuts a read or write short (0 bytes is no progress, not the end of a
stream), lands a cancel at a cancelation point, sleeps on the base first, or runs
test code at that point. A plan that asks for an error a call cannot return, or a
cancel where none can land, is refused when it is set. `count` reports calls by
kind; the trace keeps every record, the last n or none, and hashes what it keeps
so two runs can be compared. With `track_paths`, the default, opened directories
and files are named by the paths they were opened with, joined across `openDir`,
so a plan can fail the sync of `repo/objects/pack.idx` and not another file.
With an empty plan and the trace off a call costs a step, a count and one bit
test. `random_seed` makes `io.random` reproducible. `allocator(child)` puts
allocations through the same plan, counts and trace, as `.alloc`, `.resize` and
`.remap`. It makes one shim per child, on the first call for that child, and
returns `error.OutOfMemory` when it cannot.

`Plan(Call, Fault)`, `Trace(Event)` and `Steps` are generic, so a package with
raw calls of its own (a seam around system calls `Io` cannot express) plans and
traces them with its own call type on `FaultIo`'s steps. `beginForeign` and
`endForeign` put such a call into `FaultIo`'s plan and trace as `.foreign`, and a
`Layer` over the `FaultIo` routes the seam's hook while every other slot reaches
the `FaultIo` unchanged.

`everyFault(gpa, base, ctx, options)` makes one clean run of the operation `ctx`
describes, then one run per step and per fault that applies there: each error
in `options.errors` the call can return, a cancel, short reads and writes, and a
refused allocation. Each run is `ctx.setUp`, `ctx.run`, `ctx.check`, then
`ctx.tearDown`: `check` judges what the run left behind before `tearDown`
releases it, and `tearDown` follows every run whose `setUp` succeeded, a failing
one too. Every faulted run must make the same calls as the clean run up to its
fault, or `everyFault` fails as `Nondeterministic` and names the first record
that differed. It therefore never reports a pass for a run that tested
something else. Every run's `io.random` draws from `options.random_seed`, so a
temp name drawn from it is the same name in every run.

`corpus.entry` builds one length-prefixed entry for `std.testing.Smith`'s slice
draws, and `corpus.encode` builds a whole Smith input from a list of draws at
compile time. `Source` is the one source of random decisions; for now it is a
seeded generator whose draws are fixed per seed on every target.

## Scope

- It does not simulate a scheduler, a file system or a network yet. Code that
  waits on a `Clock` runs on real threads of the base `Io`, and `everyFault`
  over several tasks on a threaded base is refused as nondeterministic.
- It does not shrink a failing run yet.
- It does not control time for code that bypasses `Io`: `std.Thread`, spin loops
  on atomics and raw system calls see real time.
- It does not detect data races. That is ThreadSanitizer's job.
- It is not a test runner and sets no per-test timeouts.

## Platforms

`Clock`, `Layer`, `FaultIo`, `everyFault`, `Counting`, `NoResize` and `corpus` are portable Zig. `Quarantine` closes
memory with `madvise` and `mprotect` on Linux, macOS and the BSDs, and with a
decommit on Windows. Elsewhere it hands out plain pages and quarantines nothing;
`Quarantine.supported` says which.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing else is
  linked into the module.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI, fetched only in shakedown's own tree.

## Testing

`zig build test` runs the unit suite, the quarantine death tests and the
example. A probe base checks that each slot of an empty `Layer` reaches the same
slot of its base, once and with the base's userdata. The `everyFault` tests save
a file four ways: through a temp file and a rename, which survives every single
fault, with a temp name drawn from `io.random` that is the same in every run; in
place, which one faulted run catches losing the old save; with a leak on an
error path, which an allocator check catches; and with a temp name counted
outside the `Io`, which the determinism check refuses. The death tests run in
child processes: a use after free and a one-byte overflow must kill them. The
clock's stress test keeps 1,000 threads in timed waits while the clock moves
10,000 times from another thread, and checks that none hangs and none times out
early; `-Dstress-threads=N` and `-Dstress-rounds=N` resize it. `zig build check`
compiles everything without running it, and `zig build bench` runs the
benchmarks by hand; CI compiles them and never times them.

[CI](.github/workflows/ci.yml) runs the source checks and the Linux Debug suite
on every push it is asked for, and before a merge the Debug suite on macOS and
Windows as well, plus the Linux Debug suite on Zig master, which never blocks. `zig build check` cross-compiles for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
