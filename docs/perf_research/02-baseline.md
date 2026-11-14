# Baseline: where the time goes

Measured 2026-11-10 on `dev/performance` at `9bbd4d7f`, CPU backend,
ReleaseFast, pinned to the P-cores (method in [README.md](README.md)).
Wall times against RSpice and ngspice are in [03-rspice.md](03-rspice.md).
Census lines come from the throwaway counters in
[census.patch](census.patch); a census build's timings are not used.

The post-layout decks (`chain`, `ring`, `sram`, `logic` with BSIM4 or
PSP103, 1k and 10k transistors plus extracted R and C) are generated; the
corpus has nothing above 8,000 devices.

## The Newton split

Transient job, default threads (8 lanes where the lane gate admits them).
Shares of the Newton time; `it/step` is iterations per attempted step.

| Deck | n | steps | it/step | eval | load | factor | solve | update | wall s |
|---|---|---|---|---|---|---|---|---|---|
| `rc_ladder_1000` | 1,003 | 10,123 | 2.00 | 26% | 5% | 3% | **54%** | 12% | 0.52 |
| `scaling_rc_ladder_100k` | 100,003 | 235 | 2.00 | 47% | 13% | 11% | 15% | 14% | 1.57 |
| `vacask_rc` | 4 | 1,006,012 | 2.00 | 34% | 14% | 10% | 19% | 23% | 0.71 |
| `vacask_graetz` | 10 | 1,000,007 | 2.00 | 44% | 5% | 18% | 12% | 21% | 2.06 |
| `vacask_mul` | 12 | 500,016 | 2.04 | 42% | 5% | 18% | 14% | 21% | 1.11 |
| `bench_ngspice_mosamp` | 25 | 100,613 | 2.14 | **68%** | 1% | 8% | 3% | 21% | 2.35 |
| `ring51` | 57 | 4,013 | 2.89 | 70% | 1% | 7% | 4% | 18% | 0.24 |
| `vacask_ring` | 30 | 20,421 | 3.05 | 82% | 0% | 2% | 1% | 15% | 1.97 |
| `scaling_inverter_chain_256` | 261 | 1,046 | 3.98 | 72% | 0% | 7% | 4% | 17% | 0.44 |
| `scaling_inverter_chain_4k` | 4,005 | 1,047 | 3.98 | 60% | 2% | 15% | 9% | 14% | 3.55 |
| `scaling_parallel_inverters_2000` | 2,005 | 580 | 2.24 | 69% | 2% | 8% | 4% | 17% | 0.56 |
| `chain_bsim4_1k` | 4,521 | 531 | 2.03 | 40% | 3% | 31% | 12% | 13% | 0.59 |
| `ring_bsim4_1k` | 4,295 | 1,013 | 2.01 | 37% | 3% | 33% | 13% | 14% | 1.08 |
| `sram_bsim4_1k` | 1,741 | 528 | 2.06 | 31% | 1% | 49% | 5% | 13% | 0.74 |
| `logic_bsim4_1k` | 3,967 | 774 | 2.53 | 18% | 1% | **58%** | 7% | 16% | 2.32 |
| `chain_psp103_1k` | 5,521 | 531 | 2.90 | 49% | 4% | 27% | 10% | 11% | 0.95 |
| `logic_psp103_1k` | 5,051 | 774 | 3.02 | 25% | 2% | 54% | 7% | 13% | 3.98 |
| `chain_bsim4_10k` | 44,925 | 269 | 2.04 | 44% | 6% | 24% | 12% | 14% | 4.38 |
| `ring_bsim4_10k` | 44,129 | 513 | 2.02 | 39% | 5% | 31% | 13% | 12% | 7.57 |
| `chain_psp103_10k` | 54,925 | 269 | 2.87 | 52% | 5% | 22% | 11% | 10% | 10.5 |
| `sram_bsim4_10k` | 17,053 | 528 | 2.09 | 15% | 1% | **73%** | 6% | 5% | 14.1 |
| `logic_bsim4_10k` | 38,619 | 389 | 2.86 | 7% | 1% | **86%** | 5% | 2% | 50.1 |

Three profiles:

- **Thick factors** (`logic`, `sram`): the refactor is 49 to 86% of Newton
  time, at 8 lanes.
- **Thin factors and small circuits**: device evaluation is 40 to 82%.
- **Linear circuits**: the triangular solve leads, because the factor is
  already skipped.

