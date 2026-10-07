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
  and `awaitArmed` as the barrier before `advance`.
- `alloc.Counting`, an allocator that counts calls, refusals and bytes live, at
  their peak and in total.
- `alloc.Quarantine`, an allocator that never hands out an address twice and can
  end each block at an inaccessible page.
- `corpus.entry` and `corpus.encode`, which build `std.testing.Smith` inputs at
  compile time.
- `Source`, a seeded source of random decisions whose draws are fixed per seed.

[Unreleased]: https://github.com/pedronaugusto/shakedown/commits/main
