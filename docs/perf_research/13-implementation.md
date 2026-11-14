# Implementation status

What of the levers is in the tree, behind which bit of `ESPICE_PERF`
([11-lever-gate.md](11-lever-gate.md)), what each lever's test compares
against, and what was left out. Nothing here is merged: the work sits
uncommitted on `dev/performance`.

Implementation runs in waves. A wave is a set of work packages that touch
disjoint files, written in parallel and then compiled and tested together.
A later wave is more implementation, ordered by dependency: it needs an
earlier wave's code or its measurement.

## State of the checks

| Check | Result |
|---|---|
| `zig build check` (every test root, `-Dgpu=false`) | Green after wave 3 |
| `zig build test`, Debug, levers off, `--filter op/`, wave 1 | 433 of 433 steps; assembly probes pass; op decks 68 pass and 2 xfail |
| The same after wave 2 | Green on the fifth run (exit 0; op decks 68 pass and 2 xfail). The first run had 427 of 433 steps: eight allocation-failure tests crashed on one bug of the N6 census, and the #256 generator failed; runs two to four failed on that generator alone, four times for four different reasons (see [Found while implementing](#found-while-implementing)) |
| Corpus, Debug, exact levers on (`c1,c3,c6,c7,n3,n7,n8`), wave 1 | 907 pass, 5 xfail, 0 xpass; the 46 decks that load Verilog-A at run time pass from the ReleaseFast snapshot |
| Corpus, Debug, wave-2 tree, levers off (958 decks, the 46 that load Verilog-A at run time included) | 953 pass, 5 xfail, 0 fail |
| The same with the wave-2 exact set (`c1,c3,c5,c6,c7,n3,n7,n8`) | The same 953 and 5 by name: no deck moved |
| The same with `c4` alone, and with `c8` alone | No deck moved, each |
| The same with `c2` alone | 15 decks fail (ValueMismatch); see [C2 on the corpus](#c2-on-the-corpus). `all` fails the same 15 and no other |
| `zig build test`, Debug, levers off, `--filter op/`, wave 3 | Green on the second run (exit 0; 1257 tests, 10 skipped at the 18 skip sites `HEAD` has; op decks 68 pass and 2 xfail). The first run had one red test, the hand count of a bypass replay's writes: it assumed no unknown of `mos1` aliases when the series resistors are present, and the two branch flows always alias a port. The test now gives every unknown its own node |
| A lever test goes red on its bug | Wave 2: 39 of 39 named tests red under 38 patches. Wave 3: 61 red under 63 patches, 2 named tests green ([Red-first check](#red-first-check)) |
| Corpus, Debug, wave-3 tree, levers off | 953 pass, 5 xfail, 0 fail: the wave-2 list by name |
| The same with the exact set, with `c3` alone (stage 2 runs), with `c4` alone (14 C4-only models), with `c8` alone | No deck moved, each |
| The same with `c2` alone at `ESPICE_HELD_EPS=1e-3` | 10 decks fail, down from 15; `all` fails the same 10 and no other ([C2 on the corpus](#c2-on-the-corpus)) |
| `zig build check`, wave-4 tree (`-Dgpu=false`) | Green |
| `zig build check`, wave-5 tree (waves 4b, 4c and 5 in, C5 out) | Green on the second run. The first had two errors: a parameter of `lu_reorder.adopt` that shadowed an import, and a field count written against an older `@typeInfo` |
| `zig build test`, Debug, levers off, `--filter op/`, wave-5 tree | Green on the second run (exit 0; 1271 tests pass, 10 skipped at `HEAD`'s skip sites; op decks 68 pass and 2 xfail). The first run had one red test, the new ladder-budget test: its fixture read ground's row for the node's voltage. With the index fixed, its four hand counts (184 iterations lever-off; 177, 147 and 137 under `c8` at `itl2` of 50, 20 and 10) hold on the binary |
| Corpus, Debug, wave-5 tree, levers off | 953 pass, 5 xfail, 0 fail: the wave-3 list by name |
| The same with the exact set (`c1,c3,c6,c7,n1,n3,n6,n7,n8`), with `c8` alone (order per query, rung budget), with `c4` alone (backoff) | No deck moved, each |
| The same with `c2` alone at the default `held_eps = 1e-4` | 3 decks fail, down from 10 at `1e-3` on wave 3; `all` fails the same 3 and no other. Clean at `1e-6` ([C2 on the corpus](#c2-on-the-corpus)) |
| C2 | Rejected by the owner after that run; being deleted ([C2 on the corpus](#c2-on-the-corpus)) |
| `zig build check` and `zig build test`, Debug, levers off, `--filter op/`, wave-9 tree (`dv`, `c4h`, N1's running maximum, the GPU `uic` and hold rows, the host-stepped census, C2 deleted) | Green (exit 0; op decks 68 pass and 2 xfail) |
| `zig build check` and `zig build test`, Debug, levers off, `--filter op/`, wave-10 tree (the operating-point ladder, OPtran, gear 3..6, snapshot, HB samples and kinduc's LTE on GPU lanes, all behind held admit patches) | Green on the third run (exit 0; op decks 68 pass and 2 xfail). The first check failed on Zig 0.18's `std.EnumSet` (no `initEmpty`; `.empty`). The first unit run had one red test, the kinduc lane-LTE test's own precondition: its points were taken by step count, before the pulse rose, so the spans it zeroes held no flux. It now takes them by time |
| Corpus, Debug, wave-9 tree: levers off, the exact set (`c1,c3,c6,c7,n1,n3,n7,n8`), `c4` alone, `c8` alone, `all` | 953 pass, 5 xfail, 0 fail in each of the five: the wave-3 list by name, no deck moved. `all` was 3 failures on wave 5 only through `c2`. `all` also set `n2`, `n4`, `n9`, `g8` and `g9`, which nothing read, so it tested none of them; they were deleted on 2026-11-11 ([18](18-lever-verdicts.md)) |
| GPU-only code: `zig build check` with CUDA on and HIP off (wave-3 tree, in the default dev shell) | Green on the first run, 41 min: every device kernel went through `ptxas`, some at 10 to 11 GB of memory each |
| `zig build test`, Debug, CUDA compiled in, levers off, `-- --filter op/ --backend cuda --jobs 1` (wave-3 tree, RTX 4060 Laptop, 8 GB) | Green (exit 0): the op decks run on the device backend, 68 pass and 2 xfail, none skipped as ineligible. How many unit tests reached the device was not counted: the slowest test binary never loaded the driver library while it was sampled. The build wrote 60 GB of Debug binaries; they are deleted |
| G1, G2, G3, G7 on a device, with their levers on | Not run: needs the ReleaseFast GPU build and `espice calibrate` (`--backend auto` stays on the CPU without a calibration file, and says so) |
| ReleaseSafe gate (`zig build test`) | Not run |

## Wave 1

| Lever | In | Where | Test and oracle | Left out |
|---|---|---|---|---|
| C1 | Panels in the serial replay and in the subtree lanes | `solver/lu_runs.zig`, `lu_replay.zig`, `sparse_lu.zig`, `subtree.zig` | The column loop (`refactorColumns`), bitwise | Panel rows readable in place (a per-refactor copy stands in); the threaded kernel body, so **a thick factor at 2 or more threads is unchanged** until wave 2; stage 2 tiles |
| C2 | Stage 1: accept on the held factor inside a margin | `solver/confirm.zig`, `converger.zig` | Five cases against the full confirming iteration; counters for held accepts, misses and wrong accepts | Stage 2 (values-only evaluation); the guard census, so `held_margin` and `held_guard` are provisional |
| C3 | Stage 1: a linear circuit skips the confirming factor | `solver/confirm.zig`, `analysis/Circuit.zig` (`linear`) | The two-iteration path, bitwise | Stage 2; an ill-conditioned linear deck with an analytic oracle |
| C4 | Windowed review with backoff; static solves not counted; first-iterate replay for models that do not read the iteration | `device/batch_bypass.zig` | The plain evaluation at both points; `f0 + G0 (x1 - x0)` per row (#256), on mos1 tied and untied and on the diode | The key ([finding 25](06-open-issues.md#incidental-findings)); the cheap hit in the reduce; census counters |
| C6 | Steps 2 and 3: park after 256 pauses; per-query cap 16 | `analysis/par_eval.zig`, `par_lanes.zig`, `exec_config.zig` | The serial stamp, bitwise, at 1, 2, 3 and 8 lanes | Step 1 (#253) |
| C7 | Step 1: the reduce forms `A = G + alpha C` | `analysis/par_eval.zig`, `Circuit.zig` | Serial `combineGC`, bitwise | The companion rhs in the reduce; steps 2 and 3 |
| N3 | Part 1 on the serial host path; part 2 (`rebase` narrowed) | `device/stamp.zig`, `batch.zig`, `analysis/circuit_devices.zig`, `tran/host_ops.zig` | Today's passes: `q_vec`, the LTE tape and every state, bitwise | The ParEval and GPU paths (it falls back there, so at 8 lanes the lever does nothing yet) |
| N7 | The Gear step bound's minimum in lanes | `tran/integrator.zig` | The index-order loop, bitwise | Ring rotation (no copy in it is a pure move); the waveform record; the `timing:` line |
| N8 | Lane-affine claims for stamp chunks and reduce blocks | `analysis/par_lanes.zig` | The serial stamp, bitwise, every pass twice | The reset skip; the limit and update walks |
| G1 | Stage 1 for AC: lane replays on the pool | `analysis/lane_fan.zig`, `executor_lanes.zig` | The serial loop, member order kept | The HB spectral Newton and `solveBatchSerial`, so `hb_2048` is unchanged |
| G2 | Part 1: publish before the growth test; early loads | `solver/kernels/lu.zig`, `lu_tables.zig` | `refactorColumns` and `solve`, bitwise, on host lane threads with a real barrier | The wide column's U part in shared memory; chunks |
| G3 | Step 1: the device LU waits for a pivot sequence that survived 16 refactors | `analysis/gpu/lu.zig` (`Hold`) | The host path | Needs a GPU run |
| G7 | Stage 1: the tail panel loads before its waits; one barrier per in-panel level | `solver/kernels/lu_tail.zig` | As G2 | Stages 2 and 3 |

Device ABI after wave 2 is 42 (41: `Hooks.track_charges`,
`Hooks.charges_clean`, `BypassTol.c4`; 42: `Hooks.census`,
`Hooks.census_counts`, `Hooks.stage_moved`, `BypassTol.stats`). Wave 3
takes 43; see there for the merge.

## Wave 2

| Work | Bit | In | Where | Test and oracle | Left out |
|---|---|---|---|---|---|
| Source runs in the threaded kernel body (#222) | `c1` on the host, `g2` on the device | A column takes each supernode run of its U list as one step: lane 0 does the run's triangle, every lane splits the rows below; two barriers per run | `solver/kernels/lu_steps.zig`, `lu_lever_tables.zig` | `refactorColumns` and `solve`, bitwise, on host lane threads | Destination chunks |
| Reorder when the operating point's pivots leave the diagonal (#218) | `c8` | After a full factor whose fill passes 1.3 times the diagonal-pivot fill: reorder with the chosen pivots on the diagonal and factor once more; kept only if fill does not grow. One statistics line per full factor | `solver/lu_reorder.zig` | A shuffled tridiagonal (n = 400): less fill after the reorder and a solve inside the residual bound | A deck from the corpus that takes the path |
| Ladder rungs in a cycle (#218) | `c8` | A counter of failed solves and of iterates that repeat. The stop itself needs three state hooks a system must offer | `solver/cycle.zig` | A system in an exact 2-cycle: the early stop leaves what the full budget leaves | `Circuit` does not offer the hooks, so nothing stops yet. **Rejected and deleted in wave 6**: [one corpus deck of 958 repeats](#wave-5-binary-c8-by-part) |
| Supernode triangular solve | `c5` | Forward and back substitution by panel, on C1's panel copy | `solver/lu_solve.zig` | `SparseLu.solve`, bitwise | After a threaded refactor it falls back; `solveT` |
| N3 with ParEval attached | `n3` | A clean verdict per chunk, combined by lane 0 | `analysis/par_eval.zig`, `device/batch.zig` (`stage_moved`) | Today's accept pass: charges, tape and states, bitwise | The GPU path |
| The companion rhs in the reduce | `c7` | The reduce adds the companion rows while it forms A | `analysis/par_eval.zig` | Serial `companionAt`, bitwise | Steps 2 and 3 |
| LU-only lanes returned (#253) | `c6` | Lanes the solver did not admit go back to the pool | `analysis/circuit_devices.zig` (`settleLaneLoan`) | None yet: a loan-arithmetic test is being written | |
| The #256 generator | none (a test) | Every model in `traits.bypass_models`, every tie, the lever off and on; a model that cannot bypass is a named marker | `device/tests/bypass.zig` | `f0 + G0 (x1 - x0)` per row | |
| The bypass census (#257) | none (`ZP_TRAN_STATS`) | `bypass-stats:` line | `device/batch_bypass.zig` | A hand count of a scripted run; the census changes no value | |
| BSIM4's path latches leave the key | `c4` | A field that reaches only charge values affinely is not compared | `device/traits.zig` (`charge_only`) | A commit that moves only such fields keeps its recording with the lever on and drops it with the lever off | PSP103 (its row never moves), MOS2 (not eligible) |
| HB spectral Newton and LSTB rounds on the pool (#260) | `g1` | The consume and host-solve steps and the host rounds fan out | `analysis/pss/mhb_gpu.zig`, `gpu/freq.zig` | The serial loop, member order kept | Needs a GPU run for the HB half |
| The N6 census | none (`ZP_TRAN_STATS`) | `latency-census:` line: instances whose charge and limit inputs did not move | `device/batch_census.zig` | Hand-counted cases, bit compare | |
| #254 | none | Nothing to write: the card lookup is on `main`; closed with the setup profile | | | |

### Red-first check

Each implementer wrote one bug per test as a patch against non-test source.
The patches are applied together in a scratch worktree and built once; a
lever test that stays green there is a hole.

Wave 2: 38 patches applied, 39 lever tests named by them, 39 red, each at
an assertion of the test itself. No named test stayed green. Three notes:

- One patch was withdrawn from the run. Turning `linear and` into `linear
  or` in `Circuit.freeze` trips the shipped assertion `if (linear)
  assert(!has_state_q)` and aborts unrelated tests, which is the assertion
  doing its job, but it leaves the test of the linear flag unproven. Its
  replacement drops only the constant-Jacobian and limiter terms and runs
  with wave 3.
- Several tests are named by two patches (the three C8 cycle tests, the
  first C3 test, the #256 generator). Each is proven able to fail; which
  patch it fails on alone is the second round's question.
- One shipped test also went red, `same deck, same bytes: run twice, any
  solver_threads, any device_threads`. One patch reverts the tied-terminal
  fix in `sink.zig`, which is on the shipped path, and that test is the
  fix's own regression test (its decks hold none of the C4-only models,
  so the other shipped-path patch cannot reach it).

Wave 3: 63 patches applied to a snapshot of the settled tree, 61 tests
red, each at its own assertion, and no shipped test red beside them. 12
patches were left out: one of each pair that names the same test, so that
this round shows the other patch alone (it did, for the C8 cycle tests and
the first C3 test); the two shipped-path patches of wave 2; the skipped
barrier, a data race; and one that no longer applies. The test of the linear
flag is among the 61. Two named tests stayed green, so each has a hole:

- `singleTaskCensus counts the stamps of cells one chunk fills`. The
  mutant puts a position on a chunk's first index into the chunk before
  it. In the hand-counted case one cell gains two single stamps and another
  loses two, so the count is 6 of 8 either way.
- The #256 generator on the three models without `u_kinds`. The mutant
  gives their potentials the current tolerance (`abstol` for `vntol`). The
  generator's moves are a share of `reltol |v| + vntol`, and the relative
  term covers them at every drawn voltage, so every case still replays.

Both went back to their owners with the arithmetic. One applied mutant is
equivalent and says so in its row (it sets `par_fresh` before the run, and
a failed run always passes a clear).

Left out by construction: a skipped barrier under C6 is a data race, so it
cannot go red on every run. C6's per-query cap of 16 had no test; it is now
a pure function, `ThreadPool.queryWant`, with one.

### C2 on the corpus

With `c2` on, at the wave-2 margin (`held_margin = 0.5`), 15 of 958 decks
leave their tolerance:

| Deck | First value out | Size |
|---|---|---|
| `hspice/temp_list`, `hspice/tnom_default` | `v(a)` at the operating point | 2.9e-5 relative |
| `variants/step_temp_source` | `v(b)` at the operating point | 2.8e-5 relative |
| `hspice/match_diode`, `hspice/meas_match` | AC and DC mismatch | 4.6e-5, 2.4e-5 relative |
| `hspice/noise_ac_sweep`, `noise/contributions` | one noise contribution | 1.8e-6 relative |
| `multi_analysis/bench_ngspice_rca3040` | `v(30)` in the transient | 0.36% |
| `tran/bench_ngspice_mosmem` | `i(vwb)` | 2.7% |
| `tran/bench_ngspice_schmitt`, `tran/device_mos1_large_signal` | a supply current near zero | 1.4e-11 A, 6.8e-11 A |
| `stress/scaling_parallel_inverters_100`, `_2000` | `i(vdd)` at the second point | 7.1e-9 A, 1.4e-7 A |
| `tran/bench_tline_ltra1_1_line`, `tran/bench_tline_txl1_1_line` | `i(vdd)` at the second point | 1.5e-10 A |

A held accept never publishes its own iterate: the published point is the
linearization point, as on the fresh path. The moves come from the iterate
the held update produces, which is normally discarded. It survives when a
later gate refuses the accept (it is then the next linearization point) and
through the limiters and device state, which run at it. The margin bounded
the size of that update, and a chord step that small can still sit a full
linear-rate factor away from the root, where a fresh Newton step leaves a
quadratic remainder.

The unit test "no wrong accept" could not see this, so the fix came with a
generator: 147 cubic, sine and diode runs whose fixture refuses the first
passing iterate, so that the held iterate is published, with the root by
bisection as the oracle. The criterion is now an error bound. With `s_h`
the held update and `s_prev` the previous update, both in units of the
Newton tolerance, the chord rate is `2 s_h / s_prev` (the factor 2 because
the previous step was a fresh Newton step, which converges quadratically),
and the distance left after the accept is `2 s_h² / (s_prev - 2 s_h)`. C2
accepts when that is under `held_eps` (default `1e-3`, about 1e-6 relative
at `reltol = 1e-3`) and declines after a limited iteration or a C3 zero
step, where no rate can be read. `held_eps` is the number a shipped option
would carry.

The corpus by `held_eps`, on the wave-3 tree:

| `ESPICE_HELD_EPS` | Decks out of tolerance |
|---|---|
| `1e-3` | 10: the four mismatch and noise decks, and six source currents at the second transient point (the two inverter stress decks, `bench_ngspice_schmitt`, `device_mos1_large_signal`, the two line decks) |
| `1e-4` | 2: `tran/bench_tline_ltra1_1_line` and `tran/bench_tline_txl1_1_line` |
| `1e-5`, `1e-6`, `1e-8` | 0 |

`temp_list`, `tnom_default`, `step_temp_source`, `bench_ngspice_rca3040`
and `bench_ngspice_mosmem` no longer move at any value. The bound does not
yet hold everywhere: the two line decks give the same `i(vdd)` at the
second point at `1e-3` and at `1e-4` (1.47e-10 A against -4.9e-12 A), 30
times the value, where the bound promises a thousandth of the row's Newton
tolerance. An accept that far from its estimate is not near the bound, so
the estimate is wrong at that point; the suspect is a held factor that
belongs to another matrix than the system (the first transient point after
the operating point, or a step change). That is back with the implementer.
Until it is closed, `1e-5` is the largest value the corpus passes, and what
C2 still saves there is the census's question.

Wave 4 replaced the rate read off two updates by a measurement: one step
of iterative refinement of the held update against the matrix in hand
(`t1 = J_h^-1 (J_k - J_h) dx_h`, the held update's first-order error, row
by row, whatever made the two matrices differ). On the wave-5 tree, at the
new default `held_eps = 1e-4`, 3 of 958 decks leave their tolerance, and
`all` fails the same 3:

| Deck | Value out | Expected | Got |
|---|---|---|---|
| `stress/scaling_parallel_inverters_100` | `i(vdd)` at the second point | -1.614e-10 A | -9.56e-11 A |
| `stress/scaling_parallel_inverters_2000` | the same | -3.228e-9 A | -1.912e-9 A |
| `tran/device_mos1_large_signal` | the same | 3.61e-12 A | 3.75e-11 A |

The three fail at `1e-4` and `1e-5` and pass at `1e-6` and `1e-8` (the
three decks alone were rerun at those values; the whole corpus at the
default only). The two line decks pass at the default now.

The estimate is not what fails. The Newton trace (`ZP_OPDBG`, lever off
against `c2`) shows the two runs parting in the operating point: on the
100-inverter deck its last iterate has an update of 5.7e-10 V lever-off
(3.2e-7 of the tolerance) and 2.8e-9 V on the held factor (1.6e-6 of it),
which is what the refinement said, and why `1e-6` declines. The next solve
is the first transient point, whose step is tiny, and the charge terms
carry `C (v - v_op) / dt`: both runs converge there with residuals near
1e-18, on supply currents 6.3e-11 A apart. An operating point off by
1.6e-6 of its tolerance becomes 60 times the current tolerance one solve
later. Lever-off passes because its last operating-point iterate is a full
Newton step, which lands orders below the tolerance.

So a held accept is unsafe wherever the next solve differentiates its
result over a much smaller step: the operating point and every other
static solve, and possibly the point before a breakpoint restart.

**Verdict: rejected by the owner (2026-11-11), and deleted.** In their
words: "remove this accuracy lever (I now dislike it), it should be
whatever spice support not this. 1e-6 is so far off". Three criteria in a
row needed a bound of their own, and the value the corpus accepts is a
millionth of the Newton tolerance, where little is left to accept: C2 gave
1.03 to 1.15 at its loosest criterion. The accuracy a user sets stays
SPICE's own option set. No rule for static solves is built; the code, the
`c2` bit, `ESPICE_HELD_EPS` and the C2 tests go, and C3 (linear circuits,
exact) stays. Stage 2, the values-only confirming evaluation, closes with
it.

## Wave 3

Censuses that decide the next stages, the stages that needed no number, and
placement. A census has no bit: it prints under an existing statistics
switch and changes no value, and each has a hand-counted test.

| Work | Bit | In | Where | Test and oracle | Left out |
|---|---|---|---|---|---|
| Tile and tail census (C1 stage 2, N1) | none (`ZP_LU_STATS`, `-Dlu-instrument`) | `lu-runs:` per full factor: the share of pairs in tiles of w = 2, 4, 8, the share inside trailing blocks of order 256, 512 and 1024, the last supernode's size | `solver/lu_runs_census.zig` | A 9-step factor written out in the test: 176 pairs, 78 and 52 and 0 in tiles, 5 and 55 and 176 in tails of order 3, 6, 9 | The tiles themselves |
| Subtree census of the full factor (N9) | none (same) | `lu-subtree-census:` the share of pairs below the cut of the 8-lane plan | `solver/lu_runs_census.zig` | The same factor: 0, 7, 155, 176 pairs below cuts 0, 2, 8, 9 | N9 itself |
| Chunk census (G2 stage B) | none (same) | Per epoch: chunks, the critical path with chunks as nodes beside the one with columns, chunk sizes overall and along the path, and the columns whose in-chunk sources come last in stored order against the fallback | `solver/kernels/lu_chunks.zig` | Hand-derived patterns | Stage B |
| The solve on subtree lanes (thin factors) | `c5` | Forward over the subtrees, back in reverse, each row's sum in its order. The forward half runs on lanes only when every L edge stays in a lane or crosses phases forward | `solver/subtree_solve.zig` | `SparseLu.solve`, bitwise | `solveT` |
| The solve on host threads (thick factors) | `c5` | The four solve kernels of the device body as four task rounds, on the factors the threaded refactor left | `solver/kernels/lu_host.zig` (`initOpts`, `solve`) | `SparseLu.solve`, bitwise: dense and circuit matrices, inline and on 4 threads, after a failed run, aliased | `solveT`; one round with barriers |
| Both solves behind `Solver` | `c5` | `direct.zig` takes the lane-scale solve only on factors its own last refactor produced, on 2 or more threads | `solver/direct.zig` | A second `Solver` with the lever off, bitwise, over nine steps that cross every invalidation; an `Io` wrapper in the test counts task launches, so the test cannot pass by always falling back | |
| C2 by an error bound | `c2`, `ESPICE_HELD_EPS` | See [C2 on the corpus](#c2-on-the-corpus); the census now tallies candidates by predicted-error decade | `solver/confirm.zig` | 147 nonlinear runs against a bisection root | The default, until the corpus sweep |
| C3 stage 2 | `c3` (only with `n3` off) | A linear circuit is accepted after the first iteration at the point, and with the iteration count, the two-iteration path gives. The trace of every consumer of the second iteration is in the implementer's report; one reads stale planes (N3's staged accept), so N3 on keeps stage 1 | `solver/confirm.zig` (`linearAccept`), `converger.zig` | The two-iteration path: x and x_old bitwise; evaluations, factor calls and solves 1, 1, 1 against 2, 2, 2 | With N3; under `-Dcertify`, INITFIX, a device flip |
| Single-task cell census (C7 step 2) | none (`ZP_TRAN_STATS`) | `pareval-census:` the share of stamps whose cell gets every contribution from one chunk | `analysis/par_lanes.zig`, `par_eval.zig` | A hand count, and a second count that walks the tapes another way at 1, 2, 3, 8 lanes | C7 steps 2 and 3 |
| C6's cap as a function | `c6` | `ThreadPool.queryWant` | `analysis/exec_config.zig` | Hand values | |
| Three models without `u_kinds` | `c4` | `juncap200`, `r2_cmc`, `vbic13_4t` join the C4-only set: a model with no branch-flow unknown has only potentials. No model is left that cannot bypass | `device/traits.zig`, `batch_bypass.zig` | The #256 generator | |
| The cost of a bypass hit | none (`ZP_TRAN_STATS`) | `replay_writes` and `charge_reads` on the `bypass-stats:` line | `device/batch_bypass.zig` | Cells a plain evaluation changes on planes filled with a signalling NaN | Fitting the cost |
| Limit-pass census (N6) | none (`ZP_TRAN_STATS`) | Instances whose `limit` inputs kept their bits since the last accepted point (`Hooks.census_accept`, device ABI 43) | `device/batch_census.zig`, `batch_state.zig` | Two hand-derived cases | The limiter's other input |
| Step bookkeeping as phases (N7) | none (`--timing-in-depth`) | `timing: tran step:` begin, charges, bound, ring, record | `analysis/tran` | Armed and unarmed waveforms bitwise; the phase sum fits inside the test's own timing of each call | A per-attempt split |
| Fans past eight threads | `g1` | A lane fan borrows up to 63 helpers, in chunks of 8 | `analysis/lane_fan.zig` | The serial loop, bitwise, at 1 to 64 threads; the pool's free count comes back whole | |
| The price as a pure function | `p1` | `price.place` decides CPU or GPU from the calibration file's model rows and the deck's census: no probe, no clock, no record of earlier runs. A batch without a row stays on the host; the audit records and does not demote; a stale file is refused by the name of the row that differs | `analysis/price.zig`, `machine.zig`, `machine_keys.zig`, `gpu/context_cost.zig` | `placement.tsv` by deck name against a hand-written fixture of this machine's numbers; the margin M = 3.3 is recomputed by the test; two decks are named `known` markers | The measured file; steps 2 and 4 to 7 |
| The device LU's rent-or-buy | `p1` | An epoch moves to the device when its age times the saving per refactor covers M times the table build (and the driver start if it is down), on the line through the two `lu` rows nearest its flops per unknown | `analysis/lu_price.zig`, `gpu/lu_admit.zig` | Hand arithmetic on fixture rows: rent, buy, the break-even age | Moves nothing until the build gives `lu_host_key` |
| `espice calibrate` | none (a subcommand) | Ported from `dev/integration` with step 1's corrections: the host LU timed through the solver's own entry at 1 and 8 lanes, bring-up kept out of the table time, linear devices, identity rows | `analysis/gpu/calibrate.zig`, `espice/calibrate.zig` | Round trip of the file; a refused file names its row | It has never run: it needs the card |

The device ABI is 43 in the working tree (`Hooks.census_accept`).
`dev/integration` took 41 for another hook, so a merge takes 44.

## Wave 4

What the wave-2 timings and the wave-3 corpus and mutation runs sent back.
Type-checked; not yet run.

| Work | Bit | In | Where | Test and oracle |
|---|---|---|---|---|
| C8 keeps an order only when it wins | `c8` | The reorder is a trial: it is kept when the new factor needs strictly fewer multiply-subtract pairs, else the old order is written back. After a kept reorder, once fewer than half the columns that pivoted off their row still do, the original order is tried again and wins ties. At most 4 drift reorders per solver and `log2 n + 1` returns after each. No clock, no lane count. One `lu-c8:` line per trial under the statistics switch | `solver/lu_reorder.zig` (`decide`), `direct.zig` | Keep: pairs fall and the scaled residual holds. Undo: pivots back on the diagonal end on the original order, bitwise the lever-off factor, refactor and solve from there |
| C2 by iterative refinement | `c2`, `ESPICE_HELD_EPS` (default now `1e-4`) | The held update is corrected once against the matrix in hand, `dx = dx_h - J_h^-1 (J_k - J_h) dx_h`, and the size of that correction, per row, is the error estimate. No history, so it holds whatever changed the matrix inside the solve: the iteration counter (a MOS model stamps no gate charge on the first iterate of the first transient point), a bypass replay, a limiter. Costs one more solve and one pass over the pattern per attempt | `solver/confirm.zig` (`refine`) | 720 first-step runs with a capacitor missing on the first iterate, a supply-current row, the root by bisection |
| C4's re-arm doubles its wait | `c4` | Each turn-off doubles the reviews before the next re-arm (64, 128, 256, ...), never reset | `device/batch_bypass.zig` | The waits by hand |
| The tolerance class of an unknown | none (a test) | At x = 0 a move of 1 nV on a potential replays and 1 nA on a flow misses, on a model without `u_kinds` and one with | `device/tests/bypass.zig` | Hand values; closes the hole mutation 08 showed |
| A position on a chunk's first index | none (a test) | One more hand-counted case in the single-task census test | `analysis/par_lanes.zig` | Hand count; closes the hole mutation 09 showed |

C8 went round twice more after the wave-3 binary was timed
([the C8 guard](#wave-3-binary-the-c8-guard)):

| Work | Bit | In | Where | Test and oracle |
|---|---|---|---|---|
| The judge sees the parallel shape (4b) | `c8` | A trial compares `pairs / 8 + span`: the pairs of the factor over a nominal 8 lanes, plus the heaviest path through its column graph weighted by pairs. Pure in the factor, so 1 lane and N lanes decide alike. Only losing trials count against the bound of 4. The `lu-c8:` line prints pairs, span, levels, the last supernode and the cost for both orders | `solver/lu_reorder.zig` (`shape`, `judge_lanes`) | Two hand-built factors of three pairs each, a chain and a star: the star costs less |
| The kept order travels with the query (4c, being written) | `c8` | A reset solver is a fresh one again. A circuit built from another's snapshot takes the order its dependency ended on and tries it once against the original on its first factor. A pooled workspace carries nothing, so 1 job and N jobs give the same bytes | `solver/direct.zig` (`keptOrder`, `adoptOrder`), `analysis/Circuit.zig`, `circuit_life.zig` | A reset solver against a fresh one, bitwise; an adopted order runs the one trial |

Wave 4b's first form kept the order across `Solver.reset`. Its author
showed why that cannot ship: the only caller of `reset` is a circuit
taking a workspace from the pool its Problem's queries share, so the
carried order would depend on which query last held that workspace.

## Wave 5

Each item's census passed its gate
([Wave 3 censuses](#wave-3-censuses)). Written, type-checked, and green
in the Debug unit tests with the levers off; the corpus, the red-first
check and the timings are next.

| Work | Bit | In | Where |
|---|---|---|---|
| N1, the tail of a thick factor on every lane | `n1` | The trailing block's columns leave the column-at-a-time schedule: each takes its sources outside the tail, then panel by panel the later columns take a finished panel's sources, shared over the lanes. A column whose tail sources do not come last and in panel order in its stored list stayed on today's path in wave 5; wave 8 runs each U position in the latest segment among its own source and those stored before it, still exact ([measured](#wave-6-binary-what-the-lu-levers-decide)) | `solver/kernels` |
| N6, exact form | `n6` | A charge-only pass keeps an instance's charges when everything they were computed from holds its bits: the unknowns it reads, its Instance bytes, the `SimState` fields the model declares it reads, and a counter every Model write bumps. That covers the re-read after the commit and the charge pass before the step bound. The accept pass only records, since it also moves device state. Two stages are out: the charge half of a Newton pass shares one model call with the residual, so skipping it saves nothing; and the limit pass cannot be proven unchanged, because the contract does not say which `SimState` fields `limit` reads and the iteration count moves on every pass. The limit stage would need that declaration from VerA; its ceiling is the census's unchanged share, 94% on the MOS1 chain and under 1% on every BSIM4 deck, so it is not requested yet. **Rejected and deleted in wave 6**: [1 to 2% up on MOS1, 1 to 2% down on BSIM4](09-after-the-levers.md#n6-latency-for-the-charge-and-limit-passes) | `device/batch_latency.zig`, `device/batch*.zig`, `analysis/tran/sim_init.zig`; `Hooks.set_latency` (ABI 44) |
| The step bound on lanes | `n7` | The states split into chunks, each chunk's minimum computed on a lane by the unchanged loop, the minima combined NaN first: the serial loop's bits. On with 2 or more lanes and at least 16,384 charge states. The 20 ns per state is five history streams and a chain of eight divisions, none of which can become a multiply without moving bits. At order 1 the promote probe repeats part of the first bound call; fusing the two changes every caller and the GPU side, so it is not done | `analysis/tran/bound_lanes.zig`, `tran/host_ops.zig`; `ParEval.each` |
| C1 admits a factor by its runs | `c1` | A factor takes the panels only when runs of at least `run_min` steps hold 0.7 of its pairs ([six measured shares](#wave-6-binary-what-the-lu-levers-decide): 85 to 98% and 24%; provisional until a deck lands between): decided once per pivot epoch, pure in the factor | `solver/lu_runs.zig` |
| The ladder's rung budget | `c8` | A stepping rung (gmin stepping, source stepping, the sources-off rung) gets `itl2` iterations, without ngspice's floor of 100, so the deck option sweeps the budget on one binary; `gminFactor`'s easy and hard thresholds are quarters of the same number. The plain rung, the clean solve, `.dc` sweep points and transient Newton keep their floored budgets. The back-up after a failed rung stays the fourth root: it is a step-size rule, and no measurement yet says it costs more than it saves at a small budget. At `itl2` of 2 or less no stepping solve can converge, and the ladder falls through to its last rung. **Swept, rejected and deleted in wave 6**: [no budget serves both chains](#wave-5-binary-c8-by-part) | `analysis/dc/op_ladder.zig`, `op_ladder_tests.zig` |
| **C5 is rejected and deleted** | (`c5` goes) | [Measured](#wave-3-binary-c1-and-c5-by-phase): every form loses its phase. Its authors' arithmetic agrees: a solve on host threads pays 28 task launches and about 2,000 cross-core hand-offs on `sram_bsim4_10k`, each as long as the level it carries; the supernode solve moves 8 bytes per multiply-add against the scalar solve's 12, a ceiling of 1.2 to 1.3 on a real factor before its gathers. A solve with several right-hand sides is another lever | `solver/lu_solve.zig`, `subtree_solve.zig`, `kernels/lu_host.zig` |

C4's break-even cannot come from counts alone. A hit pays when the hit
rate passes `(mu - 1) / (mu - rho)`, with `rho` the cost of a hit and `mu`
the cost of a miss, both in evaluations of that model, and never when
`rho >= 1`. Both are measured per model: three timed modes (plain, forced
hit, forced miss) on the #256 rig. They do not go in the calibration
file, which is per machine: two machines would then bypass differently
and publish different bits for one deck. If C4 is kept, they become a
comptime table beside `charge_only` in `traits.zig`, integers in 1/1024 of
an evaluation with their provenance in a comment, and the review's test
becomes `h * (M - R) < total * (M - 1024)`: exact integer arithmetic, so 1
lane and N lanes agree. A model with no row keeps one in five; a row with
`R >= 1024` never allocates a bypass (the count model expects that for
the diode). Until then the doubling only bounds the loss.

### Open decision: a bounded Newton update on the stepping rungs

Decided on 2026-11-11, in another form than this section proposed: a
per-node clamp as the deck option `dv`
([decisions](#decisions-of-2026-11-11)). The case for it stands as
written.

On `chain_psp103_10k` the operating point is 46% of the run, and its trace
([below](#wave-3-binary-where-the-time-is-with-the-exact-set-on)) shows why:
PSP103 has no limiter, so 154 of 611 iterations move some node by more
than 1 kV and 329 by 10 V to 1 kV on a 1.2 V circuit. Those updates carry
no information, but the rung at gmin 1e-4 passes through 5e8 V and still
converges, so a rule that stops a solve when it leaves a box would turn a
success into a failure.

The form its author would trust scales the update and never stops it: when
the largest node-voltage update exceeds a bound, the whole update is
scaled to the bound, which keeps the Newton direction, and the iteration
counts as limited, so it is never accepted. A published point is then
still one that a full Newton step passed, and the answer's definition does
not move. The bound would be a small multiple of the circuit's voltage
scale (the largest independent source), set only on the ladder's stepping
rungs, behind its own bit. Its gates: an infinite bound is today's ladder
bitwise; every deck that converges today still converges within its
tolerance; the KCL residual at the published point; a fixture with an
analytic root where the unscaled iteration diverges; and fewer
operating-point iterations on the four chain and logic decks.

It is not built. It changes which iterates a solve visits, so it is a
tolerance-class change to convergence behaviour, and whether to scale at
all, and by what multiple, is the owner's call.

Wave 5 adds two measurements to the case
([C8 by part](#wave-5-binary-c8-by-part)). No rung budget stands in for
the bound: 20, 50, 100 and 200 iterations each lose on one of the two 10k
chains. And the bound is a PSP103 matter only: `chain_bsim4_10k`'s plain
rung also starts with an update of 4e17 V, but it converges in 75 to 139
iterations where ngspice's native model takes 98, so its cost is the
chain's depth and not the start.

### Decisions of 2026-11-11

The owner handed five open calls back ("pick the better longterm
approach") and settled two of them directly.

| Call | Decision | What follows |
|---|---|---|
| The bound on the Newton update | Built as the deck option `dv`. Star-Hspice 1998, chapter 6: "DV=x: the maximum iteration-to-iteration voltage change for all circuit nodes in both DC and transient analysis ... CMOS circuits frequently require a value of about 1 volt for large digital circuits. Default=1000". The manual does not say whether it clamps per node or scales the update, nor how a limited iterate is judged; here it is a clamp per node voltage, an iteration that clamped is limited and never accepted, and absent means no bound and today's path bit for bit (HSPICE's default is 1000 V). No lever bit and no automatic value. The host Newton loop honours it on every path that goes through `converger`, the GPU's device evaluation and device LU included. The GPU lane kernels (sweep, Monte Carlo and parallel-transient lanes) run their own Newton on the card: their clamp is written (`Bodies.clampUpdate`, setting the limit word's veto bit; on the host instantiation every lane's iterates are bitwise `converger.newton`'s at W = 1), and a `dv` deck keeps those lanes on the host only until the GPU session has run it on the card, when the three refusals go. The shooting period's per-step Newton is being given the option. HB, MHB and the shooting outer Newton update harmonic or period unknowns and are outside it, as HSPICE defines `DV` for DC and transient; JFNK takes its own damped step, so a bounded solve runs the direct loop | A sweep of `dv` on the four 10k decks decides whether the simulator ever picks one itself for a model without limiters |
| C4 | The cheap hit is closed as unsound, and the first look had misread the replay share ([corrected](#wave-5-binary-c4-first-look)): the review keeps the bypass off for nine tenths of a run. One measurement with the review held on (`c4h`) decides | Keep if `c4,c4h` takes 10% off the eval phase of both BSIM4 1k decks with the corpus name list intact; else delete |
| FMA bodies of `exp`, `log`, `pow` | **The owner's:** both bodies stay, selected at comptime by the target's FMA class. FMA targets take 1.38x, 1.24x and 1.64x; `x86_64` and `x86_64_v2` keep today's body, bits and speed; no target is dropped | Value bits become one set per class, as the derivative lanes' already are. Being written in Gompute, uncommitted |
| The one-test `exp` | Not shipped alone: no gain on the FMA-free body, which stays byte for byte 2.0.1. The FMA body is written with the single test | |
| Nothing is CPU-only | **The owner's**, on seeing `dv` keep GPU lanes on the host: "lets not make anything cpu only, everything should be gpu as well." | A feature, option or lever lands with its GPU form and a host-instantiation test against the host loop, or with a written blocker. A host fallback is allowed only so that nothing is silently ignored, and it is tracked until it goes. `dv`'s lane-kernel clamp is being written; the inventory of every existing refusal and host-only path is being drawn up, to be worked down in the GPU session |
| Two math libraries ([finding 28](06-open-issues.md#incidental-findings)) | **The owner's:** no upstream request; VerA is going to consume `gompute.math` | `src/device/tests/math_agree.zig` is the gate until then and is deleted with `contract.gm`. The Gompute FMA release and the VerA release that consumes it must enter ESPice's pins together, or a fold and its run-time call differ on FMA targets |

## Later

Each needs a result or a measurement first: the small-matrix path
(#250, after an instruction count per call), N9 (after C8's verdict), N2
(rounding class, after N1), C7 steps 2 and 3 (after a
profile of the reduce with N8 on), the cheap bypass hit and C4's
break-even (after `espice calibrate` runs), G8, G9, the unified reduce
(#251), placement stages 4 to 6
(#249), LTRA (#252, after a profile of the convolution), and whatever
[12-math-and-contract.md](12-math-and-contract.md) ranks for Gompute's
math kernels and the VerA contract.

`n2`, `n4`, `n9`, `g8` and `g9` had bits with no code behind them; they
were deleted on 2026-11-11
([18-lever-verdicts.md](18-lever-verdicts.md)). A lever gets its bit with
its code. N4's work is Gompute's
([decisions](#decisions-of-2026-11-11)).

## Order of the remaining work

1. Validate wave 2: type-check, Debug unit tests with the levers off, a
   red run of each new test on its bug, the Debug corpus with the exact
   levers on and then with each tolerance lever alone, a ReleaseFast
   snapshot and its timings.
2. Wave 3: the censuses that decide the items under [Later](#later), the
   stages that need no number (the lane-scale solves of C5, C3 stage 2, the
   helper cap of G1), and placement steps 1 and 3 behind `p1`
   ([08-placement.md](08-placement.md)). Then the items themselves, each
   when its number is in.
3. One GPU session: the first compile of the GPU-only code, the device
   checks of G1, G2, G3 and G7, the GPU corpus, and the gates of #217,
   #220, #222, #224, #227, #228, #260 and #261.
4. A verdict per lever from the measured tables. An accepted exact lever
   becomes the only path and its bit is deleted. A rejected lever is
   deleted with its code. A tolerance lever becomes a named user option,
   and only when it decides on SPICE's own options: none ships with an
   accuracy number of its own (the owner's ruling on C2).
5. **The last step: no environment variable.** `ESPICE_PERF` goes, and so
   does every other variable the simulator reads to make a choice (27
   `ESPICE_*` and `ZP_*` names in `src/espice/config.zig` today). The
   simulator then makes every choice itself: CPU against GPU and every
   placement threshold from the price model and the one-time calibration
   file ([08-placement.md](08-placement.md)); whatever is genuinely the
   user's choice (a backend override, a tolerance opt-in, a diagnostic) is
   an option of the simulator. The operating system's path conventions
   (`HOME`, `XDG_CACHE_HOME`, `TMPDIR`) are not choices and stay.
6. The full ReleaseSafe `zig build test`, the changelog lines, and a pull
   request when the owner asks for one.

## Measured

### Wave 2, one ReleaseFast binary

One binary of the wave-2 tree, `--backend cpu`, on the machine and decks of
[02-baseline.md](02-baseline.md). "Off" is the wall time with no lever, the
least of the rounds; every other cell is that wall divided by the lever's,
so above 1 is faster. The exact set is `c1,c3,c5,c6,c7,n3,n7,n8`. Another
project's builds ran on the machine during the measurement: the rounds of
one cell differ by 4% at the median and 26% at the worst, so read a cell
within 0.05 of 1 as no change.

Every exact lever, alone and as a set, left the raw file byte-identical on
every deck, at 1 and at 8 lanes. `c4` moved the raw of every deck that has
a bypassed model, `c2` of seven decks; `c8` moved none of these.

8 lanes, 5 rounds:

| Deck | Off (s) | `c1` | `c5` | `c3` | `c6` | `c7` | `n3` | `n7` | `n8` | exact set | `c2` | `c4` | `c8` | `all` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `chain_bsim4_1k` | 0.61 | 0.99 | 1.01 | 1.01 | 1.07 | 1.03 | 1.06 | 1.01 | 1.04 | 1.10 | 1.03 | 1.02 | 1.01 | 1.13 |
| `logic_bsim4_1k` | 2.24 | 0.91 | 0.98 | 0.98 | 1.10 | 0.97 | 0.97 | 0.98 | 0.99 | 0.94 | 1.10 | 0.96 | 0.97 | 1.09 |
| `sram_bsim4_1k` | 0.85 | 0.94 | 0.99 | 1.01 | 1.19 | 1.03 | 1.04 | 1.01 | 1.04 | 1.10 | 1.10 | 1.17 | 1.01 | 1.27 |
| `chain_psp103_1k` | 0.97 | 0.98 | 0.97 | 0.98 | 1.03 | 1.04 | 1.03 | 0.98 | 1.01 | 1.09 | 1.03 | 1.00 | 0.99 | 1.13 |
| `logic_psp103_1k` | 3.98 | 0.97 | 1.02 | 1.01 | 1.17 | 1.00 | 0.99 | 1.00 | 1.01 | 1.03 | 1.07 | 1.01 | 1.00 | 1.15 |
| `scaling_inverter_chain_4k` | 3.23 | 0.99 | 1.00 | 0.99 | 1.02 | 1.02 | 0.98 | 1.00 | 1.00 | 1.05 | 0.99 | 1.00 | 0.98 | 1.05 |
| `bench_ngspice_mosamp` | 2.14 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.04 | 1.00 | 1.00 | 1.04 | 1.02 | 0.98 | 1.00 | 1.03 |
| `vacask_rc` | 0.40 | 1.00 | 1.00 | 1.00 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 0.98 | 0.98 |
| `vacask_graetz` | 1.60 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.11 | 1.00 | 1.00 | 1.11 | 1.06 | 0.86 | 0.99 | 0.88 |
| `scaling_rc_ladder_100k` | 1.31 | 1.01 | 0.99 | 1.00 | 1.02 | 1.00 | 1.06 | 1.01 | 1.01 | 1.07 | 1.01 | 1.00 | 0.99 | 1.04 |

1 lane, 3 rounds:

| Deck | Off (s) | `c1` | `c5` | `c3` | `c6` | `c7` | `n3` | `n7` | `n8` | exact set | `c2` | `c4` | `c8` | `all` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `chain_bsim4_1k` | 1.59 | 0.99 | 0.99 | 1.00 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 | 0.99 | 1.01 | 0.99 | 1.00 | 0.98 |
| `logic_bsim4_1k` | 4.54 | 1.14 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 0.99 | 0.99 | 1.11 | 1.08 | 0.99 | 0.99 | 1.18 |
| `sram_bsim4_1k` | 1.76 | 1.08 | 0.99 | 1.00 | 1.00 | 1.01 | 1.01 | 0.99 | 0.99 | 1.07 | 1.05 | 1.13 | 1.00 | 1.22 |
| `chain_psp103_1k` | 3.10 | 1.00 | 1.00 | 1.00 | 1.00 | 0.99 | 1.09 | 0.99 | 1.00 | 1.08 | 1.02 | 0.99 | 1.00 | 1.14 |
| `logic_psp103_1k` | 8.49 | 1.11 | 1.01 | 1.02 | 1.00 | 1.01 | 1.00 | 1.01 | 0.99 | 1.08 | 1.04 | 1.02 | 1.00 | 1.22 |
| `scaling_inverter_chain_4k` | 6.54 | 0.99 | 0.99 | 0.98 | 0.99 | 0.99 | 0.99 | 0.99 | 0.99 | 0.98 | 1.00 | 0.99 | 0.99 | 0.99 |
| `bench_ngspice_mosamp` | 2.20 | 1.01 | 1.00 | 1.01 | 1.01 | 1.00 | 1.02 | 1.00 | 1.01 | 1.05 | 1.04 | 1.00 | 1.03 | 1.05 |
| `vacask_rc` | 0.41 | 1.00 | 0.99 | 1.01 | 1.00 | 1.02 | 1.00 | 1.01 | 1.01 | 1.02 | 0.99 | 1.01 | 1.00 | 1.00 |
| `vacask_graetz` | 1.61 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 | 1.11 | 1.00 | 1.00 | 1.11 | 1.07 | 0.87 | 1.00 | 0.89 |
| `scaling_rc_ladder_100k` | 1.25 | 0.99 | 1.00 | 1.00 | 0.99 | 1.00 | 1.01 | 1.00 | 1.00 | 0.97 | 0.97 | 0.93 | 0.93 | 0.99 |

10k decks, 8 lanes, 2 rounds:

| Deck | Off (s) | `c1` | `c1,c5` | exact set | `c2` | `c4` | `all` |
|---|---|---|---|---|---|---|---|
| `chain_bsim4_10k` | 4.40 | 1.02 | 1.01 | 1.08 | 1.04 | 1.00 | 0.94 |
| `sram_bsim4_10k` | 17.93 | 1.17 | 1.12 | 1.36 | 1.15 | 1.22 | 1.68 |
| `chain_psp103_10k` | 9.48 | 1.00 | 0.98 | 1.03 | 1.01 | 1.01 | 0.92 |
| `logic_bsim4_10k` | 50.69 | 1.05 | 1.08 | 1.06 | 1.12 | 1.02 | 1.82 |

10k decks, 1 lane, 1 round:

| Deck | Off (s) | `c1` | `c1,c5` | exact set |
|---|---|---|---|---|
| `chain_bsim4_10k` | 9.76 | 0.91 | 0.98 | 0.96 |
| `sram_bsim4_10k` | 37.24 | 1.47 | 1.48 | 1.49 |

What the tables say:

- **C1** pays where the factor is thick: 1.47 on `sram_bsim4_10k` at one
  lane (instructions down 1.81 times), 1.08 to 1.14 on the 1k logic and
  SRAM decks at one lane. At 8 lanes the table shows a loss on those 1k
  decks (0.91 and 0.94, and the two sets that hold C1 agree). One round on
  the E-cores shows the other sign: the factor phase of `logic_bsim4_1k`
  falls from 2082 ms to 1973 ms with `c1`. So the 8-lane sign on a small
  thick factor is open, and the wave-3 binary settles it in a quiet
  window before C1 can be the only path.
- **C6** is the largest exact gain at 8 lanes on the 1k decks (1.10 to
  1.19 on logic and SRAM). **N3** gives 1.03 to 1.11 where charges matter
  (`vacask_graetz`, the PSP chain, the RC ladder). **C3, C5, C7, N7, N8**
  are inside the noise alone; C5's solves are wave 3.
- **The exact set** gives 1.03 to 1.11 on the 1k decks at 8 lanes (one
  loss, `logic_bsim4_1k` at 0.94, which is C1's), and 1.36 on
  `sram_bsim4_10k`.
- **C2** (the wave-2 criterion, margin 0.5) gives 1.03 to 1.15. Its new
  criterion is slower to accept, so these are an upper bound.
- **C4** gives 1.13 to 1.22 on the SRAM decks, nothing elsewhere, and
  loses on `vacask_graetz` (0.86): the shipped bypass turns itself off
  there after 72 evaluations, C4 re-arms it 1300 times and replays 41% of
  7.8 million evaluations of a diode whose evaluation is cheaper than the
  compare. The re-arm needs the break-even rate the wave-3 counters give.
- **C8** is the largest single effect and it has both signs. Measured
  apart (one round, E-cores, beside a build, so only the ratios count):

  | Deck | Exact set (s) | With `c8` (s) | Ratio |
  |---|---|---|---|
  | `logic_bsim4_10k` | 66.6 | 41.4 | 1.61 |
  | `sram_bsim4_10k` | 18.0 | 18.6 | 0.97 |
  | `chain_bsim4_10k` | 6.67 | 7.10 | 0.94 |
  | `chain_psp103_10k` | 13.3 | 17.7 | 0.75 |

  The factor phase of the transient, per refactor, and the factor's
  entries:

  | Deck | Entries, off | Entries, `c8` | Refactor, off (ms) | Refactor, `c8` (ms) |
  |---|---|---|---|---|
  | `logic_bsim4_10k` | 1,714,033 | 1,695,824 | 38.7 | 25.5 |
  | `sram_bsim4_10k` | 843,283 | 843,283 | 10.5 | 10.7 |
  | `chain_bsim4_10k` | 608,841 | 657,913 | 1.39 | 2.46 |
  | `chain_psp103_10k` | 680,581 | 744,799 | 1.93 | 2.94 |

  The reorder is kept without a check that it won: on both chains it
  leaves 8% to 9% more entries than it found. On the logic deck 1% fewer
  entries buy a third of the refactor time, so the entry count does not
  measure the win either; the pair count of the factor is the candidate.
  The operating point of the logic deck also gains: 15.5 s of full
  factors over 80 iterations against 4.3 s over 46. `all` inherits both
  signs: 1.82 on `logic_bsim4_10k`, 0.92 and 0.94 on the chains.

### Wave 3 binary: the C8 guard

The wave-3 ReleaseFast binary with wave 4's first guard (keep a reorder
only when the factor's pairs fall), exact set against exact set plus `c8`,
8 lanes on the E-cores, one round:

| Deck | Exact set (s) | With `c8` (s) | What happened |
|---|---|---|---|
| `chain_bsim4_10k` | 6.12 | 5.55 | Ends on the original order; the operating point's factor time falls from 1502 to 838 ms |
| `chain_psp103_10k` | 13.0 | 13.3 | Ends on the original order |
| `logic_bsim4_10k` | 72.0 | 60.2 | The operating point keeps its gain (17.5 s to 5.1 s). The transient runs on the original order: 44.0 s of factor time against 44.5 s |

The guard removes both losses and with them the transient gain of the
logic deck. Two causes, both measured:

- The kept order did not reach the transient. One trial restores (990.7M
  pairs against 1746.6M), the next keeps (668.1M against 325.7M), and no
  later line prints; the transient's first factor is the lever-off factor
  to the byte (155,737,938 pairs, 910 levels, a last supernode of 470
  columns). `Solver.reset` wrote the original order back between the two
  analyses.
- Pairs do not rank the two orders. The kept order's last factor has
  143.3M pairs, 870 levels and a last supernode of 59 columns. At 1 lane
  the two orders refactor in the same time (63.7 ms against 62.8 ms per
  refactor over 1111 refactors); at 8 lanes the kept order takes 25.5 ms
  against 38.7 ms. The gain is the shape the lanes see: the original
  order ends in a chain of 470 dense columns that runs serially.

Wave 4b and 4c answer both ([Wave 4](#wave-4)).

On `chain_bsim4_10k` the operating point makes 78 factor calls, 14 of them
full factors, and spends 1979 ms in them where a transient refactor costs
1.4 ms. The full factors alternate between pivots on the diagonal and 1 to
3% off it, and the pairs follow that share while the fill barely moves:

| Pivots off the diagonal | Pairs | Entries |
|---|---|---|
| 0.11% | 2,868,572 | 563,986 |
| 0.39% | 3,259,578 | 578,618 |
| 1.22% | 6,323,601 | 647,210 |
| 1.84% | 18,862,434 | 789,362 |
| 2.64% | 22,299,092 | 821,830 |
| 2.70% | 103,885,782 | 1,204,195 |
| 2.93% | 68,022,073 | 975,584 |

Fill is a weak sign of it: the 1.22% epoch has 1.15 times the entries of a
diagonal one, under the drift trigger of 1.3, and 2.2 times the pairs,
which every replay inside it pays.

### Wave 5 binary: C8 by part

`c8` gated three mechanisms: the reorder with its kept order, the cycle
watch, and the rung budget. The wave-5 ReleaseFast binary measures them
apart (8 lanes, cores 0 to 15, one round beside a build, so iteration
counts are exact and seconds are rough). The base set is
`c1,c3,c6,c7,n1,n3,n7,n8`.

**The reorder is the gain, and only on the thick deck.**

| Deck | Base (s) | With `c8` (s) | Operating point, iterations and factor time | Transient factor time (ms) | Raw |
|---|---|---|---|---|---|
| `logic_bsim4_10k` | 42.2 | 30.3 | 80, 9831 ms to 46, 3076 ms | 26,461 to 23,123 | differs |
| `sram_bsim4_10k` | 12.5 | 12.5 | 26 both | 8172 to 8185 | identical |
| `chain_psp103_10k` | 9.26 | 8.01 | 611 to 349 (the budget, below) | 952 to 973 | differs |
| `chain_bsim4_10k` | 3.98 | 6.92 | 78 to 349 (below) | 541 to 570 | differs |

On the logic deck plain Newton converges either way and the budget plays
no part (`itl2 = 100` under `c8` gives the same 46 iterations): a full
factor costs 67 ms against 123 ms, and a transient refactor 20.8 ms
against 23.8 ms.

**The rung budget has both signs, so it goes back to ngspice's floor.**
Under `c8` the deck's `itl2` is the budget of a stepping rung; lever-off
it is floored at 100:

| `itl2` under `c8` | `chain_psp103_10k`: iterations, failed rungs, wall (s) | `chain_bsim4_10k`: iterations, failed rungs, wall (s) |
|---|---|---|
| 20 | 229, 3, 7.25 | 440, 3, 8.24 |
| 50 (the default) | 349, 3, 8.01 | 349, 2, 6.98 |
| 100 | 611, 4, 9.70 (the lever-off ladder, iteration for iteration) | 236, 0, 6.37 |
| 200 | 1088, 4, 12.46 | 236, 0, 6.84 |

A failing PSP103 rung never converges: its update swings by about 955 V
on every iteration for the whole budget (not a bitwise cycle, so the
watch counts nothing), and a smaller budget only wastes less. A slow
BSIM4 rung converges between its 50th and 100th iteration, and cutting it
at 50 fails it and adds rungs. No constant serves both. The cause is the
unbounded update
([the open decision](#open-decision-a-bounded-newton-update-on-the-stepping-rungs)),
and a budget treats its symptom. `stepBudget` is deleted (wave 6).

**The cycle watch stops nothing.** `c8` alone over the 958 corpus decks:
6 decks have a failed solve at all, one
(`regression/mos1_bulk_forward_series_r.sp`, 10 of its 11 failed solves)
repeats its host state, and no solve is stopped, here or on the four 10k
decks. Building the three state hooks could help that one deck at most.
The watch is deleted (wave 6), and `c8` gates the reorder alone.

**`chain_bsim4_10k`'s operating point is a lottery, with or without
`c8`.** At the cold start every device is off, the first factor is close
to singular, and the first update is 4.0e17 V lever-off and 1.6e16 V
under `c8` (the trial reorder changes the pivots of that factor). From
there the path depends on the last bits of everything. Thirty runs each
with `gmin` moved inside ±1% of 1e-12:

| | Plain Newton fails | Iterations when it converges | Iterations when the ladder runs | Run (s): converged, ladder, all |
|---|---|---|---|---|
| Lever off | 11 of 30 | 75 to 100 | 227 to 247 | 4.27, 6.92, 5.24 |
| `c8` | 6 of 30 | 73 to 94 | 385 to 388 (236 at the floored budget) | 4.39, 8.24, 5.16 |

So the reorder does not make the plain rung fail more often, and the
3.98 s to 6.92 s of the table above is one draw: the deck's own `gmin`
lands on a lever-off success and a `c8` failure. Two consequences. A
before/after of any change that moves rounding on this deck must compare
the transient phases, or a sample of perturbed runs, never one wall
time. And the BSIM4 chain runs in 4.3 s or 6.9 s by chance.

The chance is the `itl1` edge, not a defect of the start. With
`itl1 = 300` each of the 11 lever-off failures converges on the plain
rung, after 103 to 139 iterations: plain Newton on this chain needs 75 to
139, the budget is 100, and a draw past it pays about 230 iterations of
ladder in place of 3 to 39 more. ngspice 44.2 with its native BSIM4,
which starts every MOSFET switched on (`MODEINITJCT`), takes 98 on the
same deck, so it sits on the same edge. Nothing in the engine is wrong
here: `itl1` is the user's option, and a deck that sets it to 200 never
draws.

### Wave 5 binary: C4, first look

Base set against base set plus `c4`, 8 lanes, one round beside a build;
the transient's evaluation phase and the bypass counters of the deck's
main model:

| Deck | Model | eval, base (ms) | eval, `c4` (ms) | Seen by the bypass | Replays (of seen) | Turned off, re-armed |
|---|---|---|---|---|---|---|
| `chain_bsim4_1k` | `bsim4va` | 162.0 | 159.1 | 127,000 | 37,797 (30%) | 5, 4 |
| `logic_bsim4_1k` | `bsim4va` | 343.9 | 349.9 | 118,156 | 59,841 (51%) | 6, 5 |
| `chain_psp103_1k` | `psp103` | 371.0 | 372.7 | 134,000 | 38,828 (29%) | 5, 5 |
| `vacask_graetz` | `diode` | 729.5 | 750.8 | 217,528 | 85,928 (40%) | 16, 15 |
| `bench_ngspice_mosamp` | `mos2` | 1292.4 | 1234.9 | 1,030,023 | 433,845 (42%) | 12, 12 |
| `scaling_inverter_chain_4k` | `mos1` | 1345.3 | 1366.4 | 41,600,000 | 29,869,911 (72%) | 0, 0 |

The phase does not move, and the reason is not the cost of a replay. The
counter `evals` holds only the evaluations made while the bypass was on.
`chain_bsim4_1k` runs 1078 iterations over 1000 instances, 1,078,000
evaluations, so its 37,797 replays are 3.5% of the run; on
`logic_bsim4_1k` they are 3.1% of 1,958,000. The review turns a batch off
when a window replays under one in five, and wave 4's doubling then keeps
it off for 64, 128, 256, 512 and 1024 reviews: after five turn-offs the
rest of a run of 1078 to 1958 solves is plain. (This page first read the
30% and 51% as shares of the run and concluded that a replay costs an
evaluation. C4's author corrected it.)

What a replay costs, from instruction counts and not yet from a clock:
about 2,600 instructions against 11,446 for the dual evaluation of
`bsim4va`, 0.23 of one, of which 2,000 are the charge core; a miss adds
about 0.06. On those numbers the bypass breaks even near one hit in
fourteen, and a batch that replays 30 to 51% of what it sees would take
19 to 36% off the device evaluation if it stayed on.

The cheap hit is closed: replaying the charge as `q0 + C0 dx` leaves an
error of half the second derivative times `dx` squared, which no deck
option bounds and the integrator multiplies by `2/dt` (about 5e-10 A
against `abstol` 1e-12 on this deck). It is the C2 failure again, and it
would save 0.5% of the evaluation.

So one measurement is left. The bit `c4h` holds the review on for a whole
run, and `bypass-stats:` gains the evaluations made while off and the
windows under one in five and one in fourteen. C4 stays if `c4,c4h` takes
at least 10% off the eval phase of both BSIM4 1k decks with the corpus
name list intact; otherwise it is deleted.

### Wave 6 binary: what the LU levers decide

The instrumented wave-6 binary (`-Dlu-instrument=true`), base set
`c1,c3,c6,c7,n1,n3,n7,n8`, with and without `c8`; the last factor of the
transient. Its factor times carry the instrumentation and are for
comparing rows only.

| Deck | Order | N1 at T = 256 | C1 run share | Transient factor |
|---|---|---|---|---|
| `logic_bsim4_10k` | original | admitted: 61.5M pairs, none on the fallback | 98.0%, admitted | 28.27 s over 1111 |
| `logic_bsim4_10k` | `c8`'s kept order | declined: 16 columns hold 4.1M of 57.3M pairs | 97.4%, admitted | 23.96 s over 1111 |
| `sram_bsim4_10k` | either | declined at every T (256: 6.65M of 11.72M pairs in 98 columns; 4096: 39.92M of 39.98M) | 95.0%, admitted | 8.73 s over 1101 |
| `chain_bsim4_10k` | original | not built: the steady factor is under `parWorthIt` | 23.6%, declined | 0.934 s over 548 |
| `chain_bsim4_10k` | `c8` | same | 52.1% inside the operating point, admitted; the transient ends on the original order | 0.970 s over 548 |
| `chain_psp103_10k` | either | declined | 23.7%, declined | 1.758 s over 771 (`c8`: 1.784) |
| `logic_bsim4_1k` | original | declined | 86.7%, admitted | 1.544 s over 1958 |
| `sram_bsim4_1k` | original | declined | 85.5%, admitted | 0.414 s over 1088 |

Three things follow.

**N1 ran on one deck and one order.** On the uninstrumented binary it
takes `logic_bsim4_10k`'s refactor from 27.0 to 23.8 ms, but `c8`'s kept
order is faster still (20.8 ms) and there N1 declined: a column's U list
is stored in reverse depth-first finish order, not in step order, so after
a reordering a tail source can sit before an outside one, and wave 5 sent
such a column to the old path whole. `sram_bsim4_10k`, whose refactor is
8.2 s of a 12.5 s run, declined for the same reason at every tail size.
Wave 8 replaces the fallback with an exact form: each U position runs in
the latest segment among its own source and every source stored before
it. Stored order holds per slot, so the bits are the column loop's, and
the admission prices the chain those late pairs lengthen instead of
refusing the column. The `lu-tile:` line now prints `late=` and
`late_cols=`.

**C1's admission share is 0.7.** The decks fall in two groups, 85 to 98%
and 24%, and the one case between them (52.1%, the chain's operating
point on `c8`'s order) shows no gain. The code gives no break-even: that
needs the run pairs per panel L entry, which the share does not carry.
0.7 is provisional until a deck lands inside the gap.

**`c8`'s judge ranks the orders the way the run does.** `logic_bsim4_10k`
loses its first trial (990.7M pairs against 1746.6M, restored), wins the
second (668.1M to 325.7M) and keeps the order through the pooled reset
(cost 136.7M against 150.9M); both chains end on the original order.
`drift_bound`, `reorder_max` and `trial_cap` are not bound by any of these
lines and stay provisional.

**Wave 9: the running maximum admits both decks N1 had declined.** The
instrumented wave-9 binary, same set, one run each beside a build (so the
factor times below compare nothing), last factor of the transient:

| Deck | Order | N1 at T = 256 | Wave 6 at T = 256 | C1 run share |
|---|---|---|---|---|
| `logic_bsim4_10k` | `c8`'s kept order | admitted: 16 of 57.27M pairs late, in 16 columns; chain 1.40M | declined: 16 columns held 4.1M | 97.4%, admitted |
| `sram_bsim4_10k` | original | admitted: 3.28M of 11.72M pairs late, in 98 columns; chain 0.61M. Declined at T = 512 and up, by price | declined at every T | 95.0%, admitted |
| `chain_bsim4_10k` | original | the steady factor is still under `parWorthIt`; ladder factors admitted | same | 23.6%, declined |

A late pair costs only its place in the chain, not the column: the 16
columns that sent 4.1M pairs to the old path now move 16. Whether the
admitted tile pays on these two decks is a timing question
(`time-w10.sh big8` pairs `c1,c3,c6,c7,n3,n7,n8` with and without `n1`,
with and without `c8`), not a count.

`chain_bsim4_10k`'s one admitted N1 line belongs to a thick factor of the
ladder (fill 4.0, 33.4M pairs) that lives for a few refactors; the steady
factor (fill 2.6, 2.87M pairs) is below `parWorthIt` and never builds the
tile. `pairs=` on the `lu-tile:` line counts pairs by destination column
in the tail; `tail_T` on the `lu-runs:` line counts them by source.

### Wave 3 binary: C1 and C5 by phase

The wave-3 ReleaseFast binary, one round on the E-cores beside a build, so
only differences well past 10% count. Times are the transient's `factor`
and `solve` phases in ms.

Factor phase, no lever against `c1`:

| Deck | 8 lanes, off | 8 lanes, `c1` | Ratio | 1 lane, off | 1 lane, `c1` | Ratio |
|---|---|---|---|---|---|---|
| `sram_bsim4_10k` | 26,380 | 12,481 | 2.11 | | | |
| `logic_bsim4_1k` | 2719 | 1963 | 1.39 | 2893 | 2500 | 1.16 |
| `logic_psp103_1k` | 3241 | 2444 | 1.33 | | | |
| `sram_bsim4_1k` | 709 | 558 | 1.27 | 664 | 603 | 1.10 |
| `chain_bsim4_1k` | 182 | 188 | 0.97 | 361 | 382 | 0.95 |
| `chain_bsim4_10k` | 857 | 904 | 0.95 | | | |

Solve phase, no lever against `c5` (with `c1` at 1 lane, since the
supernode solve reads C1's panels and falls back without them):

| Deck | 8 lanes, off | 8 lanes, `c5` | Ratio | 1 lane, off | 1 lane, `c1,c5` | Ratio |
|---|---|---|---|---|---|---|
| `sram_bsim4_10k` | 1053 | 2168 | 0.49 | | | |
| `logic_bsim4_1k` | 205 | 675 | 0.30 | 193 | 259 | 0.75 |
| `logic_psp103_1k` | 265 | 956 | 0.28 | | | |
| `sram_bsim4_1k` | 46 | 196 | 0.23 | 44 | 60 | 0.74 |
| `chain_bsim4_1k` | 73 | 69 | 1.06 | 70 | 85 | 0.82 |
| `chain_bsim4_10k` | 428 | 490 | 0.87 | | | |

- **C1 wins the factor phase on every thick factor**, more at 8 lanes than
  at 1 (the threaded kernel takes a run in two barriers where it took one
  per column). The loss the wave-2 table shows at 8 lanes on the P-cores
  is not here; a quiet run on the P-cores still has to say whether it was
  noise. On the thin chains C1 costs about 5% of the factor phase at
  either lane count: the panel copy is paid and the runs are short. C1
  needs a rule that leaves a factor without long runs on the column loop.
- **C5 loses the solve phase in each of its three forms**: the solve on
  host threads is 2 to 4 times slower than the serial solve on thick
  factors, the supernode solve at one lane is 1.2 to 1.35 times slower,
  and the subtree-lane solve is slower on the 10k chain. A serial solve
  here is 0.1 to 1 ms; the factor of `sram_bsim4_10k` has 1034 levels, so
  one barrier per level costs what the solve does. The solve is 4 to 12%
  of the Newton time, so a form that won by 2 would move a deck by 2 to
  6%. C5 is a rejection as measured; its owners get the numbers once
  before the code goes.

### Wave 3 binary: where the time is with the exact set on

The instrumented binary, exact set, 8 lanes: each phase as a share of the
timed phases of the operating point and the transient together. The solve
column carries C5's loss.

| Deck | Timed (s) | Operating point | eval | factor | solve | update | begin | bound | ring |
|---|---|---|---|---|---|---|---|---|---|
| `sram_bsim4_10k` | 22.1 | 3% | 10% | 67% | 11% | 3% | 1% | 3% | 2% |
| `chain_psp103_10k` | 17.2 | 46% | 16% | 21% | 5% | 5% | 1% | 6% | 0% |
| `logic_psp103_1k` | 7.7 | 21% | 10% | 45% | 13% | 6% | 2% | 4% | 0% |
| `chain_bsim4_10k` | 7.7 | 31% | 17% | 24% | 7% | 5% | 2% | 8% | 4% |
| `scaling_inverter_chain_4k` | 5.2 | 8% | 28% | 19% | 5% | 13% | 3% | 11% | 11% |
| `logic_bsim4_1k` | 4.9 | 4% | 9% | 54% | 16% | 7% | 3% | 3% | 4% |
| `scaling_rc_ladder_100k` | 3.7 | 1% | 40% | 9% | 9% | 8% | 2% | 14% | 2% |
| `sram_bsim4_1k` | 1.5 | 3% | 15% | 46% | 16% | 8% | 3% | 5% | 4% |
| `chain_bsim4_1k` | 1.0 | 9% | 19% | 32% | 8% | 11% | 2% | 12% | 6% |

The refactor leads on every thick deck (N1, C8). The operating point is a
third to a half of the 10k chains. The step bound and the charge re-read
are a tenth each where the factor is thin (wave 5).

The operating point of `chain_psp103_10k`, from `ZP_OPDBG`: 611 iterations.
Plain Newton fails at its fourth (the update is 5.2e14 V at the second
iterate and 1.9e18 V at the third, then the matrix holds NaN). The gmin
ladder then runs 27 rungs: four fail after 100 iterations each, four
converge after 18 to 44, and nineteen after 2 to 8. So 400 iterations
belong to rungs whose result is thrown away, as
[C8's brief](04-levers-cpu.md#c8-the-operating-point) counted on
`logic_psp103_1k`. Inside the failed and the slow rungs the update has no
bound: 154 iterations move some unknown by more than 1 kV and 329 by 10 V
to 1 kV, on a 1.2 V circuit whose model has no limiter. The rung at
`gmin = 1e-4` visits 5e8 V and still converges at its 39th iteration, so
leaving a box is not a safe reason to stop one.

The budget of 100 is ngspice's (`NIiter` raises `itl2` to 100). Wave 5
put the rung budget on `itl2` itself under `c8`, so the deck option
swept it on one binary;
[the sweep](#wave-5-binary-c8-by-part) found no budget that serves both
chains, and the floor stays. A bound on the update for models without a
limiter is an owner decision and is not built.

### Wave 3 censuses

The instrumented wave-3 binary (`-Dlu-instrument`), exact set on, 8 lanes;
the LU rows describe the transient's factor.

| Deck | n | Pairs | Pairs with their source in the last 256 / 512 / 1024 steps | Pairs below the 8-lane cut | Levels | Full factors in the run |
|---|---|---|---|---|---|---|
| `logic_bsim4_10k` | 38,619 | 155.7M | 3.6 / 26.4 / 71.0% | 19.5% | 910 | 20 |
| `sram_bsim4_10k` | 17,053 | 40.1M | 8.6 / 22.1 / 49.5% | 75.1% | 1034 | 2 |
| `chain_bsim4_10k` | 44,925 | 2.87M | 7.7 / 16.0 / 24.4% | 61.6% | 653 | 14 |
| `chain_psp103_10k` | 54,925 | 3.0M | 8.1 / 16.6 / 24.8% | 70.8% | 602 | 22 |
| `logic_bsim4_1k` | 3,967 | 1.77M | 51.1 / 87.0 / 97.5% | 35.5% | 295 | 5 |
| `sram_bsim4_1k` | 1,741 | 0.78M | 79.0 / 96.6 / 99.3% | no plan | 218 | 2 |
| `logic_psp103_1k` | 5,051 | 1.64M | 47.8 / 85.6 / 96.6% | 47.8% | 302 | 2 |
| `chain_bsim4_1k` | 4,521 | 0.24M | 17.9 / 34.1 / 63.2% | 73.0% | 219 | 5 |

What each census decides:

- **N1: build.** The gate was 60% of the pairs inside the tail.
  `logic_bsim4_10k` has 71% in the last 1024 steps and only 19.5% below
  the cut, and its refactor gets 1.6 times from 8 lanes (63.7 ms to
  39.6 ms). The 1k logic and SRAM decks pass at 512 steps, but their whole
  tail is 1.5M pairs, the work of a dense factor of order 170: the task
  asks for the arithmetic of pairs per lane per panel against a barrier
  before any of it is tiled. The chains do not pass (24%), and
  `sram_bsim4_10k` (49.5%) already has 75% below the cut.
- **C1 stage 2 (tiles): closed.** The census found no pair in a tile of 2,
  4 or 8 columns on any deck. A tile that stays bitwise needs adjacent
  columns whose source lists agree in stored order; the factor stores a
  column's sources in the order its reach was searched, which differs
  between neighbours even when the sets agree. The tile columns leave the
  census line.
- **N9: not now.** A full factor has 19.5% of its pairs below the cut on
  the deck whose operating point is slow (`logic_bsim4_10k`: 20 full
  factors, 17.5 s), and what makes those factors slow is their pair count
  under off-diagonal pivots, which C8 changes (17.5 s to 5.1 s). Read the
  census again on what C8 leaves.
- **C7 step 2: unpriced still.** The share of stamps whose cell is fed by
  one chunk is 34% of slot stamps on `logic_bsim4_1k`, 50% on
  `sram_bsim4_10k`, 30% on `chain_psp103_10k` and 26% on
  `scaling_inverter_chain_4k` (rows: 4%, 26%, 3%, 0%). The term it would
  shorten is the reduce's line pair, and N8, which targets the same pair,
  measured 1.00 to 1.04. It waits for a profile of the reduce with N8 on;
  the release binary has no symbols, so that needs a `-Ddebug-info` build.
- **N6: build the exact form.** At 1 lane with no lever (the census
  counts serial host passes only), the share of passes whose inputs hold
  their bits:

  | Deck | Model | Charge pass | Limit pass |
  |---|---|---|---|
  | `scaling_inverter_chain_4k` | mos1 | 94.9% | 93.6% |
  | `bench_ngspice_mosamp` | mos2 | 60.2% | 21.9% |
  | `logic_bsim4_1k` | bsim4va | 44.2% | 0.02% |
  | `sram_bsim4_1k` | bsim4va | 49.4% | 0.2% |
  | `chain_bsim4_1k` | bsim4va | 49.6% | 0% |
  | `chain_psp103_1k` | psp103 | 25.7% | no limiter |
  | `vacask_graetz` | diode | 33.3% | 0% |

  The diode's exact third fits one pass per step repeating the point of
  the pass before it (two iterations, then the accept pass, which N3
  removes); that reading is not checked against the code. What lies above
  one repeat per step is latency: nearly everything on the MOS1 chain,
  about a fifth of the passes on BSIM4, nothing on PSP103. The limit pass
  is latent only on MOS1 and MOS2.
- **The step outside Newton, by phase** (`timing: tran step:`, ms):

  | Deck, lanes | Newton phases | begin | charges | bound | ring | Share of the step phases |
  |---|---|---|---|---|---|---|
  | `scaling_inverter_chain_4k`, 8 | 3387 | 129 | 80 | 581 | 570 | 29% |
  | `chain_psp103_10k`, 8 | 8054 | 107 | 86 | 960 | 76 | 13% |
  | `logic_bsim4_1k`, 8 | 4217 | 132 | 18 | 168 | 170 | 10% |
  | `sram_bsim4_10k`, 8 | 19929 | 189 | 118 | 754 | 496 | 7% |

  `bound` costs 17 to 21 ns per charge state per attempt on every deck,
  the same at 1 and at 8 lanes and with `n7` on or off: it is serial and
  N7's lane minimum does not touch its cost. `ring` is a whole charge
  pass per accepted step for a model with a charge and a state hook (98
  ns per MOS1 instance, 448 ns per BSIM4 instance at 1 lane, 5 ms in all
  for PSP103, which has no state hook): N3's narrowing of the re-read
  does not reach those models, and N6's exact form is what does.
- **The cost of a bypass hit.** A replay writes 87 cells per BSIM4
  instance, 89 per PSP103 and 36 per MOS1, and re-reads the charge every
  time. With `c4` off the shipped bypass reviews itself once: on the BSIM4
  decks it turns off for the rest of the run after its first window (55
  passes on `logic_bsim4_1k`, 34% hits), and it stays on for PSP103 at 14%
  hits (`chain_psp103_10k`; 62% of its evaluations miss on tolerance) and
  for MOS1 at 72%. Whether 14% pays is the break-even
  [Wave 4](#wave-4) leaves to the calibration.

## Found while implementing

- A thick factor at two or more threads runs through `HostRefactor`, which
  is the device kernel body on host threads. C1's panels are not in it, so
  C1's gain on the thick decks shows at one thread only until wave 2.
- N7: no vector copy in the step is a pure move, so ring rotation saves
  nothing as specified.
- C3 with a device LU skips the device call at the first iteration; that
  path is unchecked without a GPU.
- BSIM4's bypass misses cannot be removed by a read-set key
  ([finding 25](06-open-issues.md#incidental-findings)).
- The corpus runner's metamorphic compare is quadratic in the column count
  ([finding 26](06-open-issues.md#incidental-findings)).
- `ProtoStore.finalizeLocal` allocates a batch with `gpa.create`, whose
  bytes are undefined, and arms the `errdefer` before `binding()` sets the
  fields. A field added to the batch and freed in `destroy` (the census
  pointer) is freed uninitialized on the first allocation failure. Eight
  existing allocation-failure tests caught it.
- The #256 generator's bound was `1e-6` of the row's largest move plus a
  rounding term of 1.4e-26. On `bsim4-mode-gate` the gap was 2.76e-24 on a
  move of 2.45e-18: machine epsilon times a residual near 1e-8, lost when
  two rows that large cancel on a tied node.
- The generator then failed three more times, each on a fact the first
  bound had hidden. The replay writes a row as its recorded value plus the
  move (`batch_bypass.zig`), so two tied rows that cancel exactly in the
  plain pass round at machine epsilon times the local current in the
  replay; the bound now carries that term, derived from an untied twin.
  Eleven names in the bypass list matched no model
  ([finding 27](06-open-issues.md#incidental-findings)). `hisimhv_va` and
  `hisimsoi` latch a fatal on their default card and stamp zeros, so "never
  replayed" was true of a device that never ran; the test gives each the
  one parameter its node count needs. A generator case that stamps nothing
  now fails by name.
- Operating point, first counts under `c8` (Debug, 1k decks):
  `chain_psp103_1k` fails plain Newton at iteration 4 on a singular matrix
  and converges in 11 gmin rungs and 67 iterations; `ring_psp103_1k` spends
  all 100 plain iterations without a repeat, then 58 on the ladder. Neither
  holds an exact cycle.
- Build speed, from VerA's measurements (its `research/builds.md` §5, read
  against ESPice's `build.zig` only; checked here by line, not yet measured
  on ESPice):
  - **The absolute paths in `build_options` cost every snapshot a full
    rebuild.** `build.zig:25-29` compiles `dyn_path`, `device_abi_path` and
    `core_path` (`pathFromRoot` on the build root) into the options module.
    Only `device/Library.zig` reads them, but `device`, `solver` and
    `analysis` import the module, so every test root above them misses the
    cache in a tree at another path. That is why each wave's snapshot
    worktree wrote about 55 GB of Debug outputs. The cheap side: snapshots
    now reuse one fixed path. The fix: the three paths leave the shared
    options module, reach `Library` at run time in tests, and stay compiled
    into the shipped `espice`, whose `.hdl` loader needs them.
  - **Run steps with an environment never cache.** `setEnvironmentVariable`
    copies the whole environment into the step's key, and each `nix
    develop` has its own `TMPDIR`. `ZIG` at `build.zig:221`, `224` and
    `523` (the C API run, the espice run, every corpus run), and
    `ESPICE_PERF` at `301`/`306`, rerun on every call. VerA: 10-11.5 s per
    unchanged step against 0.44 s. Pass the value as an argument.
  - `check` type-checks every root under one watch. In VerA that held 6.4 GB
    per agent; per-root `check-<root>` steps took 0.15-0.56 GB.
  - Nothing collects the shared `.zig-cache`, and worktrees on different
    branches evict each other's manifests.