No deck rejected a step for Newton failure. LTE rejections are under 1%
except on the MOS1 chains (12%), `vacask_ring` (3.5%) and
`scaling_parallel_inverters_2000` (1.4%).

## Thread scaling

One lane against eight (`ESPICE_THREADS`, `ESPICE_SOLVER_THREADS`).
Milliseconds in the transient Newton loop.

| Deck | wall s | eval | factor | solve | update | CPU-s at 8 |
|---|---|---|---|---|---|---|
| `scaling_inverter_chain_4k` | 6.91 / 3.19 (2.2x) | 3,762 / 1,434 (2.6x) | 314 / 303 (1.0x) | 219 / 217 | 840 / 274 (3.1x) | 23.8 |
| `chain_bsim4_1k` | 1.61 / 0.56 (2.9x) | 806 / 168 (4.8x) | 263 / 137 (1.9x) | 48 / 50 | 168 / 56 (3.0x) | 4.8 |
| `ring_bsim4_1k` | 3.15 / 1.02 (3.1x) | 1,506 / 312 (4.8x) | 640 / 284 (2.3x) | 102 / 100 | 315 / 105 (3.0x) | 9.4 |
| `sram_bsim4_1k` | 1.83 / 0.74 (2.5x) | 837 / 200 (4.2x) | 510 / 315 (1.6x) | 33 / 32 | 168 / 85 (2.0x) | 6.7 |
| `logic_bsim4_1k` | 4.81 / 2.31 (2.1x) | 1,627 / 377 (4.3x) | 2,211 / 1,209 (1.8x) | 146 / 147 | 293 / 319 (0.9x) | 17.4 |
| `chain_bsim4_10k` | 10.1 / 4.38 (2.3x) | 4,342 / 1,084 (4.0x) | 1,688 / 602 (2.8x) | 358 / 303 | 923 / 345 (2.7x) | 20.8 |
| `ring_bsim4_10k` | 18.2 / 7.57 (2.4x) | 8,057 / 2,180 (3.7x) | 4,033 / 1,699 (2.4x) | 690 / 704 | 1,730 / 690 (2.5x) | 38.5 |
| `sram_bsim4_10k` | 37.1 / 14.1 (2.6x) | 8,638 / 1,919 (4.5x) | 23,066 / 9,448 (2.4x) | 810 / 813 | 1,743 / 659 (2.6x) | 97.1 |

Eight lanes buy 2.1x to 3.1x of wall. Evaluation scales 3.7x to 4.8x on
BSIM4 (2.6x on MOS1), the refactor 1.6x to 2.8x, the solve not at all, and
the whole costs 2.6 to 4.1 times the CPU-seconds of one lane. A query never
takes more than 8 lanes (`ThreadPool.per_query`, `exec_config.zig:114`), on
a machine with 8 P-cores and 16 E-cores.

## The refactor

`F` is multiply-subtract pairs per refactor of the transient's pivot
sequence. Throughput is `F` over the time of one refactor.

| Deck | n | L+U | fill | F | ms, 1 lane | pairs/ns | ms, 8 lanes | pairs/ns |
|---|---|---|---|---|---|---|---|---|
| `chain_bsim4_1k` | 4,521 | 54.6k | 2.5x | 0.24 M | 0.244 | 0.98 | 0.131 | 1.8 |
| `ring_bsim4_1k` | 4,295 | 59.3k | 2.9x | 0.32 M | 0.315 | 1.01 | 0.145 | 2.2 |
| `sram_bsim4_1k` | 1,741 | 45.0k | 4.4x | 0.78 M | 0.469 | 1.67 | 0.289 | 2.7 |
| `logic_bsim4_1k` | 3,967 | 92.5k | 4.8x | 1.77 M | 1.13 | 1.57 | 0.621 | 2.9 |
| `chain_bsim4_10k` | 44,925 | 564k | 2.6x | 2.87 M | 3.08 | 0.93 | 1.10 | 2.6 |
| `ring_bsim4_10k` | 44,129 | 624k | 2.9x | 3.85 M | 3.90 | 0.99 | 1.64 | 2.3 |
| `sram_bsim4_10k` | 17,053 | 826k | 8.1x | 40.1 M | 20.9 | 1.91 | 8.58 | 4.7 |
| `logic_bsim4_10k` | 38,619 | 1,675k | 8.9x | 155.7 M | not run | — | 29.2 | 5.3 |

