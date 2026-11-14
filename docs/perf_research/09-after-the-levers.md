# After the levers: what binds next, down to the hardware

Assume every lever of [04-levers-cpu.md](04-levers-cpu.md) and
[05-levers-gpu.md](05-levers-gpu.md) has landed at its estimate. This page
asks what the largest remaining term is, whether it is the hardware, a rule
this project chose, or software, and names the next lever. Then it asks
again, until what is left is hardware or a rule.

Two of the levers this page assumes did not land. C5 (the solve at lane
scale) lost its phase in every form measured, and C2 (the confirming solve
on a held factor) was rejected by the owner because it needed an accuracy
bound of its own. Both are deleted
([13-implementation.md](13-implementation.md)). Where a projection below
applies "C2 at its census rate" or C5, read it without them: every
refactor stays, and the solve stays serial. The confirming iteration is
then a rule cost, not a software one.

Three kinds of residual, kept apart throughout:

| Kind | Meaning | What removes it |
|---|---|---|
| **hardware** | A roofline: FP64 rate, memory bandwidth, instruction throughput, or a dependency chain the arithmetic itself imposes. | A different machine |
| **rule** | A cost that follows from a parity rule: ngspice's iterate and time grid, bitwise host order, exact charges. | An owner decision; never a default-mode change |
| **software** | Everything else. | A lever on this page (N1 to N10) or an earlier one |

Every "after" figure is arithmetic on measured inputs. The measurements
that are new on this page were taken on `9bbd4d7f` with `perf` 7.0.10
(`nix shell nixpkgs#perf`), user-space events on the P-cores, one thread
pinned to CPU 2 or the default 8 lanes on CPUs 0 to 13, while a build ran
on the other cores.

## New measurements

### Counters

`perf stat`, the regular ReleaseFast build. The last four columns are the
top-down split of pipeline slots.

| Deck | Lanes | Cycles | Instructions | IPC | Retiring | Front end | Back end | of which memory |
|---|---|---|---|---|---|---|---|---|
| `chain_bsim4_1k` | 1 | 6.6 G | 16.0 G | 2.45 | 48% | 9% | 40% | 8% |
| | 8 | 18.8 G | 20.4 G | 1.08 | 29% | 10% | 57% | 12% |
| `logic_bsim4_1k` | 1 | 17.6 G | 51.3 G | 2.92 | 51% | 11% | 31% | 6% |
| | 8 | 63.9 G | 69.5 G | 1.09 | 29% | 9% | 56% | 14% |
| `chain_bsim4_10k` | 1 | 40.3 G | 92.8 G | 2.31 | 48% | 10% | 41% | 13% |
| | 8 | 78.8 G | 119.4 G | 1.51 | 34% | 10% | 54% | 25% |
| `sram_bsim4_10k` | 8 | 350.8 G | 519.3 G | 1.48 | 38% | 9% | 49% | 17% |
| `chain_psp103_1k` | 1 | 11.7 G | 28.6 G | 2.45 | 42% | 12% | 43% | 12% |
| `scaling_inverter_chain_4k` | 1 | 24.0 G | 72.9 G | 3.04 | 54% | 3% | 42% | 9% |
| | 8 | 91.7 G | 90.6 G | 0.99 | 25% | 6% | 68% | 18% |
| `scaling_parallel_inverters_2000` | 1 | 2.7 G | 9.0 G | 3.29 | 58% | 4% | 37% | 9% |
| `bench_ngspice_mosamp` | 1 | 8.1 G | 21.6 G | 2.67 | 46% | 5% | 47% | 7% |
| `rc_ladder_1000` | 1 | 1.8 G | 2.8 G | 1.60 | 30% | 5% | 64% | 28% |

Read off:

