# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
- `corpus.entry` and `corpus.encode`, which build `std.testing.Smith` inputs at
  compile time.
- `Source`, a seeded source of random decisions whose draws are fixed per seed.
- `FaultIo`: an `Io` that counts, traces and faults every slot and operation by
  plan, with paths for opened files and directories, seeded `io.random`, an
  allocator under the same plan, and `beginForeign` and `endForeign` for a
  seam's own calls.
- `Plan`, `Trace`, `Steps` and `Match`, the generic plan, trace and step counter
  `FaultIo` is built on, for a package's own call types.
- `everyFault`: every single fault at every step of an operation, with a check
  that every faulted run made the clean run's calls up to its fault. Each run is
  checked before its `tearDown`, every run draws `io.random` from the seed in its
  options, and `EveryFaultReport` frees its trace with the allocator it was made
  with.

[Unreleased]: https://github.com/pedronaugusto/shakedown/commits/main
