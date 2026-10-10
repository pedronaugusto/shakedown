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
- A C or OS boundary. `Quarantine` and `executor` do page arithmetic on `usize`
  for `mmap`, `mprotect` and `madvise`, and the fiber layout does stack arithmetic
  for the first frame.

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
and do not establish their adoption or correctness. B7 schedule exploration and
process simulation remain outside this implementation.
