# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Pins shuttle 0.5: the simulation's fibers are typed contexts, each started with its baton and switched with no message, so the start no longer casts its argument back.

## [0.5.0] - 2026-10-27

### Breaking

- `Sim.Watchdog.Watched` reads aegis cells: `running` an `aegis.Atomic(TaskId)`, `calls` an `aegis.Atomic(Sim.Watchdog.Calls)`, `stuck` an `aegis.Atomic(Sim.Watchdog.Stuck)` (`running` or `stuck`, no longer a bool), `runner` an `aegis.Atomic` of the thread. `Sim.Watchdog`'s thread is `started()`, no longer a field.
- `FaultIo`'s fields are its own: the plan, trace, path table, seed, cancels held and batch states sit behind its lock, and its counts are aegis cells. Read them through `trace()`, `fired()`, `count()` and `steps()`, as before; `fired` takes a `*FaultIo`.
- The allocators' and `Steps`' counters are aegis `Atomic` cells (`Erased.unerased_count` and `unseen_count`, `Unwiped.count` and `unseen_count`, `LockProbe`'s, `Steps`'); read them through their functions.

### Changed

- Pins aegis 0.2.1.
- Every lock holds what it guards (aegis `BlockingGuarded`: `FaultIo`'s, `Clock`'s, the watchdog's), and time from std enters as aegis's checked nanoseconds, saturating past ±292 years as before, in one conversion that `Clock` and the simulation share.
- A simulated task's life is an aegis `state.Machine`: a move it does not allow stops the run instead of leaving the scheduler in a state no edge reaches.
- The conformance files check reads its file back with `aegis.own.readFile`, which states the file's length before it reads, so a simulation's trace of the conformance workload changes.
- Pins shuttle 0.4.0.

## [0.4.18] - 2026-10-25

### Added

- `Sim.Fs.Snapshot.digest`: a tree's identity whatever history and inode numbers reached it (every path in name order, which of them name one inode, each inode's kind, metadata, bytes, target and damage; inodes no path reaches left out), 128 bits. It keeps each file image's digest in a `Sim.Fs.ImageDigests`, which holds the image, so the states of one crash point, sharing every file none of them changed, hash each file once.
- `EveryFaultReport.repeated`: the crash states `everyCrash` did not recover again.

### Changed

- Pins preflight 0.17.3.
- `everyCrash` recovers each distinct crash state once: a state an earlier crash point already left (the same `digest`) is counted in `repeated` and not recovered again, since recovery sees nothing but that storage. Most points of a long operation leave the states the points before it left; relic's crash test of maintenance's loose-objects task made 31,520 recoveries of 447 distinct states.

### Fixed

- The watchdog counts the time a task could run, not real time: its thread's CPU time, and all the time the thread is blocked in the kernel, where it could not have made a call either. On a loaded Mac a task's thread waited for a CPU a whole watchdog time after the mark, and the watchdog aborted the process over a task that had not had the time to reach its call (sim_test's 50 ms watchdog test). The watchdog reads the thread from its own: `/proc/self/task/<tid>/stat` and the thread's CPU clock on Linux, `thread_info` on macOS, the system's process snapshot on Windows. Where nothing can be read, real time counts, as before. `Sim.Watchdog.Watched` takes the thread as `runner`, null for none.
- A cancel `FaultIo` planned at a cancelation point under blocked protection landed on a thread none of the base's tasks run on: std's `Threaded` keeps no protection for the test's own thread, and FaultIo asked it. FaultIo now keeps the protection each task sets through it (`swapCancelProtection`) and asks the base only for a task that set none; an `everyFault` sweep of code that blocks cancels around its teardown (relic's lock files) saw a cancel taken in there that a real run never meets.

## [0.4.17] - 2026-10-24

### Changed

- Pins aegis 0.1.17 and shuttle 0.3.3.

## [0.4.16] - 2026-10-21

### Fixed

