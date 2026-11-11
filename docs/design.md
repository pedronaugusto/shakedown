# shakedown design

## Simulation ownership

`Sim` owns its scheduler, filesystem and network models. Model state sits below
its `std.Io` slots; public `Net` and `Node` facades control topology and node
lifecycle. `Layer` routes each node through the shared `FaultIo`, preserving
outer fault counters. Node disks, Unix paths and loopback sockets have isolated
namespaces, while task IDs remain global. Trace events record node identity,
portable handles, addresses and bytes so a seed replays across fibers and threads.

Virtual socket handles encode monotonic IDs in the platform's handle
representation, including opaque Windows handles. Those pointers are never
dereferenced. IDs order queued accepts and are hashed as portable little-endian
u64 values; stale closed handles cannot alias new sockets.

TCP preserves byte order and exactly-once delivery, with bounded buffering,
partial writes and loss-driven retransmission. UDP models loss, duplication,
reordering, truncation and peek. Sent datagrams survive sender close. Random
latency and delivery choices use the simulation's `Source`, without host network
resources. Cancellation releases unaccepted connect endpoints and handshakes;
batch cancellation removes pending submissions without consuming unsent bytes.

The shared packet pool is bounded and warmed message/socket reuse allocates
nothing. Link capacity is established at connect time; later increases apply to
new connections. Invalid configuration and resource exhaustion return named
errors. Partitioned or permanently lost stream traffic has bounded virtual
expiry; explicit holds wait for release. Kill and crash cancel node tasks
cooperatively, and restart waits for the previous live tasks to end. Crash also
applies the node's disk model and can fail with allocation failure.

The README specifies resource limits and unsupported network modes. IPv4 and
IPv6 bindings remain separate; dual-stack UDP and interface discovery are
unsupported. The model supports limited IPv4 broadcast, not subnet-directed
broadcast. Reader and HTTP adapters use the supported Io surfaces directly.

## Storage faults

The disk model holds two images per file: what reads return (the page cache)
and what storage holds durably, with the pending effects between them that a
crash may keep. Device faults are one model with two ways to drive it. A test
names a file and a range (`corrupt`, `failReads`, `misdirectNextWrite`), or
`Fs.Options.faults` sets a chance in a million for each kind, and the calls
the code under test makes through the simulation's `Io` draw them from the
run's source. Either way they go through the same three operations: invert a
range in both images, mark a range unreadable, land a write elsewhere. A drawn
fault is a choice on the tape. A failing case therefore shrinks to the faults it
needs and replays them, and a choice of 0 is always no fault. Setup and the
test's own `read` draw nothing, so a test's fixtures are what it wrote.

Faults on reads fall on sectors at rest: those of the file that no write or
length change waits over for writeout. A sector the cache holds dirty is read
from the cache, and a device fault beneath it cannot reach the read. A
read draws at most one new fault of each kind. Its chance is the rate times
the sectors at rest it reaches, and a second choice picks the sector. So a
megabyte read costs two choices, not two thousand, and a tape stays within
`max_choices`. Bit rot inverts every bit of the sector in both images, which
is what `corrupt` does to a range. A latent sector error adds the sector to
the file's bad ranges, as `failReads` does. Bad ranges are part of storage:
they survive a crash, a snapshot holds them, and a digest tells two trees
apart by them. A write that covers bad bytes makes them readable again, as
a drive remaps a sector when it is written, and a truncation drops what the
file no longer holds. A file's ranges are kept disjoint and in order, so a
write splits at most one.

A misdirected write lands whole at another sector of the same file, at the
same offset within its sector, inside the size the file has after the write.
It is drawn once per write the file system makes, and only when the file has
another such sector, so a write to a one-sector file draws nothing. The
bytes it should have replaced keep what they held. The file's size is what
the write asked for: a misdirected append leaves zeros where its bytes
should be, and a crash may keep the growth without the bytes. The model holds
no other file's blocks, so a write never lands in another file.

A lost write is one the device reports done and never stores. The model
writes it to the cache image and keeps a third image per file: what the
device would hold once every write reached it. A sync makes that image
durable, not the cache. A later write reaches both, so it does persist, and a
crash drops the third image with the cache. A lost write records no effect
for a crash to keep. Its size and timestamps are metadata the file system
writes apart, and they are recorded. This is the fault that loses data a
sync promised. A torn write keeps only some sectors of a write no sync has
covered yet, and a crash before a sync loses what was never promised.

