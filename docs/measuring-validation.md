# Measuring validation

Implementation: `248f502` in [shakedown](https://github.com/pedronaugusto/shakedown).
Baseline: published main `d5d19d39bc60cec59456aca947a3a7b484b87318`.
Preflight remains pinned to published main `9af905ed85cab6dbb19d9431c65ee3f41fbaa74d`.
Both heads had successful dispatched CI before work began: shakedown run
37768627963 and preflight run 37711386950.

## Contracts and checks

The new contract test was first run on the baseline and failed because the
measuring module did not exist. Deterministic tests cover order-preserving
statistics, even medians and nearest-rank p99, invalid observations, fake-clock
warmup and resolution-aware batching, bounded unmeasurable rows, prefix filtering,
exactly-once untimed smoke, escaped JSONL and provenance, duplicate and malformed
rows, inconsistent statistics, both directions of comparison, observed noise,
insufficient sample evidence, and ownership under every allocation failure.

An isolated consumer containing only the shipped files exposed an artifact
registration bug at 6e11f9c: creating an executable does not make it available
through Dependency.artifact. The regression fixture now requests that artifact
with fetching disabled and expects the exact beyond-noise comparison output
and a successful exit. Registering it through installArtifact fixes the build
contract without changing the measured workload or measuring algorithm.

Local checks use Zig 0.17.0: `zig build test -Dtest-filter="bench "`,
`zig build lint`, `zig build check`, and `zig build check-consumer`. The build
also preserves the existing wasm32/x86 draw compile fixtures and native portable
draw tests. All 41 own workloads execute in ReleaseFast; both benchmark programs
smoke-run through preflight's Config.bench. CI has no timing gates. Hosted
matrices were regenerated through `zig build plan` for all three tiers.

## Measurement method and raw evidence

The [raw evidence](evidence/measuring) holds three pairs, ordered base/candidate,
candidate/base, base/candidate. Every run contains 31 retained samples per row.
Each binary is ReleaseFast. Both drivers use the committed measuring module and
the same workload source, which isolates the baseline package implementation
from the candidate implementation; the baseline lives in a separate standalone
clone at the published main commit. The candidate's rows identify the committed
implementation. No production hot path changes in this batch.

Resolution-aware calibration exposed a flaw in the old fake-clock benchmark:
its constant loop could collapse into one computation. The shared workload
driver makes each timestamp observable for both sides. Calibration starts at the
smallest meaningful workload quantum and doubles until every retained sample
lasts at least 1 ms and 1000 clock-resolution units. Timings include workload
setup and teardown, consistently on both sides. CPU provenance names the
selected target CPU model, not a measured physical hardware identity; drivers
can supply a physical CPU name through Metadata. Comparisons use the full
observed sample deviation band, not statistical significance. They produce
flags and never a performance pass/fail status.


### Paired results (ns/unit, best observed sample across three runs)

| Row | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| now/threaded | 16.739 | 16.757 | +0.11% |
| now/clock | 0.406 | 0.406 | +0.00% |
| now/faultio | 20.864 | 20.867 | +0.02% |
| pread4k/sim | 68.588 | 68.741 | +0.22% |
| sim/switch-fibers | 55.462 | 55.964 | +0.91% |
| sim/contention-pct | 132.308 | 136.012 | +2.80% |

The comparator flags changes outside the observed noise band in each pair.
No row has a same-direction beyond-noise flag in all three pairs; contention
PCT changes direction between the first two. These runs measure unchanged
package implementations through the same measuring policy; they establish
usable retained evidence, not a claimed production speed improvement.

## Preflight coordination seam

The fetched package exports a `shakedown-bench-compare` executable artifact;
preflight can ask the shakedown dependency for that artifact without fetching
shakedown's own CI dependencies. Config.bench registers the own driver and
comparison tool; preflight owns their ReleaseFast and smoke wiring. There is
no package-owned planner, A/B build step, compatibility adapter, or timing gate.

Published preflight 9af905e does not yet expose the family's A/B step described
in the design. That follow-up belongs to preflight's owner: build the published
base revision in isolation, alternate the runs, and invoke this comparison
artifact. This task has not edited another owner's preflight tree or pinned a
private branch. The measuring module and executable are usable through the
published program/artifact seams without that future automation.

## Book status

The shakedown-complete mission's measuring checkbox becomes stale when this
batch lands. The package design's B5, B6 and B7 remain future work at this
landing. No book edits, visibility changes, releases, tags or upstream messages
were made.