- **One thread is core-bound, not memory-bound.** About half the slots
  retire. On the nonlinear decks only 6 to 13 points of the back-end loss
  are memory; the rest is the core itself, which for this code means
  dependent chains (divides, square roots, the polynomial chains inside
  `exp` and `log`; the split per cause was not measured). The front end is
  3 to 12%: the 69 MB of model text (#259) is not what limits evaluation.
- **Eight lanes spend two to four times the cycles for 24 to 35% more
  instructions.** IPC falls to about 1. The difference is waiting and
  store traffic, split below.
- **Memory shows up with lanes**: 13% to 25% of slots on `chain_bsim4_10k`.

### Where the cycles go

`perf record`, flat by function. This used the census build because the
regular binary has no symbols; its extra held-factor solve inflates the
solve row, so read that row as an upper bound. One thread, share of cycles:

| Group | `chain_bsim4_1k` | `logic_bsim4_1k` | `chain_psp103_1k` | `inverter_chain_4k` (mos1, bypass on) | `parallel_inverters_2000` (mos1, bypass off) | `mosamp` (mos2) | `rc_ladder_1000` |
|---|---|---|---|---|---|---|---|
| Model equations (`stamp.evalRange`) | 41.4 | 25.0 | 49.6 | 8.2 | 38.8 | 39.0 | 15.2 |
| `exp`, `log`, `pow` (`expInline`, `softLog`, `softPow`) | 13.8 | 8.9 | 16.6 | — | 2.4 | 26.3 | — |
| Charge core outside the Newton evaluation (accept, step end, the bypass's re-read) | 10.9 | 6.3 | 7.9 | 23.8 | 17.7 | 14.5 | 4.7 |
| Limit pass (`limitRangeHook`) and `stateCtl` | 2.8 | 1.8 | — | 13.6 | 19.3 | 5.1 | — |
| Bypass compare and replay | — | — | — | 33.3 | — | — | — |
| Refactor | 17.0 | 47.2 | 13.1 | 4.6 | 5.4 | 4.8 | 2.1 |
| Solve (inflated) | 4.7 | 5.1 | 4.4 | 6.1 | 2.0 | 2.7 | 45.0 |
| LTE (`stepBound`) | 1.5 | 0.7 | 1.2 | 2.2 | 4.6 | 1.8 | 9.4 |
| `memcpy`, `memset` | 1.9 | 1.1 | 2.0 | 2.7 | 2.7 | 0.5 | 8.6 |
| Newton loop body (`converger.run`) | 1.5 | 1.0 | 1.6 | 1.9 | 1.8 | 2.0 | 10.2 |

Three things in it were not on any earlier page.

**The charge core runs up to three times per accepted step.** Once inside
the confirming Newton evaluation at `x_k`. Again in `acceptQOnly`
(`device/batch.zig:220`, called from `acceptStates`,
`circuit_devices.zig:324`), which evaluates the charges at the same `x_k`
together with the state update. And a third time in `rebase`
(`tran/host_ops.zig:111`), which re-reads every instance's charge at step
end whenever any batch of the circuit has both a charge and a state hook. A call-graph
profile of `chain_bsim4_1k` puts 4.8% of the run in that third pass alone
(`end` to `rebase` to `evalQ`) and 5.9% in the second. The PSP103 column
shows no separate accept pass because the symbol is inlined there; its 7.9%
is the charge function alone. `Sim.zig:549` says
why the bits allow sharing: "`evalQ` computes the same q bits as `eval`,
charges only."

**On a latent circuit the per-instance overhead is most of the run.** On
`scaling_inverter_chain_4k`, where 0.5% of instances are active and 99%
of evaluations are bypass hits, the full model evaluation is 8% of the
cycles. The bypass's compare and replay are 33%, its exact charge re-read
14%, the other charge passes 10% and the limit pass with its state control
14%: two thirds of the run is work for instances that did not move.

**At 8 lanes the staged-stamp reduce is 18% of all cycles, and it is cache
lines changing cores.** On `chain_bsim4_10k` at 8 lanes `ParEval.pass`
holds 24.4% of the cycles (the model evaluation it calls is a separate
row at 22%). `perf annotate` puts 75% of that function on one source
line pair, the inner loop of `sumCells` (`par_eval.zig:568`):

```text
v += stage[p];
stage[p] = -0.0;
```

A staging cell is written by whichever lane claimed the instance's stamp
chunk and read back and reset by whichever lane claimed the cell's reduce
block. Seven times in eight those are different cores, so the line is
pulled out of another core's cache once per pass and pulled back on the
next. That reading is from the claim order and the sample location;
`perf c2c` was not run. It fits the memory-bound share going from 13% to
25% of slots between one lane and eight. Another
11% of the function is the 4,096-spin wait for the other lanes to finish
stamping, and the pool threads' own spin loop is 8.2% of all cycles (94% of
it on one instruction after `pause`). Together: 18% of the cycles move
staging lines and 11% spin, on a deck whose refactor is 18%.

### Outside the Newton loop

`--timing-in-depth`, `chain_bsim4_10k`, 8 lanes, wall 4.64 s:

| Part | Time |
|---|---|
| Everything else: front end 36 ms, Problem creation 54 ms, process start and exit | 0.13 s |
| Operating point | 1.28 s |
| Transient, the five Newton phases | 2.71 s |
| Transient, outside them (step control, LTE, charge passes at step end, history, output) | 0.52 s |

The transient spends 16% of its time outside the phases every earlier page
counted. The same subtraction on other decks:

| Deck | Transient | In the five phases | Outside | Per accepted step |
|---|---|---|---|---|
| `chain_bsim4_10k` | 3,232 ms | 2,714 ms | 518 ms, 16% | — |
| `logic_bsim4_1k` | 2,626 ms | 2,507 ms | 119 ms, 4.5% | — |
| `scaling_rc_ladder_100k` | 1,484 ms | 1,194 ms | 290 ms, 20% | 1.2 ms for 100,003 unknowns: 12 ns an unknown |
| `vacask_graetz` | 2,065 ms | 1,727 ms | 338 ms, 16% (0.47 s in an earlier run) | 0.34 µs for 10 unknowns |

Setup is small at these sizes: front end and Problem creation are 132 ms
of `scaling_rc_ladder_100k`'s 1.71 s, and writing the raw file is 23 ms on
both decks.

## Class 1: thick factors

`logic_bsim4_10k`, 8 lanes, seconds. "Round 3" applies C1 at 3.6x on the
refactor, C2 at its census rate, C5, C7 and C8. "Round 4" applies the
levers below.

| Phase | Now | After round 3 | After round 4 | Floor on this machine |
|---|---|---|---|---|
| Refactor | 32.4 | 6.0 | 1.9 | 0.4 fused, 0.8 under the rule |
| Evaluation | 2.6 | 2.6 | 1.5 | 1.1 |
| Solve | 1.9 | 0.8 | 0.3 | — |
| Update, load | 0.9 | 0.5 | 0.3 | — |
| Operating point | 11.4 | 2.4 | 1.5 | — |
| Outside Newton, setup | 0.9 | 0.9 | 0.6 | — |
| **Wall** | **50.1** | **about 13** | **about 6** | |

The round-3 column is each brief's own estimate. The round-4 column is a
target, not a prediction: every N lever starts with the measurement that
prices it. A floor is given where it is arithmetic: pairs over the peak
rate for the refactor, and for the evaluation today's instruction count at
one thread's IPC spread over 8 cores with no loss (1,111 iterations of
10,688 BSIM4 evaluations at 0.72 µs, over 8).

