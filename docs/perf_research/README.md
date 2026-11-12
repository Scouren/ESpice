# Performance research, round 3 (2026-11-10)

Where ESPice still leaves time on the table by construction, measured on
`dev/performance` at `9bbd4d7f`, and a brief per lever that an implementer
can pick up without rerunning the research. Round 1 and 2 are in git history
and in issues #216 to #261; [07-prior-work.md](07-prior-work.md) lists what
they closed.

| Page | Read it when |
|---|---|
| [01-hot-path.md](01-hot-path.md) | Before touching the Newton loop, the stamp, the LU replay or the step control: the call map and the invariants |
| [02-baseline.md](02-baseline.md) | A claim needs a number: the Newton split, thread scaling, the refactor, the operating point, four censuses |
| [03-rspice.md](03-rspice.md) | Comparing against RSpice or ngspice: wall times and CPU-seconds, what RSpice does, which of its mechanisms transfer |
| [04-levers-cpu.md](04-levers-cpu.md) | Picking up a CPU work package (C1 to C8) |
| [05-levers-gpu.md](05-levers-gpu.md) | Picking up a GPU work package (G1 to G9), or asking why a faster card does not pay: what binds each kernel |
| [06-open-issues.md](06-open-issues.md) | Planning: every open performance issue, its order and what it waits on |
| [07-prior-work.md](07-prior-work.md) | Before proposing anything: closed ideas with their measurements, and published numbers |
| [08-placement.md](08-placement.md) | Touching `--backend auto`, `espice calibrate` or any CPU-against-GPU threshold: the decision, the calibration file, the steps |
| [09-after-the-levers.md](09-after-the-levers.md) | Asking what binds once C1 to C8 and G1 to G9 are in: per deck class, the next term, whether it is hardware, a parity rule or software, and the round-4 levers (N1 to N10) |
| [10-device-lu-chain.md](10-device-lu-chain.md) | Touching `kernels/lu.zig`, or citing GPU sparse LU and triangular-solve literature: the chain model, the roofline, what keeps the host's bits |
| [11-lever-gate.md](11-lever-gate.md) | Implementing a lever, or comparing one against the shipped path: `ESPICE_PERF`, one bit per lever, one build for before and after |
| [12-math-and-contract.md](12-math-and-contract.md) | Reading Gompute's math and the VerA contract for evaluation speed: cost per call, sites per evaluation in five models, the dual family's two divisions, why N5 is already done, what the `perf/lane-eval` branch and VerA's batch family measured on the instance axis and why `ddx` keeps the MOSFETs out of it, and the ranked requests M1 to M8 for Gompute and VerA |
| [13-implementation.md](13-implementation.md) | Asking what is already written: per lever, the stage that is in, its test and oracle, what was left out, and what the next wave holds |
| [14-precision.md](14-precision.md) | Asking whether a narrower float format can carry the same accuracy: pairs of f16 or f32 with FMA, f32 derivative lanes, an f32 factor under an f64 residual, on the CPU and on FP64-poor and full-rate cards; which numbers are the published answer and which only steer |
| [15-design-sweeps.md](15-design-sweeps.md) | Asking whether sizing sweeps and optimization belong in the simulator: independent candidates run in parallel over cores and cards, the frontend shape, and how a batch is priced on the CPU against the GPU |
| [16-gpu-parity.md](16-gpu-parity.md) | Asking what is CPU-only today: every refusal that sends a GPU request back to the host, the analyses with no lane form, each lever's GPU twin, and the order they are lifted in |
| [17-self-heating.md](17-self-heating.md) | Implementing diode self-heating (the `tj` node, `thermal`, `rth0`/`cth0`): what ngspice 44.2 computes, the `diode_t` variant and frontend change list, the oracle per test, and why VDMOS self-heating stays refused |
| [18-lever-verdicts.md](18-lever-verdicts.md) | Deciding a lever or removing its `ESPICE_PERF` bit: per bit its class, the evidence and whether it decides, the five bits with no reader, and the CPU-1 to CPU-10 and GPU-1 to GPU-5 runs that settle the rest |
| [19-environment.md](19-environment.md) | Adding, reading or removing an `ESPICE_*` or `GOMPUTE_*` variable: every variable with its reader, which stay, which become CLI options, which go, and which are read past the config facade |
| [census.patch](census.patch) | Reproducing a census: the throwaway counters behind [02-baseline.md](02-baseline.md) |
| [census-bypass.patch](census-bypass.patch) | The bypass miss-cause counters, applied on top of `census.patch`. It also stops the bypass from switching itself off, so use it for the bypass rows only |

