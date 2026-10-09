# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

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
