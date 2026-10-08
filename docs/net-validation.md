# B5 simulated network validation

The measuring batch landed first at published main
`9357a9ab398ac25fa8a408a71e77a124bc51d311`, after successful exact-head
fast run 37817170226 and merge run 37818062956. B5 began from that verified
green main in the same standalone clone and a new branch. Its measured source
head is `87022d597f0bbf1895612e134f4bf3f6b300cfb4`; subsequent report commits do
not change the implementation measured here.

## Contracts and regression evidence

The initial B5 contract failed on the baseline because `Sim.node` and the network
API were absent. The implementation supplies owned model state below the Io
slots, public Net/Node facades, and Layer-based node routing through one shared
FaultIo. It adds no package-owned planner or compatibility adapter.

Twenty-three network contracts cover byte preservation and half close; isolated
node disks; handshake latency, bandwidth and bounded partial writes; Unix
namespaces; normalized DNS with canonical-name and queue-close behavior; UDP
loss, duplication, hand-derived reordering, truncation, peek and broadcast;
partition expiry and hold/release; peer resets, kill/crash/restart; canceled
connect endpoint cleanup and canceled blocked writers; timed batch cancellation
and reuse; saturated finite deadlines; stale handles and sender-close delivery;
allocation-failure cleanup; allocation-free warmed message/socket reuse; shared
outer fault counters; trace byte/node identity; invalid configuration; exact
TCP retransmission; and independently calculated exponential latency. Standard
`std.http.Client` and `std.http.Server` communicate over simulated DNS and TCP.
Twelve recorded seeds replay loss/duplication/reordering/bandwidth on both fibers
and threads. No host network resources are involved.

The trace schema intentionally adds the node namespace. The 1000-seed
conformance golden changes from `0x48b6c2b3d7b27569` to `0x6484418532bdea69`;
scheduler choices remain unchanged. The updated golden and cross-executor
conformance checks pass. Existing source generators and wasm32/x86 draw
compile fixtures remain intact.

A commit-only benchmark rebuild exposed stale provenance: Zig's cached build
configuration retained the old Git revision. Revision/status are now uncached
build commands feeding generated module files. Rebuilding after committing,
without another source edit, reported the exact clean new head. All retained
rows assert their source commit, 31 samples and measured mode.

Local validation uses Zig 0.17.0: targeted network tests, the 1000-seed golden,
`zig build lint`, `zig build check`, ReleaseFast bench builds and untimed smoke.
CI runs the full suite and compiles/smokes all registered benchmarks without
timing gates. Final CI results are attached to the exact branch head before
fast-forwarding main.

## Paired ReleaseFast evidence

The [raw evidence](evidence/net) retains three pairs, in base/candidate,
candidate/base, base/candidate order, with 31 samples per row. The published
baseline is built in a separate standalone clone. Both binaries run sequentially
on the same machine with the shipped measuring module and the unchanged 41
existing workload rows. Candidate runs add RPC, gossip and an independently
built model message driver. Setup/teardown costs are included where the workload
includes them. CPU/OS/Zig provenance is recorded in every row. No rivals are
included. Values below are ns per named unit; best is the best sample across
three runs, and median range shows run-to-run variation.

| Row | Baseline best | Candidate best | Candidate median range |
| --- | ---: | ---: | ---: |
| sim/new | 2454.672 | 2555.664 | 2666.830–2915.527 |
| sim/now | 12.621 | 13.790 | 13.931–14.017 |
| sim/switch-fibers | 54.972 | 45.572 | 46.700–47.128 |
| sim/spawn-await | 83.687 | 70.473 | 70.966–71.579 |
| sim/contention-pct | 133.493 | 129.509 | 133.350–135.661 |
| pread4k/sim | 66.246 | 66.470 | 72.146–74.379 |
| net/message-32 | new row | 23.705 | 24.028–26.053 |
| net/rpc-32 | new row | 235.270 | 238.302–320.943 |
| net/gossip-3 | new row | 472.005 | 478.973–483.765 |

The comparator reports median changes and full observed sample noise, without
choosing performance pass/fail. No existing row has a slower beyond-noise flag
in all three pairs. `sim/now` is flagged slower in pair three only (+6.21%, noise
5.88%). Fiber switching and spawn/await are flagged faster in all three pairs;
these measurements do not establish a causal explanation for those changes.
Cold Sim construction's best sample is 2.556 microseconds; model message
transfer is 23.705 ns, below the design's 100 ns plus byte-copy cost estimate.

## Published dependency and preflight seam

Preflight was re-queried on GitHub before updating the pin to published main
`b28046cc22055fcd32640117fc0e6965283a8ae5`, verified by successful runs
37823307574 and 37821750595. `zig build plan -- --workflow
.github/workflows/ci.yml` regenerated the tiers through preflight's integration
seam. The previously inherited package planner was removed. Config.bench owns
ReleaseFast build/smoke registration; preflight owns CI/build/test wiring.

The published seam still does not expose automated paired A/B orchestration.
That remaining integration belongs to preflight's owner. These required pairs
were executed directly and retained; no competing planner or preflight-tree
edit was introduced. The measuring comparator's published executable artifact
remains the integration point for that owner follow-up.

## Public limitations and remaining phases

Network contracts and resource bounds are documented in README: separate IPv4
and IPv6 bindings, explicitly unsupported dual-stack UDP and interface queries,
limited IPv4 broadcast, new-connection buffer growth, 60-second partition and
permanent-loss expiry, bounded packets, and cooperative node cancellation.
`Net.link` returns named configuration/resource errors instead of hiding invalid
inputs. `Node.crash` can report allocation failure from the disk crash model.
The Zig 0.17 low-level Stream.read convenience function has an upstream tuple
access incompatibility; the working std Reader/HTTP adapters and readWithControl
surface are used without a package shim or upstream edit.

README remains work in progress. B6 stateful models, B7 programs/search, package
adoption and the preflight A/B automation follow-up remain outside this B5
landing. The book's measuring/B5 status will become stale; no book edits, tags,
releases, visibility changes or upstream messages were made.
