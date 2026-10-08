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

`bench.Row.run` performs exactly the requested units, retains observable results
and leaves its context reusable. A real monotonic clock measures the workload,
independently of any simulated clock. Bounded calibration doubles the workload
quantum until samples exceed the minimum duration and clock-resolution multiple;
unresolved rows return an error. Workload setup and teardown count when the
workload includes them. Smoke executes each selected row once without timing.

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
driver owns real state and cleanup. Command spans encompass driver draws, so a
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
This pruning preserves exactly the legal topological orderings. A full accepting
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
