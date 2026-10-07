# shakedown

shakedown tests Zig code written against `std.Io`. A `Sim` is a simulated `Io`
that runs the code's tasks one at a time and owns their time, so one seed
reproduces a whole run, schedule included. `check` runs a property over many
generated cases and shrinks a failure to its smallest form, schedules included.
The rest are test doubles: a `Clock` moves time only when the test moves it,
a `FaultIo` counts, traces and fails any `Io` call by plan, `everyFault`
injects every single fault at every step of an operation, a `Layer` overrides
some `Io` slots and forwards the rest, and three allocators count memory,
quarantine it, or refuse to resize it.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/shakedown`, mark the dependency `.lazy = true`
in `build.zig.zon`, and add the `shakedown` module only to your test modules'
imports. It is a test dependency: production code never imports it.

## Usage

[examples/usage.zig](examples/usage.zig) tests a retry loop that backs off one second, then two.
The task sleeps on the clock, and the test lets exactly each backoff pass. A
`FaultIo` then fails the first sync of a file whose path ends in `.lock`. The
same retry then runs on a simulation, where time jumps to each timer with no
one moving it, and `check` runs a property, that a number printed and parsed
back is the same number, over a hundred cases.

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

// The retry on a simulation: its tasks, its sleeps and its every
// choice are the simulation's, so no test thread moves time.
const sim = try shakedown.Sim.init(init.gpa, .{ .seed = 1 });
defer sim.deinit();
var tries: std.atomic.Value(u32) = .init(0);
const began = sim.now(.awake);
std.debug.assert(sim.run(retry, .{ sim.io(), 3, &tries }) == .finished);
std.debug.assert(began.durationTo(sim.now(.awake)).nanoseconds == 3 * std.time.ns_per_s);

// A property over a hundred cases. It holds, so `check` returns; one
// that failed would be shrunk, and printed with the tape that replays it.
try shakedown.check(init.gpa, {}, roundTrip, .{ .cases = 100 });
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

### Properties

Every random decision draws from a `Source`, as an integer below a bound, and a
recording source keeps each one on its tape. A choice of 0 is always the
simplest: 0, `false`, the first enum field, the end of a list, no fault, the
first task. The generators in `gen` are laid out so that smaller choices make
simpler values: integers shrink toward 0 with the positive side first, ranges
toward the end nearest 0, lists toward empty, and `any(T)` draws any value of a
type by reflection. A number is one choice. When drawing, about one number in
five is an edge (0, ±1, the type's extremes, powers of two and their
neighbours; ±0, infinities, NaN and the subnormals for floats), and the rest
spread over magnitudes, small as often as large. Only the drawing leans: the
choice recorded is the value, so an edge shrinks toward its neighbours like
any other.

`check(gpa, ctx, body, options)` runs the committed regressions, then
`options.cases` fresh cases, each from its own seed mixed from the run's.
Collections grow over the first half of the cases, so the first failure found is
a small one when a small one exists. A failing case's tape is shrunk: whole
spans (one generator call each) deleted, runs of choices deleted, spans zeroed,
each choice binary-searched down, spans replaced by the spans inside them, equal
siblings sorted, two choices lowered together, value moved from one choice to a
later one, and a deletion paired with a neighbour pushed to compensate. An edit
is kept only when its replay fails the same way and draws a tape shorter, or as
long and smaller choice by choice. The minimal tape is replayed once more for
its notes (`Case.note`) and its error return trace, and printed with the line
that replays it: `SHAKEDOWN_TAPE=<tape>`, or the tape added to
`options.regressions`. `SHAKEDOWN_SEED` and `SHAKEDOWN_CASES` override the seed
and the count. Under `zig build test --fuzz` the same property runs on the
fuzzer's input instead, with the regressions as its corpus, and a failure it
finds prints as a tape. `corpus.fromTape` turns any tape into such an input.

### Simulation

`Sim` is one simulated `Io`. Its tasks run one at a time, on fibers of their own
(std's context switch on x86_64 and aarch64, Win32 fibers on Windows) or on
threads that pass a baton, and switch only at `Io` calls. When the running task
blocks, the schedule picks the next ready one: the first ready (`fifo`), any
(`random`), or by probabilistic concurrency testing (`pct`). When none is
ready, time moves to the earliest timer. Every futex-based primitive in std
(`Mutex`, `Condition`, `Event`, `Queue`, `Semaphore`, `RwLock`), `async`,
`concurrent`, groups, `Select`, cancelation with its protection and `recancel`,
sleeps and timeouts, and `random` run on it unchanged. Where std allows more
than one behaviour the simulation draws one: whether `async` runs the function
at once or starts a task, a spurious futex wake (1% by default), a wake and a
cancel landing together (reporting the cancel hands the wake on to the next
waiter), and, with `yield_per_million`, a switch at any call. Each draw is made
only when there is a choice, so a tape holds only decisions that could have
gone another way, and a `Case`'s simulation (`Case.sim`) shrinks its schedule
with the case's inputs.

A run ends `finished`, `failed` with the root task's error, `deadlock` with a
report of every task still waiting (what it waits on, where it was started and
its stack), at a step or time limit, or `stuck`: a watchdog thread notices a
task that makes no `Io` call for ten seconds of real time and ends the run at
its next call, or aborts the process with the report printed when that call
never comes. `start`, `step`, `runFor` and `runUntil` drive a run a step or a
frame at a time, and `at` starts a task at an instant, for input replay.
`Options.faults` puts a `FaultIo` outermost, drawing its chances from the same
source. `allocator()` lays memory out the same way in every run of a seed, from
a region at a fixed address, so maps keyed by pointer iterate alike;
`expectDeterministic` runs a body twice from one seed and names the first call,
or the first step whose state checksum, differs. `conformance.run` checks any
`Io` against std's guarantees: the simulation, std's threaded `Io`, a `Layer`
and a `FaultIo` all pass it. `pub const panic = shakedown.panic;` in a test's
root prints the seed, the tape and the last calls of the simulation a task
panicked in.

Once a run's tasks exist, a step allocates nothing: timers, futex waits and run
queue slots live in the tasks, and a task that ended is kept, with its stack,
for the next.

`corpus.entry` builds one length-prefixed entry for `std.testing.Smith`'s slice
draws, `corpus.entries` a whole fuzz corpus of them, and `corpus.encode` a whole
Smith input from a list of draws, all at compile time. `corpus.repeat("ab", n)`
is `"ab"` written n times, the array product Zig 0.17 dropped: a static,
0-terminated constant like a literal, for any n without raising the eval branch
quota.

## Scope

- The simulation does not simulate a file system, a network or processes yet:
  those calls fail with `error.Unexpected`, except writes to stdout and stderr,
  which reach them.
- It does not reach code that bypasses `Io`: `std.Thread`, spin loops on atomics
  and raw system calls run for real, and a task waiting on them waits in real
  time. Switches happen only at `Io` calls, so a race between two calls is not
  seen.
- It does not detect data races. That is ThreadSanitizer's job.
- It is not a test runner and sets no per-test timeouts.

## Platforms

`Clock`, `Layer`, `FaultIo`, `everyFault`, `check`, `Counting`, `NoResize` and
`corpus` are portable Zig. A `Sim` runs its tasks on fibers on x86_64 and aarch64
outside Windows, on Win32 fibers on Windows, and on threads elsewhere; the
threads executor runs wherever threads do, and gives the same run of a seed.
Each fiber's stack has an inaccessible guard page below it. The simulation's
fixed-address allocator reserves its region with `mmap` or `NtAllocateVirtualMemory`.
`Quarantine` closes memory with `madvise` and `mprotect` on Linux, macOS and the
BSDs, and with a decommit on Windows. Elsewhere it hands out plain pages and
quarantines nothing; `Quarantine.supported` says which.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing else is
  linked into the module.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI, fetched only in shakedown's own tree.

## Testing

`zig build test` runs the unit suite, the death tests and the example. The
conformance checks run on std's threaded `Io`, through an empty `Layer` and an
empty `FaultIo`, and on simulations on both executors, all three schedules and
eight seeds. A thousand seeds of that workload each repeat their run, and a
digest of their trace hashes is fixed in the test, so a change to what a
simulation decides, or in what order, fails until it is made on purpose; twenty
seeds give the same run on fibers and on threads. Four planted bugs must be
found and shrunk to a few choices: Zig 0.16's condition, which loses a cancel
to a wake; an inbox that loses a wake-up between a check and a reset; a
lock-free stack with an ABA; and work started with `async` and awaited through a
queue it fills, which deadlocks when `async` runs at once. The fixed versions
pass. Ten problems of the shrinking challenge (github.com/jlink/shrinking-challenge)
must shrink, from each of nine seeds, to their canonical minimum (`bound5` to
its size, two one-element lists). A counting allocator shows a run allocates
nothing per step once its tasks exist.

A probe base checks that each slot of an empty `Layer` reaches the same slot of
its base, once and with the base's userdata. The `everyFault` tests save a file
four ways: through a temp file and a rename, which survives every single fault,
with a temp name drawn from `io.random` that is the same in every run; in
place, which one faulted run catches losing the old save; with a leak on an
error path, which an allocator check catches; and with a temp name counted
outside the `Io`, which the determinism check refuses. The death tests run in
child processes: a use after free and a one-byte overflow on a quarantine, and
a simulated task overflowing its stack, must kill them, and a simulated task
that panics under `shakedown.panic` must print its simulation's seed and last
calls first. The clock's stress test
keeps 1,000 threads in timed waits while the clock moves 10,000 times from
another thread, and checks that none hangs and none times out early;
`-Dstress-threads=N` and `-Dstress-rounds=N` resize it. `zig build check`
compiles everything without running it, and `zig build bench` runs the
benchmarks by hand; CI compiles them and never times them.

[CI](.github/workflows/ci.yml) runs the source checks and the Linux Debug suite
on every push it is asked for, and before a merge the Debug suite on macOS and
Windows as well, plus the Linux Debug suite on Zig master, which never blocks. `zig build check` cross-compiles for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
