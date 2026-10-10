# shakedown

Work in progress: network simulation, simulated processes, exhaustive schedule
search, stateful models and bounded linearizability checking are implemented.

shakedown tests Zig code written against `std.Io`. A `Sim` is a simulated `Io`
that runs the code's tasks one at a time and owns their time, so one seed
reproduces a whole run, schedule included. `check` runs a property over many
generated cases and shrinks a failure to its smallest form, schedules included.
The rest are test doubles: a `Clock` moves time only when the test moves it,
a `FaultIo` counts, traces and fails any `Io` call by plan, `everyFault`
injects every single fault at every step of an operation, a `Layer` overrides
some `Io` slots and forwards the rest, and five allocators count memory,
quarantine it, refuse to resize it, see a free of memory that still holds a
secret, or see a call made while a lock is held.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/shakedown`, mark the dependency `.lazy = true`
in `build.zig.zon`, and add the `shakedown` module only to your test modules'
imports. It is a test dependency: production code never imports it.

shakedown's API carries aegis's types (task ids, byte counts, limits), so a build
should link one aegis. A project with aegis in its own graph fetches shakedown
with `.aegis = .consumer` and binds it to its own, and shakedown's pin is then
never fetched:

```zig
const shakedown = try b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
@import("shakedown").useAegis(shakedown, aegis.module("aegis"));
```

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

With `advance = .{ .auto = .{ .late = d } }` time moves by itself instead: each
timer fires as it is armed, the clocks moving to its deadline and `d` past it, as
a sleeper that resumes late. That suits code whose own waits move its time, with
no test thread to move it: a retry loop sleeps through its backoff at once, and a
loop that measures its intervals sees each one end late.

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
`Quarantine.Options.reuse_after` is a byte count (`aegis.units.Bytes(usize)`), not
a page count.

`alloc.Unwiped` is given the bytes that must not outlive their owner (a key, a
token, a password) and scans every block as it is freed, counting the blocks that
still held one and keeping the first with the frames of its free. It refuses
resizes, so a block that shrinks or moves is freed with the contents it had.
`alloc.Erased` checks the stronger promise, every byte of every block zero by
its free, those never written too. Both see a free as the allocator receives
it, and `Allocator.free` fills a block with `undefined` first wherever runtime
safety is on: in Debug and ReleaseSafe the bytes of such a free never reach
them, whatever the program did. They count such a block as `unseen`, and their
`expectNone` and `expectErased` skip the test rather than pass it. A free
through `rawFree`, as code that wipes its secrets itself makes it, is seen in
every build. `alloc.LockProbe` is given a lock
(`Held.guarded` for an aegis `Guarded`, `BlockingGuarded` or `Order.Ordered`, `Held.flag` for an atomic flag,
`Held.mutex` for `std.Io.Mutex`, `Held.spinMutex` for `std.atomic.Mutex`) and counts the allocator
calls made while it is held, keeping the first with its frames. It reads the lock
and never takes it, and a lock does not say who holds it: it reports a call made
while anyone held the lock, which is the question for a lock the code takes itself
on a test's one thread, and for a lock inside which nothing may allocate. Both are
thread-safe, and `expectNone` or `expectErased` prints the first offender.

`FaultIo` wraps every `Io` slot and every `operate` operation, by code generated
from `Io.VTable` and `Io.Operation`, and forwards each call to its base. Each
call takes a step from the run's `Steps` and is counted. A plan is a list of
entries, each a trigger and a fault: the n-th call matching a call and a path
(`Match`: exact, prefix, suffix or contains), the call at a given step, or each
matching call with a seeded chance. A fault returns an error from the call's own
error set in place of the call (`fail`), or makes the call and loses its answer,
returning the error after it took effect (`fail_after`, as a write that reached
the disk and then reported `InputOutput`); cuts a read or write short (0 bytes is
no progress, not the end of a stream); lands a cancel; wakes a futex wait with no
one waking it (`spurious_wake`); stalls the call until a cancel ends it, as a read
of a silent terminal does; sleeps on the base first; or runs test code at that
point, and then makes the call or injects the fault its `then` names. A plan that
asks for an error a call cannot return, a cancel where none can land, or a lost
answer from a call that hands back something to release (a file, a socket, a
task, a lock) is refused when it is set.

A cancel lands as std delivers one: at a cancelation point of a task whose cancel
protection is unblocked, which `FaultIo` asks the base. Under blocked protection
no cancel lands and the call is made, and the trace records it unfaulted. A task
that takes the cancel and re-arms it with `recancel`, as std's `Queue` does when it
reports progress first, meets it again at its next cancelation point. A task is
the thread it runs on, as on std's `Threaded`; under a `Sim` it is the
simulation's task.

The operations of a `Batch` are calls too. Each is counted, stepped, decided and
traced once, by the first await that sees it, so a pump that waits on a read is
seen to submit one read however often it waits. A failure or a short read of
nothing completes a batched operation at once; a stalled one is kept from the
base until the batch is canceled, and an await with nothing else to wait on waits
out its timeout on the base, which a `Clock` makes virtual. A cancel planned on a
batched operation lands on the await. `count` reports calls by
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
something else. A cancel that cannot land, under blocked protection, leaves its
run clean, and `check` is told no fault was injected. `options.lost_answers`
tries each of its errors after the call, at every step that can lose its answer.
Every run's `io.random` draws from `options.random_seed`, so a temp name drawn
from it is the same name in every run.

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
`SHAKEDOWN_TAPE` shrinks the tape it replays when the property fails, so a
long tape the fuzzer found comes back minimal.

### Continuous fuzzing

`shakedown-fuzz` (an artifact of the package, as `shakedown-bench-compare` is)
fuzzes a package's `check` properties off the landing path, for as long as it
is given: `shakedown-fuzz --package ../relic --store ~/fuzz --limit 50M
--sessions 4` runs `zig build test --fuzz=<limit>` (or `--step <name>`, a step
whose every test binary has a property, since the fuzzer refuses one with none)
in the package with
`<store>/<package>/cache` as its cache, so the fuzzer's corpora live outside
the package and grow from session to session. Each property the fuzzer fails
is replayed on its tape (`SHAKEDOWN_TAPE`, which `check` shrinks) and written to
`<store>/<package>/findings/<test>.txt` with the minimal tape, for the
property's `.regressions`. It exits 1 when it found something.

### Exhaustive search

`explore(gpa, ctx, body, options)` runs the same body once for every way its
choices can go, depth first, where `check` samples them: a stateless model
checker over the property's own tape. A choice with more than `max_branch`
alternatives (16 by default: a latency, a byte of `random`, a fault's chance)
keeps its simplest value and is counted in `Exploration.held`; the search spans
the small ones, schedules first. A simulation made with `Case.sim` takes the
bounded schedule (`Sim.Schedule.bounded`): before every call a task makes while
another can run, the search chooses whether it goes on, at most `preemptions`
times a run (2 by default, CHESS's bound), and whenever a task waits, which runs
next; spurious wakes are choices too, at most `spurious_wakes`. `explore` returns
the runs it made and whether the search was complete within `max_runs`; a
failing run is shrunk and reported as `check` reports it, and
`SHAKEDOWN_TAPE` replays it under the same schedule. A body whose choices
change between runs of one tape fails with `Nondeterministic`. A body whose
small choices can always go one step further (an operation a fake may hold
back at every poll) is made finite by `max_deviations`, a delay bound: at most
that many choices other than schedules take a value other than 0.

Orders that differ only in steps that cannot affect each other are run once
(dynamic partial-order reduction with sleep sets, kept sound under the
preemption bound). Two steps affect each other when they touch one simulated
object (a futex, a task, a group, a disk, the network, the pipes, a process)
or one memory. Memory is invisible to the simulation, so `memory = .shared`, the
default, takes every step of every task to touch the same memory: every order
of steps of different tasks is searched. With `.per_process`, a simulated
process and each node's own tasks are separate memories, as separate address
spaces are, and their steps are ordered only by what passes through `Io`: in the
package's own test, two workers on two nodes reporting to a third take 41 runs
instead of 8048. A test whose tasks on different nodes write memory of its own
(a history for `linearizable`, a fake program's recorder) shares that memory
and keeps `.shared`. Under `Case.sim` a simulation allocates from the case's
arena, so a search pays no allocator per run: 53k runs a second of four tasks
contending a mutex on an M3.

### Simulation

`Sim` is one simulated `Io`. Its tasks run one at a time, on fibers of their own
(std's context switch on x86_64 and aarch64, Win32 fibers on Windows) or on
threads that pass a baton, and switch only at `Io` calls. When the running task
blocks, the schedule picks the next ready one: the first ready (`fifo`), any
(`random`), or by probabilistic concurrency testing (`pct`). When none is
ready, time moves to the earliest timer. Every futex-based primitive in std
(`Mutex`, `Condition`, `Event`, `Queue`, `Semaphore`, `RwLock`), `async`,
`concurrent`, groups, `Select`, cancelation with its protection and `recancel`,
sleeps and timeouts, and `random` run on it unchanged. Every call that can return
`error.Canceled` is a cancelation point, those it does not simulate yet too. Where std allows more
than one behaviour the simulation draws one: whether `async` runs the function
at once or starts a task, a spurious futex wake (1% by default), a wake and a
cancel landing together (reporting the cancel hands the wake on to the next
waiter), and, with `yield_per_million`, a switch at any call. The `bounded`
schedule makes every switch a choice (see Exhaustive search). Each draw is made
only when there is a choice, so a tape holds only decisions that could have
gone another way, and a `Case`'s simulation (`Case.sim`) shrinks its schedule
with the case's inputs.

Options are checked when the simulation is made. A `pct` schedule needs a `depth`
of 1 to 16 and a `length` of at least 1; others fail `Sim.init` with
`InvalidSchedule`. `stack_size` is a byte count (`aegis.units.Bytes(usize)`).
A trace of `.window = 0` or `.last = 0` keeps no records, as `.off` does, and
still hashes every call. A task whose context or result wants more alignment
than a task frame gives (64 bytes) cannot start: `async` then runs the function
at once, as std allows, and `concurrent` returns `error.ConcurrencyUnavailable`.
`max_steps` ends a run as `step_limit` when it would make more calls than that.

A run ends `finished`, `failed` with the root task's error, `deadlock` with a
report of every task still waiting (what it waits on, where it was started and
its stack), at a step or time limit, or `stuck`: a watchdog thread notices a
task that makes no `Io` call for ten seconds of real time and ends the run at
its next call, or aborts the process with the report printed when that call
never comes. A simulation starts its watchdog's thread on its first run, unless
`Options.watched_by` hands it a `Sim.Watchdog` it shares; `check` shares one
among all its cases' simulations. `start`, `step`, `runFor` and `runUntil` drive a run a step or a
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

Scheduler steps allocate nothing once a run's tasks exist: timers, futex waits
and run queue slots live in the tasks, and a task that ended is kept, with its
stack, for the next. File mutations allocate their tree versions, persistence
records and changed pages.

`sim.fs()` owns the disk used by the same `sim.io()`: files, directories,
symlinks, hard links, permissions, timestamps, advisory locks and explicit mmap
`read`/`write` calls. Setup with `fs.write` and `fs.mkdir` creates durable data.
Snapshots retain the tree in O(1); sparse images share a radix index and 4 KiB
pages. Name rules can be POSIX, Darwin case folding with canonical Unicode
normalization, or Windows case folding, separators and reserved names. The
Unicode tables use Unicode 16. Timestamp granularity and byte capacity are
configurable. Simulated handles cannot address real OS files.

An inode's live contents and metadata differ from its persisted state. `fileSync`
syncs that inode; on a directory handle it syncs its entry operations.
`fs.flush(handle, kind)` and `fs.flushDir(handle, kind)` let raw-call seams
express durability (`Sim.fsOf(io)` finds a simulation's disk from its `Io`, and
a flush a task makes is a step of the run, a crash point and a record): `writeout` hands changes to the device, `barrier` orders
previous writeouts before subsequent effects, `data` persists contents and
length, and `full` persists metadata too. A device flush also persists earlier
writeouts on this disk. `writeout` includes retrieval metadata, as Darwin
`fsync` and Windows `NO_SYNC` do; Linux `sync_file_range` must not map to it.
The model represents one device, and assumes a successful barrier is honoured.
std's Threaded currently reports `OperationUnsupported` for both hard-link
slots on Windows; the shared conformance checks accept that contract while
checking hard-link identity wherever the operation succeeds.

`fs.crash(.lose_all)` keeps only synced effects; `.keep_all` keeps all pending
effects; `.random` draws sectors, subsets and order from the simulation's source.
`.os_crash` retains completed writeouts without promising power-loss durability.
Crashes invalidate handles and locks. Under `.strict`, pending sectors and entry
operations may persist in any order; `.ordered_metadata` requires a publication's
earlier data first. A rename is indivisible except a Windows rename across
directories, whose two name changes can persist separately. `crashStates(limit)`
returns distinct persisted snapshots, in increasing retained-effect count, with
all allowed sectors and orders. Release each snapshot and the iterator with
`deinit`. Crash materialization and iteration can return `OutOfMemory`.

`everyCrash(gpa, ctx, options)` calls `ctx.setUp(sim)` and `ctx.run(io)`, stops at
every call boundary and after return, then runs `ctx.recover(io)` and
`ctx.check(io)` on each allowed disk image in a fresh simulation. The prefix must
match the clean trace. `max_states` bounds images per point; the returned report's
`bounded` count says how many points exceeded it. `diagnostics` records a failed
recovery's crash point, error and trace. Optional `ctx.tearDown()` releases state
owned by the context. Abandoned tasks do not execute defers, including with an
root-namespace `IoFault.crash` plan, which requires its filesystem enabled.
Explicit nodes use cooperative cancellation through their crash/kill lifecycle.
Application heap state that must survive abandonment belongs to the context.
`corrupt`, `failReads` and `misdirectNextWrite` inject storage faults by inode;
a zero-length `failReads` clears the current bad range.

`corpus.entry` builds one length-prefixed entry for `std.testing.Smith`'s slice
draws, `corpus.entries` a whole fuzz corpus of them, and `corpus.encode` a whole
Smith input from a list of draws, all at compile time. `corpus.repeat("ab", n)`
is `"ab"` written n times, the array product Zig 0.17 dropped: a static,
0-terminated constant like a literal, for any n without raising the eval branch
quota.

## Simulated network

`sim.node("service", .{ .addresses = &.{address} })` creates an isolated disk and
socket namespace. Addresses default to distinct `10.x.x.x` IPv4 addresses; DNS
registration is explicit with `sim.net().dns("service.test", node)`. Hand
`node.io()` to ordinary `std.Io` clients and servers, including `std.http`.
TCP, UDP, Unix sockets and stream socket pairs use no kernel network resources.
Unix paths and loopback addresses belong to the calling node. IPv4 and IPv6
bindings are separate; requesting a dual-stack UDP binding returns
`OptionUnsupported`. Interface queries return `InterfaceNotFound`.

`sim.net().link(a, b, options)` configures both directions. Latency can be fixed,
uniform or exponential; every random choice uses the simulation's Source and
replays on fibers and threads. TCP handshakes take two latency draws. Streams
preserve order and deliver bytes once; loss adds exponential retransmission
backoff starting at 200 ms. Each direction has bounded buffering and partial
writes; full buffers wait through the scheduler. UDP can lose, duplicate and
reorder datagrams. Bandwidth serializes bytes per directed link. A receive
reports datagram truncation and supports peek; sent datagrams survive sender
close. IPv4 limited broadcast requires `allow_broadcast` and reaches registered
IPv4 receivers on the destination port; subnet-directed broadcast is not modeled.
Unsupported protocols and socket modes return their named Io errors.

`partition` queues packets until healing or a 60-second virtual expiry, which
leaves streams timed out. `hold` queues without expiry and `release` resumes
pending delivery. `resetConnections` and `node.kill()` reset streams. A close
is TCP's: a stream that read all it was sent closes in order, its peer reading
what was sent and then the end of the stream (a write to it then resets the
writer), and one that leaves bytes unread resets its peer. `shutdown(.send)`
produces EOF after the queued bytes. Kill cooperatively
cancels the node's tasks while respecting blocked cancellation protection.
`node.crash(policy)` also applies that node's disk crash model and can fail with
`OutOfMemory`. `node.restart(f, args)` starts an owned task; it reports `NodeBusy`
until old live tasks have ended and `SimulationEnded` after a final outcome.

Batches probe every submitted operation and retain blocked submissions. A timed
await returns `Timeout`; `batch.cancel` removes pending work. Canceling a connect
releases both unaccepted endpoints and its handshake. Closed handles never alias
reused sockets. Packet buffers and socket storage are pooled; warmed message
transfer and socket reuse allocate nothing. `Options.net.max_packets` bounds
shared packet storage (1024 by default); packets hold at most 65536 bytes and
UDP datagrams at most 65535. A resource limit reports `SystemResources`;
optional duplicate packets may be dropped when the pool is full. All resources
are released by `sim.deinit()`.

`Sim.Event.node` records the call's Io namespace and `TaskReport.node` records
task ownership; task IDs remain global. Both are distinct id types
(`Sim.NodeId`, `TaskId`) and a trace records them as the numbers they are. Network traces include portable handles,
addresses and bytes. Invalid link parameters fail with `InvalidLink`, including
at `Sim.init`; topology APIs require nodes from the same Sim. Link buffer capacity
is established when a stream connects, so increasing the configured capacity
applies to new connections. `bench/` includes RPC, three-node gossip and model
message workloads, all measured with `shakedown.bench`; CI runs untimed smoke.

## Simulated processes

`sim.programs().register("git", main, .{})` makes `main` a program that
`std.process.spawn`, `run` and `replace` start as a simulated process when the
path they name is `git` or ends in it. `main` is written as `std.start` calls
one: no parameters, `std.process.Init.Minimal` or `std.process.Init`, returning
`void`, `u8` or an error union of those, so a real program's `main` registers
unchanged. Arguments before the `Init` come from the registered tuple:
`register("git", fakeGit, .{&recorder})` gives a fake program the test's state.

A process runs on the node of the one that spawned it, as a task of its own
with tasks of its own. Its `Init.io` is the simulation; its standard handles
(`File.stdin()`, `stdout()`, `stderr()`) are its own streams: pipes
(`StdIo.pipe`, 64 KiB by default, `Options.programs.pipe_capacity`), the null
device (`.ignore`), a file it was handed (`.file`), or its parent's (`.inherit`).
A pipe read waits for bytes or for the writer to close; a write waits for room
and fails with `BrokenPipe` once the reader closed. The environment is the one
given, or the parent's as it started (`Options.programs.environ` for the
test's own); the working directory is per process (`cwd`, `currentPath`,
`setCurrentDir`, `setCurrentPath`), and per node for the test.

A process ends when `main` returns: an error writes `error: <name>` to its
stderr and exits with 1, as `std.start` has it. `Child.kill` ends it at once:
every task it has ends where it stands, and what it held is given back: its
heap and arena (`Init.gpa`, `Init.arena`), its pipe ends (their readers see the
end of the stream), its files and their locks, its sockets. A node that goes
down takes its processes with it. `Child.wait` reports a deadlock with the
process it waits for. Process ids and pipe handles are values no system issues,
so a raw `kill` or `read` on one fails. `std.process.exit`, `fatal` and `abort`
end the real process, the test with it, and `std.debug.print` and `std.log`
write to the real stderr: a simulated program returns from `main`.

A handed pipe end (`.file`, `.inherit`) is the child's own copy, as an inherited
descriptor is: a pipe's side stays open while any copy is. A package whose own
calls start, signal and wait for processes past `std.process` finds the
simulation from its `Io` (`Sim.programsOf`) and makes them there:
`terminal(size)` is a master and a slave, one file each over two pipes, the
slave a terminal to a program (`File.isTty`), with a window size
(`windowSize`, `setWindowSize`); `end(child, term)` ends a child as an uncaught
signal would; `poll(child)` is a wait that does not wait and `waitFor(child,
timeout)` one with a deadline on the simulation's clock. conduit's simulated
route is built on these.

## Scope

- Writes to the test's own stdout and stderr reach the real process.
  `Options.fs = null` disables the disk; `Options.net = null` disables network
  calls. Only registered programs run: there are no real executables in a
  simulation.
- Memory maps synchronize with files only at their explicit `read` and `write`
  calls. Native page faults and implicit mapped-write coherence are outside the
  model. Its name dialects do not model a particular volume's Unicode version.
- It does not reach code that bypasses `Io`: `std.Thread`, spin loops on atomics
  and raw system calls run for real, and a task waiting on them waits in real
  time. Switches happen only at `Io` calls, so a race between two calls is not
  seen.
- It does not detect data races. That is ThreadSanitizer's job.
- It is not a test runner and sets no per-test timeouts.

## Measuring

`shakedown.bench` measures named workloads with a unit, warmup and batches long
compared with the monotonic clock's resolution. JSONL rows retain samples in
acquisition order, best, median, nearest-rank p99 and units per second, with
commit, Zig version, target CPU model and OS. The build marks dirty commits.
`--smoke` executes each selected row once and emits an explicitly untimed row.

A row says what its batches need, all outside the measured region. A `fixture`
(`setup`, optional `teardown`) is built once for the row with `.lifetime = .row`,
and every warmup, calibration and retained batch meets it warm; with `.batch` it
is built before every batch and released after it, for a workload that consumes
or ages its fixture and must not meet its own leavings. `stage(ctx, units)` runs
before each batch, to put the fixture in the state the batch needs (restore it,
or lay out the inputs of `units` units), and `settle(ctx, units)` after it, to
take what the batch left. A workload whose every unit needs its own stage cannot
be batched: `.grow = false` makes each sample exactly `initial` units, held to
the clock's resolution alone (`Options.minimum` is what growth aims at), and a
sample too short to read is `Unmeasurable`. Compose the callbacks' declared error
sets with the workload's as `Row(Context, WorkloadError)`; the runner adds its
own finite errors. Each hook owns the failure of its own: a failed `setup` or
`stage` is not followed by its `teardown` or `settle`, every hook that succeeded
is, and releases what it made before returning an error. The first error is the
one returned.

`shakedown-bench-compare before.jsonl after.jsonl` reports median changes and a
conservative noise band: the sum of each run's largest sample deviation from
its median, with at least three samples in each run before flagging. A beyond-noise flag describes observed variation; it is not a
statistical significance claim and never makes a timing change pass or fail.
Added and removed rows are named. Malformed rows, mismatched units or platforms,
and smoke rows cannot be compared. Build tools can use the fetched package's
`shakedown-bench-compare` artifact. CI smoke-checks and compiles measuring,
with no timing thresholds.

## Platforms

`Clock`, `Layer`, `FaultIo`, `everyFault`, `everyCrash`, `check`, `Counting`, `NoResize` and
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
  linked into the module but aegis.
- [aegis](https://github.com/pedronaugusto/aegis), whose runtime is `std` only:
  the id, byte-count, limit and lock types the simulation and the quarantine are
  built on. A consumer fetches it with shakedown.
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
`-Dstress-threads=N` and `-Dstress-rounds=N` resize it. The cancel tests land a
cancel on a task that holds its protection blocked and on one that does not, and
re-arm one through std's `Queue`, which takes a cancel after a partial put. The
batch tests count each operation once however often it is awaited, and wait out a
stalled read's deadline on a clock. `zig build check` compiles the tests, programs
and example without running them. `zig build bench` builds the benchmarks in
ReleaseFast and runs them, by hand; `zig build test` runs each row once at its
smallest, and nothing times them in CI.

[CI](.github/workflows/ci.yml) runs the source checks and the Linux Debug suite
on every push it is asked for, and before a merge the Debug suite on macOS and
Windows as well, plus the Linux Debug suite on Zig master, which never blocks. `zig build check` cross-compiles for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.


`crashreplay/` checks `Sim.Fs`'s crash model against real file systems, by hand
before a cut and never in CI (Linux, as root): `zig build crash-replay`, then
`sudo zig-out/bin/shakedown-crash-replay --fs ext4 --fs xfs --fs btrfs`. Each
workload (an atomic replace, a synced log, a careless save, an overwrite, files
made and named) runs on a loop disk under dm-log-writes; the log is replayed onto
the disk as it was, one entry at a time, and after each one a snapshot is
mounted, recovered by the file system, and read. Every state it recovers to must
be one `everyCrash` reaches from the same workload on `Sim.Fs`, and the replay
must rebuild the disk the run left. Crash points are the log's prefixes, in
order, as xfstests replays them.
## Licence

MIT. See [LICENSE](LICENSE).

## Stateful models and concurrent histories

`Machine(Model)` generates commands from a `Source`, checks preconditions, calls
a driver and checks responses against pure model transitions. Use `case.source`
inside `check` so inputs, commands and simulated schedules share replay and
shrinking. The caller creates and cleans up a fresh driver per case. The model
declares `State`, `Command`, `Response`, `GenerateError`,
`generate(gpa, source, state)`, `precondition`, `transition`
and `postcondition`; a driver declares `Error` and `run(io, command)`.

`Machine.replay` validates an explicit command trace before side effects. An
invalid shrink candidate returns `InvalidTrace`; a property can translate this
into `Unsatisfiable` to discard it. Generation retries invalid commands within
`max_tries`, then returns `Unsatisfiable`. Exceeding `max_commands` returns
`LimitExceeded`, so a caller must choose whether to discard that case or report
insufficient coverage. Optional caller-owned trace storage retains executed
commands and responses, including a postcondition failure. Model state advances
only on success. Model values and retained responses borrow immutable data; the
caller owns their lifetimes. No allocations occur in Machine itself. Generation receives an explicit
allocator and propagates its declared errors; use `case.gpa` or a caller-owned
arena for command arguments, cleaning up the arena on every outcome.

`linearizable.Operation(Input, Output)` records invocation, input and optional
response timestamp/output. `linearizable.check(io, gpa, Model, initial, history,
options)` checks a pure `Model.step(state, input, output) ?State`. It returns
`linearizable` with a witness of input indices, `violation` only after complete
search, or `unknown` with a limit reason. Free the result with `deinit`.

Closed intervals allow overlap at equal timestamps; use unique event ordinals
when the observation gives exact ordering. Pending operations produce unknown;
this version does not infer their responses or drop them. Search is iterative
and deterministic, with operation, candidate-examination and workspace byte
bounds. A bounded cache remembers fully rejected prefixes; hash matches are
confirmed by the exact placed set and model equality. `Model.equal` may define
state equivalence; otherwise `std.meta.eql` is used. Cache capacity reduces to
fit the byte budget, and saturation affects speed only. Cancellation and allocation failure are errors with full workspace
cleanup. Model callbacks must terminate and keep their snapshots immutable.
Large ambiguous histories can exhaust the search budget; this checker does not
implement automatic partitioning or exhaustive schedule exploration. Independent
journal and ledger fixtures test contracts, without claiming consumer adoption.
