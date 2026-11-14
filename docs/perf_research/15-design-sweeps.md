# Design sweeps: a population of runs per optimizer iteration

Whether ESPice should offer sizing sweeps and optimization as batches of
independent runs, in what smallest form, and how a batch chooses CPU
threads, CPU lanes and GPUs. A brief to implement from; nothing was built
or run for it. Line numbers are the working tree of `dev/performance` on
2026-11-11 (uncommitted edits over `9bbd4d7f`). The price model and the
calibration file are [08-placement.md](08-placement.md)'s, plus one row.

| Tag | Meaning |
|---|---|
| **[code]** | Read at the anchor in the working tree. |
| **[tsv]** | `docs/performance/gpu-phases.tsv` (RTX 4060 Laptop, 2026-11-04, host pinned to P-cores 0 to 15). |
| **[hist]** | `git show 05852567^:dev/research/gpu-ensemble.md`: the #99 research note, measured 2026-10-17 on this laptop, deleted from the tree by `05852567`. It used a stacked-deck proxy, not today's lane backend. |
| **[model]** | A prediction of `tools/gpu_extrapolate.py`, quoted from page 08. |
| **[#N]** | Stated in issue N, not re-measured. |
| **[web]** | Read at the URL in [section 3](#3-prior-art). |
| **[est]** | Arithmetic or judgement of this page. |

**The short answer.** The batch primitive already exists three times: a
`.data` or `.step` deck with `--measures`, the HSPICE `SWEEP OPTIMIZE`
optimizer, and the C points API. On the CPU each candidate is bitwise its
run alone at any `--jobs`. What is missing is narrow: a batch's result on
the GPU depends on its batch-mates, no price says where a batch of K runs
belongs, and a generation is a loop outside the DAG. On this laptop a
sizing generation of tens to hundreds of runs belongs on CPU threads; the
GPU needs thousands of lanes.

## 1. What exists today

### Cards that express independent runs [code]

| Card | Becomes | Anchor |
|---|---|---|
| `.step` | One variant row per grid point; every analysis runs per row | `frontend/Netlist/card_table.zig:122`, `frontend/Jobs/variants.zig:205-212` |
| `.data` with `SWEEP DATA=name`, inline or `MER`/`LAM FILE=` | One row per table row | `frontend/Netlist/reader_sweeps.zig:85`, `frontend/source/source_data.zig:1-4`, `variants.zig:164-173` |
| `SWEEP MONTE=n`, `MONTE=list(...)`, `SIGMA_SCALE=` | One row per trial | `variants.zig:174-198` |
| `.mc n` and `.temp start stop step` (ngspice) | One query split into lane rows, reassembled in lane order | `analysis/session_jobs.zig:216-227`, `session_sched.zig:338-370` |
| HSPICE `.temp t1 t2 ...` | Every analysis once per temperature (`tol.temp_c`) | `session_jobs.zig:137-145` |
| `.alter`, and corners as `.alter` with `.del lib` | A row when the circuit matches the nominal one and the deck has no other variants; otherwise a rebuild with its own session | `frontend/source/source_alter.zig:1-3`, `variant_planner.zig:256-274`, `espice/Problem.zig:277` |
| `.dc` | One query; its points are warm-started in sequence, not rows. A bare `.dc DATA=`/`MONTE=` is a row ensemble | `analysis/dc/dc.zig:1-5`, `variants.zig:149` |
| `SWEEP OPTIMIZE=` with `.model OPT`, `.param p=optrange(...)` | Levenberg-Marquardt or bisection; each round is a private session of variant rows | `reader_sweeps.zig:80-84`, `espice/optimizer.zig:131-175` |
| `.wcd` | FORM search; gradients from tangent rows or a finite-difference batch | `espice/wcd.zig`, `docs/using/analyses.md:704-740` |
| C: `espice_set_params`, `espice_append_points` | Rows on one template, no re-parse | `include/espice.h:209-217`, `:310-326`; `espice/points.zig:96-185` |

A point re-evaluates the live values and keeps only the writes that moved
(`variants.zig:4-9`): 6 ms a sky130 sizing point, 87 with a re-parse [#101].

### How rows reach the scheduler and what runs them [code]

Each row is a query with an implicit operating-point prerequisite
(`session_jobs.zig:229-238`). `Pool.fill` starts ready rows up to
`--jobs` (`session.zig:546-552`; the default is one per logical CPU,
`main.zig:452`). Before a row starts, `gather` may make it the leader of a
lane batch (`session_sched.zig:114-135`):

| Path | When | Width | Result against the run alone |
|---|---|---|---|
| One thread per row | Default | `--jobs` | Bitwise; "the same at every N" (`docs/using/cli.md:127-135`) |
| CPU SIMD lanes | `--lanes` or `ESPICE_LANES`, CPU backend, one device thread | 4 (AVX2) or 8 (`exec_config.zig:163-164`) | Bitwise (`session_sched.zig:109-110`). Off by default: "measured no faster" (`exec_config.zig:181-186`); 1.05x end to end on BSIM-CMG [#211] |
| Inner lanes of one run | Device weight of 4M or more, or 50k matrix entries (`executor.zig:603-626`) | Up to 8 of a pool of half the logical CPUs (`exec_config.zig:110-137`) | Bitwise |
| GPU lanes | `cuda`/`hip`, or `auto` on a card with `fp64_ratio <= 4` (`gpu/lanes.zig:428-435`) | Up to 16,384 (`exec_config.zig:73`), in waves | Within tolerance (`gpu/lanes.zig:9-11`) |
| GPU and CPU together | `gpu_share` f: the first `ceil(f * rows)` in row order stay on the device | — | Mixed (`session_sched.zig:231-244`, `gpu/lanes.zig:442-446`) |
| Several GPUs | Transient batches: contiguous row-order slices by capacity, 64 rows at least | — | Compiled, never run on a card [#220] (`gpu/multi.zig:1-7`, `gpu/devices.zig:135`, `:262`) |

Breadth-first order under GPU lanes lets a sweep's operating points drain
first, so the analyses gather N wide (`session_sched.zig:459-481`). Lanes
gather only under a run-to-completion quantum (`session.zig:552`), so
`espice_run_all` batches and `espice_advance` does not.

### Restrictions that matter for sizing [code]

**Equal across lanes:** the template, the analysis options but for the
variant row and temperature (`session_sched.zig:140-146`,
`session_jobs.zig:86-95`); `n`, `nnz` and the sparsity pattern
(`gpu/lanes_batch.zig:292-295`); per model batch the kernel, counts, row
sizes and scatter tapes (`:299-305`). Every lane replays **lane 0's pivot
order** (`gpu/lanes_init.zig:110-113`).

**Cost of a per-lane parameter change:** each member builds its own
circuit, serially (`executor_lanes.zig:193`); the estimator charges 4,096
bytes per unknown, 1,024 per matrix entry and 64 KiB of host memory a lane
(`:408-414`; measured 2.3 KB per unknown on 72 unknowns). Model rows are shared
across lanes when their bytes are equal (`lanes_batch.zig:307-312`). A W
or L that moves a model bin makes a new template, which cannot share a
batch (`points.zig:136-140`); a value that changes the topology refuses
the point (`espice.h:275-277`).

**Why a batch runs one at a time instead:**

| Family | Refusals | Anchor |
|---|---|---|
| Transient GPU lanes, whole batch | No kernel images; `uic`, snapshot, OPtran or **tangents**; Gear 3 to 6; `.options dv`; VPI, display tasks or a load check; a delay line; charge without a tape; a model batch with no device payload, with `commit_state`, `predict_first_iterate`, `check_convergence` or `advance_iteration`, coupled inductors, or host-stepped state | `tran/gpu_drive.zig:229-262` |
| The same, found at run time | Lanes of different `n`; **any lane whose `Run.init` fails** sends every lane to the CPU; no tape from the lead lane; pattern or tapes differ; a driver error | `gpu_drive.zig:73-75`, `:94`, `:99-113`; `gpu/lanes.zig:96-103` |
| One lane leaves | The device asks to reject a step: the lane reruns alone on the CPU from its start | `gpu_drive.zig:149-157` |
| OP and `.dc` GPU lanes | Fewer than 2 lanes; nodesets, `.ic` holds, a floating start; a JFNK pin or certify; `dv`; then `staticRefusal`: images, VPI/display/load check, no payload, Newton hooks, coupled inductors, host-stepped | `dc/op_lanes.zig:112-119`, `gpu/lanes.zig:467-480` |
| CPU lanes | Display tasks; nodesets, a floating start, a JFNK pin, certify | `executor_lanes.zig:53-54`, `op_lanes.zig:42-45` |

Lanes whose plain Newton fails take their own ladder on the host, one
after another (`op_lanes.zig:220-234`). Under 256 lanes the two host
passes of every round run on one thread (`tran/gpu_step.zig:331-334`).
A wave holds at most 4 GiB of host lanes and never fewer than 256
(`executor_lanes.zig:46-48`, `:173-176`), and at most the device's free
memory (`gpu/devices.zig:247`, #217).

## 2. The frontend shape

The smallest primitive is the one the owner names: a table of parameter
rows in, a table of measures out. It exists in the deck and in C.

```text
* table in, table out: espice --tokenizer=hspice --measures=gen0.json deck.sp
.param w1=2u rv=5k
.data pop MER FILE='gen0.txt' w1=1 rv=2
.enddata
.tran 10p 5n sweep data=pop
.meas tran tphl trig v(in) val=0.9 rise=1 targ v(out) val=0.9 fall=1

* the loop inside the simulator, today (src/tests/espice.zig:1579)
.param w1=optrange(2u, 0.5u, 20u) rv=optrange(5k, 1k, 50k)
.model optmod opt itropt=40 relin=1e-6 relout=1e-10
.dc vin 0 1.8 0.01 sweep optimize=opt2 results=v1,v2 model=optmod
.meas dc v1 find v(out) at=0.9 goal=1.682597
```

```c
/* the loop outside, today: the caller owns the optimizer and the flow */
espice_points_options po = { .struct_size = sizeof po, .abort_after = NAN,
                             .measures_only = 1, .early_stop = 1, .warm_start = 1 };
for (int g = 0; g < generations; g++) {
    ask(opt, x, K);                            /* K rows of live_param_count values */
    espice_append_points(p, x, K, &po, &first);
    espice_run_all(p);                         /* --jobs threads, or lanes */
    espice_copy_point_measures(p, first, K, names, M, y, reasons);
    espice_release_points(p, first, K);        /* the problem stays the same size */
    tell(opt, y, reasons);
}
```

The C header already states the contract a generation needs: "a point's
measures and reason depend only on the deck and its values, never on
count, order, max_parallel or the other points" (`espice.h:247-249`).
Both in-tree searches are already ask and tell: `points()` hands out the
rows, `feed()` takes residuals (`core/lm.zig:204-230`,
`core/bisect.zig:5-7`), and one `evaluateRows` serves them and `.wcd`
(`optimizer.zig:65-127`). That is requests instead of callbacks.

**The DAG.**

| Node | Today | Edge |
|---|---|---|
| Candidate | A variant row (`Row.variant`, `session.zig:597`) | — |
| Analysis | A query row | `dependency` on its operating point; `reads` for `.four`/`.fft` (`session.zig:598-616`) |
| Measure | Not a row: read from a finished query, or streamed under `--measures-only` (`points.zig:247-282`) | — |
| Objective | `goalError` of the RESULTS cards, inside the optimizer (`optimizer.zig:262-266`); the caller's in C | — |
| Generation | **Missing.** A `while` loop in `optimizer.search` (`:231-243`) over private sessions (`:91-95`), run once "before any query of the Problem advances" (`:4-6`) | Measures of generation g to rows of g + 1 |

Because the loop is outside the DAG, `--plan` cannot show it,
`espice_advance` cannot step it (`espice.h:183-184`), nothing can cancel
it, and a `.step` of optimizations runs its bases one after another
(`optimizer.zig:145`) instead of gathering all their rounds into one
batch. The DAG-level change is one row kind: a generation is ready when
the previous one's rows are terminal; running it calls `feed()`, then
`points()`, and appends the next rows (`appendAt` exists; ids survive
appends, `espice.h:155`). Everything below it (jobs, lanes, placement,
progress) then sees ordinary rows. The C API needs no generation node:
the caller is the edge. What C lacks is for asynchronous optimizers: no
call cancels a point (`espice.h:52-55`) or returns at the first m of K.

## 3. Prior art

Read at the URL unless marked; "speed" is the source's own claim.

| System | What it parallelises | What it says about speed |
|---|---|---|
| HSPICE optimization [web H1, H2] | Nothing stated. `.MODEL OPT`, `.PARAM p=OPTxxx(init, min, max)`, `SWEEP OPTIMIZE=`; "Only Level=1 is available" (modified Levenberg-Marquardt), plus bisection and pass/fail; gradients by finite differences (`DIFSIZ`). "HSPICE then simulates the circuit again and repeats this process". The optimization chapter of the 2010.12 guide has no parallel mode. | "Generally, 10 to 30 iterations are sufficient" |
| HSPICE `.DATA` [web H2] | The table itself: ".AC, .DC, and .TRAN commands can use external and inline data provided in .DATA commands" | — |
| HSPICE `-dp`, `-mp`, `-mt` [web H1] | Whole runs: ".ALTER blocks ...; Transient-based Monte Carlo analysis; Transient data sweeps". "Does not support DC/AC Monte Carlo and Data Sweeps." `-mt` is "for model evaluations and matrix solving", `-mp` "for multiple ALTER, SWEEP and Monte Carlo iterations", and "MP takes priority in CPU resource allocation" | "if 100 systems are available, then it only takes the time of 10 jobs plus results integration to do 1000 Monte Carlo data points"; "a multithreaded simulation may run slower than single-threaded" on small circuits |
| Xyce `.STEP`, `.SAMPLING` [web X1] | Not the samples: "executed sequentially for each sample point"; "some available parallelism, just not applied on a sample basis"; for that "it is recommended that Xyce users instead use the Dakota library" | — |
| Xyce `.EMBEDDEDSAMPLING` [web X1, X2] | All samples in one block system: "each matrix block has the structure of the original matrix", "all samples are propagated simultaneously"; `.DC` and `.TRAN` only | None given; "this method is less mature" |
| Dakota driving Xyce [web D1 to D3, X3] | Evaluations, as processes: a parameters file in, a results file out; `asynchronous` with `evaluation_concurrency` ("launch all available evaluations simultaneously" by default) | None given |
| ngspice [web N1] | Nothing across runs. No `.step` (a `.control` loop "replaces .STEP"); "does not have an integral optimization processor"; four outside optimizers (script, tclspice, Python, ASCO); OpenMP: "Only the device evaluation is parallelized" | "more than 8 threads ... does not yield much improvement" |
| ASCO [web A1, relayed by the fetch tool] | Function evaluations of differential evolution, one simulator process each over files | None given |
| Spectre 13.1 reference [web S1] | Monte Carlo is "a swept analysis with associated child analyses"; `+dp` is distributed APS | None given. ADE job policies and optimizers: **unread** (login-gated) |
| MACE, batch Bayesian optimization [web M1] | B = 4 HSPICE runs per iteration | Qualitative ("dramatic speedup"); the optimizer itself took "about 11 hours" for 175 iterations on a 10-D test function |
| AutoCkt, GCN-RL [web K1, G1] | Parallel simulator environments | "1.3 hours on a 8 core CPU"; "simulation time accounts for over 95% of the total runtime" |
| CMA-ES tutorial [web C1] | A population of `4 + floor(3 ln n)` by default, which "can be increased" | "The convergence speed (per function evaluation) decreases at most linearly with λ" |
| Batch bandits [web B1, B3] | B evaluations per round | GP-BUCB's regret is "only a constant factor, independent of B, worse"; "when comparing solely in terms of n, the sequential version outperforms the parallel versions"; synchronous workers "wait idly for others to finish" |
| cuSolverRF batch [web V1] | Refactor and solve of matrices where "each matrix ... has the same sparsity pattern, and quite similar such that factorization can be done by the same permutation" | None given; deprecated in favour of cuDSS |
| In-tree research #99 [hist] | N same-pattern points stacked on the 4060 | Beats one CPU thread from N = 1 to 30; "loses to 24 CPU processes on every deck" |

Sources: H1 `ele.uri.edu/courses/ele448/HspiceRef/hspice_sa.pdf`, H2
`.../hspice_cmdref.pdf` (HSPICE E-2010.12, a university copy); X1, X2
`xyce.sandia.gov/files/xyce/Xyce_Users_Guide_7.9.pdf` and
`Xyce_Reference_Guide_7.9.pdf`; X3 `osti.gov/servlets/purl/1415117`; D1
to D3 `snl-dakota.github.io/docs/6.17.0` and `6.19.0`; N1
`ngspice.sourceforge.io/docs/ngspice-manual.pdf`; A1
`asco.sourceforge.net`; S1 a university copy of `spectreref.pdf`; M1
`proceedings.mlr.press/v80/lyu18a/lyu18a.pdf`; B1
`jmlr.org/papers/volume15/desautels14a/desautels14a.pdf`; K1, G1, C1, B3
arXiv `2001.01808`, `2005.00406`, `1604.00772`, `1705.09236`; V1
`docs.nvidia.com/cuda/cusolver`.

**Unread**, so not cited: Storn and Price 1997 (differential evolution);
Ginsbourger's q-EI; WEIBO and GASPAD (paywalled); the ASCO manual (403);
cuDSS; Cadence ADE; any vendor's GPU SPICE page; Gulati and Khatri. Read
as abstracts only: the MACE follow-up `arxiv.org/abs/2106.15412` (claims
up to 74x less simulation time than differential evolution at batch 15)
and batched power flow `arxiv.org/abs/2101.02270`. One search found no
paper on GPU-batched Monte Carlo SPICE.

## 4. Which optimizers fit a batch

Ranked by how many of K parallel runs an iteration can use:

| # | Method | Runs per iteration | Fit |
|---|---|---|---|
| 1 | Sampling: grid, Latin hypercube, Monte Carlo, `.data` | Any K, no dependence | Exists. The only workload that reaches thousands of lanes |
| 2 | Population search: differential evolution, CMA-ES, NSGA-II | The population; grows freely | One synchronous batch per generation on one pattern. Evaluations are worth less as the population grows [web C1], so K runs buy fewer than K times the generations |
| 3 | Multi-start gradient search | Starts x (1 or n + 1) | LM exists; K starts are K independent paths, each bitwise its run alone |
| 4 | K-section pass/fail search | K points per round | Bisection asks one midpoint a round (`bisect.zig:6-7`); K points shrink the bracket K + 1 times a round: 20 rounds become 7 at K = 7 [est: 20 / log2(8)] |
| 5 | Batch Bayesian optimization | 4 to 15 in the papers read | Fewest simulations, but the optimizer's own cost is hours [web M1]: for runs of seconds to minutes, not milliseconds |
| 6 | Levenberg-Marquardt, Nelder-Mead | n + 1 | LM batches its trial with its n Jacobian points (`lm.zig:11-14`) |

**Sensitivities against K finite-difference runs.** In the tree [code]:
`.sens` is adjoint (one factorization and one transpose solve, then one
residual evaluation per parameter, DC only, `sweep/sens.zig:1-6`); `.dc`
and `.tran` tangents move each parameter row by one solve on the held
factor per accepted step, on the base run's time grid
(`tran/Tangents.zig:1-9`). Measured [#97]: a 32-stage chain fit fell from
1.05 s to 0.69 s at a residual 6e5 times lower; a 128-stage fit rose from
2.9 s to 8.4 s because it went on to a residual 270 times lower. Tangents
win when cores are the limit (population times n + 1 exceeds them) and
when the finite-difference step is near the time grid's noise. With idle
lanes K finite-difference runs cost one run of wall time, and they are
the only choice on the GPU: tangents are refused there
(`gpu_drive.zig:231`, `optimizer.zig:44-53`), as under `uic`, `.ic`, Gear
above 2 and VPI. AC goals have none yet [#97].

## 5. CPU or GPU for a batch of R runs

R is the rows of one lane family (candidates x corners x analyses). All
terms are page 08's but `job`, which it lists as missing (`job_gain`).

```text
t_run = E * (sum_b host_b + lu_host)          one run on one P-core: model and lu rows
c     = t_run / (J * g)                       J = min(job_gain, R); g = inner-lane gain, 1 below the lane gate
C(R)  = R * c
G(R)  = W * F + R * m                         W = ceil(R / wave) waves
F     = E_max * tick_floor                    ticks of the slowest lane at the launch-bound floor
m     = marginal device time per lane + lane.host_pt_us / J_host
device alone iff  M * G(R) < C(R);   R* = M * W * F / (c - M * m), none when c <= M * m
both at once:     f = (c R - F) / (R (c + m)) on the device, from R > F / c;  T = c (m R + F) / (c + m)
D cards:          G_D(R) = F + (R / D) * m    every slice pays F; only m divides
memory:           wave = min(4 GiB / host_bytes(n, nnz), free VRAM / device_bytes(n, nnz, rows))
```

**Worked example** [est on tsv], the two transient lane rows (a
26-device circuit): 3.40 s at 1,024 lanes and 9.45 s at 8,192 give
F = 2.54 s and m = 0.844 ms; the CPU's 14.6 s at 8,192 gives c = 1.78 ms.
R* = 2.54 / (1.78 - 0.844) ms = 2,700 lanes, 4,800 with M = 1.3 (page
08's figures). With today's `margin = 3.3` (`analysis/price.zig:34`) the
denominator is negative: never. A generation of 100 candidates at 5
corners is 500 rows: 0.89 s on the CPU, 2.96 s on the card. Both at once
help from 1,430 lanes; at 8,192 the split predicts 6.4 s against 9.45 and
14.6. Two cards: 6.0 s; four: 4.3 s; never under F. On an A100 [est on
model] page 08's predicted walls put R* between 1,000 and 1,900 lanes:
the card divides m by about 3.7 and F by 1.6 at most, since F is launch
latency times ticks.

So D cards and a faster card lower m, and only width beats F. Waves
multiply it: a 1,000-unknown circuit fits about 300 lanes in a host wave
[est: 4 GiB / (4,096 B x 3,500 + 64 KiB), at 10 entries a row], so 2,000
rows pay F seven times. Sizing fills a card through its inner loop (Monte
Carlo or corners per candidate), not through its population.

**Lanes that differ.** Newton ticks run until the last lane converges
(`gpu/lanes_newton.zig:82-119`); lockstep cost 1.01 to 1.43 times the mean
iteration count, 1.9 at worst [est: the inverse of [hist]'s 0.70 to 0.99
and 0.52]. Each lane keeps its own step control (`gpu_drive.zig:1-5`), so
rounds follow the lane with the most steps and the tail runs nearly alone
at the floor: that is `E_max` in F. A lane that fails plain Newton or
rejects on the device costs a host run (section 1), serial under 256.

**One more calibration row.** `job <size class> <jobs> <gain>`: the
throughput of J identical independent transients of each lane row's
reference circuit on every allowed CPU, over one P-core. [hist] measured
it once, as processes: 24 at a time gave 17.0x at 855 unknowns and 11.1x
at 8,505. Lane rows need the same size key (page 08's gap).

**What falsifies it.** A third width: 4,096 lanes of the same deck must
land near 2.54 + 3.46 = 6.0 s. A second size: 64 lanes of
`logic_bsim4_1k` ([G9](05-levers-gpu.md#g9-lanes-of-a-thick-circuit) step
1) against its size class's row. The split: 6.4 s at 8,192 lanes assumes
the host keeps its rate while it also steps the device lanes (26% of the
GPU wall [tsv]). Any of the three outside M closes the affine form.

## 6. Does parallel across runs always beat series?

For a fixed set of runs on the CPU the measurements agree, with bounds.

| | Measured | Source |
|---|---|---|
| Inner: one run on 8 lanes | 2.1x to 3.1x wall for 2.6 to 4.1 times the CPU-seconds; IPC falls from 2.3-3.0 to about 1 | [02](02-baseline.md#thread-scaling), [09](09-after-the-levers.md#counters) |
| Outer: 55 runs, 8 processes | 5.7x to 7.3x (55 to 8,505 unknowns) | [hist], corners x Jacobian table |
| Outer: 55 runs, 24 processes | 11.1x to 17.0x | [hist] |
| CPU SIMD lanes | 1.05x end to end | [#211] |

Eight cores return two to three times more as eight runs than as eight
lanes of one run [est, across two deck sets]. HSPICE draws the same line:
"MP takes priority" [web H1]. Where the claim fails or needs a bound:

| # | Case | Evidence |
|---|---|---|
| 1 | A run shorter than its dispatch | A 10-unknown operating point: 15.2 ms for 55 in series, 24 ms in 8 processes [hist]. On the GPU the floor is F: 1,024 transient lanes take 3.40 s against 1.73 s on the CPU, 8,192 operating points 0.59 s against 0.17 s [tsv] |
| 2 | A batch smaller than the machine | K below the core count leaves cores idle unless runs take inner lanes, and the pool lends them first come, first served (`exec_config.zig:128-137`): of four large candidates on a pool of 16, two get 7 extra lanes, one gets 2, one none [est], and the generation waits for the last |
| 3 | A run that already fills the machine | One post-layout point fills the card: "N points cost N times one point" [hist] |
| 4 | Memory per run | K runs hold K circuits and factors. The 256-lane wave minimum over-commits this laptop above about 8,400 unknowns by the estimator [est: 31 GB / 256 / (4,096 B x 3.5), at 10 entries a row], above about 53,000 at the measured 2.3 KB per unknown. Waveforms were the larger term: a 1,000-row sweep fell from 6.5 GB to 168 MB under `--measures-only` (`CHANGELOGS.md:54`) |
| 5 | Caches and bandwidth | One thread is core-bound (6 to 13 points of slots on memory); eight lanes reach 13 to 25 on `chain_bsim4_10k` [09]. Outer scaling drops from 17.0x to 11.1x with circuit size [hist]. Not measured on thick factors |
| 6 | Hybrid cores | 24 cores are worth 11 to 17 [hist], and `--jobs auto` starts 32 |
| 7 | The serial remainder | Lane construction, the host passes under 256 lanes, the ladder of peeled lanes (section 1) |
| 8 | Early stopping | A synchronous generation waits for its slowest member [web B3]; `early_stop` and `abort_after` bound a point (`espice.h:290-301`), but nothing cancels the stragglers |
| 9 | The set is not fixed | For an optimizer, K parallel evaluations are worth less than K sequential ones [web C1, B3]: the gain per generation is between 1 and K |

## 7. Determinism

On the CPU the rule holds today: rows are bitwise their run alone at any
`--jobs`, order and lane grouping (`src/tests/espice.zig:1510`, `:3225`),
warm starts use one nominal guess (`points.zig:212-242`), and the LM path
is the same batched or not (`lm.zig:11-14`, test at `espice.zig:1579`).

On the GPU a lane's bytes depend on its batch-mates at seven sites [code].
The GPU lockstep test compares a lane with its run alone to 1e-3 of each
column's peak, and bitwise only between two copies of one point in one
batch (`espice.zig:3317-3320`, `:3558`).

| Site | Dependence | Anchor |
|---|---|---|
| Pivot tape | Lane 0's order, on lane 0's first matrix: the lowest row of the batch decides everyone's rounding | `lanes_init.zig:110-113`; `session_sched.zig:215-217` |
| Retape | When half the active lanes fail a replay, the first failing lane becomes the lead | `lanes_newton.zig:94-101`, `:114`, `:165-169` |
| Dense peel pool | Whether a failed lane is solved on the device or by its host solver depends on how many others failed that tick | `lanes_init.zig:161`; `lanes_newton.zig:84-86`, `:97-100` |
| Waves | Each wave has its own lane 0; the wave size follows K, the circuit and the card's free memory at that moment | `executor_lanes.zig:173-176`; `devices.zig:247` |
| Host share | A row's index decides CPU (bitwise) or device (tolerance) | `session_sched.zig:231-244` |
| Device slices | Split by rates measured in the last batch; slices share the tape, but retapes and peel pools are per slice | `devices.zig:192-217`; `multi.zig:1-7` |
| Whole-batch fallback | One lane's failed `Run.init` moves every lane to the CPU | `gpu_drive.zig:94` |

What makes a lane independent: (1) the tape comes from the template's
nominal circuit, once per template and options, and every batch, wave and
slice replays it (`devices.TapeShare` already carries one tape to many
slices); (2) a lane whose replay fails peels alone, and nothing retapes
the others; (3) the dense peel is chosen by `n` alone; (4) fallbacks are
per lane; (5) a point batch goes whole to one side, placed once per
optimization from the declared population, never per generation and
never from `espice_lane_width`; (6) a population method draws by
(generation, candidate) from `.option seed`, never from a stream consumed
in completion order. Then a lane's bytes are a function of the template,
its own values and the backend. CPU against GPU stays within tolerance
until device evaluation is shown bitwise (page 08, open question 1).

## 8. Verdict and stages

**A good addition, and a small one.** The evaluation primitive is built,
and the owner already deferred the optimizer's rebuild "on top of the
high-throughput points system" [#97, 2026-10-19]. No new batch engine and
no GPU-first sizing path: in [hist] and [tsv] small batches lose there.

| Stage | Built | Where | Oracle | Gate | GPU |
|---|---|---|---|---|---|
| 0 Measure | Sizing-shaped decks (64, 512, 4,096 rows at two circuit sizes) in the placement oracle; series, `--jobs`, `--lanes`, `cuda` walls; the `job` row | `tools/`, `src/analysis/gpu/placement.tsv`, `gpu/calibrate.zig` | Measured walls by deck name | The three falsifiers of section 5 have numbers | Needs the card, a ReleaseFast GPU build and `espice calibrate` |
| 1 Batch-independent lanes | Section 7's points 1 to 4 | `gpu/lanes_init.zig`, `lanes_newton.zig`, `tran/gpu_drive.zig` | The same candidates in other batches: other mates, orders, wave sizes and slice counts | Exact on a fixed backend: byte-identical across batch compositions, red first on a changed lane 0; CPU raws unchanged | This is the GPU stage. The host build of the lane bodies tests the tape rule without a card |
| 2 Price a batch | Section 5 as a pure function beside `price.place`; lane rows keyed by size; `gpu_share` whole per batch | `analysis/price.zig`, `machine.zig`, `gpu/lanes.zig` | The placement oracle by name | Each stage-0 deck lands on its measured winner or within M; no clock in the decision | Rows need a calibrated card; without them every batch prices to the CPU |
| 3 Generation as a row | The `search` loop becomes a row kind; then one population method behind `points()`/`feed()` | `analysis/session*.zig`, `espice/optimizer.zig`, `src/core` | Today's serial optimizer: every base's history byte-identical; a new method against its own run one candidate at a time | The `netlist/optimize` conformance decks and `src/tests/espice.zig:1579` byte-identical at `--jobs` 1 and N, and under `--lanes` | Rows are ordinary rows, so GPU lanes take them after stage 1. Blocked on the device: tangents, so gradients there are finite-difference lanes |
| 4 Width | Corners and candidates in one batch (lanes across templates of one pattern); cancel a point and return at the first m of K; the #220 gate | `session_sched.zig`, `c_api.zig`, `gpu/multi.zig` | Each corner run alone; a cancelled generation's survivors against the full one | Exact; `GOMPUTE_FAKE_DEVICES=2` byte-identical to one device | #220's gate needs the card |

## 9. Open decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| 1 | Where the optimizer lives | Outside, through the C points API, for everything beyond HSPICE's own cards; inside, only what a deck-only user needs |
| 2 | Syntax | No new card: one new `METHOD=` value on `.model OPT` and one population key; tables stay `.data` |
| 3 | Which methods ship | In order: K-section pass/fail (small, and setup and hold searches are the common case), multi-start LM on tangents, then one population method. Differential evolution is the least code that fills a wide batch [est]; CMA-ES's default population is small [web C1]. Decide after stage 0 |
| 4 | Objective language | Keep `.meas ... GOAL=` with `WEIGHT=` and the `GOAL < v` form for constraints (`frontend/Parse/measure_words.zig:66-72`, `core/measure_card.zig:161-176`); a general expression is already a `.meas ... PARAM=` card |
| 5 | The LM path | Trying several dampings per iteration would use a batch but leaves HSPICE's CLOSE/CUT rule, which the owner kept [#97, 2026-10-08]. Keep it; use multi-start |
| 6 | The GPU contract | Batch-independent on a fixed backend (stage 1). Bitwise equal to the CPU also needs the host to start from the template's pivot order (rounding class): not now |
| 7 | `--jobs auto` | One per logical CPU against a measured gain of 11 to 17 [hist]: set it from the `job` row |
| 8 | The 256-lane wave minimum | Cap by host memory first |

## Could not verify

- Any GPU number: none was measured for this page. The lane fit has two
  points from one 26-device circuit; no lane deck has a large circuit.
- In-process outer scaling: [hist] measured processes on an older engine.
- Whether device `.meas` passes, device step control or the 16-round
  launch add a batch dependence: read, not tested.
- Whether jobs plus borrowed lanes oversubscribe: 32 jobs and a pool of
  16 on 32 logical CPUs (`main.zig:452`, `exec_config.zig:123`).
- Every [est] figure. Line anchors moved while this page was written;
  they were re-checked once at the end.
