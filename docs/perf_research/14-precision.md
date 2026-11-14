# Reduced precision: narrower floats, pairs of floats, mixed-precision solves

This page asks whether the simulator can compute in a narrower
floating-point format on the CPU and the GPU and still publish the same
accuracy. The owner's phrasing was "splitting f32 into 2 f16s for FMA to be
accurate enough"; the form that fits this engine is an f64 carried as two
f32. Nothing was built or run for it. Levers here are named H1 to H3.
Classes are those of [README.md](README.md#classes).

One rule weighs every idea below. The owner rejected C2 on 2026-11-11:
the accuracy a user sets is SPICE's own option set (`reltol`, `abstol`,
`vntol`, `chgtol`, `trtol`, `gmin`, `pivrel`, `pivtol`, `itl1` to `itl4`),
and a lever that is safe only under a new accuracy number does not ship
([11-lever-gate.md](11-lever-gate.md#why-a-variable-against-the-standing-rule)).
So an idea whose published answer cannot change ranks above one that
needs a tolerance of its own, whatever its ceiling.

Every number carries one of three labels:

- **measured**: read from a page or file of this repository, which is named.
- **computed here**: arithmetic on measured or cited numbers, shown.
- **cited**: from a source in [References](#references). A source that
  could not be opened says "not read" there and is never cited second hand.

A "hand count" is this page's own operation count of an algorithm that was
not built. It is an estimate.

## The short answer

- **A pair of f16 does not reach f32.** It carries 22 bits against 24, its
  proven error is 8 to 39 times f32's rounding error, it costs 6 to 31
  operations where f32 costs one, and its range (6.1e-5 to 6.6e4) excludes
  `abstol`, `gmin` and every femtofarad. Closed.
- **A pair of f32 does not reach f64.** It carries 48 bits against 53. Its
  proven error per operation is 2u² to 9.8u², which is 64 to 314 times
  f64's rounding error, and it keeps f32's exponent range. It can never be
  bit-identical to the f64 host path. Three f32 words pass f64's accuracy
  but still round differently about once every two BSIM4 evaluations.
- **With FMA nothing is split.** The split the owner remembers is
  Veltkamp's, which Dekker used to multiply exactly without an FMA: 17
  operations. An FMA gives the exact product error in 2. The pair is the
  result and its rounding error, both in the full format.
- **Pairs pay on one machine class only.** The break-even is the card's
  FP32-to-FP64 rate: 60.6 f32 operations per f64 operation on the RTX 4060
  at the pipe's ceiling, about 27 at the rate Gompute's own f32 pair bodies
  reach. On an A100 or on the CPU that budget is 2, and a pair multiply
  costs 9. There a pair loses 4.5x to 15.5x per operation.
- **On the 4060 the pair's own ceiling is the chain, not FP64.** BSIM4's
  value path in f32 pairs is 25k to 44k f32 operations against 4,231 f64
  ones. The lane kernel's instruction count rises 1.8x to 2.5x, so its
  latency term passes its FP64 term. Over
  [G4](05-levers-gpu.md#g4-f32-derivative-lanes-on-fp64-poor-cards) the
  sweep gains 1.06x to 1.14x. Closed until
  [G8](05-levers-gpu.md#g8-lane-kernels-one-thread-per-instance-and-lane)
  shortens the chain.
- **"It only steers convergence" is not an argument here.** The published
  point is an iterate, not the root. A narrower Jacobian, factor or
  predictor moves it inside the tolerance, and the next solve divides that
  move by `dt`. C2's corpus run measured it: an operating point off by
  1.6e-6 of its tolerance became 60 times `abstol` one solve later
  ([section 1](#what-this-repository-already-measured)).
- **The one place a narrow number changes no published bit is a verdict.**
  The confirming iteration's Jacobian and solve produce only "converged".
  f32 lanes there ([H2](#h2-f32-lanes-on-the-confirming-iteration-only))
  are the form of G4 that leaves the published point alone, at about half
  of G4's gain. It needs no accuracy number. It is still an approximate
  confirm, which is C2's shape, so it is the owner's call.
- **An f32 factor with an f64 residual is closed on both machines.** It was
  built (`--lu-fast`), lost 2 to 32% on every deck and was deleted. Its
  ceiling is 1.5x to 2x of one phase, and it is safe only under a growth
  and condition guard, which is an accuracy number of the simulator's own
  ([ruled out on 2026-11-11](11-lever-gate.md#why-a-variable-against-the-standing-rule)).

## Sources and method

| What | Where |
|---|---|
| ESPice | The working tree of `dev/performance` on `9bbd4d7f`, read on 2026-11-11 |
| Kernel terms, card rates | [05-levers-gpu.md](05-levers-gpu.md#what-binds-each-kernel), `tools/gpu_devices.json` |
| Flops per evaluation | [12-math-and-contract.md](12-math-and-contract.md#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes) (a static model, not a counter) |
| Cycle shares, class budgets | [09-after-the-levers.md](09-after-the-levers.md#where-the-cycles-go), [02-baseline.md](02-baseline.md#the-confirming-iteration) |
| The C2 corpus runs | [13-implementation.md](13-implementation.md#c2-on-the-corpus) |
| The retired f32 work | `git show 9502bb6f^:dev/solvers/gpu-convergence.md` sections 7.5 and 9.5; `git show 9502bb6f^:dev/solvers/gpu-lu.md`, "fast_mode" |
| Gompute | `Gompute/AGENTS.md`, `Gompute/src/device/math.zig`, `Gompute/skill/gompute/OVERHEAD.md` lines 102 to 116 (`BENCH=math`, RTX 4060 Laptop) |
| VerA 0.23.0, pinned | `zig-pkg/vera-0.23.0-fzAu7BznSAHTovhsbqKB1WQBFu66b65RDnBfVhQi4EF9/lib/contract/family.zig` |
| This machine's CPU flags | `/proc/cpuinfo` on the i9-14900HX: `fma`, `avx2` and `f16c` present; `avx512f` and `avx512fp16` absent |
| Literature | [References](#references); fetched 2026-11-11 |

Symbols: `p` is the significand width in bits, `u = 2^-p` the unit
roundoff. `F(x)` is the KCL residual, `q` a charge, `J` the Jacobian, `κ`
a condition number.

## 1. Which numbers are the answer

The engine publishes `x_k`, the last linearization point
([the rule](07-prior-work.md#the-published-iterate-rule);
`src/solver/converger.zig:378` restores it). So the answer is an iterate.
Three kinds of number follow from that:

- **Answer**: its bits reach a raw file, or it sets the point Newton
  converges to.
- **Steer**: it changes which iterates are visited. The published point
  then moves within the tolerance. That is not "nothing".
- **Verdict**: a yes or no, or a minimum. Its bits are discarded.

| Quantity | Kind | Precision it needs | Why | What a narrower format changes |
|---|---|---|---|---|
| `x`, the unknowns | answer | f64 | Printed, and differenced: the next solve forms `C (v - v_prev) / dt` | Published bits; correctness at small `dt` |
| `F(x)`, the KCL sum | answer | f64 | Newton's limiting accuracy is `‖J^-1‖` times the error of `F` (Theorem 5.2 in [14]). KCL is a sum that cancels | Correctness at high-impedance nodes |
| `q` and the charge history | answer | f64 | Part of `F`: the current is a difference of charges over `dt` | Correctness at small `dt` |
| Time, breakpoints | answer | f64 | `t + dt` must differ from `t`: at `t` = 1 ms and `dt` = 1 ps the ratio 1e-9 is under f32's 6e-8 | Correctness |
| Published linearizations (AC, noise, sensitivities, operating-point `gm`; `Circuit.eval`) | answer | f64 | Printed | Published bits |
| `J`, its LU factors and the update, on an iteration that produces the next point | steer | f64 on the step that produces the published point | The rate, not the fixed point, depends on it: below | Iteration count, and the published point within the tolerance |
| The same on the confirming iteration | verdict | f32 where `κ u` is far below 1 | The update is tested and discarded | Nothing, unless the verdict flips at the edge |
| Limiting and device state | steer | f64 | It reads `x` and writes state; not bound by the FP rate | The iterate path |
| The convergence test itself | verdict | Any; its inputs are f64 already | A compare per row | Nothing |
| LTE and the step bound | steer of the grid | f32 accuracy is enough; f64 bits are needed to keep the grid | The divided difference's rounding noise sits `trtol reltol / (4 u)` = 7e-3 / 2.4e-7 = 2.9e4 under the LTE tolerance in f32 (computed here, a rough bound). But `dt` is published in the time column | Every transient raw's time bits; some accept or reject verdicts |
| Predictor and the `x` history it reads | steer | f32 | A starting guess | The iterate path |

### Where Newton is iterative refinement

Tisseur's result, as stated by Higham and Mary ([14], Theorems 5.2 and 5.3;
Tisseur's paper itself was not read): with an inexact Jacobian `J + E_i`
and a residual carrying error `ψ`, the iterates satisfy

```text
‖x_i+1 - x*‖ <= α_i ‖x_i - x*‖ + β_i
α_i ≈ ‖J^-1 E_i‖ + ‖J*^-1‖ ‖x_i - x*‖ + κ(J*) u
β_i ≈ ‖J*^-1‖ ψ + u ‖x*‖
```

"Errors in forming J and solving the linear system do not affect the
limiting accuracy, provided they are not too large ... they do, however,
affect the rate of convergence" ([14], after Theorem 5.2). Iterative
refinement is the same statement for `F(x) = b - Ax`.

So with an f64 residual, an f32 Jacobian or an f32 factor leaves Newton's
fixed point alone and adds a linear rate `ρ = ‖J^-1 E‖`. For entries
rounded to f32, `|E| <= u_f |J|`, so `ρ <= u_f cond(J)` with `u_f` =
6.0e-8 and `cond` Skeel's `‖|J^-1||J|‖` (computed here). For an f32 LU,
`ρ` is about `3n u_f ‖|J^-1||L||U|‖` ([13], equation 7.2). The role is the
one a held factor played in C2, which is rejected and deleted; its
measurement is [below](#what-this-repository-already-measured).

### Where it stops

Four places, each with its arithmetic (computed here):

1. **Cancellation in `F`.** The error of a KCL sum is `u Σ|I|`, and the
   solve divides it by the node's conductance. With 1 mA through a node of
   1e-6 S: f32 gives 6.0e-8 x 1e-3 / 1e-6 = 6.0e-5 V, 60 times `vntol`.
   At a node held only by `gmin` (1e-12 S): f64 gives 1.1e-16 x 1e-3 /
   1e-12 = 1.1e-7 V, a tenth of `vntol`; an f32 pair gives 3.6e-6 V at
   `u²` and 3.5e-5 V at its proven 9.8u². f64 itself has one digit to
   spare there.
2. **`q(t_n) - q(t_n-1)` over a small `dt`.** The noise current is
   `u |q| / dt`. For 1 nC stepped at 1 ps: f64 1.1e-13 A (0.11 `abstol`),
   an f32 pair 3.6e-12 to 3.5e-11 A (3.6 to 35 `abstol`), f32 6.0e-5 A.
   For 1 fC at 1 ps: f64 1.1e-19 A, the pair 3.6e-18 A, f32 6.0e-11 A.
3. **Ill-conditioned Jacobians.** The rate `ρ` reaches 1 near `cond(J)` =
   1/u_f = 1.7e7. Entries 1e15 apart sit in one matrix: `gmin` = 1e-12 S
   beside 1e3 S, and `force_g = 1e10` (`converger.zig:141`). In f32,
   `1e3 + 1e-9` is `1e3`: a 2 by 2 block `[G+g, -G; -G, G+g]` with `G` =
   1e3 and `g` = 1e-9 is exactly singular after rounding.
4. **The published point.** The step that produces `x_k` is the last one
   whose rounding the answer sees. With f64 it is a full Newton step and
   lands orders below the tolerance. With rate `ρ` it lands at `ρ` times
   the previous update. That update is at least one tolerance whenever the
   step took three or more iterations.

### What this repository already measured

C2 is not a mechanism any more: the owner rejected it on 2026-11-11 and
its code is deleted. Its corpus run stays as the measured warning against
every "this only steers convergence" argument. Four runs moved a converged
point by less than its tolerance, and each lost decks:

| Run | What moved | What the corpus did | Where |
|---|---|---|---|
| C2, the held-factor confirm | An operating point by 1.6e-6 of its tolerance (2.8e-9 V against 5.7e-10 V) | The first transient point carries `C (v - v_op) / dt`: supply currents 6.3e-11 A apart, 60 times `abstol`. 15 of 958 decks out at the first criterion, 3 at the last, 0 only at a bound of 1e-6 | measured, [13-implementation.md](13-implementation.md#c2-on-the-corpus) |
| `ESPICE_F32_PLANES`, Jacobian planes rounded through f32 on the host | The converged operating point, within `reltol` | `disto/bench_disto_bjt_ce`: the third-harmonic finite difference amplified it to 1.35% against 1e-3. `stress/vacask_graetz` stopped converging. 598 to 596 of 616. Newton iterations +0.22% | measured, `gpu-convergence.md` section 9.5 |
| `-Dgpu-jac-f32` | — | Four mos1 and mos6 decks off by 0.8 to 10%; 1.16x on `parallel_inverters_2000` | measured, [07-prior-work.md](07-prior-work.md#closed-in-this-codebase) |
| A build that published `x_k+1` | Every point by one Newton step | 10 decks at rtol 3e-3 | measured, [07-prior-work.md](07-prior-work.md#the-published-iterate-rule) |

**What C2 measured, in numbers.** The residual and the unknowns were
f64. Every accepted point passed the Newton test, on the held factor's
update. Only the solve was approximate. On
`stress/scaling_parallel_inverters_100` the last operating-point update
was 5.7e-10 V on the fresh factor and 2.8e-9 V on the held one, so the
two published points sat 2.2e-9 to 3.4e-9 V apart (the difference and the
sum of the two updates; computed here). The first
transient point has a tiny step and carries `C (v - v_op) / dt`. Both runs
converged there with residuals near 1e-18, on supply currents 6.3e-11 A
apart. That is an amplification of 6.3e-11 / (2.2e-9 to 3.4e-9) = 0.019
to 0.029 S (computed here): the node's `C / dt`. A move of a millionth of
the tolerance became 60 times `abstol`.

So an error far inside the Newton tolerance is not small. The next solve
multiplies it by `C / dt`, and the acceptance test of the solve that made
it cannot see that.

**What it means for a narrow Jacobian.** An f32 Jacobian on a producing
step moves the next point by up to `cond(J) u_f` times that step's update
([above](#where-newton-is-iterative-refinement)). With an update of 1 mV
that reaches C2's 2.2e-9 V at `cond(J)` = 2.2e-9 / (6.0e-8 x 1e-3) = 37
(computed here; an upper bound, since rounding errors do not all align).
Keeping the residual and the unknowns f64 and passing the deck's own
Newton test is therefore not enough to leave the answer alone. C2 did
both, with the test's update taken from an approximate solve, exactly as
an f32 Jacobian's would be. The condition that does is narrower: **the
step that produces a published point is a full f64 Newton step.**

`disto_bjt_ce` says the same from another side. It failed although its
linearizations were f64, so the two re-open conditions recorded for G4 (an
f64 retry on a Newton failure, f64 `Circuit.eval`) do not cover it.

## 2. Multi-word arithmetic

A double-word number is a pair `(h, l)` with `h = RN(h + l)`: the rounded
value and what rounding lost ([3], Definition 1.4). Its building blocks are
error-free transformations:

| Block | Operations | Source |
|---|---|---|
| Fast2Sum (needs `|a| >= |b|`) | 3 | [3], Algorithm 1 (Dekker) |
| 2Sum | 6 | [3], Algorithm 2 (Møller, Knuth) |
| Exact product with an FMA: `p = a b`, `e = fma(a, b, -p)` | 2 | [3], Algorithm 3 |
| Exact product without one (Veltkamp's split, Dekker's product) | 17 | [3], section 1; [7] attributes the split to Veltkamp |

The FMA form is exact when the product does not underflow: exponents must
satisfy `e_a + e_b >= e_min + p - 1` ([3]). In f32 that is -126 + 23 =
-103: a product under 2^-103 = 9.9e-32 loses its low word bit by bit, and
at 1.2e-38 the pair is an f32 (computed here).

### Formats

| | `p` | `u` | Range of normal numbers |
|---|---|---|---|
| f16 | 11 | 4.9e-4 | 6.1e-5 to 6.6e4 |
| f32 | 24 | 6.0e-8 | 1.2e-38 to 3.4e38 |
| f64 | 53 | 1.1e-16 | 2.2e-308 to 1.8e308 |

IEEE 754 values; [13], Table 1.2 lists the same `u` and decimal ranges.

| Word type | Bits carried | Proven relative error per operation | Against the next format up (computed here) |
|---|---|---|---|
| Pair of f16 | 22 | 2u² to 9.8u² = 2^-21 to 2^-18.7 | 8 to 39 times f32's `u` = 2^-24 |
| Pair of f32 | 48 | 2u² to 9.8u² = 7.1e-15 to 3.5e-14 (2^-47 to 2^-44.7) | 64 to 314 times f64's `u` = 2^-53 |
| Triple of f32 | 72 | 28u³ to 44u³ = 2^-67.2 to 2^-66.5 | 2^-14 of f64's `u`: more accurate, not identical |

Thall reports the same for an f32 pair on a GPU: "approximately 48 bits"
at single-precision exponent range, with measured errors of 1.1 to 4.5
units of the 48th bit for add, multiply, divide and square root ([9],
Table II). An earlier GPU pair is reported at 44 bits, on hardware whose
addition truncated ([12]).

### Operation counts and bounds

Pairs, with an FMA. Counts and "proven" bounds are [3], Table 1; the
"improved" bounds are the Coq-checked ones of [4], Table 1; the square
root is [5], Algorithm 8 and Theorem 3.6.

| Operation | Algorithm | Operations | Proven bound | Improved |
|---|---|---|---|---|
| pair + word | 4 | 10 | 2u² | — |
| pair + pair, sloppy | 5 | 11 | none: relative error 1 observed on mixed signs | — |
| pair + pair, accurate | 6 | 20 | 3u² + 13u³ | — |
| pair x word | 9 (FMA) | 6 | 2u² | — |
| pair x word | 7 | 10 | 1.5u² + 4u³ | — |
| pair x pair | 11 (FMA) | 8 | 6u² | 5u² |
| pair x pair | 12 (FMA) | 9 | 5u² | 4u² |
| pair / word | 15 | 10 | 3u² | — |
| pair / pair | 17 | 18 | 15u² + 56u³ | — |
| pair / pair | 18 (FMA) | 31 | 9.8u² (needs `p >= 13`) | — |
| sqrt(pair) | SQRTDWtoDW (FMA) | 8 | (25/8)u² | — |

The sloppy add matters here: a KCL row adds currents of both signs, which
is the case it has no bound for. Lange and Rump's cheaper unnormalized
pairs ([10]; about 8, 6, 7 and 5 operations for add, multiply, divide and
square root by hand count) are faithful only under their "no inaccurate
cancellation" condition, which a residual violates by design.

Triples ([6]):

| Operation | Operations | Proven bound |
|---|---|---|
| Add | 42, plus tests | — |
| Multiply, fast | 38 | 44u³ + 176u⁴ |
| Multiply, accurate | 46 | 28u³ + 107u⁴ |
| Reciprocal | 65 to 73 | — |
| Divide | 103 to 119 | 24u³ to 39u³, plus terms in u⁴ |
| Square root | 111 to 127 | — |
| Round to one word | 3, plus 4 tests | — |

Their own conclusion: triple-word arithmetic "is of interest for
implementing correctly-rounded transcendental functions" ([6]).

### `exp`, `log`, `pow`

No table-driven pair `exp` or `log` with a proven bound in f32 words was
found as a published algorithm. What exists:

- **The QD library** ([8], section 5): `exp` by reduction to `|r| <=
  ln 2 / 512` and a Taylor series; `log` by Newton on `exp`. No tables.
- **Correctly rounded libraries** (CORE-MATH [11], and CRlibm as [11]
  describes it): a fast path, a rounding test, and an accurate path;
  CRlibm's accurate path is in triples of f64, and [11]'s fast paths use
  pairs of f64. This is the mature table-driven form, one format up.
- **Gompute, in this workspace**: the device bodies of f32 `exp`, `log`,
  `sin` and `cos` are f32 pairs with FMA error terms, tables (64 rows for
  `exp`) and Ziv's test, with an f64 fallback on about 2^-13 of `exp`'s
  inputs (`math.zig`, `expfFast`: "~25 f32 ops and FMAs", good to about
  2^-40).
  Measured on the 4060: f32 `exp` 111.36 Gcalls/s against 4.87 for the f64
  body, f32 `log` 98.70 against 4.05 (`OVERHEAD.md`, `BENCH=math`).
- **Thall's GPU pair functions** ([9], Table II): errors of 10.6 units of
  the 48th bit for `exp`, 11.0 for `ln(1 + x)`, 241 for `cos`.

A pair `exp` good to 2^-45 needs a pair reduction, a two-word table row,
the leading polynomial terms in pairs and one pair multiply: about 60 f32
operations by hand count, `log` about 80, `pow` about 200.

### The plain answers

**Does a pair of f16 reach f32?** No, on four counts.

1. Bits: 22 carried, 18.7 to 21 proven, against 24.
2. Cost: 6 to 31 f16 operations for one f32 operation. A format with half
   the width has at most twice the lanes.
3. Range: f16's smallest normal number is 6.1e-5 and its largest 6.6e4
   ([13] calls overflow and underflow "quite likely" in half precision).
   `abstol` = 1e-12, `gmin` = 1e-12 and a 1 fF capacitor are not
   representable.
4. One bound in the table (Algorithm 18) is not even proven at `p` = 11.

**Does any target have a fast f16 FMA?**

| Target | f16 arithmetic | Source |
|---|---|---|
| This CPU (i9-14900HX) | Conversions only (`f16c`). No `avx512fp16` | measured: `/proc/cpuinfo` |
| Intel AVX-512 FP16 | "General-purpose numeric operations" on half precision, on the 4th generation Xeon Scalable | cited: [20], abstract page only; the guide's instruction list was not read |
| NVIDIA, PTX ISA 9.5 | `add`, `sub`, `mul`, `fma`, `neg`, `abs`, `min`, `max`, `tanh`, `ex2` on `.f16` and `.f16x2`, `sm_53` or higher. No f16 divide or square root. Throughput is not stated | cited: [19], section 9.7.4 |
| AMD CPUs and GPUs | not read | — |

So a fast f16 FMA exists on some Xeons and on NVIDIA cards. It does not
change the answer: where it exists, f32 is at least half as fast and
needs one operation.

**Does a pair of f32 reach f64?** No. It reaches 44.7 to 47 proven bits
against 53, at f32's exponent range. Against the tolerances that gap is
mostly harmless: `reltol` is 1e-3 and the pair's error is 3.5e-14. It
shows only where section 1 says cancellation eats the margin. Against the
bit-identity contract it is absolute: every value differs from the host's
near the 45th bit.

**Can three f32 words give f64's bits?** No. A triple is accurate to
2^-67, so its rounding to f64 is wrong whenever the exact result lies
within 2^-67 of a rounding boundary: about one operation in 2^13. BSIM4's
value path is 4,231 flops, so 4,231 / 8,192 = 0.5 misrounded operations
per evaluation (computed here). Exact f64 arithmetic from f32 words needs
the full 106-bit product, which is five words before rounding.

**Can the integer pipe give f64's bits?** In principle: IEEE arithmetic
in integer instructions is exact by construction. A multiply needs a
64 by 64 to 128-bit product, a normalization and a rounding, about 30
instructions by hand count. It closes on the chain: see the last row of
[the kernel table](#the-lane-kernel-on-the-4060).

## 3. Where it would pay

### What binds today

A narrower format can only help a kernel that waits on the FP64 pipe, on
value bytes, or on lanes. Measured, pages 05, 09 and 02:

| Kernel or phase | Machine | Binds on | A narrower format can reach |
|---|---|---|---|
| `arp_leval_bsim4va`, `arp_lchg_bsim4va` (lane sweeps) | 4060 | FP64 pipe: 4,499 and 1,136 µs terms | Yes |
| `arp_eval_bsim4va` (one circuit) | 4060 | FP64 pipe, 849 of 978 µs; memory 245 next | Yes, down to the memory term; the kernels are 6 to 38% of the wall |
| `arp_lu_refactor16` | 4060 | Memory traffic or the column chain (two readings) | Only its FP64 share |
| `arp_lu_upanel`, `arp_lu_lpanel`, tail solves | both cards | Chain | No |
| Every kernel | A100 | Chain or memory; FP64 terms 2 to 144 µs | No |
| Device evaluation | CPU | The core: 48% of slots retiring, the divider on 18% of samples | No: lanes are one µop already |
| Refactor | CPU | Memory, 12 bytes a pair; compute after C1 stage 2 | Value bytes, then lanes |
| LTE, solve, bookkeeping | CPU | Dependent chains | No |

### The budget per f64 operation

A narrow form pays when it costs fewer narrow operations than the card's
rate ratio.

| Machine | FP64 | FP32 | Budget: f32 operations per f64 operation | Source |
|---|---|---|---|---|
| RTX 4060 Laptop | 207 GFLOP/s | 12,550 GFLOP/s | 12,550 / 207 = 60.6 at the pipes' ceilings | measured, `tools/gpu_devices.json` |
| The same, at the rate real bodies reach | 4.87 Gcalls/s x 21 flops = 102 GFLOP/s | 111.36 Gcalls/s x 25 = 2,784 GFLOP/s | 2,784 / 102 = 27 | computed here from `BENCH=math`; the 25 and 21 are approximate counts |
| RTX A6000 | 605 GFLOP/s | 64 times that | 64 | `tools/gpu_devices.json` (datasheet ratio) |
| A100 | 9,700 GFLOP/s | 19,500 GFLOP/s | 2 | datasheet, [05-levers-gpu.md](05-levers-gpu.md#the-two-machines) |
| i9-14900HX, AVX2 | 4 lanes | 8 lanes | 2 | nominal |

| Operation | f32 operations | Gain on the 4060 at 60.6 | at 27 | On an A100 or the CPU (budget 2) |
|---|---|---|---|---|
| pair x pair | 9 | 6.7x | 3.0x | 4.5x slower |
| pair + pair, accurate | 20 | 3.0x | 1.4x | 10x slower |
| pair / pair | 31 | 2.0x | 0.9x | 15.5x slower |
| sqrt(pair) | 8 | 7.6x | 3.4x | 4x slower |
| triple x triple | 38 | 1.6x | 0.7x | 19x slower |
| triple + triple | 42 | 1.4x | 0.6x | 21x slower |

All computed here: gain = budget / operations. Triples do not pay on any
machine once the measured rate is used.

### BSIM4's value path in pairs

Page 12's flop model of one BSIM4 evaluation: 1,478 add and multiply
flops, 252 divides, 48 square roots, 67 `exp`, 27 `log`, 1 `pow`; 4,231
value flops and 7,151 lane flops, so `d` = 7,151 / 11,382 = 0.63.

```text
f32 operations for the value path (computed here; exp, log, pow by hand count)
add, mul   1,478 x 9..20   = 13,302 .. 29,560
divide       252 x 18..31  =  4,536 ..  7,812
sqrt          48 x 8       =    384
exp           67 x 60      =  4,020
log           27 x 80      =  2,160
pow            1 x 200     =    200
total                        24,602 .. 44,136
```

Against 4,231 f64 flops that is 5.8 to 10.4 f32 operations per flop. In
FP64-equivalents at 60.6 it is 406 to 728: the value side's FP64 work
falls 5.8x to 10.4x. At 27 it falls 2.6x to 4.6x.

### The lane kernel on the 4060

`arp_leval_bsim4va` on the 8,192-point transient sweep, with the terms of
`tools/gpu_extrapolate.py` ([05](05-levers-gpu.md#what-binds-each-kernel)).
The first row is measured; the others are computed here. Instructions per
evaluation are taken as 11,382 / 0.43 = 26,470 (page 05: 43% of the
kernel's instructions are FP64).

| | fp64 | FP32 work | issue | mem | lat | Binds | µs per launch |
|---|---|---|---|---|---|---|---|
| Today | 4,499 | — | 172 | 711 | 458 | FP64 pipe | 3,692 measured |
| G4: lanes in f32 | 4,499 x 4,231 / 11,382 = 1,672 | 47 | 172 | 711 | 458 | FP64 pipe | 3,692 x 0.382 = 1,410 |
| G4 and pair values | fallbacks only | 207 to 334 | 304 to 431 | 711 | 810 to 1,148 | chain, then memory | 810 to 1,150 |
| G4 and exact f64 in the integer pipe | 0 | — | 970 | 711 | 2,580 | chain | 2,580: loses to G4 |

- G4's factor: (4,231 + 7,151 / 60.6) / 11,382 = 0.382.
- Pairs: instructions go 26,470 to 26,470 - 4,231 + (24,602..44,136) =
  46,841..66,375, which is 1.77x to 2.51x. The issue and latency terms
  scale with that.
- Integer pipe: 26,470 - 4,231 + 4,231 x 30 = 149,169 instructions, 5.6x.
  It would have to cost under 14 instructions per f64 operation to match
  G4.

The roofline bound before the gain: after G4 the kernel is still
FP64-bound, so pairs have something to remove. Once they remove it, the
bound is one warp's own instruction chain, which pairs lengthen. That is
G8's subject, and on an FP64-class card it binds already.

The sweep's wall (9.45 s, of which kernels 6.97 s and this kernel 71%;
14.6 s on the CPU; all measured, page 05):

| | This kernel | Wall | Against today |
|---|---|---|---|
| Today | 4.95 s | 9.45 s | — |
| G4 | 4.95 x 0.382 = 1.89 s | 2.48 + 2.02 + 1.89 = 6.39 s | 1.48x |
| G4 and pair values | 1.09 to 1.54 s | 5.59 to 6.04 s | 1.56x to 1.69x |
| H2: f32 lanes on the confirming iteration only | 4.95 x (1 + 0.382) / 2 = 3.42 s | 7.92 s | 1.19x |

Pair values add 1.06x to 1.14x over G4. `arp_lchg_bsim4va` is FP64-bound
too (an FP64 term of 1,136 µs against 1,120 measured) and holds values
only, so pairs would shorten it and G4 does not; its share of the other
2.02 s was not read. The pair rows assume the temporaries fit: the kernel
already uses 255 registers a thread.

Page 05 priced G4 at a wall of about 5 s with `d` = 0.8. With page 12's
`d` = 0.63 it is 6.4 s.

### On a full-rate FP64 card, and on the CPU

| Where | Bound today | What pairs or f32 do | Result |
|---|---|---|---|
| A100, lane kernel | chain: 663 µs of 144 / 83 / 158 / 663 | Pipe work 2.9x to 5.2x (24,602..44,136 against 2 x 4,231); chain 1.77x to 2.51x | 663 to 1,170..1,660 µs: loses 1.8x to 2.5x |
| A100, any kernel, f32 in place of f64 | chain or memory; FP64 terms are 2 to 144 µs | Halves a term that does not bind | Nothing |
| CPU, device evaluation, f32 lanes | The core: 48% retiring; "a lane operation is one µop at any width up to four", and no BSIM4 value carries more than 5 lanes (page 12) | A 5-lane value takes one µop instead of two | Page 12's verdict stands: no |
| CPU, device evaluation, pair values | The divider and the instruction stream | 9 to 31 operations where f64 takes one | Loses 4.5x to 15.5x per operation |
| CPU, refactor, f32 values | Memory: 12 bytes a pair, 8 after C1 stage 1; compute after stage 2 | 12 to 8 bytes (1.5x), 8 to 4 (2x), 4 to 8 lanes (2x) | At most 1.5x to 2x of the phase: [section 4](#the-ceiling-and-what-was-measured) |
| CPU, LTE in f32 | The divider: a chain of eight divisions a state (N7) | `VDIVPS ymm` 5 cycles for 8 against `VDIVPD ymm` 8 for 4: 3.2x per element ([21]) | At most 1.07x on `rc_ladder_1000` (9.4% of one thread), 1.01x on `chain_bsim4_1k` (1.5%); every transient raw's time bits move. Closed |

AVX-512 would double both lane counts and change no ratio. This CPU has
none.

## 4. Mixed-precision linear solves

### What the literature proves

Factor in a low precision `u_f`, compute the residual in the working
precision or above, refine.

| Refinement | `u_f` | Converges for | Source |
|---|---|---|---|
| LU-based | f32 | `κ∞(A)` up to 1e8 | [13], Table 7.1 |
| LU-based | f16 | 1e4 | [13], Table 7.1 |
| GMRES preconditioned by the factors | f32, residual in f128 | 1e16 | [13], Table 8.1 |
| GMRES preconditioned by the factors | f16, residual in f128 | 1e12 | [13], Table 8.1 |

The rate is `ψ(n) κ(A) u_f` ([15]; [13] sharpens it to
`3n u_f ‖|A^-1||L||U|‖`). The condition is "essentially `c_n κ(A) u_ℓ <
1`" ([14], section 5.1).

What was measured on sparse matrices:

- Langou and others, 147 matrices: 15 with a condition number near 1e8
  did not converge and 18 overflowed in f32 ([15]).
- Buttari and others, 41 matrices: with MUMPS the mixed form is usually
  close to f32 speed; SuperLU's f32 factor is at most about 30% faster than
  its f64 one; when it loses, by 7% on average ([16]).
- Zounon and others: "the anticipated speedup of 2 over a double precision
  LU factorization is obtained only for the very largest of our test
  problems". Half of their matrices pass 1.5x serially. An f32 factor can
  be slower than f64: fill-in cascades produce subnormal numbers in f32
  (one MUMPS factor took 3.59 s in f32 against 1.63 s in f64) ([17]).
- Amestoy and others: the f32 factorization is roughly twice as fast only
  where the factor dominates and scales; less in parallel ([18]).

No published simulator was found that factors in f32, keeps an f64
residual and lets Newton do the refining. Page 07 has the closest: GLU3.0
in single precision, and Kapre and DeHon's FPGA evaluation (only its
abstract page was read here, so the tolerances page 07 quotes from it were
not re-verified).

### Circuit Jacobians

"Circuit simulation matrices also vary from being positive definite to
being extremely ill-conditioned" ([22], section 6). The SuiteSparse
collection publishes a 2-norm condition number per matrix ([23]):

| Matrix | n | `κ₂` | Against f32's limit of 1e8 |
|---|---|---|---|
| Sandia/adder_trans_01 | 1,814 | 4.93e3 | inside |
| Hamm/add20 | 2,395 | 1.20e4 | inside |
| Hamm/memplus | 17,758 | 1.29e5 | inside |
| Bomhof/circuit_1 | 2,624 | 1.95e5 | inside |
| Sandia/adder_dcop_01 | 1,813 | 3.27e7 | at the edge |
| Grund/meg4 | 5,860 | 4.19e10 | outside |
| Sandia/oscil_dcop_01 | 430 | 5.88e12 | outside |
| Sandia/fpga_dcop_01 | 1,220 | 1.82e17 | outside (rank deficient by 1) |
| Rajat/rajat01 | 6,833 | 4.29e22 | outside (null space of 56) |

Two cautions. These are unscaled, and the quantity in the convergence
condition is Skeel's `cond(A)`, which row scaling cannot inflate, so `κ₂`
overstates the hard cases. And the pattern is the one section 1 predicts:
transient matrices (`adder_trans`) carry `C / dt` on the diagonal and are
well conditioned; operating-point matrices (`*_dcop`) are not.

No condition number of this corpus has been measured. `src/solver` has no
estimator: KLU's `klu_condest`, `klu_rcond` and `klu_rgrowth` ([24]) have
no counterpart. What it has that an estimator needs:

- `replayHolds` (`src/solver/direct.zig:492`) already forms `‖A‖₁` and
  `‖A‖∞` and solves a probe both ways, with A and with its transpose.
  Hager's 1-norm estimator is four or five such solve pairs.
- `maxMultiplier` (`direct.zig:730`) and the growth monitor
  (`refactor_growth_limit = 1e-12`) see element growth.
- The LAWN 41 scaled residual of `residual_tests.zig` measures backward
  error (1.6e3 full, 6.0e3 replay over 2,000 seeded systems).

[H3](#h3-a-condition-census-in-the-solver) is that census.

### Newton as the refinement

It holds, by section 1, and `gpu-convergence.md` section 7.5 said so
first: "Newton's fixed point is set by the f64 residual, so the Jacobian's
precision affects only the rate". It is the role the held factor played
in C2, with `ρ` of about `cond u_f` in place of a chord rate.

It is also what the owner ruled on. C2 kept the residual exact, kept the
published point at `x_k` and changed only the solve. It needed a bound of
its own, passed the corpus only at 1e-6 of the Newton tolerance, and is
deleted. An f32 factor is the same lever with a smaller, matrix-dependent
`ρ`, and it needs two numbers SPICE does not have: a growth limit for f32
(the deleted fast mode used 1e-6 where the f64 path uses 1e-12) and a
condition bound past which the factor is redone in f64.

### What breaks

- **Pivoting.** The f64 pivot tape is replayed on f32 values. The growth
  monitor cannot run at 1e-12 in f32; the deleted fast mode used 1e-6.
- **`gmin` beside large entries.** Section 1, item 3: after rounding to
  f32 a floating node's only path to ground is gone, and the matrix is
  singular.
- **Singular detection.** An f32 factor reports singular or huge growth
  where the f64 one succeeds. The answer is an f64 refactor, which needs a
  rule for when: a number.
- **Subnormals.** [17]'s cascade needs long elimination chains, which a
  10k-instance factor has (inferred; not measured here).
- **Range.** A product of two SI doping densities (1e26 x 1e23 = 1e49)
  overflows f32. Such products sit in setup code, which stays f64, but
  nothing proves the stamps free of them.

### The ceiling, and what was measured

The roofline bound first: the host refactor is memory-bound today (12
bytes a pair), and compute-bound only after
[C1](04-levers-cpu.md#c1-supernode-panels-in-the-refactor-replay) stage 2.

| `logic_bsim4_10k` (thickest deck) | Refactor | Wall | f32 saves at most | Wall after |
|---|---|---|---|---|
| Today, 12 to 8 bytes a pair | 32.4 s | 50.1 s | 32.4 x (1 - 1/1.5) = 10.8 s | 39.3 s, 1.27x |
| Today's phase, if values were its only stream (8 to 4 bytes) | 32.4 s | 50.1 s | 16.2 s | 33.9 s, 1.48x |
| After round 3 | 6.0 s | about 13 s | 3.0 s | 1.30x |
| After round 4 | 1.9 s | about 6 s | 0.95 s | 1.19x |

Computed here from page 09's class budgets. These are ceilings with no
refinement cost and no extra iteration.

Measured, the deleted `--lu-fast` (f64 full factor and pivots, f32 replay,
equilibration, refinement to a backward error of 16u, GMRES fallback;
`gpu-lu.md`):

| | Serial f64 | Serial f32 with refinement | 8 lanes f64 | 8 lanes f32 with refinement |
|---|---|---|---|---|
| `sram_bsim4_1k` | 1.71 s | 2.25 s | 1.60 s | 1.94 s |
| `logic_bsim4_1k` | 5.05 | 6.32 | 4.00 | 4.64 |
| `sram_bsim4_10k` | 38.6 | 46.0 | 27.3 | 28.4 |
| `logic_bsim4_10k` | 183.6 | 186.6 | 85.7 | 183.8 |

Over 530 decks: 2.20 refinement steps a solve, 37 fallbacks in 4.5 M
solves. On `vacask_graetz`: 5.34 steps, and 35% of 2.0 M solves fell back.
It lost on every deck.

On the device: the 4060's refactor is 10,290 µs with terms 5,885 (FP64) /
3,061 / 13,111 (memory) / 15. f32 values remove the FP64 term and 4 of 84
bytes a pair. Under the memory reading the term goes to 13,111 x 80 / 84 =
12,490 µs: 1.05x. Subtracting the tool's whole FP64 term gives 10,290 -
5,885 = 4,405 µs: 2.3x. The truth is between, on a kernel whose expected
verdict after C1 is "host"
([G2](05-levers-gpu.md#g2-supernode-panels-in-the-device-lu)). On an A100
the FP64 term is 126 of 2,290 to 4,570 µs.

## 5. What each idea does to the contracts

Device math gives the same bits everywhere by one of two routes: one body
with no optional contraction, or correct rounding (`Gompute/AGENTS.md`). A
pair body written with explicit `@mulAdd` is one body, so a host
instantiation of it equals the device bit for bit. That is an oracle for
the kernel. It is not the f64 host path.

VerA's contract says "Values are bit-exact except the transcendentals"
(`family.zig:35`) and lets only the lanes be narrower (`family.zig:79-81`).
A pair-valued family is outside it.

None of the ideas touches a reduction order, so each keeps 1 job equal to
N jobs if its bodies are straight-line. A refinement loop's step count
depends on the data, never on the thread count.

| Idea | Class | CPU and GPU agree in bits | Oracle that catches a wrong number |
|---|---|---|---|
| Pair-of-f32 values on the device | tolerance at best; outside VerA's value contract | No: every value differs near the 45th bit | The KCL certificate (`-Dcertify`) for a wrong `F`; the host pair instantiation, bit for bit; the f64 kernel within the deck tolerance; [H1](#h1-the-bit-census) |
| G4, f32 lanes on every iteration | tolerance | No | The f64 lane kernel within tolerance; the corpus by name. Expected to lose decks by section 1, item 4 |
| H2, f32 lanes on the confirming iteration | exact while no verdict flips; tolerance by the letter | Yes, on every step whose verdict agrees | Corpus raws byte-identical against the f64 kernel; the flips, by name |
| f32 Jacobian and factor, f64 residual | tolerance, and only under a guard number | No | LAWN 41 scaled residual in f32 units; the corpus |
| f32 LTE | mode by the README's letter: the time grid's bits change | Yes if both do it | ngspice's grid in the corpus |
| Correctly rounded f64 `exp` and `log` with an f32-word device body | rounding, once, on both targets | Yes, by correct rounding | Gompute's f128 oracle |
| f64 in the integer pipe | exact | Yes | Bit for bit |

## Levers

### H1 The bit census

**Class:** measurement. A throwaway patch like `census.patch`; no bit, no
shipped path. **Files:** `src/device/dual.zig`.

**Today.** No number says how many value bits a model needs, how often an
f32 confirm would flip a verdict, or which decks G4 would lose on the
current tree. Each precision idea on this page waits on one of them.

**Change.** Generated code never opens a value, so the family can round.
A comptime `k` rounds every value result to `k` bits with Veltkamp's
split: `c = x (2^(53-k) + 1)`, `h = c - (c - x)`, three operations. Three
settings answer three questions on the host, with no GPU:

1. `k` = 45 and 47 on values: the decks a pair-of-f32 value path loses.
2. Lanes through f32 on every iteration: G4 on today's corpus.
3. Lanes through f32 on the confirming iteration only: H2's flips.

**Expected gain.** None. It prices G4, H2 and pairs before any kernel is
written.

**Oracle.** `k` = 53 leaves every raw byte-identical. Red first: `k` = 52
must move a raw.

**First step.** Setting 3 on the 15 decks of
[the C2 table](13-implementation.md#c2-on-the-corpus). Done when the
number of verdict flips and of moved raws is known.

### H2 f32 lanes on the confirming iteration only

**Class:** exact while no verdict flips; tolerance by the letter, since a
flip publishes a different iterate. No accuracy number of its own. An
owner decision all the same: it is an approximate confirming solve, which
is the shape of the lever the owner removed.
**Machine:** cards with FP64 at 1/64 of FP32. **Files:** `src/device/dual.zig`
(the lane element type, [M6](12-math-and-contract.md#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes)),
the lane kernels of `src/analysis/gpu`.

**Today.** Every lane evaluation is f64. G4 as briefed puts f32 lanes on
every iteration, which changes the step that produces the published point.

**How it differs from C2.** Three things. It carries no number: the test
is the deck's own `reltol`, `vntol` and `abstol`, unchanged. Its
perturbation is `cond(J) u_f` of an update already under the tolerance,
where the held factor's was a chord rate. And its update is never used as
a point: C2's moves came from held updates that became the next
linearization point when a later gate refused the accept. What it shares
with C2 is the one thing that cannot be removed: the verdict comes from an
approximate solve, so a flip at the edge of the test is possible.

**Change.** Iteration 1 is never accepted, so it stays f64. From
iteration 2 an evaluation runs with f32 lanes first. If its verdict is
"converged", `x_k` is published as today, and every bit of it came from
f64 steps. If not, the iteration is repeated in f64 and its f64 update
is taken. No f32 update ever becomes a linearization point, which is the
leak that sank C2 ("it survives when a later gate refuses the accept").
Dispatch is per launch: two kernels, one batch each. It assumes nothing
later reads the confirming iteration's Jacobian planes. The LTE does not:
it reads charges, currents and the Gear history
(`src/analysis/tran/integrator.zig:488`). A bypass that replays stamps
would.

**Expected gain** (computed here, with `d` = 0.63). A two-iteration step
costs 1 + 0.382 against 2: 1.45x on the kernel. A three-iteration step
costs 1 + (0.382 + 1) + 0.382 = 2.76 against 3: 1.09x. On the host decks
47 to 50% of factors are confirming on the chain, ring and sram circuits
and 33% on `logic` ([02](02-baseline.md#the-confirming-iteration)), so
two-iteration steps dominate. The sweep goes 9.45 s to about 7.9 s where
G4 reaches 6.4 s. The share of confirming launches on the sweep itself is
not measured.

**Oracle.** The f64 lane kernel: raws byte-identical on every deck with
no flip. A flip is an f32 "converged" where f64 says "not"; each is named.
Page 02's held-factor census is the nearest evidence: a held factor, far
cruder than an f32 Jacobian, flipped 0 of 1.6 M verdicts at a margin of 0.5 and at most
11 of 500,027 at a margin of 1.0.

**First step.** H1, setting 3. Then this is G4's fallback: build it if
G4's gate loses decks again.

### H3 A condition census in the solver

**Class:** measurement; prints under the existing statistics switch and
changes no value. **Files:** `src/solver/direct.zig`.

**Today.** No condition number of any corpus matrix is known. Every "f32
is enough when `κ u_f` is small" on this page, and N2's "moves within
rounding", rests on a number nobody has.

**Change.** On each full factor, Hager's estimate of `‖A^-1‖₁` with the
A and transpose solves `replayHolds` already calls, times `‖A‖₁`; and the
same estimator on `A^-1 diag(|A| e)` for Skeel's `cond`. Print the largest per
deck and per analysis.

**Expected gain.** None. It says what fraction of the corpus has
`cond u_f` under 1e-3, where an f32 verdict cannot flip in practice, and
which decks sit past 1e8.

**Oracle.** The exact `κ₁` from a dense inverse on the small decks. The
estimate is a lower bound, so it must never exceed it. KLU ships the same
estimator as `klu_condest` ([24]).

**First step.** The 15 decks of the C2 table and `vacask_graetz`.

## 6. Verdict and ranking

"Ceiling" is computed here unless marked measured. Rows are ordered by the
owner's rule first and by ceiling second: what cannot change the published
answer, then what moves it with no number of its own, then what needs a
number. "Answer" says what happens to the published values.

| # | Idea | Class | Needs a new accuracy knob? | Answer | Where it pays | Ceiling | Risk | Verdict and first step |
|---|---|---|---|---|---|---|---|---|
| 1 | [H1](#h1-the-bit-census), [H3](#h3-a-condition-census-in-the-solver): the two censuses | measurement | No | Unchanged | — | — | — | **First.** They decide rows 2, 3 and 6 |
| 2 | [H2](#h2-f32-lanes-on-the-confirming-iteration-only): f32 lanes on the confirming iteration only | exact unless a verdict flips | No: the test is the deck's own | Unchanged, bit for bit, on every step whose verdict agrees. Every published point comes from f64 steps | Lane sweeps on FP64-poor cards | Kernel 1.09x to 1.45x; sweep 9.45 to about 7.9 s (1.19x) | A wasted f32 evaluation on every non-converged try; a flip publishes one iterate early; it is C2's shape | Open, owner's call. H1 setting 3 |
| 3 | G4: f32 derivative lanes on every iteration | tolerance | No | Moves inside the tolerance on every step: the producing step is no longer a full f64 Newton step | The same | Kernel 2.6x; sweep to 6.4 s (1.48x), not the 5 s page 05 states | The `C / dt` amplification C2 measured; lost 2 and 4 decks in its two earlier forms | Open, behind row 2. H1 setting 2 before any kernel |
| 4 | Correctly rounded f64 `exp` and `log`, f32-word device body (triples, Ziv's test, f64 fallback) | rounding, once | No | Every raw moves once in its last bits, on CPU and GPU alike; CPU and GPU stay equal | FP64-poor cards after G4 | Value-side FP64 work 1.5x; kernel about 1.3x, chain-bound (hand counts: 400 operations a call) | A proof of correct rounding for two functions on two targets; a slower host `exp` | Not now. Reprice after G8 |
| 5 | f64 in the integer pipe | exact | No | Unchanged by construction | FP64-poor cards | Loses to G4 unless under 14 instructions per operation | — | **Closed** on the latency term |
| 6 | Pair-of-f32 values on FP64-poor GPUs | tolerance at best; outside VerA's value contract | No knob exists that would make it safe: `F` and `q` themselves lose 6 to 8 bits | Moves: every value differs from the host's near the 45th bit | Lane sweeps, after G4 | Kernel 1.2x to 1.7x over G4; sweep 1.06x to 1.14x over G4 | CPU and GPU bits part; `gmin` nodes; f32 exponent range; 255 registers | **Closed** until G8 lands: the chain binds. H1 setting 1 reprices it |
| 7 | f32 LTE and step control | mode by the letter | No | The time grid's bits move on every transient | Linear decks | 1.07x on `rc_ladder_1000`, 1.01x on BSIM4 chains | Accept or reject flips | **Closed** |
| 8 | f32 Jacobian and factor, f64 residual, CPU | tolerance | **Yes**: an f32 growth limit and a condition bound | Moves inside the tolerance; singular in f32 at `gmin` nodes | Thick factors | 1.27x today, 1.19x after round 4, before refinement cost | Subnormals; f64 fallbacks | **Closed**: measured -2% to -32% with refinement; without it, it is the lever the owner removed |
| 9 | The same on the GPU | tolerance | **Yes**, the same two | The same, and CPU and GPU part | 4060 device LU | 1.05x to 2.3x of one kernel; nothing on an A100 | The same | **Closed**: the kernel's own verdict is "host" |
| 10 | Pair values on an A100 or the CPU | — | — | — | Nowhere | Loses 1.8x to 2.5x on the kernel, 4.5x to 15.5x per operation | — | **Closed**: the budget is 2 operations |
| 11 | Pairs of f16 | — | — | — | Nowhere | — | — | **Closed**: 22 bits under 24, 6 to 31 operations for one, range |
| 12 | Triples of f32, or f64's bits from f32 words | — | — | Misrounds 0.5 operations per evaluation | Nowhere | 0.6x to 1.6x per operation on the 4060 | — | **Closed** |

No row is "unchanged by construction" and also pays. Row 5 is, and loses.
Row 2 is unchanged unless a verdict flips, and needs no number. Everything
with a larger ceiling moves the answer.

Row 4's arithmetic: `exp` and `log` are 67 x 21 + 27 x 25 = 2,082 of the
4,231 value flops. At 400 f32 operations a call, 94 calls are 37,600
operations, 620 FP64-equivalents: the value side goes to 2,769 (1.53x).
Instructions go 2.34x, so the latency term is 458 x 2.34 = 1,070 µs
against G4's 1,410.

Read as an answer to the owner's question: the arithmetic is real and
proven, and Gompute already ships it one format down. It buys speed only
where FP64 is rationed, which is one laptop card class, and there the
lane kernel stops being FP64-bound before the pairs have paid for
themselves. The accuracy that can be given up without moving a published
bit is the verdict of the confirming iteration, and nothing else.

## What this changes on other pages

- [05, G4](05-levers-gpu.md#g4-f32-derivative-lanes-on-fp64-poor-cards)
  prices the sweep at about 5 s with `d` = 0.8. With page 12's `d` = 0.63
  it is 6.4 s. Its step 2 asks VerA for f32 lanes; page 12 (M6) already
  says the contract allows them.
- G4's re-open conditions, here and on
  [07](07-prior-work.md#closed-in-this-codebase), do not cover the
  mechanism that failed `disto_bjt_ce` and, on 2026-11-11, C2.
- [07](07-prior-work.md#the-published-iterate-rule) cites
  `converger.zig:354`; in the working tree the restore is at line 378.
- `OVERHEAD.md` says f64 "runs at 1/64 rate"; its own table gives 22.9x
  for `exp` and 24.4x for `log` between the f32 and f64 bodies. The pipe
  ratio is a ceiling, not the rate a kernel sees.

## Not determined

- How many value bits each model needs: no run has rounded values (H1).
- Verdict flips of an f32 confirming Jacobian, and the share of
  confirming launches in a lane sweep (H1, H2).
- The condition number of any corpus Jacobian (H3).
- `d`, measured. 0.63 is page 12's static model.
- The operation counts of a pair `exp`, `log` and `pow` (60, 80, 200), of
  a triple `exp` (400) and of an integer f64 operation (30) are hand
  counts. None was built.
- Whether pair temporaries fit the lane kernel's 255 registers.
- Whether anything on the lane path reads the confirming iteration's
  Jacobian planes after the verdict (H2 assumes not).
- Whether any model's core forms a product outside f32's exponent range
  or under 9.9e-32.
- The wall of an f32 factor with no refinement. Only the form with
  refinement was built.
- f16 throughput on NVIDIA cards, f16 arithmetic on AMD hardware, and
  which Intel parts beyond the 4th generation Xeon carry AVX-512 FP16.
- Not read: Dekker 1971 and Knuth's 2Sum (cited through [3]); Tisseur
  2001 (the server returned 401; cited as stated in [14]); Göddeke,
  Strzodka and Turek 2007 (404); Carson and Higham 2017; Haidar and
  others 2018 beyond the abstract; Dembo, Eisenstat and Steihaug 1982;
  the body of Intel's FP16 guide; the body of Kapre and DeHon 2009.

## References

1. T. J. Dekker. A floating-point technique for extending the available precision. Numerische Mathematik 18, 1971. Not read; cited through [3].
2. D. E. Knuth. The Art of Computer Programming, volume 2 (2Sum). Not read; cited through [3].
3. M. Joldes, J.-M. Muller, V. Popescu. Tight and Rigorous Error Bounds for Basic Building Blocks of Double-Word Arithmetic. ACM TOMS 44(2), 2017. Sections 1 to 6, Table 1. https://hal.science/hal-01351529v3
4. J.-M. Muller, L. Rideau. Formalization of Double-Word Arithmetic, and Comments on "Tight and Rigorous Error Bounds for Basic Building Blocks of Double-Word Arithmetic". ACM TOMS 48(1), 2022. Table 1. https://hal.science/hal-02972245v2
5. V. Lefèvre, N. Louvet, J.-M. Muller, J. Picot, L. Rideau. Accurate Calculation of Euclidean Norms Using Double-Word Arithmetic. ACM TOMS 49(1), 2023. Algorithm 8, Theorem 3.6. https://hal.science/hal-03482567v2
6. N. Fabiano, J.-M. Muller, J. Picot. Algorithms for Triple-Word Arithmetic. IEEE Transactions on Computers 68(11), 2019. https://hal.science/hal-01869009
7. J. R. Shewchuk. Adaptive Precision Floating-Point Arithmetic and Fast Robust Geometric Predicates. Discrete & Computational Geometry 18, 1997. Read for the split and its attribution; its expansion-sum counts were not used. https://people.eecs.berkeley.edu/~jrs/papers/robustr.pdf
8. Y. Hida, X. S. Li, D. H. Bailey. Library for Double-Double and Quad-Double Arithmetic. Technical report, 2007 (ARITH-15, 2001). Section 5. https://www.davidhbailey.com/dhbpapers/qd.pdf
9. A. Thall. Extended-Precision Floating-Point Numbers for GPU Computation. 2006, addendum 2009. Table II. http://andrewthall.org/papers/df64_qf128.pdf
10. M. Lange, S. M. Rump. Faithfully Rounded Floating-point Computations. ACM TOMS 46(3), 2020. https://www.tuhh.de/ti3/paper/rump/LaRu2017b.pdf
11. A. Sibidanov, P. Zimmermann, S. Glondu. The CORE-MATH Project. ARITH 2022. Sections I and II. https://hal.science/hal-03721525v3
12. G. Da Graça, D. Defour. Implementation of float-float operators on graphics hardware. 2006. Read in part. https://arxiv.org/abs/cs/0603115
13. E. Carson, N. J. Higham. Accelerating the Solution of Linear Systems by Iterative Refinement in Three Precisions. SIAM J. Sci. Comput. 40(2), 2018; read as MIMS EPrint 2017.24. Tables 1.2, 7.1, 8.1, equation 7.2, section 6. https://eprints.maths.manchester.ac.uk/2562/
14. N. J. Higham, T. Mary. Mixed Precision Algorithms in Numerical Linear Algebra. Acta Numerica 31, 2022; read as MIMS EPrint 2021.20. Section 5.1 (Theorems 5.2 and 5.3, after Tisseur 2001), section 7.6. http://eprints.maths.manchester.ac.uk/
15. J. Langou, J. Langou, P. Luszczek, J. Kurzak, A. Buttari, J. Dongarra. Exploiting the Performance of 32 bit Floating Point Arithmetic in Obtaining 64 bit Accuracy. LAPACK Working Note 175, 2006. https://www.netlib.org/lapack/lawnspdf/lawn175.pdf
16. A. Buttari, J. Dongarra, J. Kurzak, P. Luszczek, S. Tomov. Using Mixed Precision for Sparse Matrix Computations to Enhance the Performance while Achieving 64-bit Accuracy. ACM TOMS 34(4), 2008; read as LAPACK Working Note 180. https://www.netlib.org/lapack/lawnspdf/lawn180.pdf
17. M. Zounon, N. J. Higham, C. Lucas, F. Tisseur. Performance Impact of Precision Reduction in Sparse Linear Systems Solvers. PeerJ Computer Science 8:e778, 2022; read as MIMS EPrint 2020.21. http://eprints.maths.manchester.ac.uk/
18. P. Amestoy, A. Buttari, N. J. Higham, J.-Y. L'Excellent, T. Mary, B. Vieublé. Combining Sparse Approximate Factorizations with Mixed Precision Iterative Refinement. ACM TOMS 49(1), 2023. Section 4, read in part. https://hal.science/hal-03536031v2
19. NVIDIA. Parallel Thread Execution ISA, version 9.5, section 9.7.4, Half Precision Floating-Point Instructions. https://docs.nvidia.com/cuda/parallel-thread-execution/index.html
20. Intel. Intel AVX-512 - FP16 Instruction Set for Intel Xeon Processor Based Products, Technology Guide, document 669773, 2024. Abstract page only. https://www.intel.com/content/www/us/en/content-details/669773/intel-avx-512-fp16-instruction-set-for-intel-xeon-processor-based-products-technology-guide.html
21. uops.info, Alder Lake-P rows of `VDIVPD ymm` and `VDIVPS ymm`. Published figures, not measurements of this round. https://uops.info/html-instr/VDIVPD_YMM_YMM_YMM.html , https://uops.info/html-instr/VDIVPS_YMM_YMM_YMM.html
22. M. Bollhöfer, O. Schenk, R. Janalík, S. Hamm, K. Gullapalli. State-of-The-Art Sparse Direct Solvers. arXiv:1907.05309, 2019. Section 6. https://arxiv.org/abs/1907.05309
23. SuiteSparse Matrix Collection, per-matrix pages (condition numbers from the collection's SVD statistics). https://sparse.tamu.edu/Sandia/adder_dcop_01 and the same path for each matrix named.
24. T. A. Davis, E. Palamadai Natarajan. KLU User Guide, version 2.3.6, 2025. `klu_condest`, `klu_rcond`, `klu_rgrowth`. https://raw.githubusercontent.com/DrTimothyAldenDavis/SuiteSparse/dev/KLU/Doc/KLU_UserGuide.pdf