- On Windows, a simulated process's standard error was taken for its standard output where the test process's two shared one handle, as a hosted runner's steps do: the simulation tells a process's streams apart by the handle its code names. Each simulation, before it runs, now gives the test process standard handles no two of its streams share (each that shares an earlier one's gets a duplicate of it, `SetStdHandle`); a test makes them share and runs a child's output and errors through. conduit's simulated pipes test was red on every Windows leg so.
- The clock stress test steps its clock for the rounds asked, or as many as 20 s of real time holds: on the riscv64 machine QEMU emulates, its thousand waiters ran past the hosted job's limit (811 s on the 2026-10-21 nightly), where they finish in about two minutes in a local VM. The stress is in how the waiters interleave, which the rounds a budget holds still exercise.

## [0.4.15] - 2026-10-21

### Added

- `Sim.Fs.ownership(inode)`: the device, owner and group of the file a stat through the simulation's `Io` reports as `inode` (null for an inode no file has), which `std.Io`'s stat does not carry, so a seam that builds a platform's whole stat over a simulation (airlock's) fills them from the model. `Sim.Fs.Options` names the volume's `device` and the simulated process's `uid` and `gid` (1, 1000 and 1000 by default): a file takes the owner and group at create, a set-owner call through the `Io` changes them, and they persist as the file's other metadata does.

## [0.4.14] - 2026-10-20

### Changed

- `Sim.Fs` finds a name in a directory by a hash every name keeps (the same for any two names the file system calls the same, Darwin's and Windows' folding included), where each lookup compared the name with every entry of the disk; and two crash states compare their entries by the names they share before looking any up. A crash exploration of a git ref update on a Darwin-named disk spent most of its time there.

## [0.4.13] - 2026-10-20

### Added

- `Case.io()`: the `Io` for a case's own work. It is `std.testing.io`, except under the fuzzer, where each input has an `Io` of its own, joined when the input ends. Zig 0.17's fuzzing runner keeps one `std.testing.io` for all of a target's inputs while `std.testing.allocator` is a new one per input, and `Io.Threaded` frees a group's task on the thread that ran it after the group's await has returned, so a property that started tasks on `std.testing.io` could free one into the next input's allocator ("corrupted footer metadata").

## [0.4.12] - 2026-10-20

### Fixed

- `Sim.Fs`: the `createFile` that makes a file with read-only permissions returns a handle that writes it, as POSIX `open` with `O_CREAT` and Windows' `CreateFile` do (the permissions are for later opens); it was `error.AccessDenied`, which stopped git's way of writing a loose object (0444) in a simulation.

## [0.4.11] - 2026-10-17

### Changed

- Pins shuttle 0.3.0 (its pool makes a stack usable when first handed out) and aegis 0.1.12.

## [0.4.10] - 2026-10-17

### Added

- `bench.Row.latency`: a row whose units are timed one at a time, that many, so its median and p99 are a latency distribution's rather than batch means'. For a unit that is a round trip to another process or machine, where a mean hides the tail; each unit is held to `bench.latency_resolution_multiple` (100) clock resolutions. parley's benchmarks time requests to a server process with it.

## [0.4.9] - 2026-10-17

### Fixed

- A simulation's watchdog could abort the process when its own sample came late: it gave a task marked stuck until twice the watchdog time after the task's last call, so a mark taken late (the watchdog's thread descheduled on a loaded host) left the task no time to reach the call that ends the run. The second watchdog time now counts from the mark (cloak's suite aborted once in the VM just after its restart).

## [0.4.8] - 2026-10-17

### Fixed