One P-core does at most 1.9 pairs per nanosecond: 3.8 GFLOP/s, 5% of the
core's nominal 72 GFLOP/s. Each pair streams an 8-byte L value and a 4-byte
row index and does a load, a multiply, a subtract and a store through a
dense accumulator. On `sram_bsim4_10k` that is 480 MB per refactor, read
from L3 at 23 GB/s, since each L column is read on average 97 times
(`F` over the L entries). Eight lanes share that stream, which is why the
refactor scales 2.4x. On the thin factors the bound is different: 10 to 12
pairs per axpy, so the loop pays per call, about 11 ns per axpy at one lane.

### Supernode runs

A *run* is a stretch of consecutive entries of one U column whose source
columns are consecutive steps of one supernode (identical L pattern below
the block). The census line `lu-runs` counts how the flops fall:

| Deck | Mean axpy, pairs | F in runs of 1 | 2-3 | 4-7 | 8-15 | 16+ | F in the rectangular part | F in axpys of 32+ rows |
|---|---|---|---|---|---|---|---|---|
| `chain_bsim4_10k` | 10.2 | 44.9% | 31.4% | 12.7% | 10.4% | 0.5% | 49.9% | 9.4% |
| `ring_bsim4_10k` | 12.3 | 34.4% | 22.0% | 26.0% | 17.1% | 0.4% | 58.8% | 10.0% |
| `chain_psp103_10k` | 9.6 | 45.9% | 30.4% | 11.4% | 11.5% | 0.8% | 48.6% | 11.2% |
| `logic_bsim4_1k` | 38.2 | 7.7% | 5.6% | 14.2% | 20.0% | 52.4% | 77.9% | 87.5% |
| `sram_bsim4_1k` | 34.8 | 10.4% | 4.1% | 16.4% | 34.1% | 35.0% | 75.0% | 87.3% |
| `sram_bsim4_10k` | 96.9 | 2.0% | 3.1% | 2.5% | 14.6% | **77.9%** | 84.4% | 98.0% |
| `logic_bsim4_10k` | 185.8 | 1.3% | 0.7% | 1.9% | 5.5% | **90.6%** | 83.4% | 98.7% |

On the 10k thick factors 92 to 96% of the flops sit in runs of 8 or more
columns (69 to 72% at 1k), and under 6% in runs the stored order breaks (a supernode
neighbour present in the column but not adjacent). The corpus decks have no
supernodes worth the name: `scaling_inverter_chain_4k` has `F` of 20,006
for n of 4,005. Dependency depth of the transient factor (`levels`):
`logic_bsim4_10k` 910, `sram_bsim4_10k` 1,034, `chain_bsim4_10k` 653.

## The confirming iteration

