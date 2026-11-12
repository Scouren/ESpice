# GPU levers

Nine work packages, each priced on the roofline before anything is tuned:
the bound named with its arithmetic, the best possible time, then the
change. No GPU ran in this round. Every GPU time below is from
`docs/performance/gpu-phases.tsv` (RTX 4060 Laptop, driver 595.71, commit
`681b3ccd`, 2026-11-04, CUPTI traces, walls median of three) or from the
issue cited, and every other card is a prediction of
`tools/gpu_extrapolate.py` from those traces.

The device LU's evidence (chain model, roofline per card, literature, what
keeps the host's bits) is in [10-device-lu-chain.md](10-device-lu-chain.md);
what binds on an FP64-class card once these are in is in
[09-after-the-levers.md](09-after-the-levers.md#class-6-an-fp64-class-card).

## The two machines

| | RTX 4060 Laptop (measured, `tools/gpu_devices.json`) | A100 80 GB (datasheet) | i9-14900HX, 8 P-cores (nominal) |
|---|---|---|---|
| FP64 | 207 GFLOP/s | 9,700 GFLOP/s | 8 x 2 FMA ports x 4 lanes x 2 x 4.5 GHz = 576 GFLOP/s |
| FP32 | 12,550 GFLOP/s | 19,500 GFLOP/s | twice the FP64 figure |
| Memory | 227 GB/s DRAM, 1.0 TB/s inside a 32 MB L2 | 2,039 GB/s | about 23 GB/s per core out of L3 ([C1](04-levers-cpu.md#c1-supernode-panels-in-the-refactor-replay)) |
| Host link | 12.5 GB/s | 25 GB/s | — |

On this laptop the CPU out-computes the GPU in FP64 by about 3x. The card
leads only on memory bandwidth and on FP32. So a kernel that is FP64
compute-bound belongs on the host here, and "this belongs on the CPU" is
the expected verdict for half of what follows. An A100 inverts it: 17x the
P-cores' FP64. Every lever below says which machine it is for.

## Where the GPU wall goes

Measured on the 4060, `--backend cuda`:

| Deck | Path | CPU wall | GPU wall | Host share of GPU wall | Kernels | Largest kernel |
|---|---|---|---|---|---|---|
| `lanes_hb_diode_2048` | HB lanes | 6.26 s | 23.3 s | 100% | 0.00 s | — |
| `lanes_ac_bsim4_8192` | AC lanes | 1.25 | 4.14 | 99% | 0.02 | — |
| `lanes_op_bsim4_8192` | OP lanes | 0.17 | 0.59 | 94% | 0.02 | — |
| `lanes_pss_diode_2048` | PSS lanes | 0.55 | 1.43 | 80% | 0.22 | — |
| `logic_bsim4_10k`, host LU | device eval | 57.9 | 49.0 | 94% | 2.31 | host refactor |
| `logic_bsim4_1k` | device eval | 3.10 | 3.19 | 75% | 0.71 | `arp_eval_bsim4va` 60% |
| `scaling_inverter_chain_4k` | device eval | 3.45 | 2.81 | 64% | 0.77 | `arp_eval_mos1` 34%, reduce 32% |
| `logic_bsim4_10k` | device eval and LU | 57.9 | 47.2 | 51% | 19.7 | `arp_lu_refactor16` 62% |
| `sram_bsim4_10k` | device eval and LU | 18.0 | 13.3 | 11% | 11.6 | `arp_lu_refactor16` 49% |
| `logic_psp103_10k` | device eval and LU | 61.5 | 32.5 | 14% | 27.2 | `arp_lu_refactor16` 58% |
| transient lanes, 1,024 points | lanes | 1.73 | 3.40 | 13% | 2.95 | `arp_leval_bsim4va` |
| transient lanes, 8,192 points | lanes | 14.6 | 9.45 | 26% | 6.97 | `arp_leval_bsim4va` 71% |

Three regimes, and the lever differs for each:

1. **The host is the wall** (lane sweeps other than transient, and every
   deck that keeps the LU on the host). A faster card changes nothing: the
   A100 prediction for these rows is 1.0x to 1.3x of the 4060.
   [G1](#g1-lane-groups-host-work-on-the-pool-then-a-batched-dense-lu),
   [G3](#g3-operating-point-pivot-epochs-stay-on-the-host),
   [G5](#g5-a-resident-newton-loop-where-the-host-is-the-bound).
2. **The device LU is the wall** (thick factors): 75% to 90% of kernel
   time. Its refactor spends about 1,700 clock cycles on each step of a
   3,000-step chain and moves ten times the bytes it needs, and its tail
   solves are a dependent chain.
   [G2](#g2-supernode-panels-in-the-device-lu),
   [G7](#g7-the-dense-tail-of-the-device-solves).
3. **The lane evaluation is the wall** (transient sweeps). FP64-bound on
   this card, chain-bound on an FP64-class one.
   [G4](#g4-f32-derivative-lanes-on-fp64-poor-cards),
   [G8](#g8-lane-kernels-one-thread-per-instance-and-lane),
   [G9](#g9-lanes-of-a-thick-circuit),
   [G6](#g6-placement-by-price-on-a-datacenter-card).

## What binds each kernel

A card with 47 times the FP64 rate does not run these kernels 47 times
faster, because FP64 is not what most of them wait for. The table prices
each recorded kernel with the model in `tools/gpu_extrapolate.py`: per
launch, the time each ceiling alone would take, from counted warp
instructions, FP64 warp instructions and 32-byte memory sectors. `lat` is
one warp's own instruction chain at 4 cycles an instruction, which is the
floor when the grid is too small to fill the card. Microseconds per launch.

| Kernel (deck) | 4060, measured | 4060 terms: fp64 / issue / mem / lat | A100 terms | Binds on an A100 | A100, predicted |
|---|---|---|---|---|---|
| `arp_lu_refactor16` (`logic_bsim4_10k`) | 10,290 | 5,885 / 3,061 / **13,111** / 15 | 126 / 985 / **2,914** / 22 | the column chain and memory traffic (two readings, below) | 2,290 to 4,570 |
| `arp_lu_upanel` (same) | 2,112 | 37 / 27 / 78 / **109** | 2 / 20 / 17 / **158** | chain | 2,110 to 3,060 |
| `arp_lu_lpanel` (same) | 1,110 | 33 / 10 / 62 / 39 | 2 / 7 / 14 / **57** | chain | 1,020 to 2,040 |
| `arp_lu_uhead`, `arp_lu_lhead` (same) | 941, 668 | mem 1,310, 103 | mem 291, 23 | memory traffic | 360 to 1,010 together |
| `arp_eval_bsim4va` (same, 10,688 threads) | 978 | **849** / 32 / 245 / 36 | 23 / 13 / **55** / 52 | memory, then chain | about 60 |
| `arp_leval_bsim4va` (8,192-point sweep, 3,712 threads) | 3,692 | **4,499** / 172 / 711 / 458 | 144 / 83 / 158 / **663** | chain | 800 to 1,600 |
| `arp_lchg_bsim4va` (same) | 1,120 | **1,136** / 50 / 66 / 133 | 36 / 24 / 15 / **193** | chain | — |

Read across a row. On the 4060 the evaluation kernels are FP64-bound, as
[G4](#g4-f32-derivative-lanes-on-fp64-poor-cards) says. On an A100 the
FP64 term all but vanishes and what is left is the same in every row:
**bytes moved through index tables, and chains of dependent steps.** The
whole device LU call on `logic_bsim4_10k` goes from 15.1 ms to between 5.8
and 10.7 ms, and 3.1 to 5.1 ms of that is the two tail solves, which do
not speed up at all (the A100's clock is lower than the 4060's). On
`sram_bsim4_10k` the tail solves are 3.3 of the 4.5 ms the best case
predicts.

**Two readings of the refactor.** The tool's memory term says the kernel
moves sectors at the L2's rate: 13.1 ms predicted against 10.3 measured on
`logic_bsim4_10k`, 7.9 against 8.9 on `logic_psp103_10k`. But it predicts
2.5 ms on `sram_bsim4_10k`, which takes 5.1. A second model fits all three:

```text
T = 0.847 us * S_r + 50 ps * F
```

where `F` is the multiply-subtract pairs and `S_r` the steps on the
critical path (2,959 on logic, 3,617 on sram: one per source column a
trunk column takes, plus its pivot step). Fitted on the two BSIM4 decks, it
predicts the PSP103 deck 12% high. In it the chain is 24% of the logic
refactor and 60% of the sram one, and 69 to 88% of the counted sectors
would be waiting blocks polling done stamps (an inference from the sector
arithmetic, not a counter): a symptom of the chain, not a cost of the
arithmetic. One chain step costs about 1,730 clock cycles where its
arithmetic needs 8, or about 88 with a division. The two readings agree on
what an A100 does with today's kernel (2.3 to 4.6 ms) and on the fix, and
they are told apart by three small timings
([10-device-lu-chain.md](10-device-lu-chain.md#6-ranked-list-for-an-fp64-class-card),
M0), which is G2's first step.

So the answer to "the card has far more FLOPs, why does it not pay" has
three parts, each a lever:

| What hides the FLOPs | Where | Lever | Class |
|---|---|---|---|
| A chain of about 3,000 steps at 0.85 µs each, and 84 bytes moved per multiply-subtract pair against 8 needed | refactor | [G2](#g2-supernode-panels-in-the-device-lu) | exact |
| A chain of steps in fixed order, one per tail row | tail solves | [G7](#g7-the-dense-tail-of-the-device-solves) | exact, then rounding |
| A grid too small to fill the card: one thread walks a whole lane | lane kernels | [G8](#g8-lane-kernels-one-thread-per-instance-and-lane), [G9](#g9-lanes-of-a-thick-circuit) | exact |
| The host between kernels | every path | [G3](#g3-operating-point-pivot-epochs-stay-on-the-host), [G1](#g1-lane-groups-host-work-on-the-pool-then-a-batched-dense-lu), [G5](#g5-a-resident-newton-loop-where-the-host-is-the-bound) | exact |

What the stack is worth on an A100, per deck. Every figure is the model's
prediction with the lever's effect entered by hand (G2 as one eighth of the
sectors and half the instructions; G7 as a tail of 0.3 ms), so read them as
orders of magnitude. The chain model is less generous: a refactor of 0.4 to
1.2 ms and a tail at 0.37 of today's give an LU call of 2 to 4 ms, the
last row but two:

| | `logic_bsim4_10k` | `sram_bsim4_10k` | `logic_psp103_10k` |
|---|---|---|---|
| CPU wall, 8 lanes (at the trace's commit) | 57.9 s | 18.0 s | 61.5 s |
| 4060, measured | 47.1 s | 13.3 s | 32.5 s |
| A100, today's kernels | 33 to 39 s | 6.8 to 11 s | 14 to 22 s |
| LU call: today on the 4060 | 15.1 ms | 8.8 ms | 13.9 ms |
| LU call: A100, today's kernels | 5.8 to 10.7 ms | 4.5 to 8.3 ms | 4.9 to 9.5 ms |
| LU call: A100 with G2 | 4.0 to 6.6 ms | 3.6 to 5.4 ms | 3.2 to 5.9 ms |
| LU call: A100 with G2 and G7 | 1.2 to 1.8 ms | 0.6 to 0.9 ms | 1.3 to 2.5 ms |
| the same, chain model, G7 stage 1 only | 2 to 4 ms | 2 to 4 ms | 2 to 4 ms |
| Wall: A100 with G2 and G7 (both models) | 27 to 31 s, over 90% of it host | 2.4 to 6 s | 7 to 13 s |
| and with G3 and [C8](04-levers-cpu.md#c8-the-operating-point) | about 10 s | — | — |

The transient of `logic_bsim4_10k` is 1,110 iterations of about 34 ms on
the CPU. With G2 and G7 an A100 runs one in 1.5 to 4 ms. What remains is
the operating point on the host (9 s of table builds and 11 s of full
factors in the trace), which is why G3 and C8 are in this list.

## G1 Lane groups: host work on the pool, then a batched dense LU

**Class:** exact (stages 1 and 2). **Issue:** #260, then #228.
**Machine:** any; stage 3 is for an FP64-class card.

**Bound: overhead.** The GPU is busy 0 to 20% of the wall (0.1 ms of 23 s on
`hb_2048`). A lane group runs its members' host work on one executor
thread, so 2,048 queries that the CPU backend runs 14 at a time become
about 3 serial chains (`executor_lanes.zig:79`, and the frequency-lane loop
near `:344`).

**Speed of light.** With the GPU doing none of the heavy work, the floor is
the CPU backend's wall: 6.2 s for `hb_2048` against 23.8 s, 1.25 s for
`ac_8192` against 4.1 s. Stage 1 can reach it and no more.

**Change.**

1. Fan the per-member host work (`finishAlone`, the per-lane spectral
   Newton, `solveBatchSerial`) over the session pool. Members are
   independent: each owns its circuit and context. Results keep their order.
   Done when `hb_2048` under `cuda` is within 10% of the `cpu` wall and the
   user-CPU to wall ratio is at least 10.
2. Do not form a lane group when the group's heavy work is host work: a
   `lanes` term in the price (#249 stage 4) that counts it. Done when the
   placement oracle sends the four sweep decks to the CPU on this card.
3. HB only, FP64-class cards only: a batched dense LU of the harmonic
   systems on the device. `dense_lu.eliminateBlocked` is 94% of 88
   CPU-seconds on `hb_2048` on both backends. It is compute-bound FP64, and
   a batch of equal-size dense factors is the shape a GPU is built for. On
   the 4060 the arithmetic says no (207 GFLOP/s against the pool's 576
   nominal). On an A100 the same flops have a 17x ceiling over the P-cores.
   Before building: count the flops (`2/3 m^3` per harmonic system times
   factors) and divide by 9.7 TFLOP/s. Done when that number is written
   down and is under a fifth of the CPU wall, or the stage is closed.

**Oracle and gate.** The host path per member is the oracle: raw outputs
byte-identical between `cpu` and `cuda` on the four sweep decks, the GPU
corpus (`--backend cuda --jobs 1`) verdicts unchanged by name, 1 against 8
threads byte-identical. Stage 3: each lane's factor against
`eliminateBlocked` on the host, bitwise if the elimination order is kept.

## G2 Supernode panels in the device LU

**Class:** exact. **Issue:** #222 (bars), #219 (launch cost afterwards).
**Machine:** an FP64-class card. On the 4060 the kernel becomes FP64-bound
at 5.9 ms and the verdict after
[C1](04-levers-cpu.md#c1-supernode-panels-in-the-refactor-replay) is
expected to be "host".

**Bound: the column chain, with memory traffic behind it; not
arithmetic.** One call of `arp_lu_refactor16` on `logic_bsim4_10k`
performs 155.7 M multiply-subtract pairs in 10.3 ms. Only 3% of its warp
instructions are FP64, and an FP64 warp instruction has about half its
lanes working. Two things take the time
([What binds each kernel](#what-binds-each-kernel),
[10-device-lu-chain.md](10-device-lu-chain.md#1-what-binds-today-measured)):

- **The chain.** A column takes its source columns one U entry at a time
  in the host's stored order and waits for each to be published. The
  critical path is 2,959 such steps over 910 column levels (3,617 over
  1,034 on `sram_bsim4_10k`), at about 0.85 µs a step: 2.5 and 3.1 ms. On
  one column level sit about 12 block-wide barriers, 2 or 3 dependent
  global-memory round trips, 3 divisions in sequence, and a 7-barrier
  column-max tree for the growth test that runs before the column is
  released (`kernels/lu.zig`, `column`).
- **The bytes.** 409.7 M sectors a call, 13.1 GB, against 1.25 GB if each
  pair loaded one L value: a `dmap` index per pair (311 MB of them,
  streamed from DRAM), loads that straddle sectors, columns wider than
  `col_max` = 256 working in global memory, and the done-stamp polls of
  waiting blocks.

**Speed of light.** Per refactor of `logic_bsim4_10k`, with the pair kept
as two operations:

| | 4060 | A100 |
|---|---|---|
| Arithmetic | **3.0 ms** | 0.064 ms |
| L values through L2, 8 bytes a pair | 1.25 ms | **0.28 ms** (the L2 rate is an estimate) |
| Chain at its own latency (8 cycles a step, 88 with a division) | 0.05 ms | 0.07 ms |
| Chain at today's step | 2.5 ms | 2.5 to 3.6 ms |
| Now | 10.3 ms measured | 2.3 to 4.6 ms predicted |

On the 4060 arithmetic binds, and the host's P-cores do the same pairs in
1.1 ms nominal: after C1 the verdict there is "host". On an A100 today's
chain is ten times every hardware term. An axpy-form kernel cannot become
FP64-bound there at all: it does 0.25 flop per byte of L against a balance
point of 1.08, so each loaded L value has to feed five or more pairs.

**Change.** Three parts, all exact
([mapping](10-device-lu-chain.md#5-mapping-onto-kernelsluzig-and-lu_tableszig)):

1. *Shorter steps in today's kernel* (M3). Release the column before the
   growth test: waiters need the values, not the verdict. Issue the next
   step's `dmap` and L loads ahead of the step-end barrier. Keep the U part
   of a wide column in shared memory.
2. *The destination supernode chunk as the ticket unit* (M1). A chunk is
   consecutive columns of one supernode. External source runs are applied
   to all its columns with no barrier inside a run's rectangular part, the
   lanes striding rows and each running `acc -= L[i, s] * u` in run order,
   which is the host's `panelRows`. Then an in-chunk sweep, one step per
   column. Levels collapse inside a chunk, one row-to-slot map per (chunk,
   source supernode) replaces a `dmap` entry per pair, and one L value
   feeds every column of the chunk. Source runs alone, without destination
   chunks, cut the chain by at most 1.63x to 1.75x.
3. *Where the panel lives.* 48 KB of shared memory is about 5,900 slots
   and one trunk column is up to 1,143 rows (2,001 on sram), so a chunk of
   wide columns works in `val`, with the active pivot column and the run's
   U values staged in shared memory.

Per value slot the subtractions keep the host's stored order and nothing
is contracted, so the factor stays bitwise `refactorColumns`'s. The stored
U order is the DFS order, not ascending, so a supernode's columns can be
non-adjacent in it: 1.2 to 7.0% of the pairs sit in such broken runs and
stay on today's per-column path. Relaxed supernodes are out: a stored zero
can flip a signed zero.

**Expected.** Refactor on an A100 from 2.3 to 4.6 ms to 0.4 to 1.2 ms on
`logic_bsim4_10k`, as `H * a + (S_r - H) * t_in` with H the hand-offs on
the critical path between chunks; neither H nor the in-chunk step `t_in` is
measured. Against the host's 8 lanes: 29.2 ms today, about 8 ms after C1.

**Oracle and gate.** The host panel replay of C1 is the oracle
(`ESPICE_GPU_LU_CHECK=1`, 0 mismatches on `logic_bsim4_2k`,
`logic_bsim4_10k`, `sram_bsim4_30k`); raws byte-identical to the host run
on the five device-LU decks. Report the time per chain step, sectors per
pair, FP64 share of warp instructions and the fraction of the roofline
reached; under 70% means the bound moved, so classify it again.

**Steps.**

1. Land C1 on the host. Refit #222's admission bars against it on the 4060
   and record which decks, if any, still prefer the device.
   Done when the bars are measured values with the new host kernel.
2. *Measure the step* (M0; one small kernel each, no solver change; any
   card): the refactor with `refactor_growth_limit = 0` against the
   default, which gives the barrier time; a two-block ping-pong through a
   done stamp, for the hand-off; a block doing K barrier steps of one
   multiply-subtract through shared and through global memory, for the
   in-chunk step. Done when the 0.85 µs step is attributed.
3. Part 1 of the change, as an A/B on today's kernel. Done when the time
   per chain step is reported before and after; watch resident blocks
   (registers per thread).
4. Offline, no GPU: from the epoch tables, H (the critical path with
   chunks as nodes), the chunk sizes along it, and the share of pairs
   whose in-chunk sources come last in stored order. Go if
   `H * a + (S_r - H) * t_in` is under half of `a * S_r`.
5. Build the chunk kernel body once for the device and for host threads,
   as `kernels/lu.zig` does today. Done when the gate passes on the host
   threads build, before any GPU run.
6. Measure on the GPU, with `ncu` counters for sectors and DRAM bytes.
   Done when the roofline fraction is reported.

## G3 Operating-point pivot epochs stay on the host

**Class:** exact. **Issue:** #261, #249 stage 4. **Machine:** any.

**Bound: overhead.** `logic_bsim4_10k` under the device LU: 19 pivot epochs
during the operating point, each a host full factor plus a table build and
upload, 6.0 s of `load_ms` and 3.1 s of `build_ms` on one thread out of a
33.6 s wall. The transient reuses one epoch for 1,110 refactors.

**Speed of light.** Zero table builds during the operating point, so the
floor is the host's own operating point. That is not free, and the issue's
option 1 should be priced against it: the CPU backend spends 11.0 s in 80
operating-point factors on this deck at 8 lanes
([02-baseline.md](02-baseline.md#the-operating-point)), against about 9 s
of epoch work plus 1.2 s of device calls. The gain from moving the
operating point to the host is therefore small until
[C8](04-levers-cpu.md#c8-the-operating-point) cuts the host's cost. The
lever that pays on both backends is fewer epochs and a cheaper full factor.

**Change.**

1. Admit the device LU only once a pivot sequence has survived N refactors
   (the transient's case). Until then the LU runs on the host with
   `lu_threads`. Done when `gpu-lu (op)` reports `epochs` of at most 2 on
   the three 10k decks and the operating-point time is not worse.
2. Then C8, on the host, for both backends.

**Oracle and gate.** Raw output byte-identical (the pivot rule does not
change, only where the factor runs); `ESPICE_GPU_LU_CHECK=1` 0 mismatches;
`cuda` wall and operating-point time before and after on
`logic_bsim4_10k`, `sram_bsim4_10k`, `logic_psp103_10k`.

## G4 f32 derivative lanes on FP64-poor cards

**Class:** tolerance. **Issue:** none (P2 in the previous round).
**Machine:** cards with FP64 at 1/64 of FP32, which is every consumer
NVIDIA card. Pointless on an A100 (FP64 at 1/2).

**Bound: compute, in the FP64 pipe.** The lane evaluation
`arp_leval_bsim4va` is 71% of kernel time on the 8,192-point transient
sweep, at 255 registers a thread, with 43% of its instructions in the FP64
pipe. On this card an FP64 instruction costs 64 FP32 ones, so nearly all of
its 3.7 ms a launch is those instructions.

**Speed of light.** The value half of a dual stays f64 (the residual never
changes). If a fraction d of the FP64 instructions are derivative lanes and
move to FP32, kernel time falls toward `1 - d` of today's. With d at 0.8
(to be measured: count FP64 instructions of the `W == 1` value-only kernel
against the full one), the sweep's kernels go 6.97 s to about 2.5 s and the
wall 9.45 s to about 5 s, against 14.6 s on the CPU.

[12-math-and-contract.md](12-math-and-contract.md#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes)
has since counted d at 0.63 from the model's static flop counts, which
puts the sweep at about 6.4 s, and says the contract already allows f32
lanes (step 2 below needs no VerA change).
[14-precision.md](14-precision.md) works the rest through: what an f32
lane does to the published point, a form that keeps it
([H2](14-precision.md#h2-f32-lanes-on-the-confirming-iteration-only): f32
lanes on the confirming iteration only), and why wider substitutes (pairs
of f32 for the values) are closed.

**Why it is tolerance class, and what failed before.** An f32 Jacobian
changes the Newton path, not the residual. The previous round's census
(`ESPICE_F32_PLANES`) measured +0.22% iterations over the corpus and lost
two decks; a GPU build (`-Dgpu-jac-f32`) measured 1.16x and failed four
MOS1 and MOS6 decks by 0.8 to 10%
([07-prior-work.md](07-prior-work.md#closed-in-this-codebase)). The
re-open conditions recorded there are the design: an f64 retry on a Newton
failure, and every linearization that is published (`Circuit.eval` for AC,
noise, sensitivities) kept f64.

**Scope.** Lanes only. On single-circuit device evaluation the kernels are
6 to 38% of the wall, so the same change buys at most 1.2x there.

**Oracle and gate.** The f64 lane kernel is the oracle. The full GPU corpus
passes; every deck whose raw moves is named with its largest move; the four
decks that failed before are in the gate by name. No flag: the card's FP64
ratio selects it, as `auto` already does for lanes.

**Steps.**

1. Measure d (the instruction count above). Done when the predicted kernel
   time is a number, and the lever is closed if d is under 0.5.
2. VerA: a dual whose derivative lanes are f32 on the device target.
3. The f64 retry on a Newton failure, per lane.
4. The gate.

## G5 A resident Newton loop where the host is the bound

**Class:** exact. **Issue:** none; continues 01 1.2 and 1.3 of the previous
round. **Machine:** an FP64-class card.

**Bound: overhead, by Amdahl.** With the LU on the host, the host is 62 to
94% of the GPU wall and the A100 prediction is 1.0x to 1.7x over the CPU.
Per iteration the path costs `x` up, planes down, a limit pass, and the
update and gates on the host: 86 µs of host work plus 219 µs of waiting per
evaluation on `logic_bsim4_10k` (#261).

**Why it is not built now.** The previous round measured the two pieces and
closed them: with resident A in, the remaining bytes are under 0.3% of an
iteration, and the waits are 0.2% of a step wherever the device LU runs.
Where the device LU does not run, the host LU is the bound and a resident
loop has nothing to be resident around.

**What re-opens it.** G2 and G7 on an FP64-class card. With both, a 10k
deck's iteration on an A100 is 0.7 to 4 ms of kernels, and the 86 µs of
host work per evaluation, plus about ten launches at 7.6 µs each, is 10 to
25% of it at the low end and 3 to 5% at the high one. On thin factors, where the LU call is at its 1.3 to 1.5 ms floor
whatever the size, the share is higher. Then the loop to build is:
evaluate, reduce, combine, refactor, solve, update, limit and the
convergence gates on the device, with one verdict word read per iteration.
Each piece already has its host oracle. The transient lanes already run
this way (`arp_lane_gates`, `arp_lane_update`), which is the second
instance to factor from.

**Done when** (as a decision, not a build): after G2 and G7, the
per-iteration host share on an FP64-class card is measured and is above
30%.

## G6 Placement by price on a datacenter card

**Class:** exact (placement never changes a result). **Issue:** #249, #251,
#224, #226. **Machine:** A100 or H100.

**Bound: none; this is a measurement.** The predictions say which paths a
datacenter card turns from a loss into a win, and each needs one real run
to replace the prediction:

| Path | 4060 against CPU | A100, predicted | What it needs |
|---|---|---|---|
| Transient lanes, 8,192 points | 1.5x | 3.1x to 4.1x | Nothing: `auto` admits lanes at FP64 of at least FP32/4 |
| Device eval and LU, `logic_psp103_10k` | 1.9x | 2.8x to 4.5x | G3, then G2 |
| Device eval and LU, `sram_bsim4_10k` | 1.4x | 1.6x to 2.7x | G3, then G2 |
| Device eval only, 1k and 4k decks | 0.8x to 1.3x | 0.9x to 1.7x | Host-bound: the price should keep these on the CPU |
| OP, AC, PSS, HB lanes | 0.27x to 0.38x | the same | G1 |

**Change.** Run `espice calibrate` and the placement oracle on the card;
finish #249 stage 4 so the device LU and each lane family are priced terms;
then #224 and #226, which only pay there.

**Done when** the placement oracle's recorded walls include one FP64-class
card and every row above is a measurement.

## G7 The dense tail of the device solves

**Class:** exact for stages 1 and 2; rounding for stage 3, which needs the
owner's decision. **Issue:** none. **Machine:** any card that runs the
device LU; decisive on an FP64-class one.

**Bound: latency.** On an A100 the two tail kernels are predicted to be
the largest part of the LU call, ahead of the refactor (3.1 to 5.1 ms of
5.8 to 10.7 on `logic_bsim4_10k`). The last `t` pivot steps of a factor (3,072 on
`logic_bsim4_10k` and `sram_bsim4_10k`, 2,048 on `logic_psp103_10k`, chosen
by the cut search up to `tail_max` = 5,120) are solved in panels of 64
rows, one block each (`lpanel`, `upanel`). A row gathers every earlier
column in stored order, eight loads ahead of an eight-step subtraction
chain (`kernels/lu.zig:672`), and each panel then sweeps its own 64-by-64
block step by step. The counts: 55,600 warp instructions per warp in
`upanel`, each warp's a single dependent chain, and 48 panels each
waiting on the one before. Measured 2.1 ms and 1.1 ms a call
on `logic_bsim4_10k`, 44 µs and 23 µs per panel, on a kernel whose
arithmetic is 37 µs in total. On `sram_bsim4_10k` the two are 3.3 ms of an
8.8 ms LU call. No card makes a chain shorter: the model's prediction for
an A100 is the same time or worse. The per-panel time is the same on all
three decks (23 to 25 µs forward, 44 to 45 µs back): it is the kernel's
own chain, not the factor's.

**Speed of light.** The fixed order pins one multiply and one subtract per
tail row between a row's value and the next row's: 3,072 steps, 12 µs at
2 GHz if the pair takes 8 cycles (an assumption; step 1 measures it). Everything above that is instructions per term,
barriers and waits, not arithmetic. An exact kernel has two orders of
magnitude of room.

**Change.**

1. *Loads off the chain, sweep by level* (exact, no new storage; M2 in
   [10-device-lu-chain.md](10-device-lu-chain.md#m2-solve-tail-loads-off-the-chain-sweep-by-in-panel-level)).
   First time three variants of `lpanel` with every stamp pre-published
   (as is, block load skipped, sweep skipped) to split the 23 µs. Then:
   (a) `loadBlock` reads the panel's dense block from global memory after
   the last earlier panel has published, one entry at a time; its inputs
   are final before the kernel starts, so load it before the waits. (b) A
   panel sweeps its 64 rows in 64 barrier steps forward and 128 back
   whatever the block's sparsity; group the rows by in-panel dependency
   level instead, each row keeping its own order. Steps per direction fall
   from 3,072 toward the tail's dependency depth (at most 909 and 1,033).
   Done when the tail solves are reported per panel before and after, with
   the solve bitwise unchanged.
2. *A dense tail* (exact). Store the tail's two triangles panel-major: the
   64-by-64 block of row panel i and column panel j contiguous, absent
   entries as zeros with the presence mask the diagonal block already
   uses. A gather step is then a block read with no index loads (today:
   two u32 loads per term, then two gathered f64 loads), and all lanes of
   a warp read one run of sectors. Size: 37.7 MB per triangle at t = 3,072
   if stored whole, so refit the cut `t0` with the new cost (the dense
   part of these factors is far smaller than 3,072: their pair counts
   equal a dense LU of order 490 and 780). Build it if stage 1 leaves the
   gather as the larger half. Done when the tail solves are under 1 ms a
   call on the 4060 with the factor bitwise unchanged.
3. *Inverted diagonal blocks* (rounding class). After each refactor,
   invert the 48 diagonal blocks in parallel (48 x 64³ flops, trivial).
   The panel sweep becomes one 64-by-64 matrix-vector product and the
   chain per panel drops from 64 dependent steps to one. The published
   GPU triangular solves that beat level sets restructure the chain:
   blocks with a product between them (Lu, Niu, Liu: 4.72x over cuSPARSE)
   or one thread per row with a busy wait (CapelliniSpTRSV: 4.74x, and
   exact per row). The circuit and power-grid solvers
   that keep level sets leave the solves on the host or lose there (Chen
   2015: the host 3.16x faster; Świrydowicz 2023: 40% slower than the
   CPU). Sources in
   [10-device-lu-chain.md](10-device-lu-chain.md#33-triangular-solve). It
   changes the solve's
   rounding against the host's, so either `cpu` and `cuda` stop being
   byte-identical on thick decks, or the host tail solve adopts the same
   arithmetic, which moves every thick deck's low bits once. Build it only
   if stage 2 leaves the tail above half of the LU call on an FP64-class
   card.

**Oracle and gate.** `SparseLu.solve`, bitwise, for stages 1 and 2
(`ESPICE_GPU_LU_CHECK=1`, raws byte-identical to the host run). Stage 3:
the scaled residual of each solve against the host's, and the full GPU
corpus by name with every moved deck listed.

## G8 Lane kernels: one thread per instance and lane

**Class:** exact. **Issue:** #224 (the colouring exists for OP and DC
lanes), #226. **Machine:** FP64-class cards; neutral on the 4060.

**Bound: FP64 on the 4060, the chain on an A100.** The lane evaluation
runs one thread per lane, and that thread walks every instance of its
circuit (`lane_kernels.zig:115`: "One thread walks every instance of its
lane, so it alone writes its lane's cells"). So an 8,192-point sweep of a
26-device circuit launches 3,712 threads on average, 116 warps, each
executing 233,700 instructions in a row. An A100 holds about 860 warps of
this kernel (255 registers a thread) on 108 SMs. The model: the FP64 term
falls from 4.5 ms to 0.14 ms on an A100, and the chain, 0.66 ms, is what
is left. The same shape binds `arp_lchg_bsim4va` and `arp_lane_lte`.

**Speed of light.** The work is 11.7 M FP64 warp instructions a launch:
0.14 ms on an A100, 0.05 ms on an H100, if enough of it is in flight.

**Change.** Launch one thread per (instance, lane), as `LaneStateKernel`
already does for the limit pass and as `laneRange` already supports when
it is given an instance list (`lane_kernels.zig:387`). Two ways to keep
each plane cell's sum in tape order without atomics:

1. Colour the instances so that no two of a colour share a plane cell, and
   launch a colour at a time (#224's charge colouring is the instance in
   the tree). Cells
   then receive their adds in colour order, which must equal tape order,
   so colours are assigned in tape order.
2. Or stage each instance's stamps and reduce in tape order, as the
   single-circuit device evaluation does.

With seven times the threads and a chain one seventh as long, the model
gives 0.16 ms a launch on an A100 against 0.66 ms (the bound moves to the
kernel's own stack traffic: 82% of its sectors are local memory, register
spills at 255 registers a thread) and 0.12 ms against 0.47 ms on an H100.
On the 8,192-point sweep that is lane kernels of about 0.3 s against 1.1 s
predicted, and a wall of about 2.8 s against 14.6 s on the CPU, 87% of it
host: materializing 8,192 lanes on one thread (`executor_lanes.zig:191`)
and the per-step control. Fan the materialize loop over the pool in the
same change.

**Oracle and gate.** The one-thread-per-lane kernel is the oracle: planes
bitwise equal at the same `x` for every lane; raws byte-identical on the
transient sweep decks. On the 4060, wall not worse.

**Steps.**

1. Count, per lane deck in the corpus, instances per circuit and colours
   needed. Done when the launch count per evaluation under colouring is
   known (colours times launches must not undo the gain: a launch is
   7.6 µs).
2. Build it for the evaluation and charge kernels. Done when the gate
   passes on the host build of the lane bodies.
3. Measure on an FP64-class card with [G6](#g6-placement-by-price-on-a-datacenter-card).

## G9 Lanes of a thick circuit

**Class:** exact. **Issue:** #226, #220. **Machine:** FP64-class cards.
This is the workload that fills one: W lanes put W times the arithmetic on
every step of the chain.

**Why.** One refactor of `logic_bsim4_10k` is 0.31 GFLOP. An A100 does
that much arithmetic in 32 µs, and no kernel will get near it: the
elimination order is a dependency chain, and the indices cost more than
the values. A sweep changes the arithmetic. Corners, Monte Carlo samples
and sweep points of one circuit share its pattern and its pivot sequence,
so the lane axis is free parallelism: every index, ticket and barrier is
paid once per W lanes, each lane load is contiguous along the lane axis,
and the FP64 share of instructions rises with W. Sixty-four corners of
that deck are 20 GFLOP a refactor, 2 ms at the card's full rate. The
kernel will not reach that rate: each lane loads its own L values, 8 bytes
a pair, so it ends bound by L2 traffic at about a quarter of the FP64 pipe
(1.78 ps a pair on an A100, 18 ms for the 64 corners) unless G2's chunks
let one loaded value feed several pairs. FP64 work equals chain time at
about 55 lanes on `logic_bsim4_10k` and 263 on `sram_bsim4_10k`
([10-device-lu-chain.md](10-device-lu-chain.md#m4-batch-axis-a-lane-is-a-value-set)).

**Today.** The lane backend runs the LU as one thread per lane
(`kernels/lane.zig:3`): the whole refactor of a lane's matrix in one
thread's instruction chain. That is the right shape for the 26-device
sweep circuit and the wrong one for a thick factor, where the chain would
be 155.7 M pairs long. No lane deck in the tree has a large circuit, so
this has not been measured. The lane policy read for this page tests the
card's FP64 ratio and not the circuit's size (`gpu/lanes.zig:423`); a size
guard elsewhere was not searched for exhaustively, hence step 1.

**Change.** The ticketed column kernel of G2 with a lane axis: a block
takes one target column (or supernode) for W lanes, values lane-major
(`val[slot * n_lanes + l]`, the layout the lane backend already uses),
tables shared. Pivots replay lane 0's tape, as lane batches do today; a
lane whose pivot test fails leaves the batch for the host.

**Before building.**

1. Run a 64-point sweep of `logic_bsim4_1k` and of `sram_bsim4_10k` on the
   CPU and under `--backend cuda` on the 4060. Done when the lane path's
   behaviour on a large circuit is a measurement and not a reading of the
   source.
2. Price it in [08-placement.md](08-placement.md)'s lane term: a lane
   family row needs the circuit's F, not only its point count.
3. Build after G2, since it is G2's kernel with one more axis.

**Oracle and gate.** Lane l's factor and solve bitwise equal to the scalar
replay of lane l (the `W == 1` instantiation); raws byte-identical to the
CPU lane path.