## Classes

Every lever carries one class. The class fixes its gate.

| Class | Meaning | Gate |
|---|---|---|
| **exact** | Same operations per value in the same order. | Corpus raws byte-identical; 1 thread and N threads byte-identical; the scalar path (`W == 1`, the column loop, the serial stamp) is the oracle in a unit test that goes red first. |
| **rounding** | One summation order changes, once. | `tests/VERDICTS.tsv` unchanged by name; an owner decision, since every raw moves in its last bits. |
| **tolerance** | A result moves within the Newton or LTE tolerance on some decks. The published iterate, the acceptance test and the time grid stay ngspice's. | The full oracle corpus passes; every moved deck is named with its largest move. It then ships as a named opt-in, off by default ([the owner's decision](11-lever-gate.md#why-a-variable-against-the-standing-rule)), or as the default when it selects itself by whether it applies. |
| **mode** | The published iterate, the acceptance test or the time grid changes. | Never the default. A named opt-in mode with its own oracle (ngspice at `reltol = 1e-6`, or analytic). See [the published-iterate rule](07-prior-work.md#the-published-iterate-rule). |

Standing rules from rounds 1 and 2 that every brief respects: the host path
is the oracle of every threaded and device kernel; no float atomics; every
GPU kernel goes through Gompute in Zig; no new user-facing flag or
environment variable for an exact lever (the temporary developer gate in
[11-lever-gate.md](11-lever-gate.md) is how a lever is judged, not what
ships); a tolerance lever may ship as a named opt-in.

## Ranking

Ranked by expected wall-time gain on the decks each lever pays on. "Est."
is arithmetic on measured inputs, not a measurement of the change; each
brief's first step is the measurement that confirms or closes it.

On the CPU (this laptop, and any machine):

| # | Lever | Class | Pays on | Expected | Decided by |
|---|---|---|---|---|---|
| 1 | [C1](04-levers-cpu.md#c1-supernode-panels-in-the-refactor-replay) supernode panels in the refactor | exact | thick factors | Est. refactor 29 to about 9 ms on `logic_bsim4_10k`, wall 50 to about 28 s | A one-lane microbenchmark of the panel arithmetic (step 2) |
| 2 | [C8](04-levers-cpu.md#c8-the-operating-point) the operating point | tolerance | large cold starts | The operating point is 23 to 44% of wall on three 10k decks; est. 9 of 50 s on `logic_bsim4_10k`. **Measured: the reorder takes `logic_bsim4_10k` from 42.2 to 30.3 s and leaves the other 10k decks where they were; the rung stop and the rung budget are rejected** ([13](13-implementation.md#wave-5-binary-c8-by-part)) | An offline reorder of the largest pivot epoch |
| 3 | [C4](04-levers-cpu.md#c4-bypass-that-pays-on-production-models) the bypass | tolerance (already) | latent circuits, and the decks ngspice wins | Est. 1.3x to 1.9x on the Newton loop of `bench_ngspice_mosamp`. BSIM4 post-layout decks: 65 to 97% of eligible evaluations miss on instance bytes, 3 to 11% on voltages; evaluation to 0.62 to 0.65 of today, 0.32 to 0.38 if the first iterate may replay (upper bounds) | Which bytes of the row move; the cost of a hit |
| 4 | [C2](04-levers-cpu.md#c2-the-confirming-solve-on-the-held-factor) confirming solve on the held factor | tolerance | every nonlinear transient | **Rejected by the owner, deleted**: it needed its own accuracy bound, and only 1e-6 of the Newton tolerance kept the corpus clean | — |
| 5 | [C3](04-levers-cpu.md#c3-linear-circuits-one-confirm-per-factor) linear circuits | exact | linear decks | Est. 1.37x (solve only) to 2x on the Newton loop | The trace of what reads iteration 2 |
| 6 | [C5](04-levers-cpu.md#c5-solve-and-update-at-lane-scale) solve and update at lane scale | exact | all decks at 8 lanes | **Rejected by measurement**: every form built lost its phase, and the code is deleted | — |
| 7 | [C6](04-levers-cpu.md#c6-lanes-past-eight-and-what-idle-lanes-burn) lanes past eight, idle lanes | exact | large circuits | At most 1.25x to 1.35x on thin 10k decks; CPU-seconds down | One build with the cap changed |
| 8 | [C7](04-levers-cpu.md#c7-one-reduce-pass-that-also-forms-a) one reduce pass | exact | parallel stamping | Up to the load's share, 1 to 13% | — |

On a GPU. The 4060 in this laptop has a third of the P-cores' FP64 rate, so
most of this list is for an FP64-class card (A100, H100), and every figure
for one is a model prediction:

| # | Lever | Class | Pays on | Expected | Decided by |
|---|---|---|---|---|---|
| 1 | [08-placement.md](08-placement.md) placement from one calibration | exact | every `auto` run | Today `auto` cannot reach the GPU on this branch; `logic_bsim4_10k` under `auto` was 97.7 s against 68 s on either backend (#249) | Steps 1 and 2 of that page, on the card |
| 2 | [G3](05-levers-gpu.md#g3-operating-point-pivot-epochs-stay-on-the-host) pivot epochs stay on the host | exact | device LU, any card | 9 s of table builds on `logic_bsim4_10k` | — |
| 3 | [G2](05-levers-gpu.md#g2-supernode-panels-in-the-device-lu) with [G7](05-levers-gpu.md#g7-the-dense-tail-of-the-device-solves): supernode chunks in the device refactor, the solve's tail off its chain | exact (G7 stage 3: rounding) | thick factors, FP64-class card | LU call 15 ms to between 1 and 4 ms on an A100; `sram_bsim4_10k` 18 s on the CPU to 2.4 to 6 s | Three kernel timings of one chain step (G2 step 2); the panel split (G7 stage 1) |
| 4 | [G1](05-levers-gpu.md#g1-lane-groups-host-work-on-the-pool-then-a-batched-dense-lu) lane groups' host work on the pool | exact | OP, AC, PSS, HB sweeps, any card | From 0.27x to 0.39x of the CPU to parity; then a batched dense LU for HB | — |
| 5 | [G8](05-levers-gpu.md#g8-lane-kernels-one-thread-per-instance-and-lane) one thread per instance and lane | exact | transient sweeps, FP64-class card | Lane evaluation 0.66 to 0.16 ms a launch on an A100 | Colours per lane deck |
| 6 | [G9](05-levers-gpu.md#g9-lanes-of-a-thick-circuit) lanes of a thick circuit | exact | corners and Monte Carlo of large circuits | The workload that fills an A100: W times the arithmetic per chain step, ending at L2 traffic, a quarter of the FP64 pipe; unmeasured | One sweep run of a 1k and a 10k deck |
| 7 | [G4](05-levers-gpu.md#g4-f32-derivative-lanes-on-fp64-poor-cards) f32 derivative lanes | tolerance | lane sweeps on consumer cards | Est. 9.5 to about 5 s on the 8,192-point sweep | The FP64 instruction count of the value-only kernel |
| 8 | [G5](05-levers-gpu.md#g5-a-resident-newton-loop-where-the-host-is-the-bound), [G6](05-levers-gpu.md#g6-placement-by-price-on-a-datacenter-card) | exact | after 3 | A decision and a measurement, not builds | A run on an FP64-class card |

After those, from [09-after-the-levers.md](09-after-the-levers.md), which
also says where each deck class ends on hardware or on a parity rule:

| # | Lever | Class | Pays on | Measured today | Decided by |
|---|---|---|---|---|---|
| 1 | [N3](09-after-the-levers.md#n3-one-charge-evaluation-per-accepted-step) one charge evaluation per accepted step | exact | every transient with charges | The charge core runs up to three times a step: 6 to 18% of one thread | The bitwise test of the staged charges |
| 2 | [N8](09-after-the-levers.md#n8-lane-affine-staging) lane-affine staging | exact | large decks at 8 lanes | 18% of all cycles move staging lines between cores, 11% spin (`chain_bsim4_10k`) | `perf c2c`; a timing split of the evaluation phase |
| 3 | [N1](09-after-the-levers.md#n1-the-dense-tail-as-a-tiled-factorization-on-every-lane) the dense tail tiled over the lanes | exact | thick factors, after C1 | Lanes scale 1.6x to 2.8x of 8 on the refactor | The share of pairs inside the tail |
| 4 | [N6](09-after-the-levers.md#n6-latency-for-the-charge-and-limit-passes) latency for the charge and limit passes | exact where bitwise unchanged | latent circuits | Two thirds of a 99%-latent MOS1 run is per-instance work for instances that did not move. **Exact form rejected: plus 1 to 2% on MOS1 decks, minus 1 to 2% on BSIM4** ([09](09-after-the-levers.md#n6-latency-for-the-charge-and-limit-passes)) | A census of bitwise-unchanged instances |
| 5 | [N7](09-after-the-levers.md#n7-step-bookkeeping) step bookkeeping | exact | tiny and linear decks most | 16 to 20% of the transient is outside the five Newton phases on three of four decks measured | A timing line for it |
| 6 | [N4](09-after-the-levers.md#n4-the-transcendental-kernels) `exp`, `log`, `pow` | exact or rounding | every nonlinear deck | 9 to 26% of one thread | Cycles per call |
| 7 | [N5](09-after-the-levers.md#n5-derivative-sparsity-in-the-generated-model-code) derivative sparsity in VerA | exact | evaluation-bound decks | Unknown | Instructions per evaluation, value-only against dual |
| 8 | [N2](09-after-the-levers.md#n2-fused-multiply-add-in-the-lu-kernels) fused multiply-add in the LU kernels | rounding, owner decision | thick factors, after C1 and N1 | — | Pairs per cycle with and without contraction |

The order to build in, with the open issues folded in, is in
[06-open-issues.md](06-open-issues.md#order).

## Reproducing a number

Machine: i9-14900HX (P-cores are CPUs 0 to 15, E-cores 16 to 31), 31 GB,
RTX 4060 Laptop. The CPU numbers come from one build:

```text
nix develop .#ci -c zig build exe -Doptimize=ReleaseFast -Dgpu=false -Dcuda-arch=none -Dhip-arch=none
taskset -c 0-15 zig-out/bin/espice --backend cpu --timing-in-depth -b -r out.raw deck.sp
```

`--timing-in-depth` prints one `timing: <job> newton:` line per query
(iterations, factors, and the milliseconds in eval, load, factor, solve,
update); `ZP_TRAN_STATS=1` adds the step counts. Thread counts are pinned
with `ESPICE_THREADS` and `ESPICE_SOLVER_THREADS`. A wall time is the median
of three runs after one warm-up, run from the deck's directory. The censuses
need `git apply docs/perf_research/census.patch` in a scratch worktree and
`-Dlu-instrument=true`; the patch is measurement code and never lands.

The counters and profiles in [09-after-the-levers.md](09-after-the-levers.md)
are `perf` 7.0.10 from `nix shell nixpkgs#perf`: `perf stat` with the
`cpu_core/…/u` events (cycles, instructions, slots and the five `topdown-`
events) on the build above, pinned with `taskset -c 2` and
`ESPICE_THREADS=1 ESPICE_SOLVER_THREADS=1` or left at the default lanes on
`taskset -c 0-13`; `perf record` and `perf annotate` on a build with
`-Ddebug-info=true`, since the default binary is stripped.

No GPU number on these pages was measured in this round. Each one cites the
issue or the recorded trace it comes from (`docs/performance/gpu-phases.tsv`),
and every figure for another card is a prediction of
`python3 tools/gpu_extrapolate.py --device a100_80_sxm`.
