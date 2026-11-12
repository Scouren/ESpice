# CPU levers

Eight work packages. Each names its class ([README.md](README.md#classes)),
what it applies to, the measured headroom with its arithmetic, the oracle,
the gate and steps with a "done when". Numbers are from
[02-baseline.md](02-baseline.md) unless a source is given. Line numbers are
`dev/performance` at `9bbd4d7f`.

A gain is quoted on the transient Newton loop at 8 lanes unless it says
otherwise. Gains do not multiply freely: two levers that remove refactor
time are each priced again after the other lands. C2 and C5 are rejected
and deleted; their sections stay as the record of what was tried.

| Lever | Class | Pays on | Headroom |
|---|---|---|---|
| [C1](#c1-supernode-panels-in-the-refactor-replay) | exact | thick factors | The refactor is 49 to 86% of Newton time and runs at 5% of a core's FP64 rate |
| [C2](#c2-the-confirming-solve-on-the-held-factor) | tolerance | every nonlinear transient | **Rejected by the owner and deleted.** It needed an accuracy bound of its own, and the corpus stayed clean only at 1e-6 of the Newton tolerance |
| [C3](#c3-linear-circuits-one-confirm-per-factor) | exact | linear circuits | Half the solves; the solve is 54% of Newton time on an RC ladder |
| [C4](#c4-bypass-that-pays-on-production-models) | tolerance | latent circuits, BSIM4 post-layout decks among them | The bypass is off on decks that are 99% latent; on BSIM4, 65 to 97% of eligible evaluations miss on instance bytes and 3 to 11% on voltages |
| [C5](#c5-solve-and-update-at-lane-scale) | exact | everything at 8 lanes | **Rejected by measurement and deleted.** The solve never scales, and no form built made it faster |
| [C6](#c6-lanes-past-eight-and-what-idle-lanes-burn) | exact | large circuits | 8 of 32 threads used; 2.6 to 4.1x the CPU-seconds for 2.1 to 3.1x the wall |
| [C7](#c7-one-reduce-pass-that-also-forms-a) | exact | parallel stamping | The reduce and the load are two serial sweeps over the planes |
| [C8](#c8-the-operating-point) | tolerance | large cold starts | The operating point is 23 to 44% of wall on three 10k decks |

What binds once these eight are in, and the levers after them (N1 to N10),
is in [09-after-the-levers.md](09-after-the-levers.md).

## C1 Supernode panels in the refactor replay

**Class:** exact. **Files:** `src/solver/lu_replay.zig`,
`src/solver/lu_panel.zig`, `src/solver/kernels/lu.zig` (the threaded
kernel), `src/solver/subtree.zig`.

**Today.** The full factor already runs supernode panels: `panelRun`
(`lu_panel.zig:149`) applies a run of consecutive panel steps to a column
as a dense triangular part plus `panelRows` (`:193`), `W` rows per vector,
bitwise the column loop because each row's subtractions stay in step order.
The refactor replay does not: `Replay.columnAfter` (`lu_replay.zig:65`)
calls `scatterAxpy` (`:174`) once per U entry, one
`dst[idx[p]] -= src[p] * f` at a time. The threaded kernel for thick
factors (`kernels/lu.zig:479`) is the same loop with a destination map.

**Headroom.** One P-core replays 1.9 pairs/ns on `sram_bsim4_10k`: 3.8
GFLOP/s against a nominal 72. Each pair streams 12 bytes (an L value and a
row index), 480 MB per refactor out of L3 at 23 GB/s. On the 10k thick
factors 92 to 96% of the pairs sit in runs of 8 or more supernode columns
and 83 to 84% in the rectangular part below the block
([census](02-baseline.md#supernode-runs)). The roofline: arithmetic
intensity is 2 FLOP per 12 bytes, 0.17 FLOP/B, against a ridge near 3
FLOP/B for this core (72 GFLOP/s over 23 GB/s). The replay is memory-bound
by a factor of about 18, and SIMD alone cannot fix a memory bound.

**Change, in two stages.**

1. *Runs (one target column, a run of source columns).* Per pivot epoch,
   build a run table: for each column, its U entries cut into runs of
   consecutive steps of one supernode. A run goes through the panel
   kernel: the block rows as a dense triangular solve, the common rows as
   `panelRows`, gathered from the accumulator once per row per run instead
   of once per pair. Singleton entries keep `scatterAxpy`. This removes the
   index stream (12 to 8 bytes per pair) and puts four pairs in each
   vector instruction. Expected: 1.5x from the stream alone, more if the
   core rather than L3 was the bound; a measurement decides.
2. *Tiles (several target columns per pass of a source panel).* When
   consecutive target columns belong to one supernode and list the same
   source runs in the same order, apply each source run to all of them
   before moving on, with the target supernode's own dense panel as the
   accumulator. The source panel's values are then read once per w target
   columns: bytes per pair fall by w and the kernel becomes compute-bound.
   This is SuperLU's supernode-panel update (Demmel et al. 1999, section
   on 2-D blocking). Expected: toward the core's vector rate, 4x or more
   over today on `logic_bsim4_10k` and `sram_bsim4_10k`, and better lane
   scaling, since eight lanes stop sharing one L3 stream.

To make a panel readable in place, reorder each supernode column's rows in
`li`/`lx` once per pivot epoch so the common rows appear in one order
across the supernode. A column's rows are distinct, so their order does not
change any value (`lu_replay.zig:164`, "Pairing is bitwise..."). Do it
after the full factor finishes: the factor's DFS walks `li`, and every
epoch table (`buildTape`, the subtree plan, the device tables) must be
built after it.

**Soundness.** A value slot receives the same subtractions in the same
order, none contracted into an FMA. Stage 2 holds that only for target
columns whose stored source order agrees; the table build checks it and
falls back to stage 1 per column.

**Oracle.** `refactorColumns` (`lu_replay.zig:185`), the column loop, in a
unit test that compares every L, U and pivot value bitwise on the
post-layout matrices and on random patterns with planted supernodes. The
`W == 1` instantiation of `panelRows` is the scalar oracle of the vector
one. The test goes red first by breaking the row order.

**Gate.** Corpus raws byte-identical; 1 against 8 threads byte-identical;
`ESPICE_GPU_LU_CHECK=1` 0 mismatches where a GPU build exists; the LAPACK
scaled-residual oracle unchanged. Report pairs/ns at 1 and 8 lanes on the
eight post-layout decks before and after.

**Steps.**

1. Land the `lu-runs` line of [census.patch](census.patch) as a permanent
   `ZP_LU_STATS` line. Done when it prints on the eight decks and matches
   the table in 02.
2. Microbenchmark first: replay `sram_bsim4_10k`'s transient factor 100
   times through `refactorColumns` and through a prototype that sends runs
   of 8 or more to `panelRun`'s arithmetic. Done when pairs/ns at one lane
   is recorded for both; stop here if the prototype is under 1.3x.
3. The row reorder and the run table, per pivot epoch, sized once from the
   pattern. Done when the oracle test passes.
4. Stage 1 in the serial replay, then in the subtree lanes, then in the
   threaded kernel body. Done when the gate passes at each.
5. Extend the census with the share of pairs whose target columns group
   into tiles of w = 2, 4, 8. Done when that share is known for the two
   thick 10k decks; stage 2 is worth building above 50% at w = 4.
6. Stage 2. Done when the gate passes and the refactor's speedup from 1 to
   8 lanes is reported.

**Also for the device.** The same table drives
[G2](05-levers-gpu.md#g2-supernode-panels-in-the-device-lu). After stage 1
lands, refit the host-against-device admission bars (#222, #249).

## C2 The confirming solve on the held factor

**Verdict: rejected by the owner (2026-11-11), code deleted.** C2 was
built three times: a margin on the held update, an error bound read off
two updates, then a measured bound from one step of iterative refinement.
Each needed a tolerance of its own (`held_eps`), and the corpus stayed
clean only with that bound at 1e-6 of the Newton tolerance: an operating
point accepted 1.6e-6 of its tolerance away from the fresh one became 60
times the current tolerance at the first transient point, where the charge
terms divide the difference by a tiny step
([measured](13-implementation.md#c2-on-the-corpus)). The owner's ruling:
the accuracy a user sets is SPICE's own option set (`reltol`, `abstol`,
`vntol`, `chgtol`, `trtol`), not a bound this simulator invents. Stage 2
(a values-only confirming evaluation) falls with it: without the held
solve, the confirming iteration's Jacobian is the one its update is solved
with. The text below is the proposal as researched.

**Class:** tolerance. Needs the owner's decision: the rule in force says an
inexact solve is not a default-mode option
([the rule](07-prior-work.md#the-published-iterate-rule)). This lever uses
one for a verdict and never for a published value, which is a narrower
thing than what was ruled out. **Files:** `src/solver/converger.zig`.

**Today.** A step that converges at iteration k factors and solves at k
only to learn that the update is under tolerance; `x` is then restored to
the linearization point (`converger.zig:354`). At 2.0 to 2.9 iterations a
step, 25 to 50% of all factors do nothing else.

**What was measured.** With the factor of iteration k-1 held and used for
iteration k's solve, the largest scaled update is the fresh factor's to
within the histogram's resolution, and a verdict taken at a margin of 0.5
(accept when the held-factor update is under half the tolerance) agrees
with the fresh verdict on every one of 1.6 million confirming iterations
across 15 decks: zero wrong accepts. It accepts 86 to 100% of the
confirming iterations ([census](02-baseline.md#the-confirming-iteration)).
The reason is visible in the same table: most confirming updates are under
1% of the tolerance, so a few percent of error in the update cannot move
the verdict.

**Change.** In the Newton loop (`converger.zig:282`), at an iteration that
can accept (not the first, factor held, matrix changed):

1. Solve on the held factor (`slv.solveNeg`, `direct.zig:294`).
2. If the largest scaled update is under the margin, hand that update to
   `finalizeStep` as today. On acceptance the published point is the same
   `x_k` bit for bit, because it is the linearization point and no solve
   produced it.
3. Otherwise factor and solve as today.

The step attempts a held solve only when the previous iteration's scaled
update was small enough to make acceptance likely. Without that guard a
deck at 4 iterations a step pays three wasted solves per step
(`scaling_inverter_chain_4k`: 2,349 wasted solves at 49 µs against 1,157
saved factors at 79 µs is a net loss).

**What can still move.** Two things, both within the Newton tolerance:

- The limiter history. After an accept it holds values written at the
  discarded iterate, which now comes from the held factor. Where a limiter
  clamps at the start of the next step, the clamp sees an "old" value that
  differs in its low bits.
- A held-factor accept that `finalizeStep` then refuses for a reason other
  than the update (a device test, a limiting event). The census saw none
  in 1.6 million. The iteration then continues from an inexact step; every
  later iterate is still an exact Newton step from its own linearization.

**Expected gain** (factor share times factors saved, less the wasted
solves):

| Deck | Newton time now | Saved | Speedup of the Newton loop |
|---|---|---|---|
| `sram_bsim4_10k` | 12.9 s | 4.4 s (47% of 9.45 s) | 1.52x |
| `logic_bsim4_10k` | 37.8 s | 10.1 s (33% of 32.4 s, less 333 solves) | 1.36x |
| `logic_bsim4_1k` | 2.09 s | 0.41 s | 1.25x |
| `chain_bsim4_10k` | 2.49 s | 0.29 s | 1.13x |
| `vacask_graetz` | 1.59 s | 0.14 s | 1.10x |

After C1 the refactor is cheaper and these shrink in proportion.

**Stage 2, later: a values-only confirming evaluation.** An iteration that
accepts on a held factor never uses its Jacobian. Evaluating residual and
charge without derivative lanes would cut that evaluation by the dual
overhead. It collides with three things and waits for them: the bypass
records stamps at exactly these iterations (C4), the device convergence
test reads the linearization, and every new entry point per model grows the
binary (#259).

**Oracle.** The fresh-factor verdict: the census counter becomes a debug
assertion mode that computes both and fails on a wrong accept. ngspice
remains the oracle of the results.

**Gate.** The full oracle corpus passes; every deck whose raw moves is
named with its largest move; `tests/VERDICTS.tsv` unchanged by name; 1
against 8 threads byte-identical; the wrong-accept assertion mode is clean
on the corpus and the post-layout decks. No flag: the margin and the guard
select it.

**Steps.**

1. Split `finalizeStep`'s update test into a pure function of `(x, dx)`.
   Done when the corpus is byte-identical with it.
2. Extend the census: for each iteration, the previous iteration's scaled
   update, so the guard's bound is a fitted number. Done when a bound keeps
   95% of the saved factors and wastes under 5% of solves on every deck.
3. The held-factor path at `W == 1`. Done when the gate passes.
4. Price it again after C1 and decide whether stage 2 is worth its cost.

## C3 Linear circuits: one confirm per factor

**Class:** exact, by argument. **Files:** `src/solver/converger.zig`,
`src/analysis/tran/Sim.zig`, `src/device/traits.zig`.

**Today.** A circuit with no nonlinear device still takes two iterations a
step, because the first is never accepted (`converger.zig:626`). The
second finds the matrix bitwise unchanged, so the factor is skipped
(`direct.zig:278`): on all 1,016,379 steps of the three linear decks
measured. What remains of it is an evaluation, a load, a solve and an
update, and the solve is 54% of Newton time on `rc_ladder_1000`.

**Argument.** With every stamp independent of `x`, the residual at the
first iterate's result is `A x1 - b` to rounding, and the second solve
returns an update at rounding level. ngspice, which solves for `x` rather
than for an update, gets the same `x` twice and always accepts at the
second iteration. ESPice's second iteration can only disagree with that
when its own rounding noise exceeds the tolerance, in which case it
iterates where ngspice would not. Skipping the confirming solve on a
linear circuit therefore publishes the same `x1` on every step where
today's confirm passes, and ngspice's behaviour on the rest.

**Change.**

1. A circuit-level flag, set once at build: every batch's stamp is
   independent of `x` (`constant.g` and no `limit`, no state that reads
   `x`). Time-varying sources are fine.
2. Stage 1: when the flag is set and the matrix is bitwise unchanged at the
   second iteration, skip the solve and accept. Everything else runs, so
   every plane and state a later phase reads is what it is today.
3. Stage 2: skip the whole second iteration. First trace every consumer of
   what it produces (`Sim.end`'s charge re-read at `tran/host_ops.zig:78`,
   `updateStates`, the planes the LTE reads).

**Expected gain.** Stage 1 on `rc_ladder_1000`: 109 of 404 ms, 1.37x on
the Newton loop. Stage 2: half the loop, toward 2x. `vacask_rc` (n = 4,
two million iterations) and the T-line decks gain the same shares.

**Oracle.** Today's engine: corpus raws byte-identical. A unit test on a
linear deck that counts solves per step (2 before, 1 after) and compares
the published vector bitwise. An ill-conditioned linear deck (resistors
over 15 decades) where today's second iteration does not accept, with an
analytic solution as its oracle, pins down the one case that changes.

**Gate.** Corpus raws byte-identical; the linear decks' solve count
halves.

**Steps.**

1. The flag and its test (a deck with one diode must not set it). Done
   when the flag is correct on every corpus deck by name list.
2. Stage 1. Done when the gate passes.
3. The trace for stage 2, written into the PR. Done when each consumer is
   listed with the line that proves it does not read iteration 2.
4. Stage 2. Done when the gate passes.

## C4 Bypass that pays on production models

**Class:** tolerance (the bypass already is; `batch_bypass.zig:1`).
**Files:** `src/device/batch_bypass.zig`, `src/device/traits.zig`, VerA.
**Issues:** #257, #256 (its oracle, first).

**Today.** Per instance per iteration the bypass gathers the unknowns,
compares the whole instance row with `std.mem.eql`
(`batch_bypass.zig:195`), replays every recorded stamp with a first-order
residual, and re-reads the charge exactly (`:201`). It never looks at a
step's first iterate (`:165`). `review` (`:117`) turns a batch off for the
rest of the run when hits are under one in five after four evaluations per
instance.

**What was measured.**

- The off switch fires during the operating point, when nothing is latent,
  and it is final. Every BSIM4 post-layout deck, the diode decks and
  `scaling_parallel_inverters_2000` run their whole transient with the
  bypass off. `bench_ngspice_mosamp` loses it 1% into the run
  ([census](02-baseline.md#the-bypass)).
- `bench_ngspice_mosamp` and `scaling_parallel_inverters_2000` are latent
  on 99% and 73% of evaluations by the previous round's activity census,
  and device evaluation is 68% and 69% of their Newton time. The first is
  a deck ngspice wins.
- Where the bypass stays on it is not cheap: on the MOS1 chains at 99%
  hits, one thread is slower than ngspice, which evaluates everything
  ([03-rspice.md](03-rspice.md#where-ngspice-still-wins)).

- With the switch disabled, the misses are bytes and not voltages
  ([census](02-baseline.md#why-it-misses)). Past the first iterate, the
  whole-row compare fails on 96.5% of BSIM4 evaluations on
  `chain_bsim4_1k`, 92.3% on `sram_bsim4_1k`, 64.6% on `logic_bsim4_1k`
  and 78.6% of MOS2 evaluations on `bench_ngspice_mosamp`, while the
  tolerance test fails on 3.2%, 3.5%, 10.9% and 0.9%. The post-layout
  BSIM4 decks are latent circuits that the key cannot see as latent.
- PSP103 and the diode decks miss on tolerance (83% and 98% of eligible
  evaluations); their rows never change. The key does nothing for them.
- Found while implementing ([finding 25](06-open-issues.md#incidental-findings)):
  BSIM4's moving bytes are eleven latch fields that the evaluation does
  read, so step 2 as written below (key on the read set) fixes MOS2 and
  not BSIM4. BSIM4 needs the narrower fact that those latches enter only
  the charge's value.

**Change, cheapest first.**

1. *The review rule.* Count from the first transient step, not from the
   operating point. Judge a window, not the whole run, and re-arm: a batch
   that was turned off is probed again after a backoff. Before choosing
   constants, measure what a miss costs with the bypass on (the recording)
   against a plain evaluation; that ratio is the break-even hit rate, and
   one in five is a guess until it is measured.
2. *The key.* A recording is valid while what the evaluation reads is
   unchanged. Comparing the whole row asks more: it also covers what the
   step writes and the evaluation never reads. Split the row hot and cold
   on VerA's read set, or have the writer bump an epoch.
3. *The first iterate.* A model that does not read the iteration number
   may replay it. With 2.0 iterations a step that doubles what the bypass
   can skip. The list of such models comes from VerA's `sim_reads`.
4. *A cheap hit.* A hit's Jacobian and capacitance stamps are bitwise the
   recording's. Under ParEval they already sit in the instance's staging
   cells: stop resetting those cells in the reduce, and a hit writes only
   its residual. The tolerance compare runs over SoA references, vector
   wide.

**Expected gain.** Evaluation time scales as
`first + (1 - first) * (active + latent * h)`, with `first` the share of
first iterates and `h` a hit's cost over an evaluation's. On
`bench_ngspice_mosamp` (`first` 0.47, 99% latent, `h` assumed 0.3): steps
1 and 2 bring evaluation to 0.63 of today and the Newton loop to 0.75
(1.34x); with step 3, 0.31 and 0.53 (1.9x). `h` is the number to measure.
The same formula on the BSIM4 census, taking every byte miss as latent
(an upper bound, since the byte test hides the tolerance test) and `h` at
0.3: `chain_bsim4_1k` (`first` 0.49, 3.2% active) 0.65 of today's
evaluation with steps 1 and 2 and 0.32 with step 3; `sram_bsim4_1k` 0.65
and 0.33; `logic_bsim4_1k` (`first` 0.39, 10.9% active) 0.62 and 0.38.

**Oracle.** The plain evaluation's linearization, row by row: the
generator of #256, which must exist and go red on the reverted tied-gate
fix before any of this lands. ngspice for the results.

**Gate.** #256's generator green; the full oracle corpus passes; every
moved deck named with its largest move; raws byte-identical between 1 and
8 threads; P-core cycles on `scaling_inverter_chain_256`, `_4k`,
`bench_ngspice_mosamp`, `scaling_parallel_inverters_2000` and the four
BSIM4 1k decks.

**Steps.**

1. #256.
2. Land the hit and miss-cause counters of
   [census-bypass.patch](census-bypass.patch) behind `--timing-in-depth`. Done when each model's hit rate and miss
   causes print per query.
3. The miss-cost measurement and the review rule. Done when the two latent
   decks keep the bypass on and no deck is slower by more than noise.
4. The key. First list which bytes of a BSIM4 and a MOS2 row differ
   between a recording and the next compare (candidates: module-level
   variables the model assigns on every evaluation, limiter history).
   Done when BSIM4's misses on instance bytes are under 5% of eligible
   evaluations, from 65 to 97% today.
5. The first iterate, per model on `sim_reads`.
6. The cheap hit. Done when a hit costs under a fifth of an evaluation,
   measured per model.

## C5 Solve and update at lane scale

**Verdict: rejected, code deleted.** Three forms were built behind `c5`
(a supernode solve on C1's panels, the solve on subtree lanes, the solve
on host threads) and each lost the solve phase on every deck measured, by
1.1x to 4.2x ([13-implementation.md](13-implementation.md#wave-3-binary-c1-and-c5-by-phase)).
The reason is arithmetic: a solve with one right-hand side moves about 12
bytes per multiply-add against 8 for a dense panel, so a factor that is
entirely panels gains at most 1.5x and the measured factors, half to two
thirds in panels, about 1.2x before the gather, the scatter and the second
copy of L are paid; at 8 lanes, starting and joining the lanes costs about
as much as the solve. A solve with several right-hand sides on one factor
would be a different lever. The text below is the proposal as researched.

**Class:** exact. **Files:** `src/solver/sparse_lu.zig` (`solve`),
`src/solver/kernels/lu.zig` (`lhead`, `uhead`, `lpanel`, `upanel`),
`src/solver/subtree.zig`, `src/solver/converger.zig` (`finalizeStep`).

**Today.** The triangular solves run on one thread on every deck: 5 to 15%
of Newton time at 8 lanes, about 1 ns per stored entry (`logic_bsim4_10k`:
1.72 ms for 1.71 M entries, 12 GB/s of values and indices). The update
phase (limiting, state updates, the convergence tests) scales 2 to 3x at 8
lanes and not at all on `logic_bsim4_1k`.

**Headroom.** With eval at 4.0 to 4.8x and the solve at 1.0x, the solve's
share doubles under lanes. Apply C1 at 3x and C2 at its measured rate to
`logic_bsim4_10k` and the 1.9 s of solves become the second largest phase
of a 12 s loop.

**Change.**

1. *Supernode solve.* With C1's row order, a supernode's forward step is a
   dense block times a vector into contiguous values: no index per entry,
   vector wide. Same operations per row in the same order.
2. *Threads.* The kernel body already has both solves scheduled for threads
   (level-scheduled head, panelled tail, `runHost`); `direct` uses only the
   refactor. Wire the solves for factors the threaded refactor admits, and
   a subtree-lane solve (forward over the subtrees, back in reverse) for
   the thin ones. Each row's sum keeps its order.
3. *The update pass.* When an iteration cannot accept (the first, or an
   update over tolerance: `converger.zig:619` already marks exactly these
   with `evalFollows`), the limit pass and the next evaluation touch the
   same instances in the same order; run them as one lane dispatch. Time
   the futex wake after a long factor first (incidental finding 2 in
   [06-open-issues.md](06-open-issues.md#incidental-findings)).

**Oracle.** `SparseLu.solve`, bitwise, in a unit test on the post-layout
factors; the serial update pass for step 3 (raws byte-identical).

**Gate.** Corpus raws byte-identical, 1 against 8 threads byte-identical.
Report solve and update milliseconds at 1 and 8 lanes on the eight decks.

**Steps.** In the order above; each is done when its gate passes and the
phase's 1-to-8 speedup is recorded. Step 1 waits for C1 step 3.

## C6 Lanes past eight, and what idle lanes burn

**Class:** exact. **Files:** `src/analysis/exec_config.zig`,
`src/analysis/executor.zig`, `src/analysis/par_eval.zig`. **Issue:** #253,
and `perf/pareval-idle` from #258.

**Today.** A query takes at most 8 lanes (`ThreadPool.per_query`,
`exec_config.zig:114`) on a machine with 8 P-cores and 16 E-cores. Waiting
lanes spin 4,096 pauses before they park (`par_eval.zig:545`).

**Measured.** 2.6 to 4.1 times the CPU-seconds for 2.1 to 3.1 times the
wall. `scaling_inverter_chain_4k` keeps 7.5 cores busy for a 2.2x wall
gain. `logic_bsim4_10k` burns 304 CPU-seconds, more than RSpice uses for
the same deck. `scaling_rc_ladder_100k` borrows 8 lanes for the LU and
runs no faster than on one thread (#253). Nothing past 8 lanes was
measured: the cap is a constant.

**Change.**

1. Return lanes nothing uses: borrow for the LU only what the per-epoch
   admission (`direct.zig:516`, the subtree plan) says it will use.
2. Park sooner. `perf/pareval-idle` parks after 256 pauses and measured
   `scaling_inverter_chain_4k` at 88.0 to 55.0 G cycles; finish and merge
   it.
3. Measure lanes past eight, with one constant changed: 16 on the P-cores'
   hyperthreads, then 24 with the E-cores, on the four BSIM4 10k decks.
   ParEval claims chunks dynamically (`chunks_per_lane = 8`,
   `par_eval.zig:537`), so a slow core takes fewer. If eval gains, make the
   cap a function of the machine and of the query's weight.

**Expected gain.** Unknown for step 3; it is one build and eight runs.
Evaluation is 39 to 52% of Newton time on the thin 10k decks, so doubling
its throughput is worth at most 1.25x to 1.35x there.

**Oracle and gate.** ParEval is bitwise the serial stamp at any lane
count: corpus raws byte-identical at 1, 8 and the new count. Wall and
CPU-seconds per deck, both reported.

## C7 One reduce pass that also forms A

**Class:** exact. **Files:** `src/analysis/par_eval.zig`,
`src/analysis/Circuit.zig` (`vals`), `src/analysis/tran/integrator.zig`
(`companionAt`). **Issue:** #251.

**Today.** ParEval writes each stamp to its own staging position, then
`sumCells` (`par_eval.zig:565`) sums every plane cell in tape order and
resets the positions. The load then sweeps the planes again on one thread
to form `A = G + ag0 * C` and the companion right-hand side. The load is 1
to 13% of Newton time (13% on `scaling_rc_ladder_100k`, 5 to 6% on the
thin 10k decks) and `ParEval.pass` is 33% of
`scaling_inverter_chain_4k`'s cycles in #258's profile, waiting included.

Measured since ([09-after-the-levers.md](09-after-the-levers.md#where-the-cycles-go)):
on `chain_bsim4_10k` at 8 lanes, 18% of all cycles sit on the sum-and-reset
line pair of `sumCells`, inside the phase the timing calls `eval`. The
lane that stamps a cell and the lane that reduces it are unrelated, so the
staging line changes cores. Step 2 below and
[N8](09-after-the-levers.md#n8-lane-affine-staging) answer it.

**Change.**

1. Form `A` and the companion term inside the reduce: when a lane has
   summed a cell of `G` and of `C`, it writes `g + ag0 * c` to `A` in the
   same pass. Each value is computed from the same operands by the same
   operations.
2. Measure before going further: the share of stamps whose plane cell
   receives every one of its contributions from a single task. Such a cell
   can be accumulated in place by that task in serial order, with no
   staging position.
3. Keep the staging cells of bypassed instances (C4 step 4) out of the
   reset.

**Expected gain.** Step 1 removes the serial load: up to its share. Steps
2 and 3 are unpriced until the census exists.

**Oracle.** The serial stamp and the serial load, bitwise, at 1, 4 and 32
workers (the existing test). **Gate.** Corpus raws byte-identical; 1
against 8 threads byte-identical; then #251 unifies this reduce with the
device's.

## C8 The operating point

**Class:** tolerance for the two changes that pay; exact for the
measurement. **Files:** `src/solver/sparse_lu.zig`,
`src/solver/order.zig`, `src/solver/direct.zig`, `src/analysis/dc/op.zig`.
**Issues:** #218, #261.

**Measured.** The operating point is 23%, 30% and 44% of wall on
`logic_bsim4_10k`, `chain_bsim4_10k` and `chain_psp103_10k`
([table](02-baseline.md#the-operating-point)). Two causes:

- *Fill.* The ordering assumes pivots on the diagonal. During the ladder,
  threshold pivoting leaves it, and a factor is accepted up to three times
  the diagonal fill (`fill_cap`, `sparse_lu.zig:269`).
  `logic_bsim4_10k` takes 20 pivot epochs whose flop counts run from 155.7
  M to 2,185 M, 16.2 G in the full factors alone. The transient that
  follows needs 155.7 M per refactor.
- *Failed rungs.* A rung that will not converge burns its whole budget.
  `logic_psp103_1k`: plain Newton fails after 100 iterations, then four
  gmin rungs fail after 100 each. 500 of the 616 operating-point
  iterations belong to attempts whose result is thrown away.

**Change.**

1. *Reorder on pivot drift.* When a full factor fills past a bound over
   the diagonal count (1.3x, to be fitted), compute a new fill-reducing
   order for the matrix with the chosen pivots on its diagonal, and factor
   again preferring that diagonal. One ordering costs a pattern pass; the
   factor it replaces costs up to 14 transient refactors. Weighted
   matching before ordering is the standard form of this (static pivoting
   in SuperLU_DIST and PARDISO).
2. *Stop a rung that cannot converge.* Exact form first: a rung whose
   iterate repeats bit for bit is in a cycle and will use its budget;
   stopping it at the repeat changes nothing downstream. Count how many
   failed rungs repeat before building more. The general form, a
   stagnation test, moves the ladder's path and is an owner decision.
3. *A parallel full factor.* The full factor is serial; the refactor after
   C1 is not. Out of scope until 1 and 2 are measured.

**Expected gain.** Step 1 on `logic_bsim4_10k`: if every epoch cost the
transient's 155.7 M, the 80 operating-point factors fall from 11.0 s to
about 2.3 s at 29 ms each, 9 s of a 50 s wall. Step 2 on the PSP103 decks:
at most 500 of 616 iterations, if every failed rung is a cycle.

**Why tolerance class.** A different elimination order changes the
factor's rounding, so an operating point reached through it differs in
its low bits, and the transient starts from it. Only decks whose ladder
leaves the diagonal move.

**Oracle.** The scaled LU residual for each factor; ngspice for the
operating points (the gmin-stepping decks #218 lists). **Gate.** The full
oracle corpus passes; moved decks named; operating-point time and
iteration count before and after on the five decks of the table and on
#218's `.op` copy of `chain_bsim4_100k`.

**Steps.**

1. Print per full factor: flops, fill, the share of columns pivoted off
   the diagonal. Done when the table in 02 is reproduced by
   `ZP_LU_STATS`.
2. Prototype the reorder on `logic_bsim4_10k`'s largest epoch offline.
   Done when its flop count under the new order is known.
3. Build it behind the fitted bound. Done when the gate passes.
4. Count bitwise-repeating iterates on failed rungs (`ZP_OPDBG`). Done
   when the count is known for the two PSP103 decks; build the exact stop
   only if it is most of them.

**Verdict on change 2 (2026-11-11): rejected.** The count is in: with the
watch on over the 958 corpus decks and the four 10k decks, six decks have
a failed solve at all and one repeats its host state; no failed PSP103
rung repeats, because its update swings by about 955 V without ever
landing on the same bits. A rung budget of `itl2` in place of ngspice's
floor of 100 was tried as the cheap stand-in and has both signs across
the two 10k chains. Both are deleted, and `c8` gates change 1 alone
([measured](13-implementation.md#wave-5-binary-c8-by-part)). What the
failed rungs need is a bound on the update, which is
[an owner decision](13-implementation.md#open-decision-a-bounded-newton-update-on-the-stepping-rungs).