A sync that lies returns success and does only what `writeout` does. What it
covered reaches the device's volatile cache, so an OS crash keeps it. Power
loss may keep any subset of it, in any order the barriers allow, until a later
honest `data` or `full` sync on the disk persists it, as a device flush
drains its cache. That is the bound of the lie: exactly the effects pending
when the sync was made, and no longer than the next honest sync. Barriers
stay honoured. A drawn lie is a choice like any other. `everyCrash` explores
lies instead of drawing them. With `lying_syncs = k`, each crash point is
also run with its last 1 to k `data` or `full` syncs lying (the model counts
them, and a run is told which ordinal the lies begin at), and the images
each leaves are recovered like any other. An honest sync persists what
earlier lies left, so the images of any set of lies are among those of the
run of last syncs that begins at its earliest lie. A point after `m` syncs
is run `1 + min(m, k)` times, with at most `max_states` images each. The
digest still recovers each distinct image once. A lie changes nothing the
code under test can see before a crash: reads come from the cache, and read
faults draw over sectors whose writes have been handed to the device, which
a lying sync and an honest one leave alike. So every run of a point makes
the calls the clean run made, and the prefix check holds.

What the model rests on, and where it is taken from: device read errors that
persist until the sector is rewritten, and silent corruption, as field
studies of disk fleets report them (Bairavasundaram et al., SIGMETRICS 2007
and FAST 2008). Misdirected and lost writes as Krioukov et al. define them (FAST
2008: a misdirected write lands at the wrong location and the intended one
keeps old data; a lost write is reported done and never written). A drive remapping a pending sector when it is written, as drive
vendors and smartmontools describe. These are recalled, not re-read. Syncs that lie: macOS documents that
`fsync` does not ask the drive to empty its cache and that `F_FULLFSYNC`
does (Apple's fsync(2) manual page). On Linux, a failed writeback can mark
the pages clean, so a later `fsync` succeeds with the data never stored
(LWN, "PostgreSQL's fsync() surprise", 2018). The model's lie is the first
kind, a device cache that a flush did not drain. The second is a lost write
seen through the cache. The
faults are opt-in and the defaults are honest storage, so no existing test
draws a new choice.

## Measurement contracts

`bench.Row(Context, WorkloadError)` declares callback, `fixture` and `stage` /
`settle` hook errors. Callers compose the callbacks' finite declared error
sets as `WorkloadError`; `RunError(WorkloadError)` adds named runner failures.
`run(ctx, units)` performs exactly the requested units and retains observable
results. Only the workload callback lies between the timer timestamps; setup
and teardown inside it still count.

A batch (warmup, calibration, retained and discarded samples, smoke) is
`stage(units)`, `run(units)`, `settle(units)`. The fixture's lifetime is the
workload's choice, with no default: `.row` builds it once before the row's first
batch and releases it after its last, so the batches meet one warm fixture and
`stage` puts back whatever a batch changed; `.batch` builds and releases it
around every batch, so nothing carries between batches, at the price of a cold
fixture each time. A fixture rebuilt for every calibration and warmup batch
made rows that only read their fixture measurably slower than the same code
held warm; the choice is explicit so that neither shape is a silent default.
`stage` and `settle` are told the batch's units, so a batch can stage the
inputs of all of them; the batch is bounded by `Options.max_batch`. A row that
cannot be batched sets `grow = false`: every sample is `initial` units, there is
no calibration, `Options.minimum` (the target of growth) does not apply, and a
sample under `resolution_multiple` clock ticks is `Unmeasurable`.

Setup failure stops the row or batch before any workload or teardown; each hook
owns cleanup of partial acquisitions through `errdefer`. A failed `stage` is
followed by no run and no settle. Every hook that succeeded is followed by its
counterpart exactly once, even when the workload fails, and the counterpart owns
releasing resources before returning an error. The first error is returned:
stage, then run, then settle, then teardown. No failed row emits a row of
results. Runner allocations are released on all exits. Drivers retain their
paired/interleaved base-candidate schedule; the runner never reorders
invocations or samples.

A real monotonic clock measures the workload, independently of any simulated
clock. Bounded calibration doubles the workload quantum until samples exceed the
minimum duration and clock-resolution multiple; unresolved rows return an error.
Smoke executes each selected row once without reading the clock.

JSONL samples remain in acquisition order, in nanoseconds per named unit.
Statistics use an even median and nearest-rank p99. Parsing rejects malformed,
duplicate or inconsistent rows. Comparisons reject incompatible units or
platforms and untimed smoke rows. They report median changes against the sum of
each run's greatest sample deviation, requiring at least three samples to flag
a change. That band describes observed noise, not statistical significance or a
performance pass/fail gate. Added and removed rows are reported explicitly.

Metadata identifies the commit, Zig version, OS and target CPU model; drivers
may supply a physical CPU name. Git revision and dirty status are uncached build
commands, so a rebuild after a commit cannot retain stale source provenance.

## Aegis types and the raw sites

shakedown builds on aegis, whose runtime is `std` only. The module is a test
dependency, but a consumer fetches aegis with it.

What is typed, and what each type catches:

- `TaskId` (`aegis.id.Id`) and `Sim.NodeId` (the network model's) name a task and
  a node. `Event`, `TaskReport`, `Trace.Record` and the watchdog's running-task
  slot carry them, so a task id cannot stand where a node id does, or in a count
  or a digest. Both are the `u32` they were, hashed as that number, so no trace
  hash and no conformance golden moved. `TaskId.fromRaw(0)`, `ids.outside`, is no
  task: calls from the driver. A simulation issues ids with one
  `aegis.id.Counter`, which never wraps: a run that has issued every id cannot
  start another task (`SystemResources`, which `async` answers by running the
  function at once and `concurrent` by `ConcurrencyUnavailable`).
- `Options.max_steps` is checked as an `aegis.bounded.Limit`: a finite maximum, zero
  included, never a sentinel. `Options.stack_size` and `Quarantine.Options.reuse_after`
  are byte counts (`aegis.units.Bytes`), the unit a page count is mistaken for.
- `Quarantine` keeps its tables beside their spin lock as an `aegis.Guarded`, so
  no access to them is made without the lock. A free of memory it never gave out
  stops with a message in every build; the `unreachable` it was let any build do
  anything.
- Contracts that were `std.debug.assert` are errors where the value comes from
  outside (`Sim.init` returns `InvalidSchedule` for a `pct` depth or length out of
  range; a trace window of zero is a trace that keeps nothing; a context a task
  frame cannot align is a spawn that does not happen), and `aegis.assert` where
  the caller is another part of this package (`release` of a task that has not
  ended, a free of a block the allocator does not hold).
- `Core.Start` names how a task begins, in place of a `State` of which four of
  seven values were invalid.

The raw sites that remain, each with the reason it is allowed:

- No danger there. Frame offsets and sizes are bytes of one frame, laid out in one
  function. Futex addresses and their bucket hash are addresses used as numbers.
  `steps`, `ready_seq`, `timer_seq` and `Steps` count up by one from zero.
  Virtual time is `i64` nanoseconds, all clocks in the same unit, every addition
  saturating by design (a sleep of the largest duration is a sleep for ever) and
  every conversion from `Io.Duration` or `Io.Timestamp` made in
  `Core.nanoseconds`, which saturates. aegis's `Instant` and `Duration` now have
  saturating forms, so the reason against adopting them has gone; the clock,
  the network model and the watchdog still keep plain `i64` nanoseconds, and
  moving them is a change of its own, measured on its own.
  `FaultIo`'s key for the calling task is a `u64` of its caller's own choosing over
  any base `Io`: `Sim` hands it the task's number at one place.
  Hashing a task or node id into a trace digest or a seed (the digest of
  a new task, the network's input digests) takes its number.
- Safe-type internals. `net/Model.key` joins two node ids into the link table's
  key, and `net/Model.followerIndex` maps a node id to its place in `Core.contexts`,
  which holds the nodes after the first in the order their ids were issued. Each is
  the one function that knows the representation, in the model that issues the ids.
- A C or OS boundary. `Quarantine` does page arithmetic on `usize` for `mmap`,
  `mprotect` and `madvise`.

The package's glint configuration (`ci/preflight.json`) gates A004 (ids, byte counts and
limits) and Z026 over `src` and `bench`, tests and benchmarks included. A001 to A003,
which watch `Guarded`, are reports: glint decides them only for a receiver whose type
it resolves and an acquisition whose `defer` is the last statement of its block, so on
this code they leave 42 sites undecided, and a gate treats an undecided site as a
failure. They gate once glint can decide the code as written. A site that carries
`glint-ignore` says why; one that glint no longer finds fails as stale.

The tests that guard these types are written with plain integers and without
importing aegis (`src/reference_test.zig`): an event hashed as its plain twin, task
ids against a model of the order tasks start in, the quarantine's eviction against
a model that adds spans and drops the oldest, and its addresses across threads. aegis
runs its own concurrency tests on this simulation, so a flaw shared by the two must
not be able to confirm itself.

## Build-tool boundary

A fetched dependency exposes the `shakedown-bench-compare` executable through
`Dependency.artifact`, registered with `installArtifact`, without fetching this
repository's test or CI dependencies. `ci/bench-consumer` checks that contract
with package fetching disabled. The embedded before/after JSONL files are
comparator test fixtures, not benchmark archives.

Preflight's `Config.bench` owns ReleaseFast build and untimed smoke registration.
The package supplies workload drivers and the comparison artifact; preflight
owns CI planning and build/test wiring. Timing never gates correctness. Manual
benchmark commands and comparator usage are documented in the README.

## Stateful testing and linearizability

Machine has no entropy or storage of its own: the caller supplies a Source and
optional output buffer. Model transitions are pure value snapshots, and the
driver owns real state and cleanup. Generation accepts an explicit allocator
and a declared error set; command arguments have the caller-owned arena lifetime,
including rejected draws and errors. Command spans encompass driver draws, so a
Case tape shrinks inputs and schedule choices together. Preconditions are checked
before driver calls. Explicit replay validates the entire trace before execution;
a removed prerequisite cannot become a spurious driver failure. Trace and length
limits are explicit errors, and generator rejection exhaustion is Unsatisfiable.

The concurrent-history checker borrows closed invocation/response intervals.
A response strictly before another invocation imposes precedence; equality permits
overlap. A pure model accepts or rejects each candidate response. Iterative DFS
keeps one snapshot per depth and considers candidates in input order. Only an
operation whose invocation precedes or equals the earliest remaining response can
be selected: all of its real-time predecessors must already have been placed.
This pruning preserves exactly the legal topological orderings. A bounded
open-addressed cache records fully rejected (placed set, model state) pairs.
An order-independent index fingerprint is confirmed with the exact placed set
and model equality, so collisions cannot prune a distinct state. Models may
supply `equal`; otherwise value equality uses `std.meta.eql`. Equal states must
admit identical future responses. Cache allocation is lazy at the first
backtrack, capacity fits the remaining byte budget, and a saturated or disabled
cache only costs search speed. A full accepting
ordering is a witness; complete rejection is a violation. Search, operation and
workspace limits and pending calls are unknown, never a successful truncated
proof. Cancellation is checked between candidates; all owned arrays unwind on
error, and only a successful witness transfers to the result. Model callbacks
are responsible for terminating and keeping referenced state immutable.

Fixtures independently model register reads/writes, journal append sequence and
reader cursors, and ledger visibility/revisions. A separate whole-permutation
oracle checks randomized small histories. These fixtures do not import consumers
and do not establish their adoption or correctness.

## Exhaustive search

`explore` is a stateless model checker over the `Source`: its `Chooser`
backend answers every draw, depth first along a path of choice points kept
across runs, and a run replays the path's prefix before it leaves it. The
search never owns a simulation: a `Sim` drawing from a searched source reports
what the search needs through the same source (`pick` names the actors a
schedule choice is between, `step` marks where an actor begins a step, `touch`
names what a step touched, `spawned` orders a new task after its parent), and
draws nothing else differently, so a failing run's tape replays under a plain
replaying source.

A step is an actor's run from one call's entry to the next, or to a wait: the
granularity at which the bounded schedule can switch. Its footprint is what the
simulation's calls touched in it (futex, task, group, disk, network, pipes,
process, the fault plan's counters) plus the memory its domain stands for, by
`Bounded.memory`. Reduction is Flanagan and Godefroid's: after each run, every
step's latest dependent step of another actor it does not already follow, by
vector clocks over each object's last write and reads since, is a race, and
the choice before that step must also try this step's actor (or every option,
where it could not run). Where that choice was a preemption, or no choice was
offered because the bound was spent, the actor is also tried where the racing
step's actor was last chosen without one (Coons, Musuvathi and McKinley), so the
bound hides no order. Sleep sets keep the options tried at a choice asleep
until a step they depend on runs; a run that would schedule a sleeping actor
is redundant, counted, and adds nothing to search. With `.shared` memory every
step of every task conflicts, and the reduction searches exactly the orders the
full search does (a test checks it).

The path's choice points keep their actors, options and sleep sets in pools
that grow and shrink with the path, since a point adds to them only while it is
the deepest; a run's steps, accesses and race analysis reuse their room. The
`bounded` schedule draws its preemption choices at every call's entry, keeps the
ready queue in arrival order (so a choice of 0 is the oldest), and gives each
task its own stream for `random`, so independent tasks' bytes do not depend on
their order.

## Targeted search

`check` owns the run: its `Runner` keeps a `target.Targets` while it draws its
own cases. The table holds each label, the highest score the current case
reported, and each label's best passing case (score, choices, bounds). It has
none under `explore`, a replayed tape or the fuzzer, so `Case.target` does
nothing there. `target.climb` knows nothing of `check`. It is given a starting
case and a `Probe` that replays a candidate tape and says whether the property
failed, what the climbed label scored, and what tape the replay drew. The
shrinker is built the same way, around its `Replay`.

The climb keeps one current tape and score. Each scan begins with the spans:
each span with two children or more, from the last back, has its children but
the last written again after themselves, and the first that raises the score is
kept. A list's elements are its children and its closing choice the last, so
this doubles a list in one replay, where a choice at a time grows it by one
fresh tail per replay (Hypothesis's span mutations make the same move). Then
from the last choice back, each choice tries, in each direction, a jump (to its recorded bound, or to 0). The
jump is kept when the score does not fall and the tape grows no longer. Failing
that, a step search: steps of 1 to 4, then doubling, then halving the gap, each
kept only when it raises the score. A replay's tape replaces the current one
whole, since a moved choice can change what every later draw means. After a rise
the scan starts again from the end. A climb ends when a whole scan raises
nothing, after `max_improvements` rises, at a failure, or when its budget is
spent. `check` climbs each label in turn, round after round while any label
rises. Every climb replay is a case (a pass counts toward `cases`, a discard
toward the ten-fold try limit), and the case it draws updates every label's
best, not only the one being climbed.

A candidate replays through `Source.Backend.extend`: its choices, then fresh
draws from a seed. A move that lengthens a list, or lets a task take one more
step, then meets real values rather than the zeros past a replay's end. The seed
is the case seed of the run's next index, so a check's seed fixes its climbs.
Scores are `f64`, compared exactly: a score coarser than its choice, a 64-bit
distance among them, is level across neighbouring values and stops a step
search. The jump exists because shakedown draws a yes-or-no decision as a
threshold inside a wide range (`more`, `chance`): crossing it by steps costs
some forty replays, and one jump does it.

## Points to reach

A property can pass without testing what it was written for: the retry
never ran, the partition never met a write. `CheckOptions.reach` names the
points a run must reach and `Case.reached` marks one. The table lives in the
`Runner`, as the targets do, so nothing outlives the run: per label, whether
the current case reached it and whether a passing case has. A case's marks
count once it passes; a discarded case is not a case, and a failing one ends
the run anyway. Marking draws nothing, so the tape of a case and its
shrinking are the same with points or without them. Once every case has
passed, `check` and `explore` fail with `error.PropertyFailed`, the report
(or `CheckReport`, its `err` `error.Unreached` and its tape empty) naming the
points no case reached. Under `explore` a point counts in any run, so the
search proves a point reachable within its bounds, or, complete, that no run
within them reaches it.

The points are declared in the options rather than registered by their first
mark (Antithesis's `sometimes(condition, label)`): a point whose code never
runs would never be registered, and that is the case this exists for. A mark
of a label the options do not name is not kept, so a helper shared by several
properties may mark points only some of them ask for. The opposite, a point
that must never be reached, needs nothing new: the body returns an error, or a
simulated task does and the run ends `failed`.

## Clocks per node

The simulation keeps one set of clocks, and they drive everything physical:
timers, latencies, `max_time`, `Sim.now`. A node made with `Sim.node` reads
them through a skew kept on its own context (a simulated process on the node
reads its node's): its reading of a clock is the simulation's, plus an offset
per clock, plus `drift_ppm` millionths of the time since the node was made.
Node zero, the test's, keeps the simulation's time, so there is one reference
a test can trust. A skew of zeros is the identity, computed as such, and draws
nothing: a simulation whose options ask for no skew, no steps and no lateness
makes the tapes and traces it made before, and the determinism golden holds.

A timeout is read on the clock of the node whose call waits, and kept, as
before, in the timer queue of its clock kind, at the simulation's reading
where the node's clock reaches the deadline. The skewed time since the node
was made is floor(e × (10^6 + drift) / 10^6) of the simulation's e, so that
reading is an exact ceiling and no search is needed; and since the drift is an
`i20`, the rate stays above zero and a node's clocks never run backwards. A
jump (`Node.stepReal`, `Node.suspendFor`, or a drawn step) changes the node's
offsets, then moves each timer waiting on that node's jumped clocks to where
the new skew reaches the reading it waits for, firing those already reached.
Only the wall clock steps back; `suspendFor` refuses a negative span, and the
monotonic offsets change only forward. A report of a sleeping task gives its
deadline on its node's clock.

What is drawn is drawn from the run's source and is on its tape: a `.drawn`
skew when the node is made (each offset and the drift a choice, 0 the
simplest, then 1, -1, 2, -2, so a shrunk case has the smallest skew that still
fails), a wall-clock step at a read of `.real` by `step_per_million`, and a
timer's lateness when its deadline is computed (`Options.clock.late`, the same
for every node, never for a task of `Sim.at`). The alternative of a lateness
per node was left out: lateness is the load of the machine running the test,
not a property of one simulated machine. The test's own setup writes to a
node's disk (`Fs.write`) stamp the simulation's time; a task's file calls
stamp its node's.

## Liveness after faults heal

`Sim.settle` is the pattern TigerBeetle's liveness mode makes of a run:
faults for a while, then none, then progress within a bound. It ends the
faults it owns: every partition and hold of the network, the fault plan,
which it empties, and the nodes' drawn wall-clock steps. What a fault left behind stays (a stalled call, a node
killed or crashed, a damaged disk), as it would on a real system, and the
links keep their latency and loss, which are the network the test chose. The
run then goes on in a drive mode of its own, `settle`: one step at a time,
as `step` takes them, but never moving time past the bound, as `runUntil`
does not. Between steps the driver asks whether the property holds: every
task ended, or the test's `Progress`, a predicate recovered from the test's
state by `@fieldParentPtr` as a `Hook` is. What is due at the bound itself
runs before the verdict, so a bound of ten seconds admits a timer of ten.

A property that does not hold by the bound is `stalled`, with a report of
every task still alive, gathered as a deadlock's is: the driver switches to
each waiting task, which captures its own stack. A ready task is reported
without one, since switching to it would run it. The run is paused, not
ended: a test may drive it further, or settle again with a longer bound. A
run that ends first is `ended` with its outcome, a deadlock's reports
included. The result is data, as `Outcome` is, and formats as a report a
`check` body keeps as a note before returning its error, so a failing case
shrinks and replays like any other: the faults it drew before the settle are
on its tape.

## Simulated processes

The process model (`sim/programs/Model.zig`) sits below the core and knows no
task: programs by name, process records (id, node, streams, image, environment,
heap, arena, working directory, exit) and the pipes. The core owns the tasks,
so it ends a process: `Core.endProcess` drops every task the process has but the
running one (`Core.drop`: out of the run queue, the futex queue and the timers,
never resumed, nothing unwound), and gives back what the process owned. Every
handle the disk, the network and the pipes issue records the process that
opened it (0 for the test's own), so an end closes exactly the process's own,
locks included; a handle a process was given (`StdIo.file`, `.inherit`) stays
its giver's.

A task's `io_context` names the namespace of the call it makes: node, process
and, through the process, its working directory. File slots whose first
argument is a file pass through `programs/calls.fileSlot`, which turns a
simulated process's standard handles into its streams and answers pipe ends as a
pipe does; everything else reaches the file system unchanged, so traces of code
that spawns nothing are what they were. A pipe operation that would wait
returns null and the caller waits on the stream readiness every socket and pipe
change wakes. `processReplace` starts the new image on a fresh task and retires
the caller (`Core.retire`), so no task ever returns into a replaced image.
Namespaces of processes live in the core's `keep` arena until the simulation
ends: a task's last call may still name one after its process was reaped.

A process is a memory domain of its own by contract: it shares no memory with
its parent but through its streams, files, sockets and exit status, as a real
process cannot.
