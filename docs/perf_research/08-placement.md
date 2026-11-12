# Placement: CPU or GPU, per part, from one calibration

How `--backend auto` should choose where each part of a query runs: one
calibration run per machine writes a file, and every deck after that is
placed by arithmetic on that file. This page is a brief to implement from.
No GPU ran for it and nothing was built. Line numbers are `dev/performance`
at `9bbd4d7f`. It is the design behind
[G6](05-levers-gpu.md#g6-placement-by-price-on-a-datacenter-card) and the
#249 row of [06-open-issues.md](06-open-issues.md#per-issue).

Every claim carries its source:

| Tag | Meaning |
|---|---|
| **[code]** | Read at the anchor on `dev/performance` `9bbd4d7f`. |
| **[int]** | Read on `origin/dev/integration` `6ff136e5` with `git show`. That code compiles and has never run (#258). |
| **[tsv]** | Measured data in the tree: `docs/performance/gpu-phases.tsv` (RTX 4060 Laptop, driver 595.71.05, commit `681b3ccd`, 2026-11-04, walls median of three) or `src/analysis/gpu/placement.tsv`. |
| **[model]** | Output of `python3 tools/gpu_extrapolate.py --device a100_80_sxm`, run for this page. A prediction; its own held-out error is up to 30% of a deck wall (`--check`). |
| **[#N]** | Stated in issue N, not re-measured. |
| **[est]** | Arithmetic or judgement of this page. |

The parts of a query that can sit on either side: the **device
evaluation** (one batch per model type), the **sparse LU** (refactor and
solves, per pivot epoch), and for sweeps the **lane family** (transient
lanes; OP and DC lanes; PSS lanes; HB lanes; frequency lanes).

## 1. What exists

### On `dev/performance`

| Piece | State | Anchor |
|---|---|---|
| No driver call before a price admits the GPU (plan stage 1) | Landed. The oracle is a counter on every driver entry. | `src/analysis/gpu/driver.zig:30`, `:67`; tests `src/tests/espice.zig:3612`, `:3629`, `:3656` |
| The calibration file: parse, format, atomic write, identity, staleness (stage 2) | Landed. | `src/analysis/machine.zig` |
| `auto` prices from the file; no file means CPU and one note | Landed. | `src/espice/config.zig:274`, `src/espice/Problem.zig:374-381`, `src/analysis/exec_config.zig:97` |
| `espice calibrate` (stage 3) | Ported from `origin/dev/integration` in wave 3 with step 1's corrections ([13](13-implementation.md#wave-3)). Never run: it needs the card. At `9bbd4d7f` it was absent. | `src/espice/calibrate.zig` (the spine), `src/analysis/gpu/calibrate.zig` (the measurements), `src/main.zig:145` (the subcommand) |
| `price.place` and the device LU's rent-or-buy (steps 3 and 4), behind `p1` | Written in wave 3 and tested against a fixture, not a measured file. The LU half prices nothing while `machine.lu_host_key` is 0. | `src/analysis/price.zig`, `src/analysis/lu_price.zig`, `src/analysis/gpu/lu_admit.zig`; `machine.zig:221` |
| Lane terms, prestart after build, probe correction (steps 5 and 6) | Not started. The `lane` rows are parsed and unread; `likelyGpu` still decides the prestart. | `machine.zig:203`; `config.zig:288` |

So at `9bbd4d7f` `auto` could not reach the GPU on any machine unless
someone wrote the file by hand, and the note it prints (`machine.zig:385`)
named a subcommand the binary did not have. Today the subcommand exists and
has not run.

**The file** [code]. Path
`<cache>/espice/machine/<first 16 hex digits of /etc/machine-id>.tsv`,
`<cache>` being `$XDG_CACHE_HOME`, else `$HOME/.cache` (`machine.zig:391`,
`:421`). Text, one `key<TAB>value` row per constant, at most 64 KB
(`:205`). Unknown rows are skipped; a missing constant row makes the whole
file unreadable (`:304`).

| Rows | Fields | Read by |
|---|---|---|
| Identity | `driver`, `uuid` (one per card), `threads`, `p_cpus`, `e_cpus`, `espice` | `stale` (`:228`) compares the driver version, the card count, the uuid set and `threads`. It does **not** compare `p_cpus`, `e_cpus` (test at `:641`) or `espice`. |
| 14 priced constants | `start_ms`, `eval_fixed_us`, `bus_b_per_us`, `stage_b_per_us`, `host_lane_gain`, `margin`, `min_ratio`, `slowdown`, `concurrency`, `hist_ns_per_byte`, `hist_floor_bytes`, `host_ratio`, `host_loss_us`, `fp64_ratio` | `context_cost.zig`, `price.zig`, `gpu/lanes.zig:428`, `:455` |
| 9 stored constants | `sms`, `cc`, `mem_gb`, `start_in_ms`, `launch_us`, `bus_lat_us`, `bus_up_gbs`, `bus_down_gbs`, `lu_table_ns_per_flop` | Nothing. A grep for each finds no reader outside `machine.zig`. |
| `model` rows | Image Wyhash, then `dev_us`, `host_p_us`, `host_e_us` at 1, 64, 1,024 and 16,384 instances, `jit_ms`, `lane_gain` (`:154`) | Nothing. Parsed, never priced. The fixture has none. |

The only file in the tree is the test fixture
`src/analysis/gpu/placement.machine.tsv`: the constants the price carried in
code before stage 2, with their provenance in comments.

**What decides today** [code]. The file is consumed at three sites.

| Part | Rule | Anchor |
|---|---|---|
| Device evaluation, one bit for all eligible batches of a query | `admit`: a host probe (three evaluations per batch, fastest kept), or a `CostCache` record of an earlier run; then `gpuWins`: `cpu_us >= min_ratio * gpu_us` and `margin * (start + E * gpu_us) < E * cpu_us`. Device time per batch is `host_us * slowdown * ceil(count / concurrency) / count`. | `context_cost.zig:189`, `:224`, `:340`; `price.zig:42` |
| The same, after 40 evaluations | The audit: measured device µs per evaluation above the priced host µs demotes the rest of the query to the host and writes a `CostCache` record. | `context_eval.zig:204`, `:464`; `context_cost.zig:50` |
| Device LU, per pivot epoch | Source constants, not the file: `n >= 10,000`, then `F >= 50M`, or `F/n >= 500` and `F >= 5M`. The same bars under `auto` and under an explicit backend. | `executor.zig:534`, `:572`; `gpu/lu.zig:554`, `:570`, `:578`, `:589` |
| Transient, PSS, HB and frequency lanes, one bit per Problem | `fp64_ratio <= 4`. | `gpu/lanes.zig:423`; `session_sched.zig:171` |
| OP and DC lanes | `13 * 64 / fp64_ratio > cpus`. | `gpu/lanes.zig:452` |
| Share of a lane batch the device keeps | Card capacity in host cores from three source constants (13 cores, 1:64, 24 SMs). | `gpu/devices.zig:140`, `:337`; `gpu/lanes.zig:437` |
| Driver prestart | Deck file of 1 MiB or more, once a file exists. | `config.zig:118`, `:284`; `Problem.zig:381` |
| Cold kernel image under `auto` | An image of 1 MiB or more with no marker file keeps the whole query on the CPU. | `context_cost.zig:140`; `context_batch.zig:160-162` |

**The placement oracle** [code]. Test "price: each recorded deck lands on
its measured winner" (`context_cost.zig:518`) reads
`src/analysis/gpu/placement.tsv`: 13 decks, each with its evaluation count,
recorded probe rows (`count:host_us:held_bytes`), recorded `fixed_us` and
`init_us`, and measured `cpu_s` and `cuda_s`. It checks, per deck: the
verdict equals the measured winner unless the walls are within `margin`
(1.3); a deck with a `known` cause must miss; the priced wall ratio is
within 10x of the measured one (`:526`). It prices with one host lane
(`:559`), and it bypasses the probe, the `CostCache` and the audit. It has
no post-layout deck, no device-LU deck, no lane deck and no tiny deck. One
row is `known` (`scaling_inverter_chain_4k`).

### On `origin/dev/integration` only

`espice calibrate` [int]: `src/analysis/gpu/calibrate.zig` (the measurements),
`src/espice/calibrate.zig` (the spine), a subcommand in `src/main.zig`, and
`machine.zig` grown by a `pe_ratio` constant and `lu` rows.

| It measures | How | Anchor [int] |
|---|---|---|
| `start_ms`, `start_in_ms` | Seven child processes that start the driver, against seven that exit at once; medians. | `espice/calibrate.zig:134` |
| `launch_us`; bus latency and rates; a device-to-device copy | An empty `arp_gc_combine` launch and sync; pinned copies of 4 KiB to 64 MiB fitted by least squares; one 64 MiB copy. | `gpu/calibrate.zig:141` |
| `fp64_ratio`, `sms`, `cc`, `mem_gb` | Driver attributes. | `gpu/calibrate.zig:218` |
| One `model` row per compact model (33 LEVEL-table models) | A generated deck of N instances at each of the four sizes: device evaluation through `GpuContext.eval`, host evaluation pinned to one P-core and to one E-core, ParEval gain on 8 lanes at the widest size, first module load. | `espice/calibrate.zig:76`, `:240`; `gpu/calibrate.zig:241` |
| Four `lu` rows | Grid Laplacians (48² and 160² in 2-D, 16³ and 28³ in 3-D): one forced device call (refactor and both solves), the host refactor and solve, the first call's table build. | `espice/calibrate.zig:63`; `gpu/calibrate.zig:322` |

It then folds the model rows back into the stage-2 constants (`derive`,
`espice/calibrate.zig:271`): one `slowdown` and one `concurrency` as medians
over models. The per-model rows are written and still unread.

### Where the tree and the issues disagree

| Issue text | Tree |
|---|---|
| #249: stages 1 to 3 "are on dev/performance". | At `9bbd4d7f` stage 3 was only on `origin/dev/integration`. The `perf/price-stage3` ref is gone; its commits are reachable through merge `b26d739f`. Wave 3 ported it ([the table above](#on-devperformance)). |
| #249 sec. 4: no built-in constants. | Source constants still decide: the three device-LU bars and `gpu_lu_min_n`; `likely_gpu_bytes`; `heavy_image_bytes`; the `<= 4` and `13 * 64` lane rules; the `e1_*` capacity; `Audit.from` and `at`; `evals < 20`. And [int] `calibrate` writes six typed policy values (`margin` 1.3, `min_ratio` 2, four history terms) into the file of measurements (`espice/calibrate.zig:119`). |
| #249 sec. 4: after the driver starts, live uuids are compared with the file's and a mismatch renames it `.stale`. | Not implemented on either branch. |
| #249 sec. 5: `tools/placement.py` re-measures a machine and rewrites the oracle. | No such file on any branch. |
| #249 sec. 4: a model row "keyed by the image's Wyhash" prices its batch; a batch without one stays on the host. | Rows exist in the schema; no code reads them. |
| `machine.zig:98` and the fixture: "the constants the price carried in code". | True for 14. Nine more are stored for stage 4 and unread. |
| `docs/using/gpu.md:15`: "The default is `--backend=cpu`". | `espice --help`: "default auto with GPU kernels, else cpu". The page also has no word on calibration, and still describes the 120x constant (`:50-56`). |
| `TESTING.md` maps every oracle. | It does not list the placement oracle. |
| Brief for this page named `src/analysis/gpu/machine.zig`. | No such file. The owner of the file format is `src/analysis/machine.zig`. |

One more divergence between branches: commit `d36ae56c` (a header note in
`price.zig`: "this price is weak ... its placement is not deterministic")
is on `origin/main` and not an ancestor of `dev/performance`.

## 2. The decision

### What the measurements say `auto` should pick

On this laptop, by measured wall [tsv], with ties inside 1.3x left to the
CPU:

| Deck (study id) | Parts on the device | CPU s | GPU s | Winner |
|---|---|---|---|---|
| 8 tiny corpus decks | none | 0.004 to 0.064 | +0.26 to 0.46 [#249] | CPU, with zero driver calls |
| `chain4k`, `logic_b4_1k`, `pinv2000`, `ring_b4_1k`, `sram_b4_1k`, `chainb4_2000`, `chain_p103_1k` | eval | 0.59 to 3.45 | 0.71 to 3.19 | tie or CPU (0.76x to 1.23x) |
| `logic_p103_1k` | eval | 5.70 | 4.32 | GPU, barely (1.32x) |
| `logic_b4_10k` | eval | 57.9 | 49.0 | tie (1.18x) |
| `logic_b4_10k` | eval and LU | 57.9 | 47.1 | tie (1.23x) |
| `sram_b4_10k` | eval and LU | 18.0 | 13.3 | GPU (1.36x) |
| `logic_p103_10k` | eval only / eval and LU | 61.5 | 61.4 / 32.5 | LU decides: 1.00x / 1.89x |
| Transient lanes, 1,024 points | lanes | 1.73 | 3.40 | CPU (0.51x) |
| Transient lanes, 8,192 points | lanes | 14.6 | 9.45 | GPU (1.54x) |
| OP, AC, PSS, HB lanes | lanes | 0.17 to 6.26 | 0.59 to 23.3 | CPU (0.27x to 0.39x) |

On an A100 [model]: device eval alone 0.86x to 1.65x; eval and LU 1.5x to
4.5x; transient lanes 0.55x to 0.95x at 1,024 points and 3.1x to 4.1x at
8,192; OP, AC, PSS and HB lanes 0.27x to 0.40x, unchanged.

Three things follow. The lane verdict depends on the point count on every
card, so no rule on the card alone is right. The four host-bound lane
families lose on every card until #260 lands. And on thick factors the LU
is the part that decides, which is exactly the part the file does not price.

### Rule 1: placement is a pure function

`place(machine file, problem counts) -> placement`. No clock, no probe, no
record of an earlier run, no thread-pool state.

Why. "Placement never changes a result" holds bitwise only where the tree
says so:

| Part | Device against host | Source |
|---|---|---|
| Device LU | Bitwise | `gpu/lu.zig:4`; `ESPICE_GPU_LU_CHECK` compares factors and `dx` bitwise |
| Frequency lanes | Byte-identical on `.ac`, `.noise`, `.sp` sweeps | #227, measured |
| OP and DC lanes | Within tolerance | test name at `src/tests/espice.zig:3396` |
| Device evaluation | "Compared within numerical tolerance; different transient step decisions can produce different grids". The oracle is differential against the CPU result, not byte equality. | `docs/using/gpu.md:5`; `TESTING.md:52` |

Where the two sides agree only within tolerance, a placement that reads a
clock makes the output bytes of one deck differ between two runs. Today
four inputs of the decision are not functions of the deck:

| Input | Anchor | What moves it |
|---|---|---|
| The host probe's time | `context_cost.zig:254` | The core the thread sits on: 439 µs, then 1,074 µs, verdict flipped [#249] |
| A `CostCache` record | `context_cost.zig:197` | Whether an earlier run left one: 9 of 18 post-layout verdicts [#249] |
| `driver.started()` | `gpu/context.zig:412` | Which query of a `--jobs N` run reached the driver first |
| Lanes granted by the pool | `executor.zig:355`, `:376` | What other queries hold at that instant |

A pure function is deterministic by construction, costs nothing at run time,
needs no P- or E-core correction (nothing is timed in a run), and is tested
without a card. A wrong price then costs time, bounded by the oracle, and
never reproducibility.

The price paid: the host cost of a model comes from its calibrated row
(model defaults, a spread bias) and not from this deck's model card. Both
sides of the evaluation term scale together with that error, so it moves a
verdict only near a crossover, where the margin sits. Whether that holds is
measured in [step 2](#6-steps): the ratio of the recorded probe to the row,
per deck.

### What is decided when

| When | What | Cost |
|---|---|---|
| Once per process | Read the file and the identity. Missing or stale: every part on the CPU, one note, no driver. | One file read of at most 64 KB and about seven sysfs or procfs reads. #249 expects under 0.2 ms; **not measured in the tree**. |
| Once per Problem, after the circuit is built | Lane family per family. Whether any planned query takes the device; if so the driver starts on a thread beside the operating point. | Arithmetic over at most about 90 rows; under 10 µs [est]. Zero driver calls when every answer is CPU. |
| Once per query, before the first evaluation | Device evaluation: which rows. | The same arithmetic. |
| Lazily, per pivot epoch | Device LU, once the factor's flops `F` are known and the epoch has survived enough refactors. | A few multiplications per refactor. |
| After measured iterations | **Nothing.** | — |

Nothing is corrected from a measurement inside a run. The audit keeps
measuring and writes its record for the oracle tooling, and it no longer
demotes under `auto`. The device LU could take a timed correction without
changing a byte, since it is bitwise; it does not need one, because its
rule below counts refactors, and a count is deterministic. (Keeping the
demotion as a guard is an [open question](#7-open-questions-for-the-owner).)

### The cost model

Problem side, all exact and already computed:

| Metric | Where [code] | Known |
|---|---|---|
| Per row: `count`, kernel image, held bytes, stamp slots | `GpuPayload`, read in `context_cost.zig:251-261` | At circuit build |
| Device weight | `executor.zig:607`, `par_eval.zig:553` | At circuit build |
| `n`, `nnz` | `Circuit` | At circuit build |
| Expected evaluations `E` | `dispatch.zig:109`: `.op` 30, `.tran` `4 t_stop / min(dt_init, ceiling)`, `.dc` 3 per point | At query start. Measured: `.op` 26 to 160; `.tran` 0.54 to 1.02 of the guess [#249] |
| LU flops per refactor `F`, and `F/n` | `gpu/lu.zig:506-508` | After the first full factor, per pivot epoch |
| Refactors survived by this pivot sequence (`age`) | New: a counter beside `GpuLu.epoch` | Per refactor |
| Points `P` of a lane family | `Session.gatherWide`, `session_sched.zig:192` | When the group forms |
| Bus bytes per evaluation | `context_cost.zig:268-270` | At circuit build |

Machine side: the rows of [section 3](#3-the-calibration-run). `interp` is
piecewise-linear in log size between a row's measured sizes.

```text
Device evaluation, per query.  A row without a model row stays on the host.
  host_b = interp(model.host_p_us, count_b)           us per eval, one P-core
  kern_b = interp(model.dev_us, count_b) - eval_fixed_us
  g      = 1 below the lane gate (weight < 4M, executor.zig:578); else the
           time-weighted mean of model.lane_gain over the rows
  C      = E * sum(host_b) / g
  G      = E * (eval_fixed_us + sum(kern_b) + bus_bytes / bus + stage_bytes / stage)
  device iff  M * G < C

Device LU, per pivot epoch.  Per F/n class, a line through the class's two sizes.
  h      = host refactor + solve at this query's lu_threads      us, from lu rows
  d      = device call, upload to download                       us, from lu rows
  build  = table build for one epoch                             us, from lu rows
  buy    = build + (driver up ? 0 : start_in_ms)
  device from the first refactor where  age * (h - d) >= M * buy;  never if h <= d

Lane family f with P points.  A family without lane rows stays on the host.
  t_pt   = E * sum(host_b)                             one point on one core
  J      = min(job_gain, P)
  C      = P * t_pt / J
  G      = E * sum_b interp(lane.tick_us, P * count_b) + P * lane.host_pt_us / J
  device iff  M * G < C

Driver start, once per Problem:
  start the driver iff  sum over planned queries of (C - M * G), where positive,  >  start_ms
```

Fixed costs and where each enters:

| Cost | Measured | Enters |
|---|---|---|
| Driver start, per process | 311 ms; 128 to 145 ms in process; teardown 100 to 140 ms [#249] | The Problem-level sum. Never per query: that is what made it a race. |
| First module load of an image (JIT) | bsim4va 15 s, psp103 35 s, hisimhv_va 1,001 s cold (`context_cost.zig:136`) | Not priced. A model row exists only for an image this driver has compiled, so "has a row" means warm. |
| Per evaluation round trip | Launch and sync 7.6 µs; bus 5.6 µs plus 12.4 / 13.2 GB/s [#249]; 86 µs of host work and 219 µs of waiting on `logic_bsim4_10k` [#261] | `eval_fixed_us` plus the measured row, which is timed end to end. |
| Device LU call floor | 1.3 to 1.5 ms whatever the size (`gpu/lu.zig:574`) | The intercept of the `d` line. |
| Table build per pivot epoch | 2.1 s an epoch on `logic_bsim4_10k` (66 s over 31 epochs [#249]); 0.48 s with `perf/lu-tables` (6.0 s + 3.1 s over 19 epochs [#261]) | `buy`. |

**The LU rule is rent-or-buy.** Each refactor on the host "rents" at `h - d`
extra; moving the epoch to the device "buys" at one table build. Buying when
the rent paid equals the price costs at most twice the best choice in
hindsight (`1 + M` times with the margin), and it needs no guess of how long
the pivot sequence will live.
On `logic_bsim4_10k` [est]: device call 15.1 ms (the five `arp_lu_*` kernels
[tsv]) against 29 ms for a host transient refactor at 8 lanes
([02-baseline.md](02-baseline.md#the-refactor)), so
14 ms of rent; build 0.48 s; the epoch moves after about 34 refactors. The
operating point changes pivots every three refactors (60 refactors, 19
epochs [#261]) and never moves. The transient's single epoch (1,110
refactors) moves once and gives up about 0.5 s. Without `perf/lu-tables` the
bar is about 150 refactors. That is #261's option 1 and
[G3](05-levers-gpu.md#g3-operating-point-pivot-epochs-stay-on-the-host),
with N derived instead of chosen. It removes all four LU source constants.

**The lane form, checked against the only two points there are** [est]. The
two transient rows fit `G = 2.54 s + 0.844 ms * P` against
`C = 1.78 ms * P`: crossover near 2,700 points, and near 4,800 with
M = 1.3. The 2.5 s is not setup. Lane kernel time is 2.95 s at 1,024 points
and 6.97 s at 8,192 [tsv]: a launch costs its latency whatever the width
until the card fills, which is why `lane.tick_us` is a row over widths and
not a rate.

**The margin M** is not a machine constant. It is the 95th percentile of
`|log(predicted / measured)|` over the oracle's decks [#249 sec. 5]. It
lives beside the price as one constant, and the oracle test recomputes it
from `placement.tsv` and fails when the constant is smaller. `margin` and
`min_ratio` leave the file.

**Device evaluation per model type.** The cost is per row. The placement
bit stays one per query for now, with one exception that needs no new
mechanism: a row with no model row goes to `cpu_batches`, as a batch with no
image does today (`gpu/context.zig:438-449`). Waveform-history lines (LTRA,
CPL, TXL) get no row, so they stay on the host: one line loses 88x to 186x
on the device (fixture, `slowdown` note), and the wide batch is measured
both ways (6.60 s CPU against 3.44 s GPU in `placement.tsv`; 2.42 s against
3.45 s under VerA 0.23, commit `d36ae56c`). That deletes the four history
constants. A full per-row choice (each row where `kern_b < host_b / g`) is
the same arithmetic; build it when the oracle holds a mixed deck that beats
both pure placements by more than M. None is recorded.

**Explicit `cuda` and `hip` are untouched.** They place every eligible part
on the device and never read the file. No GPU path is deleted.

## 3. The calibration run

`espice calibrate`, once per machine and per build. It reuses the paths a
query takes and adds no kernel.

| Block | Measures | Rows | Regime it serves | State |
|---|---|---|---|---|
| Start | Driver start as a process cost and in process: 7 children each way | `start_ms`, `start_in_ms` | all | [int] |
| Launch and sync | An empty kernel | `launch_us` | 1 | [int] |
| Bus | Pinned copies, 4 KiB to 64 MiB, each way | `bus_lat_us`, `bus_up_gbs`, `bus_down_gbs` | 1 | [int] |
| Device memory | One 64 MiB device-to-device copy | `stage_b_per_us` | 1 | [int] |
| Card | Driver attributes | `fp64_ratio`, `sms`, `cc`, `mem_gb` | 3 | [int] |
| Model evaluation | Per kernel image, at 1, 64, 1,024, 16,384 instances: device µs end to end; host µs on one P-core and one E-core; ParEval gain on `ThreadPool.per_query` lanes | `model` | 1, 3 | [int] for 33 compact models. **Missing:** linear devices and sources, which have images too (`arp_evalc_resistor`, `arp_eval_vsource` in [tsv]). Enumerate the embedded image index, not a hand list. |
| Host LU | Refactor and solve through `direct.Solver`'s own entry (`refactorLu`, `direct.zig:505`), at 1 lane and at `per_query` lanes, two sizes per F/n class | `lu` | 2 | [int] times one thread only (`gpu/calibrate.zig:377`). The multicore refactor is admitted from `F >= 500k` and `F/n >= 300` (`direct.zig:658`), the same decks the device LU competes for, so the row overstates the host there. |
| Device LU | One forced call: refactor, both solves, upload to download; the epoch's table build | `lu` | 2 | [int]. To check on first run: each grid makes a new `GpuLu`, and `load_ns` wraps `bringUp` (`gpu/lu.zig:489-513`), so `table_us` may carry kernel loads and pinned allocations. |
| Lanes | Per family: device µs per Newton tick at 64, 1,024, 16,384 lanes of a reference circuit; host µs per point that stays on the host | `lane` | 3, and 1 for the host-bound families | **Missing.** Transient first. A family gets rows only once a measurement shows it can win. |
| Jobs | Throughput of one host evaluation loop on every allowed CPU against one P-core | `job_gain` | 1, 3 | **Missing.** Replaces "about 14 at once" (#260) and the `13 * 64` rule. |

Not in the run, and why. **Raw FP64 and FP32 rates** (207 GFLOP/s and
12.55 TFLOP/s on this card, `tools/gpu_devices.json`): no term reads them.
The FP64-bound regime is priced by the per-model and per-lane rows, which
are that rate times the model's instruction mix, and the device LU is bound
by memory traffic and by dependent chains (3% FP64 instructions,
[05-levers-gpu.md](05-levers-gpu.md#what-binds-each-kernel)), so a FLOP rate
would mis-price it. Add them when a part is priced from a roofline instead
of a measured row. **A P/E ratio constant** ([int] `pe_ratio`): with no
probe in a run, nothing needs correcting. `host_e_us` stays in the row as a
record and as the cross-check of `job_gain`.

**Noise.** A measurement is a median of 3 to 40 samples in a 15 ms budget
([int] `gpu/calibrate.zig:123`, `:392`). Add the spread to each row's log line,
and drop a row whose spread exceeds its stated accuracy; a dropped row keeps
its part on the host. The test of a measurement is a second measurement:
calibrate twice, compare by row name.

**Duration.** About 25 s is the plan's target [#249] and the text of the
note. With the host-LU lanes, the lane block and the job block: about 35 s
[est]. Budget 60 s with a warm driver cache; `--compile-all` (already in
[int]) compiles cold heavy images and takes minutes.

**Schema.** The file stays one TSV. Each row carries the key of what it
measured; a row whose key does not match this binary and machine is absent;
an absent row keeps its part on the host.

```text
# identity: any mismatch makes the whole file stale
driver   595.71.05
gpu      NVIDIA GeForce RTX 4060 Laptop GPU        one per card (the Model line of procfs)
cpu      Intel(R) Core(TM) i9-14900HX
cpus     32                                        online CPUs, not the affinity mask
p_cpus   0-15
e_cpus   16-31
build    ReleaseFast x86_64_v3 abi40               optimize mode, CPU target, device ABI
espice   0.20.0                                    a record
# machine constants, one per row
start_ms  start_in_ms  launch_us  bus_lat_us  bus_up_gbs  bus_down_gbs
stage_b_per_us  eval_fixed_us  fp64_ratio  sms  cc  mem_gb  job_gain
# rows keyed by what they measured
model  <image hash>               dev_us x4   host_p_us x4   host_e_us x4   jit_ms   lane_gain
lu     <host LU key> <LU image hash>   n   flops   host_us   host_par_us   dev_us   table_us
lane   <family> <image hash>      width   tick_us   host_pt_us
```

**Invalidation keys.** All are read without the driver.

| Key | Guards | Read from | Today [code] |
|---|---|---|---|
| Driver version | The driver's compiled kernels, launch and bus costs | `/sys/module/nvidia/version`, `/sys/module/amdgpu/version` | Compared |
| Card identity | Every device row | procfs per card | Compared, by uuid |
| CPU model | Every host row | `/proc/cpuinfo` | **Absent.** The file name is the machine id, which a cloned disk image shares. |
| CPU count | `job_gain`, lane gains | — | Compared, but it is the affinity count: `std.Thread.getCpuCount` is `sched_getaffinity` on Linux (`std/Thread.zig:1134` of the pinned toolchain). So `taskset -c 0-15 espice --backend auto`, the pinning the [README](README.md#reproducing-a-number) prescribes for CPU numbers, makes the file stale. Not run; read from source. |
| P and E core lists | Which cores the host rows were pinned to | `/sys/devices/cpu_core/cpus`, `cpu_atom/cpus` | Stored, not compared |
| Build: optimize mode, CPU target, `abi_version` | Host rates (a Debug binary would price with a ReleaseFast file), plane layout | Comptime (`device/abi.zig:819`) | **Absent** |
| Kernel image hash, per `model` and `lane` row | That model's device rate and its JIT warmth | Comptime, the embedded image | In the schema; unread |
| Host LU key, per `lu` row | The host refactor kernel. [C1](04-levers-cpu.md#c1-supernode-panels-in-the-refactor-replay) expects 1.5x from its first stage and 4x or more from its second on the thick 10k factors, with no change to any device image. | A build option: the content hash of the solver kernel sources | **Absent.** Without it C1 lands and the old host rate keeps sending thick factors to the device. |
| ESPice version | — | Comptime | Recorded, not compared. Keep as a record: the keys above say what changed. |
| File format | Parsing | — | Implicit: a file missing a required row does not load (`machine.zig:304`) |

Not keyed, and stated as such: power source and thermal state (a laptop on
battery), other load on the card, the PCIe link width. The start cost alone
moved 299 to 471 ms between runs [#249].

## 4. Gaps

| Gap | Evidence | Fix |
|---|---|---|
| No calibration command on this branch; the file's 9 stage-4 constants and its model rows are unread | Section 1 | Steps 1, 3 |
| No pivot-epoch term | `logic_bsim4_10k` under `auto`: 97.7 s against 68.1 CPU, 67.9 GPU; 31 epochs, 66 s of table builds [#249]. 19 epochs, 9 s with `perf/lu-tables` [#261] | Step 4: rent-or-buy |
| Device-LU bars are typed constants | `gpu/lu.zig:570-589`. `sram_bsim4_2k` (F 1.7M, F/n 509) was admitted and lost 33% before a refit [#222]. C1 moves every bar | Step 4: `lu` rows |
| The probe decides, and depends on the core | 439 µs then 1,074 µs on one deck; CPU 0.97 s, GPU 1.32 s [#249] | Step 3. Plan stage 6 is then closed, not built |
| A record of an earlier run decides | 9 of 18 post-layout verdicts [#249] | Step 3: the record is written, never read by `admit` |
| The driver's state and the pool's grant are price inputs | `gpu/context.zig:412`; `executor.zig:355` | Steps 3, 6 |
| Prestart by file size | A CPU-priced deck of 1 MiB pays a 307 ms start [#249]; `config.zig:118` | Step 6 |
| Lanes are one bit from the card | This card: 8,192-point transient sweep stays on the CPU, 14.6 s against 9.45 s [tsv]. An A100: 1,024-point sweeps would go to the device at 0.55x to 0.95x, and OP, AC, PSS, HB sweeps at 0.27x to 0.40x [model] | Step 5 |
| Host-bound lane groups | Host share 80 to 100% of the GPU wall; host seconds alone exceed the CPU wall on all four decks [tsv]; cause in #260 | Step 5 (no rows, so CPU), then [G1](05-levers-gpu.md#g1-lane-groups-host-work-on-the-pool-then-a-batched-dense-lu) |
| One `slowdown`, one `concurrency`, one `host_lane_gain` for every model | 120 spans 88x to 186x; 1,000 fits two decks to 25% [#249]; lane gain 3.3x bsim4, 1.8x psp103, 1x mos1 against one 0.1 (fixture) | Step 3: rows |
| Memory-bound batches priced as compute-bound | `txl_wide_batch_1000`: GPU 3.45 s, CPU 2.42 s, `auto` picks the GPU (`d36ae56c`). The oracle row still says 6.60 against 3.44 and expects the GPU | Step 2 re-measures; no row means host |
| The oracle is small, loose and loaded | 13 decks, 10x size tolerance, one host lane, walls taken at load 2 to 47 (`d36ae56c`), no LU, lane, post-layout or tiny deck | Step 2 |
| Staleness holes | The keys table above | Step 1 |
| [int] host LU row on one thread; `table_us` may include `bringUp`; policy values typed into the file | Section 3 | Step 1 |
| JIT warmth lives in marker files not keyed on the driver | `context_cost.zig:375` | Step 3: a model row is the marker |
| The lane term has no circuit-size axis | The lane backend runs each lane's LU in one thread (`kernels/lane.zig:3`), so a lane row measured on a 26-device circuit says nothing about a sweep of a 10k circuit ([G9](05-levers-gpu.md#g9-lanes-of-a-thick-circuit)) | Step 5: key `lane` rows by the reference circuit's size class, and keep a family on the CPU above the largest size calibrated |
| One constants block for every card of a machine | `machine.zig:76`, `:100` | Out of scope until a two-card machine exists (#220) |

## 5. Prior art

Each row was read at the URL given. "Transfers" and "does not" are this
page's reading.

| System | What it does (source) | Transfers | Does not |
|---|---|---|---|
| FFTW wisdom | `FFTW_MEASURE` finds a plan "by actually computing several FFTs and measuring their execution time"; wisdom saves it to a file to "reload it as many times as necessary"; `FFTW_WISDOM_ONLY` returns a NULL plan when there is none; a system file `/etc/fftw/wisdom`. "It should be safe to reuse wisdom as long as the hardware and program binaries remain unchanged." <https://www.fftw.org/fftw3_doc/Planner-Flags.html>, <https://www.fftw.org/fftw3_doc/Words-of-Wisdom_002dSaving-Plans.html>, <https://www.fftw.org/fftw3_doc/Caveats-in-Using-Wisdom.html>, <https://www.fftw.org/fftw3_doc/Wisdom-Import.html> | Measure once, keep a file. A mode that refuses to guess: no wisdom, no plan (here: no file, CPU). The invalidation rule is hardware plus binary. | Wisdom stores decisions per problem size, and FFTW does not detect stale wisdom itself. Circuits are unbounded, so the file stores rates. |
| ATLAS | "Uses empirical timings in order to choose the best method for a given architecture" (Whaley, Petitet, Dongarra, LAWN 147, p. 3, <https://www.netlib.org/lapack/lawnspdf/lawn147.pdf>). "Empirical searches, when ran on real machines experiencing unrelated load, are almost never strictly repeatable" (<https://math-atlas.sourceforge.net/faq.html>). | Timings on the user's machine beat typed constants. Expect a loaded machine: pin, take medians, and test a calibration against a second one. | An install-time search over code variants that may take hours. It picks a kernel, not a place to run it. |
| OpenBLAS | No calibration. Kernels are chosen by CPU detection (`DYNAMIC_ARCH`); one build constant, `GEMM_MULTITHREAD_THRESHOLD = 4`, "a factor proportional to the number of floating point operations", decides single thread or many. <https://github.com/OpenMathLib/OpenBLAS/blob/develop/Makefile.rule> | A work count is the right axis for a threshold (`borrow_min_weight` is one). | The threshold is typed and the same on every machine. |
| StarPU | History-based models per codelet and architecture, calibrated online and saved under `$STARPU_HOME/.starpu/sampling/codelets`, "separate performance models according to the hostname"; not trusted "until 10 (`_STARPU_CALIBRATION_MINIMUM`) measurements have been made on each architecture"; `STARPU_CALIBRATE=2` when "the calibration information is stale and should be dropped"; the bus is calibrated "before execution start, i.e. with an idle machine". <https://files.inria.fr/starpu/doc/html/CheckListWhenPerformanceAreNotThere.html>, <https://files.inria.fr/starpu/doc/html/Scheduling.html>, <https://files.inria.fr/starpu/doc/html/OfflinePerformanceTools.html> | Rows per (kernel, architecture); bus rows; one file per host; a minimum sample count; an explicit "stale after a kernel change". | Learning from the timings of production runs. The owner ruled inline calibration out, and it is what `CostCache` does: placement that depends on which run came first. |
| MAGMA | Block sizes and crossovers are source tables by problem size and GPU generation (`magma_get_dgetrf_nb`). "Optimal block sizes vary with GPU and, to a lesser extent, CPU"; tuned on named machines, one branch "based on experiments using AMD CPU running MKL + A100-SXM4 GPU". <https://github.com/icl-utk-edu/magma/blob/master/control/get_nb.cpp> | A threshold that is a pure function of problem size. | Constants from someone else's machine. `gpu/lu.zig:570-589` is this pattern, and it is what C1 breaks. |
| NVBLAS | Routes a BLAS call "based on a simple heuristic that estimates if the BLAS call will execute for long enough"; `NVBLAS_CPU_RATIO_<func>` "defines the ratio of the workload that should remain on the CPU". <https://docs.nvidia.com/cuda/nvblas/index.html> | Admit by predicted duration; a CPU and GPU split of one workload (`gpu_share`). | The heuristic is not documented and not measured; the ratio is typed by the user. |
| CHOLMOD on a GPU | A supernode goes to the device by fixed sizes: `CHOLMOD_ND_ROW_LIMIT 256`, `CHOLMOD_ND_COL_LIMIT 32`, `CHOLMOD_POTRF_LIMIT 512`. <https://github.com/DrTimothyAldenDavis/SuiteSparse/blob/dev/CHOLMOD/Include/cholmod.h> | Placement per part of one factor, by the part's size: the shape G2's panels would need. | Typed constants, and a driver probe at start (`cholmod_gpu.c`). |
| SuperLU_DIST | `sp_ienv_dist(7)`: "the minimum value of the product M*N*K for a GEMM call worth being offloaded to accelerator", set by `SUPERLU_N_GEMM`. <https://github.com/xiaoyeli/superlu_dist/blob/master/SRC/prec-independent/sp_ienv.c> | A flop count as the offload bar inside a sparse LU. | An environment variable the user must tune. |
| PETSc | Device initialization is `NONE`, `LAZY` ("initialized on demand") or `EAGER`; `NONE` is "useful to ensure that no accelerator is used in a program". The user picks the placement by object type. <https://petsc.org/main/manualpages/Sys/PetscDeviceInitType/> | Lazy driver start (plan stage 1). | No automatic choice. |
| Kokkos | `DefaultExecutionSpace` is a type alias "defined based on build system flags", "the highest available in the hierarchy device, host-parallel, host-serial". <https://kokkos.org/kokkos-core-wiki/API/core/execution_spaces.html> | Nothing at run time: it is the `-Dgpu` rung. | — |
| PostgreSQL planner | A plan is chosen by arithmetic over table statistics and cost constants from a configuration file. "Only their relative values matter." "There is no well-defined method for determining ideal values ... changing them on the basis of just a few experiments is very risky." <https://www.postgresql.org/docs/current/runtime-config-query.html> | The price's shape: problem statistics times machine constants, decided before execution, with the predicted costs printable. The warning is why the oracle is a deck list and M comes from all of it. | The constants are typed by an administrator. |

Not verified at a primary source: Intel MKL Automatic Offload's size
thresholds (Intel's own page is gone; forum replies disagree on the
numbers); cuSOLVER (no selection mechanism was looked up); and the
rent-or-buy bound of section 2, which is the ski-rental result of Karlin,
Manasse, Rudolph and Sleator, "Competitive snoopy caching" (Algorithmica,
1988), cited from memory and not fetched.

## 6. Steps

One pull request each, in order. Every step keeps: the corpus raws
byte-identical under `--backend cpu`; `tests/VERDICTS.tsv` unchanged by
name; explicit `cuda` and `hip` behaviour unchanged. "GPU" marks a step
whose gate needs the card. The merge gate is `zig build test` in
ReleaseSafe; a GPU step adds `zig build test -- --backend auto --jobs 1` and
`-- --backend cuda --jobs 1`.

1. **Land the calibration, corrected.** GPU. Bring `calibrate` over from
   `origin/dev/integration`. Time the host LU through the solver's own
   refactor entry at 1 and `per_query` lanes. Keep `bringUp` out of
   `table_us`. Enumerate the embedded images for the model rows. Add the
   `gpu`, `cpu`, `cpus` and `build` identity rows, compare the core lists,
   and count online CPUs. Add a calibration section to
   `docs/using/gpu.md` (text fences only).
   *Oracle:* the measurement itself, twice.
   *Done when:* `espice calibrate` exits 0 and prints its wall time, under
   60 s; a second run agrees with the first within each row's stated
   accuracy, compared by row name; images without a row are listed by name
   and match an allow-list in the test; without a card it exits 1 with a
   named error; `taskset -c 0-15 espice --backend auto` loads the file.
2. **The oracle before the price.** GPU. Move the table to
   `src/analysis/placement.tsv` and write `tools/placement.py` to
   re-measure it: `cpu`, `cuda` and `auto` walls per deck, host runs pinned
   to P-cores, a quiet machine. Add: the 8 tiny decks; the post-layout
   decks of 10k and under from
   `tests/conformance/external/spice-bench/postlayout/gen.py`; the six LU
   rows of #222 (host against device LU ms per iteration); the transient
   lane sweeps at 1,024 and 8,192 points and the four host-bound sweeps,
   which live outside the tree today and must enter the corpus. Record per
   deck the probe's `price row` lines (`context_cost.zig:263`) beside the
   calibrated rows. Map the oracle in `TESTING.md`.
   *Oracle:* measured walls, by deck name.
   *Done when:* the test is red by name on the decks today's price gets
   wrong (`known` markers for `logic_bsim4_10k`, the 8,192-point sweep,
   `txl_wide_batch_1000`); the size tolerance is the measured run-to-run
   spread, not 10x; the 95th percentile of the probe-to-row ratio is
   written down and is under M, or the pure price is reopened with the
   owner.
3. **`price.place`, pure.** Move `price.zig` to `src/analysis/price.zig`;
   it imports no driver and no clock. Rows price from `model` rows. The
   probe, the `CostCache` read, `driver.started()` and the pool's grant
   stop being inputs (price with `lanePlan(...).want`). Delete `slowdown`,
   `concurrency`, `host_lane_gain`, `min_ratio`, the four history constants,
   `heavy_image_bytes` and the marker files. M becomes the checked
   constant. Name the result type something other than `Placement`:
   `gpu/devices.zig:66` already owns that name for the choice of card.
   *Oracle:* the placement oracle by name; the driver-entry counter.
   *Done when:* a `known` marker removed for every deck it fixes; `place`
   called twice and from 8 threads gives equal results; a deck near a
   crossover run twice under `auto` with a fixture file, at 1 job and at 8,
   gives the same bytes; the 8 tiny decks still make 0 driver entries; the
   probe-flip deck (`chain_bsim4_1k`) has one verdict.
4. **Device LU by rent-or-buy.** GPU. `GpuLu.admits` takes the `lu` rows
   and the epoch's age; delete `min_per_col`, `min_call_flops`, `min_flops`
   and `gpu_lu_min_n`.
   *Oracle:* the host LU; the six LU rows by name.
   *Done when:* raws byte-identical to `ESPICE_GPU_LU=0` on the five
   device-LU decks; `ESPICE_GPU_LU_CHECK=1` reports 0 mismatches; the
   operating-point query's `gpu-lu:` line (`gpu/lu.zig:216`) reports at
   most 2 epochs on `logic_bsim4_10k`, `sram_bsim4_10k`,
   `logic_psp103_10k`; `logic_bsim4_10k` under `auto` is
   within M of the better backend; `sram_bsim4_2k` loads no epoch.
5. **Lane families.** GPU. Add the `lane` and `job_gain` blocks to
   calibrate, transient lanes first. `gpu_lanes.policy`, `staticPolicy` and
   `devices.cardCap` read rows; delete the `<= 4` rule, `13 * 64` and the
   `e1_*` constants. A family without rows stays on the CPU under `auto`.
   *Oracle:* the six sweep decks by name.
   *Done when:* on this card's file the 8,192-point sweep goes to the
   device and the 1,024-point one does not; the four host-bound sweeps stay
   on the CPU with any file, including one built from the [model] rows of
   an A100; `--backend cuda` still lanes all six.
6. **Start the driver from the plan.** GPU. After the circuit is built,
   price the planned queries and start the driver on a thread if the sum
   says so. Delete `likelyGpu` and `likely_gpu_bytes`.
   *Oracle:* the driver-entry counter; walls.
   *Done when:* a CPU-priced deck of 1 MiB or more makes 0 driver entries
   (red today); `chain_bsim4_10k` under `auto` is within 5% of `cuda`.
7. **The audit records.** Under `auto` it writes its measured-against-priced
   record and no longer demotes; `tools/placement.py` reads the records.
   Skip this step if the owner keeps the guard.
   *Done when:* no `auto` run changes placement after its first evaluation.
8. **After C1 lands:** run calibrate again and step 2's LU rows. Expected on
   this card: the thick-factor decks price to the host
   ([G2](05-levers-gpu.md#g2-supernode-panels-in-the-device-lu)). This is a
   measurement, not a code change, and it is the test that the host LU key
   works: the old file's `lu` rows must not load.

Steps 3 and the arithmetic of 4 and 5 can be built and unit-tested with no
card, against a fixture. They cannot be trusted before step 1 has produced
one measured file.

## 7. Open questions for the owner

1. **Pure price or probe.** This page drops the live probe as a decision
   input, which departs from #249 sec. 5 (ratio times the live probe) and
   closes stage 6 unbuilt. Accept, or keep the probe and the P/E correction?
   The deciding measurement is cheap: the cpu-against-cuda parity sweep
   compared byte for byte, with the differing decks listed by name. Zero
   names means device evaluation is exact class and a clock cannot change a
   byte.
2. **The audit's demotion.** Keep it as a guard against a badly wrong price
   (it catches a 100x loss at evaluation 40), at the cost of placement that
   depends on a clock? Recommended: record only, unless question 1's sweep
   finds zero differing decks.
3. **M in the source.** "No built-in constants" was the decision. M is a
   property of the model's error over the oracle set, not of a machine, so
   calibrate cannot measure it. Is a source constant that the oracle test
   recomputes acceptable?
4. **Recalibrate per build.** The `build` and host-LU keys make a file stale
   after an upgrade that changes a calibrated kernel, and a Debug binary
   never shares a ReleaseFast file. "Once per machine" becomes "once per
   machine and build". Accept?
5. **Card identity by model or by uuid.** The file is keyed by the machine
   id and the card's uuid, so every node of a cluster of identical machines
   needs its own run, and a container without `/etc/machine-id` never
   calibrates (`machine.zig:427`). Keying on the CPU model, the card model
   and the driver would let one file on a shared home serve them all.
6. **History lines stay on the host under `auto`**, giving up the
   1,000-line TXL batch, which is measured both ways. Accept until a deck
   shows the device ahead by more than M?
7. **Where the sweep decks live.** The lane oracle needs the six sweep decks
   in the conformance suite; they are in a scratch directory today.

## Could not verify

- Whether device evaluation is bitwise the host's. The tree's tests compare
  within tolerance. #251 states that the device's reduced planes equal the
  serial stamp at the same `x`; that covers the reduce, not the model
  evaluation.
- The 0.2 ms cost of loading the file, and the 10 µs of the arithmetic.
  Neither is measured in the tree.
- Anything about `calibrate` at run time. It has never run.
- The device call of the rent-or-buy estimate (15.1 ms) is kernel time only;
  uploads and downloads are not in it, so the real bar is higher than 34.
- The lane form has two measured points, both from one 26-device circuit.