- `leak.run` refuses options whose measurements past the first round cannot reach the floor below which a test says nothing (`leak.floor`, 10 000): such a run reported a |t| of zero, "no leak", having tested nothing (cloak's RSA row did).

## [0.4.7] - 2026-10-17

### Added

- `leak`: timing-leak tests, whether an operation's time depends on its secret input. Two classes of input, a fixed one and random ones, are measured interleaved in a random order and compared with Welch's t-test, uncropped, cropped at a hundred percentiles and in second order (dudect). For the built code a constant-time claim rests on: cloak's kernels first.

## [0.4.6] - 2026-10-17

### Fixed

- `gen.any` draws slices: drawing a type with a slice in it failed to compile (the length of a nested list was computed as a shift of an untyped constant by a run-time amount), so a property over such a type could not be written.

## [0.4.5] - 2026-10-15

### Fixed

- `Clock` reports a cancel to a timed wait whose deadline has already passed: `futexWait` returned at once, as a timeout, and a canceled task waiting in a loop of such waits never saw its cancel (a test bounded by real time looped 10 s). It returns `error.Canceled` when one is pending, as its `sleep` did and the base's own wait does. A read blocked in the kernel is the base's, untouched by the clock.

## [0.4.4] - 2026-10-15

### Added

- A fault plan's `.nth` trigger takes `after`, another entry's index: its calls count only once that entry has fired. A fault meant to follow another (a cancel found by the look after a write that made no progress) is placed by the plan, whatever calls a concurrent task makes before it (conduit's InputWriter test took a cancel check from the writer's own wait as the one it meant, on a riscv64 kernel's timing).

## [0.4.3] - 2026-10-14

### Fixed

- The simulation's watchdog starts its thread with the stack std gives a thread, where it asked for 64 KiB, and a `.threads` simulation gives each task's thread at least 256 KiB whatever `stack_size` asks: libc refuses a stack below its minimum (glibc's is 128 KiB on aarch64, where std asserts on the refusal), so a test linking libc there, a ThreadSanitizer run among them, crashed at the first watched simulation (eleven of aegis's tests).

## [0.4.2] - 2026-10-14

### Added

- Properties for the three parsers of what reaches shakedown from outside: a tape written as text parses back to its choices (`SHAKEDOWN_TAPE`), benchmark rows parse or are refused whatever the bytes, and the fuzz runner's findings borrow from the output they are read from.
- `gen.bytesInto`, a prefix of a buffer of any length filled with any bytes, and `gen.mutated`, a parser's input made from its examples with a few edits (a byte changed, the tail cut, bytes added), or else any bytes: the simplest is the first example whole, so a failure shrinks toward input the parser accepts. Four packages kept a copy of one or the other.

### Changed

- A simulation reserves its regions on riscv64 and loongarch, where std's Linux map flags name no NORESERVE and the build failed; a reservation with no access is charged no commit there either.
- shakedown's own suite names itself `shakedown`, so preflight's runner finds the quarantine it backs `std.testing.allocator` with in the hardened run.

## [0.4.1] - 2026-10-13

### Changed

- The fiber executor runs on shuttle 0.2: a fiber keeps its stack beside its context, which no longer carries it. Pins shuttle 0.2.0.

## [0.4.0] - 2026-10-13

### Breaking

- shakedown depends on [shuttle](https://github.com/pedronaugusto/shuttle) at run time: a simulation's fibers are shuttle's contexts, on shuttle's stacks. A project that depends on shakedown fetches shuttle with it, and one that pins shuttle itself shares the one revision bay selects.

### Changed

- Fibers run on Windows too, and `.fibers` and `.auto` take them there: Win32 fibers retire, as shuttle's switch keeps the thread information block's stack bounds on the running stack, so the system grows a task's stack, raises its stack overflow and walks it as on a thread's own.
- Fibers run on riscv64.
- The context switch, the first frame, the ThreadSanitizer annotations and the bounded frame walk are shuttle's; the executor keeps the threads kind.
- Pins preflight 0.4.3.

## [0.3.2] - 2026-10-13

### Fixed

- `Sim.Options.stack_size` defaults to a megabyte on Windows (256 KiB elsewhere): std's NT path conversion needs more than 256 KiB in a Debug build, so code under test that opens a file overflowed its task's stack.

### Changed

- Pins aegis 0.1.3 and preflight 0.4.0.

## [0.3.1] - 2026-10-12

### Changed

- The benchmarks take shakedown from preflight, which adds the one the package declares, where their imports gave it a second time.
- The README says what a build without bay must do for one aegis: pin the aegis release shakedown pins, and ask for both with the same target and mode.

## [0.3.0] - 2026-10-12

### Breaking

- `.aegis = .consumer` and `useAegis` are gone. bay gives a graph one version of each package, so a project with aegis in its own graph and shakedown already share one, and nothing binds them by hand. aegis is a plain dependency of shakedown, no longer lazy.

### Changed

- Pins aegis 0.1.1.
- The benchmarks and the 32-bit check take shakedown's own module, where they built a copy of it to bind aegis to.

## [0.2.6] - 2026-10-12

### Changed

- Pins preflight 0.3.4.

## [0.2.5] - 2026-10-12

### Changed

- The context switch is a function per architecture; 0.2.4's own source checks refused the one that held both for its length. Nothing a user sees changes.

## [0.2.4] - 2026-10-12

### Fixed

- Simulations on fibers on x86_64 keep what the switching code holds in vector registers. The context switch declared them clobbered only by their AVX-512 names, `zmm`, which the compiler does not take on a CPU without AVX-512, so optimized code kept values in `xmm` registers across a switch for the next task to overwrite. The switch declares them as `xmm` and `ymm` too.

## [0.2.3] - 2026-10-12

### Fixed

- Simulations on fibers run right in optimized builds on aarch64. The context switch declared the link register clobbered by the name std gives it, `x30`, which the compiler does not take for the link register, so optimized code kept a pointer in it across a switch, and read through a code address once back: a crash or a corrupt value in ReleaseSafe and ReleaseFast on aarch64 (macOS and Linux). The executor's switch declares it as `lr`.
- A task blocked on a fiber records where it waits by walking its frames inside its own stack. std's unwinder, on aarch64 Darwin, restores a frame's saved registers reading up from its frame pointer, which past the fiber's first frame reads beyond the stack and faults; the crash handler then hung on the unwinder's own lock.

## [0.2.2] - 2026-10-12

### Added

- `CheckOptions.fuzz`: false keeps a check from the fuzzer, for a test that asserts how `check` ran (its cases, its seed, the error it returned, its report). Under the fuzzer `check` runs the fuzzer's inputs instead, and such a test failed there on every input.

### Fixed

- Simulations on fibers run under ThreadSanitizer: each fiber is made known to it and each switch announced. It followed the thread by its stack, read one fiber's stack as another's, and crashed or hung.
- A region lands at its fixed address under ThreadSanitizer too. The address it asks for elsewhere is ThreadSanitizer's shadow memory on x86_64 Linux, so its addresses did not repeat there.

- A task reused for another job is reset field by field, leaving its context alone: on the threads executor its thread waits on the context's turn while the next job is laid out, and the whole task was copied over it, the turn included, which ThreadSanitizer reports as a race.

## [0.2.1] - 2026-10-12

### Fixed

- A fiber on x86_64 starts its function with the stack a call leaves it, 8 mod 16. It started 8 bytes off, and code built optimized, which moves 16 bytes at a time to and from the stack on that promise, faulted: every simulation on fibers crashed in ReleaseSafe and ReleaseFast on x86_64 (Linux and macOS).

## [0.2.0] - 2026-10-11

### Breaking

- shakedown is developed with [bay](https://github.com/pedronaugusto/bay): preflight is a dev dependency, and the tests, fault programs, example, consumer checks and benchmarks are the development build's (`bay test`, `bay check`, `bay bench`). What a project that depends on shakedown builds is unchanged: the module and the two programs.
- `shakedown-fuzz --bay <path>` builds the package's step as `bay dev <step>`, for a package developed with bay.
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
- `shakedown-fuzz --step <name>` fuzzes a step other than `test`, one whose
  every test binary has a property (the fuzzer refuses a binary with none);
  shakedown's own is `unit`, the suite alone.
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

- Fuzzing a `check` property gives each input a runner of its own. The test runner checks for leaks after every fuzz input, and a shared runner kept its arena between inputs, so a fuzz run failed with a false leak at the first input that grew it.
- Under `--fuzz`, a property whose cases allocate failed every input with a leak:
  the runner kept its arena and tape for the next input on the test's allocator,
  which the test runner checks after each one. It keeps them on the page allocator.

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

### Changed

- Pins aegis 0.1.0.

[Unreleased]: https://github.com/pedronaugusto/shakedown/commits/main
