# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- `CrashEveryFaultOptions` is `EveryCrashOptions`, and `EveryCrashError` names
  what `everyCrash` returns.
- `alloc.Unwiped.expectNone` decides per block: a free through `rawFree` is
  seen in every build, and only a block `Allocator.free` overwrote first
  (`unseen`) makes it skip. It skipped in every Debug and ReleaseSafe build.

- `Case.sim` allocates the simulation from the case's arena: a case that
  allocates and frees heavily in one long simulation keeps its peak until the
  case ends. A search or a property pays no allocator per case for it.
- A connected stream that closes having read all it was sent closes in order:
  its peer reads what was sent, then the end of the stream; a write to it then
  resets the writer. A close leaving bytes unread resets the peer, as before.

- `Sim` spawns processes: `std.process.spawn` and `run` start the programs
  registered on `Sim.programs()`, and fail with `FileNotFound` for any other,
  where every process call failed with `Unexpected`. `TaskReport.Waiting` adds
  `process`, a wait for a simulated process to end.

- shakedown depends on [aegis](https://github.com/pedronaugusto/aegis), whose runtime is
  `std` only: the id, byte-count, limit and lock types below are its. A consumer
  fetches it with shakedown.
- `Sim.Event.task` and `.node`, `TaskReport.id` and `.node`, `TaskReport.Waiting.task`
  and `Trace.Record.task` are `TaskId` and `Sim.NodeId`, distinct id types, in place
  of `u32`; `.raw()` is the number. A trace records the same numbers, so its hashes
  are unchanged. `Record.task` is `ids.outside`, not 0, for no task.
- `Sim.Options.stack_size` and `alloc.Quarantine.Options.reuse_after` are byte counts
  (`aegis.units.Bytes(usize)`), in place of `usize`: `.stack_size = .fromRaw(64 * 1024)`.
- `Sim.init` and `DeterminismError` add `InvalidSchedule`, for a `pct` schedule
  whose `depth` is not 1 to 16 or whose `length` is 0, which were a failed
  assertion in Debug and out-of-range memory use in release builds.
- `Trace.Mode` `.window = 0` and `.last = 0` keep no records, as `.off` does, in
  place of a failed assertion.
- A task whose context or result wants more alignment than a task frame gives (64
  bytes) cannot start: `async` runs the function at once, `concurrent` returns
  `ConcurrencyUnavailable`. It was a failed assertion in Debug and a misaligned
  frame in release builds.
- A free of memory `alloc.Quarantine` never gave out stops with a message in every
  build, where it reached `unreachable`.

- `bench.Row(Context, WorkloadError)` and `bench.run(WorkloadError, ...)`
  declare finite callback errors; `bench.RunError(WorkloadError)` composes them
  with runner failures instead of widening the public API to `anyerror`.

- `Sim.Event` and `TaskReport` add `node`. The conformance golden changes because
  every trace now records an Io namespace; scheduler choices are unchanged.
  `Sim.init` and `DeterminismError` add `InvalidLink` for invalid network setup.


- Benchmark JSONL uses the shared `bench.Result` schema, with ns/unit samples
  and provenance, replacing the repository's former aggregate-only rows.

- `Sim` now simulates file and directory calls by default. Set `Options.fs = null`
  to disable storage. Its conformance trace digest includes filesystem inputs.
- `EveryFaultReport` adds `bounded`, the count of crash points whose disk-image
  enumeration exceeded the requested bound.

- `IoFault` has `fail_after`, `spurious_wake` and `stall`: a switch over it names
  them.
- A planned `cancel` lands only where std would deliver one: under blocked cancel
  protection the call is made, and the trace records it unfaulted. `everyFault`
  tells `check` no fault was injected in such a run.
- `FaultIo` counts, steps, plans and traces each operation of a `Batch` once, as
  a call of its own, so steps and counts of code that batches include them.

### Added

- A seam's raw sync on `Sim.Fs` (`flush`, `flushDir`) made by a simulated task
  is a step of the run like any `Io` call: the schedule may switch there, it is
  a crash point of `everyCrash`, a search sees it touch the disk, and the trace
  records it as a foreign call. airlock's simulated route syncs through it.
- `Sim.programsOf(io)` and the process seams on `Sim.Programs`, for a package
  whose own calls start, signal and wait for processes past `std.process`:
  `terminal` (a master and a slave, one file each, over two pipes and a
  window size; the slave is a terminal to a program), `pipe`, `windowSize` and `setWindowSize`, `end` (a child ended as
  a term at once, as an uncaught signal does), `poll` (a wait that does not
  wait) and `waitFor` (a wait with a deadline). Each is a step of the run.
- A pipe end handed to a child (`StdIo.file`, `.inherit`) is the child's own
  copy, as an inherited descriptor is: the parent closing its end leaves the
  child's open, and the other side sees the end of the stream only when every
  copy is closed. `File.isTty` and the ANSI calls on a pipe end answer as a
  pipe does, where they returned `error.Canceled`.
- `Sim.fsOf(io)`: the simulated disk an `Io` of a simulation works on (its
  node's), null for any other `Io`, so a seam whose raw calls go past the `Io`
  makes them on the simulation whenever it is handed one.

- `shakedown-fuzz`: continuous fuzzing of a package's properties, its corpora
  in a store outside the package, each failure shrunk and written down as the
  regression to commit. `SHAKEDOWN_TAPE` now shrinks the tape it replays.

- `crashreplay/` (`zig build crash-replay`): real crash replay under
  dm-log-writes on Linux, by hand, checking that every state a real file system
  recovers to is one `Sim.Fs` reaches. ext4, xfs and btrfs, five workloads: every
  recovered state is in the model.

- `alloc.Erased`: checks every block is erased, every byte zero, by the time
  it is freed; valid in every build for frees through `rawFree`, and it counts
  rather than passes the frees `Allocator.free` hid.

- `.aegis = .consumer` and `useAegis` (build.zig): a project with aegis in its own
  graph binds shakedown to it, so its tests link one aegis and shakedown's types
  are the project's own; aegis is now a lazy dependency of shakedown.

- `explore`: a property run once for every way its choices can go, its
  simulations on the new `Sim.Schedule.bounded` (preemption-bounded, every
  switch a choice), with dynamic partial-order reduction and sleep sets;
  `ExploreOptions.memory = .per_process` takes nodes and simulated processes for
  separate memories. Finds the four planted bugs and proves their fixes within
  two preemptions. `Source.Chooser` is the backend a search drives a source with.

- Simulated processes (`Sim.programs()`, `Sim.Options.programs`): a real
  `main` registered by name runs as a process when `std.process` spawns it, with
  its own tasks, pipes or files for its standard streams, environment, working
  directory, heap and arena; `Child.wait`, `kill` and `std.process.replace`
  work as on a real system, and a killed process or a node that goes down gives
  back the files, locks, sockets and memory it held.

- `alloc.Unwiped`: an allocator that scans every block as it is freed for bytes that
  must not outlive their owner (keys, tokens, passwords), counts the blocks that
  held one and keeps the first with the frames of its free. It refuses resizes, so a
  moved or shrunk block is seen with the contents it had. `Unwiped.sees` says whether
  the build shows it a free's contents: `Allocator.free` fills the block with
  `undefined` first where runtime safety is on, and `expectNone` skips the test there
  instead of passing it.
- `alloc.LockProbe`: an allocator that counts the calls made while a lock is held
  and keeps the first with its frames. `Held.guarded`, `Held.flag`, `Held.mutex` and
  `Held.spinMutex` read an aegis lock (`Guarded`, `BlockingGuarded` or `Order.Ordered`, through its
  own `isHeld`), an atomic flag, a `std.Io.Mutex` and a `std.atomic.Mutex`.
- `bench.Row` states what its batches need, outside timing, in the declared error
  set of the workload: a `fixture` (`setup`, optional `teardown`) whose `lifetime`
  the workload chooses, `.row` (built once, every warmup, calibration and sample
  meets it warm) or `.batch` (built for each batch alone); `stage(ctx, units)` and
  `settle(ctx, units)` around every batch; and `grow = false` for a workload whose
  every unit needs its own stage, which takes samples of exactly `initial` units and
  refuses one too short to read. Each hook that succeeded is followed by its
  counterpart, even when the workload fails; the first error is the one returned.

- `Machine(Model)`: bounded stateful command generation, preconditions, pure
  transitions, driver postconditions, validated replay and shared tape shrinking.
- `linearizable`: deterministic model checking of invocation/response histories,
  real-time ordering, witnesses and explicit unknown outcomes for incomplete or
  bounded searches, with cancellation and allocation failure cleanup.

- B5 simulated TCP, UDP, Unix sockets, node-local disks and DNS, deterministic
  link latency/loss/duplication/reordering/bandwidth, partitions, hold/release,
  resets, cooperative node kill/crash/restart, and replay/resource contract tests.
- Network batches retain blocked operations and honor deadlines and cancellation.
  Pooled packets and sockets avoid allocation during warmed transfer and reuse.
- RPC, gossip and model message rows use the shared measuring module. CI and
  workflow generation now use preflight's published integration seam directly.

- `bench`: named workloads and units, warmup, bounded clock-resolution-aware
  batches, retained samples, best/median/p99, throughput and JSONL provenance.
  Smoke runs execute each workload once without timing.
- The `shakedown-bench-compare` executable and dependency artifact compare two
  JSONL runs, report observed noise and flag changes outside it without timing
  pass/fail. Deterministic statistics, serialization, comparison and fake-clock
  contracts cover measuring; shakedown's own rows use it.

- `Sim.Fs`: a directory tree, synthetic handles, sparse copy-on-write pages,
  symlinks, hard links, permissions, virtual timestamps, locks and explicit mmap
  synchronization, all through the simulation's existing `Io`.
- Separate live and persisted state, sector tearing, reordered writes, strict
  and ordered metadata, `crashStates`, snapshots, and raw `flush`/`flushDir`
  writeout, barrier, data and full durability for seams. Materializing crashes
  and iterators returns allocation errors explicitly. `os_crash` distinguishes
  writeout durability from power loss.
- `everyCrash` checks recovery at every call boundary over bounded, distinct
  persisted disk images; reports include incomplete bounds and recovery traces.
  `IoFault.crash` abandons simulation tasks without executing defers.
- Storage corruption, latent read errors, misdirected writes, byte capacity,
  POSIX/Darwin/Windows names and configurable timestamp granularity.
- File conformance against std's Threaded Io, differential operation properties,
  airlock durability-contract checks and filesystem benchmark rows.

- `IoFault.fail_after`, a lost answer: the call is made, then returns the error.
  `EveryFaultOptions.lost_answers` tries it at every step that can lose its
  answer.
- `IoFault.spurious_wake`, a futex wait woken by no one; `IoFault.stall`, a call
  that waits until a cancel ends it, and a batched operation kept pending until
  its batch is canceled, so an await waits out its timeout.
- `IoFault.Callback.then`: what happens to the call once the callback has run, a
  fault of its own, checked with the plan.
- `Clock.Options.advance`: `.auto` fires each timer as it is armed, the clocks
  moving to its deadline and `late` past it.
- `Sim.Watchdog` and `Sim.Options.watched_by`, a watchdog several simulations
  share; `check` shares one among its cases' simulations, which no longer start a
  thread each.

### Fixed

- A `Sim` directory listing resumes after the last entry it returned, by a
  cookie each entry keeps, as readdir does: a listing that removes what it
  lists (a prune of temporary files) no longer skips the entry after each one
  removed. The conformance golden changes with it.

- `Sim.Fs.crashStates` tries each subset of pending effects in the orders that
  can leave different trees, those where conflicting effects (one sector, one
  file's length or metadata, one name) trade places, rather than every
  permutation: the same states, checked against every order by a test, at a
  cost that a batch of three files no longer makes factorial.

- `check` fuzzes under `zig build test --fuzz` in a project that depends on
  shakedown: it asked its own module's `builtin.fuzz`, which a dependency is
  built without, so no property was ever a fuzz test outside this repository.
  It now asks the test runner.

- Isolate generated benchmark provenance files and check full native Windows stack-fault statuses, rejecting ordinary exit code 5.

- Portable `Source.integer` and enum, choice and float generators compile on
  32-bit targets while preserving seeded draws and replay.

- Determinism captures a tagged outcome; successful runs do not compare an
  inactive error field.

- `recancel` after a cancel `FaultIo` landed re-arms it for the task's next
  cancelation point, instead of reaching a base that never canceled the task,
  where std's threaded `Io` panics. std's `Queue` does so after a partial put.
- Every call a `Sim` does not simulate yet that can return `error.Canceled` is a
  cancelation point, as are `lockStderr` and `tryLockStderr`.
- A `Clock`'s timed batch wait whose timer has fired looks once more without
  waiting, instead of waiting out another `recheck`.

- `Layer(State, overrides)`: an `Io` that overrides some vtable slots, keeps its
  state in itself and forwards every other slot to its base.
- `Clock`: a manual clock over any base `Io`, with separate awake, boot and real
  clocks, suspend and wall-clock steps, timers fired in deadline and arming order,
  and `awaitArmed`, bounded by an `Io.Timeout` on the base, as the barrier
  before `advance`.
- `alloc.Counting`, an allocator that counts calls, refusals and bytes live, at
  their peak and in total.
- `alloc.Quarantine`, an allocator that never hands out an address twice and can
  end each block at an inaccessible page.
- `alloc.NoResize`, an allocator that refuses every resize and remap, so the
  allocation count `std.testing.checkAllAllocationFailures` depends on repeats
  from run to run.
- `corpus.entry`, `corpus.entries` and `corpus.encode`, which build
  `std.testing.Smith` inputs at compile time, `corpus.fromTape`, which turns a
  recorded tape into one, and `corpus.repeat`, text written any number of times
  as a static constant.
- `Source`, the one source of random decisions: a seeded generator whose draws
  are fixed per seed, a recorded tape replayed, or the fuzzer's input. A
  recording source keeps every draw, with its bound, on a tape grouped into the
  spans `begin` and `end` mark; a choice of 0 is always the simplest.
  `integer` draws edges and small values more often, and `more` decides one
  more element of a list.
- `gen`: integers, ranges, floats, booleans, enums, `oneOf`, `weighted`,
  slices, strings (ASCII, UTF-8 or bytes), `any` value of a type by reflection,
  and `filter`, each laid out so that a smaller tape is a simpler value.
- `check`: a property run over the committed regressions and then seeded
  cases, its failures shrunk on the tape and printed with the tape that
  replays them, its notes and its error return trace; `SHAKEDOWN_TAPE`,
  `SHAKEDOWN_SEED` and `SHAKEDOWN_CASES`; under `--fuzz`, the same property on
  the fuzzer's input. `CheckOptions.diagnostics` takes the failure as a
  `CheckReport` instead of printing it.
- `Sim`: a simulated `Io` that runs tasks one at a time on fibers, Win32 fibers
  or threads, with the `fifo`, `random` and `pct` schedules, virtual time that
  moves to the next timer when every task waits, futexes, groups, select and
  cancelation, every choice std leaves open drawn from one source, and outcomes
  that name each waiting task of a deadlock with its stack. `start`, `step`,
  `runFor`, `runUntil` and `at` drive it a frame at a time; `Options.faults`
  puts a `FaultIo` outermost; `allocator` lays memory out alike in every run;
  a watchdog ends a run whose task stops calling into it. `Case.sim` makes one
  whose schedule shrinks with the case.
- `expectDeterministic`, which runs a body twice from one seed and names the
  first call, or the first step's state checksum, that differs.
- `conformance`, std's `Io` guarantees as checks to run against any `Io`.
- `panic`, a panic handler that prints the seed, tape and last calls of the
  simulation a task panicked in.
- `FaultIo`: an `Io` that counts, traces and faults every slot and operation by
  plan, with paths for opened files and directories, seeded `io.random`, an
  allocator under the same plan, and `beginForeign` and `endForeign` for a
  seam's own calls.
- `Plan`, `Trace`, `Steps` and `Match`, the generic plan, trace and step counter
  `FaultIo` is built on, for a package's own call types. A trace in `.window`
  mode keeps the newest records and the rolling hash and nothing that grows
  with the run.
- `everyFault`: every single fault at every step of an operation, with a check
  that every faulted run made the clean run's calls up to its fault. Each run is
  checked before its `tearDown`, every run draws `io.random` from the seed in its
  options, and `EveryFaultReport` frees its trace with the allocator it was made
  with.

[Unreleased]: https://github.com/pedronaugusto/shakedown/commits/main
