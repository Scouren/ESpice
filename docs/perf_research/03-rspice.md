# RSpice against ESPice

RSpice ([JaimeHW/RSpice](https://github.com/JaimeHW/RSpice)) at commit
`ba24b294`, built `cargo build --release` with its default features, timed
on the machine and method of [02-baseline.md](02-baseline.md).

**Verdict: RSpice wins on no deck timed.** ESPice is 1.3x to 25x faster in
wall time on all 45 decks both ran. Two things still deserve attention: on
thick-factor decks RSpice spends fewer CPU-seconds than ESPice does at 8
lanes, and two of its mechanisms transfer. ngspice, the other reference,
does beat ESPice on three decks; that gap is in the last section.

RSpice's outputs were checked by exit code and by row count on a few decks,
not waveform by waveform. A wall time here says how long RSpice ran, not
that its answer matches.

## Wall time

Median of three, seconds. `r/e` is RSpice over ESPice at default threads.

| Deck | ESPice | ESPice 1 thread | RSpice | ngspice | r/e |
|---|---|---|---|---|---|
| `bench_ngspice_mosamp` | 2.12 | 2.19 | 2.70 | **1.57** | 1.3 |
| `ring51` (RSpice's own bench) | 0.219 | 0.218 | 0.371 | 0.244 | 1.7 |
| `scaling_parallel_inverters_100` | 0.040 | 0.044 | 0.073 | 0.041 | 1.8 |
| `scaling_parallel_inverters_2000` | 0.579 | 0.748 | 1.129 | 0.858 | 1.9 |
| `scaling_inverter_chain_256` | 0.406 | 0.406 | 1.063 | **0.315** | 2.6 |
| `vacask_graetz` | 1.69 | 1.72 | 4.66 | 2.64 | 2.8 |
| `vacask_mul` | 0.845 | 0.897 | 3.15 | 1.44 | 3.7 |
| `vacask_rc` (ESPice re-timed, 7 runs) | 0.390 | 0.384 | 1.91 | 1.48 | 4.9 |
| `sram_bsim4_1k` | 0.792 | 1.75 | 3.10 | 6.00 | 3.9 |
| `logic_bsim4_1k` | 2.35 | 4.71 | 9.09 | 36.6 | 3.9 |
| `rc_ladder_10000` (RSpice's own bench) | 0.640 | 0.677 | 3.15 | 1.51 | 4.9 |
| `rc_ladder_1000` (RSpice's own bench) | 0.506 | 0.511 | 2.61 | 1.05 | 5.2 |
| `scaling_rc_ladder_100k` | 1.64 | 1.64 | 9.40 | 5.61 | 5.7 |
| `ring_bsim4_1k` | 1.08 | 2.96 | 6.53 | 6.98 | 6.0 |
| `chain_bsim4_1k` | 0.560 | 1.63 | 3.46 | 3.86 | 6.2 |
| `scaling_inverter_chain_4k` | 3.51 | 6.61 | 69.2 | 5.77 | 19.7 |
| `logic_bsim4_10k` (one RSpice run) | 50.1 | — | 192.5 | — | 3.8 |
| `sram_bsim4_10k` (one RSpice run) | 14.1 | 37.1 | 72.5 | — | 5.1 |
| `ring_bsim4_10k` (one RSpice run) | 7.57 | 18.2 | 54.3 | — | 7.2 |
| `chain_bsim4_10k` (one RSpice run) | 4.38 | 10.1 | 48.8 | — | 11.1 |

The other 25 decks are small: 24 run under 50 ms in ESPice (transient, AC,
DC, noise, OP) and land at 2.4x to 7.3x, one at 25x
(`bench_ngspice_rca3040`); `sweep_opamp_wl_5000` is 5.7x (0.223 s re-timed
over 7 runs, against 1.28 s). At that size they
measure process start and parsing as much as simulation: ESPice 2 to 40 ms,
RSpice 8 to 124 ms. RSpice fails `vacask_ring` (no PSP103: "LEVEL=1040
which has no native implementation") and, like ngspice, cannot parse
`bench_pss_diode_rect_driven`.

## CPU-seconds

Wall time hides what ESPice pays in cores. User plus system seconds:

| Deck | ESPice (8 lanes) | ESPice 1 thread | RSpice (up to 8 threads) |
|---|---|---|---|
| `logic_bsim4_1k` | 17.6 | 4.7 | 12.6 |
| `sram_bsim4_1k` | 7.0 | 1.7 | 5.4 |
| `scaling_parallel_inverters_2000` | 4.4 | 0.75 | 2.8 |
| `chain_bsim4_1k` | 4.8 | 1.6 | 5.6 |
| `scaling_inverter_chain_4k` | 25.1 | 6.6 | 144 |
| `chain_bsim4_10k` | 20.8 | 10.1 | 62.0 |
| `ring_bsim4_10k` | 38.5 | 18.1 | 75.3 |
| `sram_bsim4_10k` | 97.1 | 36.8 | 87.1 |
| `logic_bsim4_10k` | 304 | not run | 208 |

On the thick-factor decks (`logic`, `sram`) ESPice at 8 lanes burns more
CPU than RSpice for its 4x to 5x wall lead, while single-threaded ESPice
does the same job in a third to a half of RSpice's CPU. The lanes buy 2.1x
to 3.1x wall for 2.1x to 4.1x the CPU: waiting lanes spin, the refactor
scales 1.6x to 2.8x, and the solve does not scale
([02-baseline.md](02-baseline.md#thread-scaling)). That is levers
[C1, C5 and C6](04-levers-cpu.md), not a property of RSpice.

## What RSpice is

Correctness first. Its default path does more work per timepoint than
ngspice's and it has none of ESPice's acceleration axes.

| Area | RSpice | ESPice |
|---|---|---|
| Linear solver | Own KLU-class kernel: matching, BTF, AMD per block, left-looking Gilbert-Peierls, values-only refactor on stored pivots. A backward-error certificate (one sparse mat-vec, up to 5 refinements) on every solve. | Gilbert-Peierls with a pivot-tape replay, SIMD supernode panels in the full factor, subtree and ticketed multicore refactor, flat slot tape under 2,048 flops. |
| Factor reuse | Skips numeric work when the CSC values are bit-identical. | The same test (`direct.zig:278`). |
| Newton | Stamp, solve, re-evaluate at the new iterate, node test, device test, then a residual proof: a full restamp with unlimited linearization. Accepts at iteration 0. | ngspice's `niiter.c`: iteration 1 is never accepted, the accepted point is `x_k`. |
| Linear decks | One absolute solve per step, no proof, growth 4x. | Two assemblies and two solves per step, growth 2x. |
| Step control | ngspice's tolerances and `CKTterr`, plus a bound of 0.4 V of device-terminal motion per step. | ngspice's `dctran.c`, statement for statement. |
| Device evaluation | Ports of ngspice's C with hand-written derivatives; array of large structs per family; a fused MOS1 to 3 kernel with a two-level stamp cache. Verilog-A through its own compiler to ahead-of-time Rust or a native JIT. | Verilog-A through VerA, forward-mode duals with `@Vector` derivative lanes, staged parallel stamping, latency bypass. |
| SIMD | None. No `target-cpu`, so baseline SSE2. | Derivative lanes, plane combines, LU panels, lane LU. |
| Threads in one circuit | rayon, at most 8: BSIM4 from 128 instances, MOS1 to 3 from 2,048. Stamping and LU serial. | Up to 8 lanes: eval, limiting, update, refactor. Solve serial. |
| Threads across runs | Frequency points (a circuit clone and a factorization per worker), Monte Carlo, corners, `.alter`. | A job pool across queries; SIMD and GPU lanes across sweep points. |
| Bypass, multirate, partitioning | None by default (a B3SOI bypass behind `.OPTIONS BYPASS`). | Latency bypass on a model allowlist. |
| AC | The 2n real-equivalent system, pivots replayed across frequencies. | Complex lane LU, SIMD across frequencies. |
| GPU | None in the engine. | Device eval, device LU, lanes. |

Source: a read of the tree at that commit, by file
(`crates/rspice-matrix/src/klu.rs`, `sparse.rs`,
`crates/rspice-core/src/engine/transient.rs`, `transient/residual.rs`,
`transient/state_recovery.rs`, `transient/truncation.rs`).

## Mechanisms that transfer

| RSpice does | Where | ESPice today | Lever |
|---|---|---|---|
| One solve per step on a strictly linear deck, and no refactor while `dt` holds | `engine/transient.rs:9819`, `:5468` | Two assemblies and two solves per step. On `rc_ladder_1000` the solve is 54% of Newton time and both solves of a step are the same solve of the same system | [C3](04-levers-cpu.md#c3-linear-circuits-one-confirm-per-factor): exact, by argument |
| Accepts at iteration 0 | `engine/transient.rs:10103` | The confirming iteration is half of all Newton work: 2.0 iterations per step on nearly every deck | None. [C2](04-levers-cpu.md#c2-the-confirming-solve-on-the-held-factor) tried to take the saving without moving the published iterate and was rejected: it needed its own accuracy bound |
| Growth 4x on linear decks | `transient/state_recovery.rs:47` | 2x, ngspice's | Class *mode*: it moves the time grid. Not proposed |
| A per-instance two-entry bit-exact evaluation memo for BSIM4 | `bsim4v8/device/eval_memo.rs` | The bypass compares at a tolerance and re-reads the charge | Covered by [C4](04-levers-cpu.md#c4-bypass-that-pays-on-production-models) |
| Parallel frequency points by cloning the circuit | `engine/ac.rs:3333` | SIMD lanes over one pivot tape, which is already cheaper per point | Nothing to take |

RSpice's certificate and residual proof are the opposite trade: they cost
it a mat-vec per solve and a full restamp per accepted point. ESPice's
equivalents are test-time oracles (the scaled LU residual, the KCL
residual), which is where they belong at this speed.

## Where ngspice still wins

| Deck | ESPice | ngspice | Why |
|---|---|---|---|
| `bench_ngspice_mosamp` (MOS2, n = 25, 215k iterations) | 2.12 s | 1.57 s | Device evaluation is 68% of Newton time on a circuit where 99% of evaluations are latent ([activity census](02-baseline.md#activity)). `softPow` is 13% of the profile in #258: `mos2.va` raises to `1 - mj` where ngspice branches to `sqrt` at `mj = 0.5`. |
| `scaling_inverter_chain_256` (MOS1, n = 261) | 0.406 s | 0.315 s | Below the lane gate, so one thread; eval 72%, update 17%. Median activity 6.6%, yet a latent instance costs about what a full MOS1 evaluation costs ([C4](04-levers-cpu.md#c4-bypass-that-pays-on-production-models)). |
| `scaling_inverter_chain_4k`, one thread | 6.61 s | 5.77 s | The same cost at 8,000 instances, 0.5% median activity. ESPice leads only through its lanes (3.51 s for 25 CPU-seconds). |

ngspice's 0.135 s on `vacask_ring` is not a result: it exits 0 without
running the PSP103 model.