A converged step publishes its last linearization point
([the rule](07-prior-work.md#the-published-iterate-rule)): the last factor
and solve only decide "converged", and their result is discarded. The census
`census-confirm` asks what the verdict would have been with the factor held
from the previous iteration instead of a fresh one. `scaled` is the largest
per-row update over its tolerance, so the engine accepts below 1.

| Deck | Confirming iterations | True `scaled` under 0.01 | Held-factor verdict accepts at 0.5 | at 0.25 | Wrong accepts at 0.5 | at 1.0 | Factors saved at 0.5 |
|---|---|---|---|---|---|---|---|
| `chain_bsim4_10k` | 269 | 207 | 265 | 252 | 0 | 0 | 48% |
| `ring_bsim4_10k` | 513 | 466 | 509 | 506 | 0 | 0 | 49% |
| `sram_bsim4_10k` | 528 | 461 | 519 | 502 | 0 | 0 | 47% |
| `logic_bsim4_10k` | 389 | 332 | 365 | 358 | 0 | 0 | 33% |
| `chain_psp103_10k` | 269 | 250 | 268 | 263 | 0 | 0 | 35% |
| `logic_bsim4_1k` | 774 | 403 | 664 | 560 | 0 | 5 | 34% |
| `logic_psp103_1k` | 774 | 361 | 693 | 633 | 0 | 4 | 30% |
| `sram_bsim4_1k` | 528 | 438 | 515 | 506 | 0 | 1 | 47% |
| `chain_bsim4_1k` | 531 | 447 | 517 | 507 | 0 | 0 | 48% |
| `ring_bsim4_1k` | 1,013 | 870 | 1,006 | 997 | 0 | 0 | 49% |
| `scaling_inverter_chain_4k` | 1,186 | 896 | 1,157 | 1,140 | 0 | 1 | 25% |
| `ring51` | 4,006 | 795 | 3,731 | 3,506 | 0 | 0 | 32% |
| `bench_ngspice_mosamp` | 83,178 | 39,031 | 82,481 | 81,247 | 0 | 0 | 38% |
| `vacask_graetz` | 1,000,007 | 997,688 | 1,000,007 | 1,000,007 | 0 | 0 | 50% |
| `vacask_mul` | 500,027 | 457,883 | 496,084 | 493,202 | 0 | 11 | 49% |

A *wrong accept* is a held-factor verdict under the margin where the fresh
factor's verdict was "not converged". There is none at a margin of 0.5 on
any deck, and at most 11 in 500,027 at a margin of 1.0. The two verdicts'
histograms agree to within 8 counts per bin on every deck: the held factor
gives the same update to the precision the test needs. On the 10k decks 77
to 93% of confirming iterations move the solution by under 1% of the
tolerance.

On the three linear decks (`rc_ladder_1000`, `scaling_rc_ladder_100k`,
`vacask_rc`) every step converges at the second iteration and the matrix is
bitwise unchanged at it, so the factor is already skipped: 10,130 of
10,130, 235 of 235 and 1,006,014 of 1,006,014 steps. What is left of the
confirming iteration there is an evaluation and a solve.

## The bypass

`census-bypass`, counted over the evaluations the bypass looks at (a step's
first iterate is never one of them). The shipped rule turns a batch off for
the rest of the run when hits fall under one in five after four evaluations
per instance.

| Deck | Model | Hits when the rule decided | Outcome |
|---|---|---|---|
| `scaling_inverter_chain_4k` | mos1 | 99% | on |
| `scaling_inverter_chain_256` | mos1 | 89 to 96% | on |
| `ring51` | mos1 | 48% | on |
| `logic_psp103_1k`, `chain_psp103_10k` | psp103 | 33%, 34% | on |
| `chain_psp103_1k` | psp103 | 19.9% after 268 evaluations per instance | **off**, about 190 iterations into the transient (the operating point takes 74) |
| `bench_ngspice_mosamp` | mos2 | 20.0% after 1,157 evaluations per instance | **off**, about 670 iterations into a transient of 215,274 (the operating point takes 485) |
| `chain`, `ring`, `logic`, `sram` with BSIM4, 1k and 10k | bsim4va | 19 to 20% after 4 to 9 evaluations per instance | **off**, during the operating point |
| `scaling_parallel_inverters_2000` | mos1 | 0% after 4 | **off**, during the operating point |
| `vacask_graetz`, `vacask_mul` | diode | 0% after 4 | **off**, during the operating point |

### Why it misses

The same decks with the off switch disabled, so the transient's own hit
rate can be read, and every miss counted by the first test it fails
([census-bypass.patch](census-bypass.patch), a Debug build; counts do not
depend on the optimization level). Shares of all evaluations of the model
between the first and the last power-of-two review of the run:

| Deck | Model | First iterate, never eligible | Hit | Miss: instance bytes changed | Miss: unknowns moved past tolerance | Shipped rule turns it off at review |
|---|---|---|---|---|---|---|
| `chain_bsim4_1k` | bsim4va | 49.1% | 0.2% | **49.1%** | 1.6% | 7 |
| `sram_bsim4_1k` | bsim4va | 48.5% | 2.2% | **47.5%** | 1.8% | 1 |
| `logic_bsim4_1k` | bsim4va | 39.3% | 14.9% | **39.2%** | 6.6% | 4 |
| `bench_ngspice_mosamp` | mos2 | 46.1% | 11.1% | **42.3%** | 0.5% | 2,740 |
| `scaling_parallel_inverters_2000` | mos1 | 44.3% | 19.7% | 24.4% | 11.6% | 1 |
| `ring51` | mos1 | 36.0% | 30.8% | 27.2% | 5.9% | never |
| `scaling_inverter_chain_4k` | mos1 | 24.8% | 74.5% | 0.5% | 0.2% | never |
| `chain_psp103_1k` | psp103 | 34.4% | 11.0% | 0.0% | **54.6%** | 573 |
| `vacask_graetz` | diode | 50.0% | 0.8% | 0.0% | **49.2%** | 1 |
| `vacask_mul` | diode | 49.0% | 0.7% | 0.0% | **50.3%** | 1 |

A limiter correction or a missing recording is under 0.1% of evaluations
on every deck in the transient; a plane-key mismatch never occurs.

Three populations:

- **BSIM4 and MOS2 miss on bytes, not on voltages.** Of the evaluations
  past the first iterate, 96.5% on `chain_bsim4_1k`, 92.3% on
  `sram_bsim4_1k`, 64.6% on `logic_bsim4_1k` and 78.6% on
  `bench_ngspice_mosamp` fail the whole-row compare of the instance
  (`batch_bypass.zig:195`), and 3.2%, 3.5%, 10.9% and 0.9% fail the
  tolerance test. The row holds something each step rewrites. The byte
  test runs first, so how many of those instances also moved is not
  known: the tolerance figures are lower bounds, the latent shares upper
  bounds. Which bytes move was not chased.
- **PSP103 and the diode decks miss on tolerance.** Their rows never
  change. `chain_psp103_1k` moves past the tolerance on 83% of eligible
  evaluations, the rectifier and the multiplier on 98%. For the diodes the
  off switch is the right verdict; for PSP103 the tolerance itself is the
  question.
- **The first iterate is 25 to 50% of all evaluations** and is never
  replayed.

Left on, the bypass would hit on 24.6% of eligible evaluations on
`logic_bsim4_1k` and 35.4% on `scaling_parallel_inverters_2000`, both of
which the shipped rule turns off during the operating point.

### Activity

Carried over from the previous round's census (`gpu-convergence.md` section
9.2 at `9502bb6f^`), not re-measured: the share of model instances whose
unknowns moved past the bypass tolerance since their own last evaluation.

| Deck | Model instances | Median active | Mean active |
|---|---|---|---|
| `scaling_inverter_chain_4k` | 8,000 | 0.5% | 0.5% |
| `scaling_inverter_chain_256` | 512 | 6.6% | 6.4% |
| `scaling_parallel_inverters_2000` | 4,000 | 0% | 26.9% |
| `bench_ngspice_mosamp` | 27 | 0% | 1.2% |
| `bench_tran_fourbitadder` | 288 | 30.6% | 32.0% |
| `vacask_mul` | 4 | 50% | 45.0% |
| `vacask_ring` | 18 | 100% | 91.6% |

Two decks here are latent almost everywhere and run with the bypass off:
`bench_ngspice_mosamp` and `scaling_parallel_inverters_2000`. Device
evaluation is 68% and 69% of their Newton time. The activity of the
post-layout decks has not been measured.

## The operating point

| Deck | OP iterations | Full factors | F per pivot epoch, smallest to largest | OP share of wall |
|---|---|---|---|---|
| `sram_bsim4_10k` | 26 | 2 | 40.1 M | 3% |
| `logic_bsim4_10k` | 80 | 20 | 155.7 M to **2,185 M** | 23% (11.0 s in factors) |
| `chain_bsim4_10k` | 78 | 14 | 2.9 M to 103.9 M | 30% |
| `chain_psp103_10k` | 611 | 22 | 3.0 M to 17.6 M | 44% |
| `logic_psp103_1k` | 616 | 2 | 1.6 M | 24% |

Two separate costs. On the BSIM4 decks the ladder's pivot sequences leave
the diagonal the ordering was computed for, and fill grows from 8.9x to as
much as 26.5x on `logic_bsim4_10k`: the 20 epochs together hold 16.2 G
pairs, 104 transient refactors' worth, before counting the 60 refactors
that replay them. On the PSP103 decks the ladder itself takes 611 and 616
iterations, and most of them belong to attempts that fail. The trace of
`logic_psp103_1k` (`ZP_OPDBG=1`): plain Newton stops at its 100-iteration
budget, then four gmin rungs stop at 100 each before a rung converges, so
about 500 of the 616 iterations produce nothing that is kept.

## Not measured

- No GPU run ([05-levers-gpu.md](05-levers-gpu.md) cites recorded data).
- No profiler: `perf` is not installed on this machine. Function-level
  shares are quoted from #258.
- `logic_bsim4_10k` at one lane, and anything past 8 lanes (the cap is a
  constant).
- RSpice's and ngspice's waveforms.