After round 3 the refactor is still the largest term. Its floor: one
refactor is 155.7 M multiply-subtract pairs. A P-core at 4.5 GHz has two
256-bit multiply-add ports: 8 fused pairs a cycle, or 4 when the multiply
and the subtract stay separate operations as the bitwise rule requires. So
8 cores do one refactor in 0.54 ms fused and 1.1 ms unfused, and the 745
refactors C2 leaves (67% of 1,111) take 0.4 s or 0.8 s. C1's estimate is
8 ms a refactor, 7 to 15 times that. Today's kernel reaches at most 1.9
pairs a nanosecond on one core ([02-baseline.md](02-baseline.md#the-refactor)),
0.42 a cycle, a tenth of the unfused peak. What sits in the gap after C1:

| In the gap | Kind | Size | Lever |
|---|---|---|---|
| The dense tail runs column by column on a dependency chain, so lanes scale 1.6x to 2.8x of 8 | software | 2x to 4x | [N1](#n1-the-dense-tail-as-a-tiled-factorization-on-every-lane) |
| Multiply and subtract are two operations by the bitwise rule; a fused one halves the work where the kernel is compute-bound | rule | 1.3x to 2x | [N2](#n2-fused-multiply-add-in-the-lu-kernels) |
| Ragged panels: supernodes of 16 to 60 columns never reach a dense kernel's efficiency | hardware, for this matrix | about 2x | — |

Then the evaluation and the operating point are next, and they are Class
2's and [C8](04-levers-cpu.md#c8-the-operating-point)'s subject. The
operating point's full factors are serial
([N9](#n9-the-operating-points-full-factors-on-every-lane)).

**End state.** About 6 s against 50 s, with the refactor at 2 to 3 ms:
compute-bound FP64 on the dense tail at a third to a half of the unfused
peak, which is hardware. An A100 with
[G2 and G7](05-levers-gpu.md#what-binds-each-kernel) is predicted at 1.2 to
4 ms for the same refactor and solve: at 10k devices a finished CPU kernel
and a finished device kernel are about level, and the card pulls ahead
only with circuit size or with lanes
([G9](05-levers-gpu.md#g9-lanes-of-a-thick-circuit)).

## Class 2: thin factors, bound by model evaluation

`chain_bsim4_10k`, 8 lanes, seconds:

| Phase | Now | After round 3 | After round 4 | Floor on this machine |
|---|---|---|---|---|
| Evaluation (with the reduce) | 1.22 | 0.8 | 0.5 | 0.5 if every instance is evaluated |
| Refactor | 0.60 | 0.31 | 0.31 | — |
| Solve | 0.38 | 0.15 | 0.15 | — |
| Update | 0.36 | 0.2 | 0.1 | — |
| Load | 0.16 | 0.03 | 0.03 | — |
| Outside Newton | 0.52 | 0.52 | 0.25 | — |
| Operating point | 1.28 | 0.5 | 0.4 | — |
| Setup, process | 0.13 | 0.13 | 0.13 | — |
| **Wall** | **4.64** | **about 2.6** | **about 1.9** | |

Round 3 does least for this class: only C4 shortens the evaluation, and
only where the circuit is latent. The inverter chain is: with the off
switch disabled, 97% of its BSIM4 evaluations past the first iterate are
within tolerance or miss on instance bytes alone
([census](02-baseline.md#why-it-misses)). C4 with its key fixed bounds the
model part of the evaluation at 0.65 of today, and at 0.32 if the first
iterate may replay; the table enters it at 0.8 and 0.5 of the phase. A
latent BSIM4 deck then joins Class 3, and what binds it is the cost of a
hit. For a deck that is not latent (`chain_psp103_1k` moves past the
tolerance on 83% of eligible evaluations) the evaluation stays the next
term, at a third to a half of the wall.

Its floor. One BSIM4 evaluation with its derivative lanes is about 7,700
instructions and 3,100 cycles (0.7 µs) on one thread. The transient needs
548 iterations of about 10,000 of them: 42 G instructions. Eight P-cores
at one thread's IPC of 2.45 and a nominal 4.5 GHz would take 0.48 s;
today's 8 lanes take 1.22 s.

| In the gap | Kind | Size | Lever |
|---|---|---|---|
| Staging lines changing cores in the reduce: 18% of all cycles at 8 lanes | software | up to 1.3x on the phase | [N8](#n8-lane-affine-staging), with [C7](04-levers-cpu.md#c7-one-reduce-pass-that-also-forms-a) |
| Spinning lanes: 11% of cycles | software | CPU-seconds, and turbo headroom | [C6](04-levers-cpu.md#c6-lanes-past-eight-and-what-idle-lanes-burn) |
| The charge core run two more times per step | software | 10% of one thread | [N3](#n3-one-charge-evaluation-per-accepted-step) |
| The confirming evaluation computes a Jacobian nobody uses | closed with C2 (rejected by the owner): without a held solve the confirming update is solved with that Jacobian | — | [C2 stage 2](04-levers-cpu.md#c2-the-confirming-solve-on-the-held-factor) |
| `exp`, `log`, `pow`: 9 to 26% of one thread | software | measure per call | [N4](#n4-the-transcendental-kernels) |
| Derivative lanes computed for partials that are structurally zero | software, in VerA | unknown; count first | [N5](#n5-derivative-sparsity-in-the-generated-model-code) |
| Evaluation scales 3.7x to 4.8x on 8 lanes | software until N8 and C6 are in, then shared cache and all-core clock | up to 1.7x | N8, C6 |
| Half the slots do not retire because the model's equations form long dependent chains | hardware | 2x | — unless the instance axis pays: gated on one measurement, not closed ([12, question 5](12-math-and-contract.md#5-the-instance-axis)) |
| Two iterations a step, ngspice's time grid | rule | 2x, and the step count | — |

**End state.** About 1.9 s against 4.6 s. Where every instance moves, evaluation is then the model's own
instruction stream on every core at an IPC the dependency chains cap near
2.5 to 3: hardware, for this model code. The only software left inside it
is the instruction count per evaluation, which belongs to the model
compiler (N5).

## Class 3: latent circuits

`scaling_inverter_chain_4k` (one thread 6.6 s, 8 lanes 3.5 s),
`bench_ngspice_mosamp` (2.1 s, a deck ngspice wins), and
`scaling_parallel_inverters_2000`.

Round 3's [C4](04-levers-cpu.md#c4-bypass-that-pays-on-production-models)
makes a hit cheap and lets the first iterate replay. With its key fixed
this class also takes in the BSIM4 post-layout chains, SRAM and logic
decks, which are up to 89 to 97% latent past the first iterate by the same
census. What it leaves is in
the profile above: after C4 the bypass's compare and replay shrink, and
the charge re-read (14% plus 10%) and the limit pass (14%) become most of
what is left, because C4 keeps both for every instance, latent or not.

The floor for a latent circuit is work proportional to the active
instances, plus one streaming compare over all of them and the linear
solve. On `scaling_inverter_chain_4k` (8,000 instances, 4,721 transient
iterations) that is 40 active instances, a compare over 256 KB of gathered
unknowns, and the solve at today's 49 µs: about 70 µs an iteration as an
estimate, against 1.3 ms on one thread today.

| In the gap | Kind | Lever |
|---|---|---|
| The exact charge re-read on every hit | rule (charge conservation), partly software | [N6](#n6-latency-for-the-charge-and-limit-passes) |
| The limit pass on every instance | software | N6 |
| The whole matrix is refactored and solved while 99.5% of it is unchanged | closed by census: 31.6% of entries change per factor, because the step size multiplies every capacitance | [07-prior-work.md](07-prior-work.md#closed-in-this-codebase) |
| The whole circuit takes every time point | rule (no multirate, no partitioning) | a mode, not a lever |

**End state.** After C4 and N6, a latent MOS1 or MOS2 deck is bound by the
solve, the LTE and the step control per iteration, which is Class 5's
term. Past that the price is the rule: one time grid for the whole
circuit.

## Class 4: linear circuits

`rc_ladder_1000`: 40 µs a step today (405 ms over 10,123 steps), two
iterations each. After
[C3](04-levers-cpu.md#c3-linear-circuits-one-confirm-per-factor) one solve
a step remains, and the profile's other rows become the budget: the Newton
loop body 10%, the LTE 9%, `memcpy` and `memset` 9%, resistor and
capacitor evaluation 15%, the capacitor charge pass 5%.

The floor for one step of a linear circuit is one residual, one solve and
one LTE pass: for about 1,000 unknowns an estimated 4 µs of streaming
arithmetic (at the nanosecond per factor entry the larger decks measure).
Memory is already 28% of the slots here, the highest in the table: the
solve walks 12 bytes per entry.

| In the gap | Kind | Lever |
|---|---|---|
| The second iteration | software | C3 |
| Copies of whole vectors per step and per iteration | software | [N7](#n7-step-bookkeeping) |
| The LTE as an index-order loop | software (its reduction is a minimum, exact in any order) | N7 |
| The solve's index stream | software | [C5](04-levers-cpu.md#c5-solve-and-update-at-lane-scale) step 1 |
| Step growth of 2x where RSpice takes 4x | rule (the time grid) | — |

**End state.** One solve a step at memory speed: hardware, a dependent
chain down the elimination tree.

## Class 5: tiny circuits with long runs

`bench_ngspice_mosamp` (25 unknowns, 215,274 iterations, 8.0 µs each),
`vacask_graetz` (10 unknowns, 2 M iterations, 0.79 µs each, and 16 to 23%
of the wall outside the Newton phases), `vacask_rc` (4 unknowns, 2 M
iterations).

Nothing here is parallel: a time step needs the one before it, and the
circuit is too small for lanes. The floor is the single-thread chain per
iteration: on `vacask_graetz` four diode evaluations (four `exp` calls),
a 10-by-10 replay and a solve, an estimated 0.2 µs. Today 0.79 µs.

| In the gap | Kind | Lever |
|---|---|---|
| Per-call overhead of factor and solve at this size | software | #250 |
| Per-batch indirect calls, vector copies, the loop body | software | N7 |
| A million accepted points recorded and written | software | N7 |
| The bypass, off on these decks | software | C4 |
| `pow` where `sqrt` would do | software, rounding class | finding 4 in [06-open-issues.md](06-open-issues.md#incidental-findings) |
| The step count | rule | — |

**End state.** One thread's dependent chain per time step: hardware. The
only parallelism left is across runs (jobs, lanes of a sweep), which
ESPice already has.

## Class 6: an FP64-class card

From [05-levers-gpu.md](05-levers-gpu.md#what-binds-each-kernel), an A100
with G2, G7, G3 and C8 in. The ranges span two models of the same trace:

| Deck | Wall | Of which host | Refactor and solve per iteration |
|---|---|---|---|
| `sram_bsim4_10k` | 2.4 to 6 s | 1.6 s | 0.6 to 4 ms |
| `logic_psp103_10k` | 7 to 13 s | 5.0 s | 1.3 to 4 ms |
| `logic_bsim4_10k` | 10 to 13 s | about 8 s | 1.2 to 4 ms |
| 8,192-point transient sweep, with G8 | about 2.8 s | 2.4 s | — |

The next term depends on which end of the range is true. At the low end
it is the host: what runs between kernels, the operating point, and about
ten launches of 7.6 µs an iteration. That is
[G5](05-levers-gpu.md#g5-a-resident-newton-loop-where-the-host-is-the-bound)'s
resident loop, which this arithmetic re-opens. At the high end it is still
the LU's chain.

Under both, the refactor does not reach the card's hardware terms. Its
arithmetic is 0.064 ms on an A100 and its L values 0.28 ms through L2; the
chain at its own latency is 0.07 ms
([10-device-lu-chain.md](10-device-lu-chain.md#2-roofline-for-the-refactor)).
After G2 it is predicted at 0.4 to 1.2 ms. So 1.5x to 4x of software
remains in the hand-off between chunks, unpriced until G2's step 2 times a
barrier, a hand-off and an in-chunk step. Below that the residual is the
trunk of the elimination tree: its depth is fixed by the ordering, and an
ordering that cuts it is not bitwise with the host's (a rule). One sparse
factor of this size cannot fill 108 SMs. Only more independent work does:
[G9](05-levers-gpu.md#g9-lanes-of-a-thick-circuit), which ends bound by L2
traffic at about a quarter of the FP64 pipe, and larger circuits.

## Where it ends

| Class | Now | After rounds 3 and 4 | Then bound by | Kind |
|---|---|---|---|---|
| Thick factors, CPU | 50 s | about 6 s | FP64 throughput on the dense tail at a third to a half of the unfused peak | hardware |
| Thin factors, CPU | 4.6 s | about 1.9 s | Active circuits: the model's instruction stream at the IPC its chains allow. Latent ones: the cost of a hit | hardware, the instruction count being VerA's; software (N6) |
| Latent circuits | 3.5 s | not priced: needs C4's and N6's censuses | Solve and step control per iteration; then one time grid for all | hardware, then rule |
| Linear circuits | 40 µs a step | about 10 µs | The solve's dependent chain | hardware |
| Tiny, long runs | 0.8 to 8 µs an iteration | 0.2 to 2 µs | One thread's chain per time step | hardware |
| FP64-class card | 13 to 47 s on the 4060 | 2.4 to 13 s | The host or the chain's hand-offs, then the elimination tree's trunk | software (G5, G2), then rule |

Each "after" figure is an estimate with a named first measurement; no
lever of round 3 or round 4 is built.

Read as an answer to "where is the next bottleneck":

- After round 4 no CPU class has one dominant software term. The
  thick-factor budget is flat: refactor 1.9 s, evaluation 1.5 s and the
  operating point 1.5 s of about 6 s, with the refactor at 2.4 times its
  floor under the bitwise rule and the evaluation at 1.4 times its own.
  The thin-factor budget is evaluation at a quarter of the wall, beside an
  operating point of 0.4 s and a refactor of 0.3 s.
- The software known to remain after that is small and named: the
  instruction count of a model evaluation (N5, in VerA), the hand-off
  between chunks of the device refactor (G2 step 2), and the host between
  kernels on a card (G5).
- The largest factors left are rules, not software: two iterations a step
  and ngspice's time grid (2x and the step count on every class), the
  unfused multiply-subtract (up to 2x on thick factors), one time grid for
  the whole circuit (most of a latent circuit's run).

## What the rules cost

No lever on these pages breaks one of these. Each has a price, listed so
that the owner can see it:

| Rule | Its price once the software is done | Where a relaxed form already exists |
|---|---|---|
| Iteration 1 is never accepted; the published point is `x_k` | One values-only evaluation and one held-factor solve per step (after C2, C3 and its stage 2). Before them: half of all Newton work. | — |
| ngspice's time grid: `trtol`, growth 2x, restart at breakpoints | The step count itself. Every floor on this page is per step. | A named mode ([07-prior-work.md](07-prior-work.md#the-published-iterate-rule)) |
| Bitwise host order in every LU kernel, no contraction | 1.3x to 2x on compute-bound kernels (N2); the tail solve's dependent chain on the device (G7 stage 3) | — |
| Exact charges at every accepted point | The charge core per instance per step, latent or not (N6) | — |
| One Newton system for the whole circuit at every time point | Latent circuits pay the solve and the compare everywhere, every step | — |
| No float atomics; host path is the oracle | Staging and a reduce for parallel stamps (C7 shrinks it, cannot remove it) | — |

## Round 4 levers

Each is short on purpose: a brief gets written when its first measurement
is in.

### N1 The dense tail as a tiled factorization on every lane

**Class:** exact. **After:** C1 stage 2. The last supernodes of a thick
factor hold most of its pairs (their count equals a dense LU of order 490
on `sram_bsim4_10k` and 780 on `logic_bsim4_10k`). Factor that tail
right-looking in tiles: a panel, then the trailing update split over all
lanes, each slot still receiving its subtractions in ascending source
order. Independent tiles scale where today's chain does not (1.6x to 2.8x
of 8). **Oracle:** `refactorColumns`, bitwise. **First step:** from C1's
run census, the share of pairs whose source and target both lie in the
tail, and the tail's order; worth building above 60%.

### N2 Fused multiply-add in the LU kernels

**Class:** rounding, owner decision, once. Every `w -= l * u` becomes one
fused operation on the host and on the device together, so the two stay
bitwise equal to each other and every raw moves in its last bits once. It
pays only where a kernel is compute-bound, which is after C1 stage 2 and
N1 on the host and after G2 on a card. **First step:** on the C1 stage 2
kernel, measure pairs per cycle with and without contraction. Close it
under 1.3x.

### N3 One charge evaluation per accepted step

**Class:** exact. **Files:** `src/device/stamp.zig`, `batch.zig`,
`src/analysis/circuit_devices.zig`, `src/analysis/tran/host_ops.zig`.

Two changes:

1. The Newton evaluation that turns out to be the accepted one already
   computed every charge at `x_k`. Let it stage what `acceptQOnly` stages
   (charges, the LTE tape, the state update) so acceptance commits instead
   of evaluating. A bypass hit keeps its own charge read.
2. `rebase` re-reads every batch of the circuit when `has_state_q` is
   set, and that flag is "some batch has a charge and a state hook"
   (`device/Circuit.zig:295`). BSIM4 and MOS1 have both, their state being
   limiter history, so every post-layout deck pays a whole-circuit charge
   pass per step, capacitors included. Narrow it to the batches whose
   charge reads a state the commit writes (a per-model fact VerA can
   emit), and within those to the instances whose commit changed it.

**Size:** 10.5% of one thread on `chain_bsim4_1k`, 6% on
`logic_bsim4_1k`, 13 to 18% on the MOS1 and MOS2 decks. At 8 lanes the
charge pass and the state update are separate ParEval passes today (the
comment at `circuit_devices.zig:322`), so the saving there includes two
lane dispatches per step. **Oracle:** today's passes: `q_vec`, the LTE
tape and every state bitwise equal after each accepted step, in a unit
test over every model, and corpus raws byte-identical. The four decks
`Sim.zig:546` names (`txl2_3_line`, `hfet_inverter`, `mesa_oscillator`,
`mos6_inverter`) are the regression set for part 2. **First step:** the
bitwise test of part 1 with the evaluation's charges captured beside
today's.

### N4 The transcendental kernels

**Class:** rounding if a result bit changes, exact if only speed does.
`expInline`, `softLog` and `softPow` are 9 to 26% of one thread. **First
step:** count calls per evaluation and cycles per call for each. A good
scalar `exp` is about 20 cycles; anything far above that is the lever.
`softPow` with an exponent of one half is finding 4.

### N5 Derivative sparsity in the generated model code

**Class:** exact, in VerA. A dual carries W derivative lanes through every
operation, including intermediates that depend on one or two unknowns, for
which most lanes are structural zeros. **First step:** instructions per
evaluation of the value-only instantiation against the dual one, per
model; and from VerA, the share of dual operations whose lane set is
smaller than W. This is the only lever that shortens the instruction
stream Class 2 ends on. Interacts with #259 (binary size).

### N6 Latency for the charge and limit passes

**Class:** exact where an instance's gathered unknowns are bitwise
unchanged since its last charge evaluation (its charge and its limiter
outputs are then the same bits); tolerance for anything looser. **First
step:** a census on the three latent decks: the share of instances whose
unknowns are bitwise unchanged between consecutive evaluations. If it is
small, the exact form does not pay and the choice is the rule in the table
above.

**Verdict (2026-11-11): the exact form is rejected and deleted.** Built
for the charge-only pass and timed on the wave-5 binary, raws identical:
it gains 1 to 2% of the run on the MOS1 decks (`ring` 305 to 288 ms on
`scaling_inverter_chain_4k`, 356 to 313 ms on `bench_ngspice_mosamp`) and
loses as much on BSIM4 (`ring` 36 to 50 ms on `chain_bsim4_1k`, 243 to
288 ms on `chain_bsim4_10k`), where no instance holds its bits from one
accepted point to the next and each lookup is a compare that misses. A
hit needs an instance bitwise at rest across two accepted points, which
is a property of the run and cannot be declined per model at build time.
The limit stage was never built: its ceiling is the census's unchanged
share, 94% on the MOS1 chain and under 1% on every BSIM4 deck.

### N7 Step bookkeeping

**Class:** exact. The parts of a step that are not Newton phases: vector
copies (rotate the history ring's slices instead; `shiftRing` and
`rebase` already swap in one place), the LTE loop (per-state arithmetic in
index order is kept; only the minimum over states is vectorized, and a
minimum is exact in any order), the waveform record, and the loop body on
tiny circuits. 16% of `chain_bsim4_10k`'s transient, 20% of
`scaling_rc_ladder_100k`'s (12 ns per unknown per step), 16 to 23% of
`vacask_graetz`'s. **First step:** a `timing:` line for the transient
outside the five phases, split into charges, LTE, history and output.

### N8 Lane-affine staging

**Class:** exact. **Files:** `src/analysis/par_eval.zig`. After or with
[C7](04-levers-cpu.md#c7-one-reduce-pass-that-also-forms-a).

Stamp chunks and reduce blocks are claimed by `fetchAdd`, so the lane that
writes a staging cell and the lane that sums and resets it are unrelated,
and the line changes cores twice a pass: 18% of all cycles on
`chain_bsim4_10k` at 8 lanes. Give each lane a home range of instances and
order the reduce blocks so that a block's cells are fed mostly by one home
range; a lane takes its own ranges first and steals only when it runs out.
A cell fed from two ranges still crosses, which is the circuit's cut and
small for a good partition. The sum per cell keeps tape order, so every
bit is unchanged. Related: the reset store is only needed for positions a
pass might not write; a batch that writes every position each pass can
skip it.

**Oracle:** the serial `evalNewton` planes, bitwise, at 1, 2 and 8 lanes
(the existing ParEval test); corpus raws byte-identical. **First step:**
`perf c2c` on the 8-lane run, and a `timing:` split of the evaluation
phase into stamping, waiting and reducing. Worth building if reducing is
over 15% of the phase.

### N9 The operating point's full factors on every lane

**Class:** exact. After C8 the operating point is a handful of full
factors with pivot search, serial today. The supernode panels of the full
factor are already SIMD; the subtree plan that parallelizes the replay
applies to independent subtrees of the full factor as well. **First
step:** the share of a full factor's flops in independent subtrees, from
the census.

### N10 Setup at scale

**Class:** exact. Front end and Problem creation are 0.09 s at 10k BSIM4
devices and 0.13 s at 200,000 linear elements (`scaling_rc_ladder_100k`,
8% of its wall), linear in the deck. They matter at a million elements or
after everything else. `chain_bsim4_100k` was not run in this round: its
cold operating point is #218. **First step:** the timing lines of the
BSIM4 100k decks once #218's gate has run.
