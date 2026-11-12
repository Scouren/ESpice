# Math and the contract: what Gompute and VerA can give device evaluation

This page asks where device-model evaluation can get faster through its two
dependencies: Gompute (the device math, same bits on CPU and GPU) and VerA
(the Verilog-A compiler that writes each model's Zig). It replaces the stub
of [N4](09-after-the-levers.md#n4-the-transcendental-kernels) and answers
[N5](09-after-the-levers.md#n5-derivative-sparsity-in-the-generated-model-code).
Nothing was built or run for it. Every number is read from source, from the
machine code of the census build, or from the profiles page 09 recorded.
Anything inferred says so.

Levers here are named M1 to M8. Classes are those of
[README.md](README.md#classes).

## The short answer

- **The kernels are not slow.** Gompute's `exp` and `log` cost 3.29 and
  3.77 ns a call against glibc's 3.88 and 4.13. Only `pow` loses (13.80
  against 10.91), because glibc's body uses FMA.
- **The models call `pow` where ngspice does not.** ngspice takes
  `1/sqrt(arg)` when a grading coefficient is one half and `exp(-mj*log(arg))`
  otherwise, and cubes by multiplying. `models/mos1.va`, `mos2.va` and
  `diode.va` spell all of these as `pow`. This is the largest math lever:
  8 to 9% of one thread on `bench_ngspice_mosamp` (inferred), nothing on
  BSIM4, which executes no `pow` ([M1](#m1-pow-as-ngspice-writes-it)).
- **The divider is the hot resource inside a BSIM4 evaluation.** 18% of the
  evaluation's samples sit on a divide or on the instruction after one, for
  2.6% of its instructions. A dual divide is two scalar divisions, and 100 of
  the 252 division sites divide by a setup constant
  ([M2](#m2-reciprocals-of-setup-constant-divisors),
  [M3](#m3-the-divider-in-the-dual-family)).
- **N5 is already done.** VerA types every value by the unknowns it depends
  on and ESPice's dual carries only those lanes. BSIM4 has 11 derivative
  lanes and no value carries more than 5. What is left of the dual overhead
  is not sparsity: the value-only core is 46% of the dual one by instruction
  count.
- **The instance axis has been started twice and reaches no MOSFET.**
  ESPice's `perf/lane-eval` branch runs four instances per call but takes
  only their `exp`, `log` and `pow` calls four wide. It measured 6.3% fewer
  cycles on mesa and a loss on the diode, and it breaks even at 1.14 runs
  per batch where VerA measured 1.06 to 2.6. VerA's own four-point family
  measured 1.5x on BSIM4 and 2.0x on PSP103 for a batch that stays on one
  path. Neither can run on BSIM4, PSP103 or MOS2 today: a `ddx()` in the
  model denies `batch_ok` in VerA 0.23
  ([question 5](#5-the-instance-axis)).
- **G4 needs nothing from VerA.** The contract already lets a family carry
  f32 lanes. The static estimate of G4's `d` is 0.63 to 0.69, under the 0.8
  it assumed and over the 0.5 that closes it
  ([M6](#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes)).
- **The contract facts are worth more than the math.** BSIM4's ten path
  latches reach only charge values, so they can leave the bypass key
  (finding 25). One mask, `limit_reads`, sits inside a tolerance formula,
  so tightening it is not bit-neutral ([M7](#m7-contract-facts)).
- **Two math libraries are in the build.** Setup code and VerA's constant
  folder call `contract.gm`; the dual family calls `gompute.math`. No test
  ties their bits together
  ([M8](#m8-one-math-provider-for-setup-and-core)).

## Sources and method

| What | Where |
|---|---|
| ESPice | The working tree of `dev/performance` on `9bbd4d7f`, read on 2026-11-10 |
| The dual family | `src/device/dual.zig` (ESPice owns it, not VerA) |
| VerA 0.23.0, pinned | `zig-pkg/vera-0.23.0-fzAu7BznSAHTovhsbqKB1WQBFu66b65RDnBfVhQi4EF9/`; `lib/contract/` and `src/codegen/device/` below are under it |
| Gompute 2.0.0, pinned | `zig-pkg/gompute-2.0.0-YJVc1oQ-BwB2JI0_gqttr3Mox-1fvn4D3rL5bdaDZbfB/src/device/math.zig`, cited as `math.zig` |
| Gompute's own timings | `Gompute/skill/gompute/OVERHEAD.md` lines 109 to 201 (i9-14900HX, pinned P-core, ReleaseFast, `-mcpu=native`, 8K inputs, best of 80) |
| Generated models | `.zig-cache/o/4aa15a45a0a753088b8b05f39eb4ff0b/bsim4va.zig`, `14b2fb149c83f3286ee7197ed44bff3b/psp103.zig`, `511eb61c8bea754dc82e1ea1172e4b8f/mos1.zig`, `5c6bd4fd7a3a9d24cdb5c215d603203d/mos2.zig`, `00046fe9547f0cea7a8de5c3855ae8d8/diode.zig`, cited by file name |
| Machine code | The census build of page 09 (`espice-instr/bin/espice`), disassembled with `objdump -d` |
| Profiles | Page 09's `perf record` files `chain_b4_1k.data`, `chain_p103_1k.data`, `mosamp.data`, `pinv2000.data`, and `stat.json`. Read with `perf report` and `perf annotate`; nothing was recorded again |
| The lane-eval branch | `origin/dev/integration` at `6ff136e5`, commits `d8b4a6af`, `05626d6a`, `9daa3b8d`; read with `git show` and `git diff origin/dev/performance...origin/dev/integration -- src/device` |
| Its measurements | GitHub issue #258 (`gh issue view 258`), read 2026-11-10 |
| VerA's batching measurements | `docs/host/batching.md` in the pinned VerA, and the two notes it cites, read from the older package on this disk: `zig-pkg/vera-0.9.0-fzAu7MjO0QFtidJjVR2JMx-2QNxzpn1bLUzd9GTaqzzV/docs/measurements/batched-instances-2026-10-01.md` and `batched-lead-2026-10-02.md` |
| ngspice | The checkout under `VerA/tests/conformance/external/ngspice` at `a9da7bca6` |
| Instruction timings | uops.info, the Alder Lake-P rows (the closest listed core to this machine's P-cores), fetched 2026-11-10. Published figures, not measurements of this round |

The model core is one function per model, `<model>__common__core`. Its
lines: BSIM4 12091 to 13702, PSP103 15027 to 18530, MOS1 1498 to 1824,
MOS2 1731 to 2162, diode 1546 to 1638.

Three counts are used, and they agree with each other:

1. **Machine code.** Instruction classes of one function of the census
   binary:

   ```text
   objdump -d --no-show-raw-insn --start-address=0x35268d0 --stop-address=0x3536c8a espice-instr/bin/espice > b4_36.s
   grep -c vdivsd b4_36.s          # 240
   grep vdivpd b4_36.s | grep -c ymm   # 23 (and 36 without ymm)
   grep -o 'call.*<[^>+]*' b4_36.s | sed 's/.*<//' | sort | uniq -c
   ```

2. **Source census.** A script walks one generated core as a token tree.
   It keeps the host or the device arm of every
   `(if (comptime zSpec) A else B)`, and for every `exp`, `log`, `pow`,
   `sqrt` and `div` site records what the argument depends on (setup values
   only, instance fields, the unknowns and with how many lanes) and what
   guards it (nothing, a model flag, a compare on data). A plain `grep` of
   the file overcounts: both arms of every `zSpec` choice are spelled, and
   setup, noise and operating-point code repeat the expressions.
   `grep -o '\.exp(' bsim4va.zig | wc -l` gives 403, 215 of them inside
   `core`; `core` on the host arm has 67 sites.

3. **Sample tally.** `perf annotate --stdio` of one function, summed by
   instruction class.

The scripts (`census.py`, `patterns.py`, `dis.py`) are measurement code in
this round's scratch directory, like `census.patch`; they are not in the
tree.

Agreement: the source census finds 67 `exp` and 27 `log` sites in BSIM4's
`core`; the machine code of the Newton evaluation calls `expInline` 63
times and `softLog` 23 times. A second script that resolves temporaries
and classifies each argument reproduces 67, 27 and 48 (`sqrt`)
independently.

## Where one BSIM4 evaluation goes

### The profile

`chain_bsim4_1k`, one thread, the census build, 6.16 G cycles sampled:

| Function | Share | Samples |
|---|---|---|
| `stamp.evalRange__func_36` (the Newton evaluation: BSIM4's `evalQ` inlined) | 38.26% | 938 |
| `SparseLu.refactor` | 16.99% | |
| `device.math.expInline` | 7.19% | 177 |
| `device.math.softLog` | 6.60% | 162 |
| `DeviceBatch(bsim4va).acceptQOnly` | 5.88% | |
| `SparseLu.solve` | 4.68% | |
| `bsim4va.q` | 4.61% | |
| `stamp.evalRange__func_1138` | 3.14% | |
| `State(bsim4va).limitRangeHook` | 2.57% | |

The deck runs 71 operating-point and 1,078 transient Newton iterations over
1,000 transistors (`--timing-in-depth`, page 09's run): 1.149 M Newton
evaluations. The evaluation body is then 2,050 cycles each
(0.3826 × 6.158 G / 1.149 M).

The same function, its 938 samples summed by instruction class. "On" is the
sampled address. "After" is the instruction that follows one of the class,
which is where a sample lands when the counter overflows while the slow
instruction is still executing. One sigma on a 15% share is 1.2 points.

| Class | Static instructions | Samples on | Samples after |
|---|---|---|---|
| Moves | 3,356 | 28.8% | 14.0% |
| of which stack loads and stores | 1,988 | 15.2% | |
| Scalar `mul`, `add`, `sub` | 1,495 | 13.0% | 14.2% |
| Packed `mul`, `add`, `sub` | 1,268 | 10.8% | 20.2% |
| FMA | 346 | 3.9% | 9.0% |
| `vbroadcastsd` from a register | 556 | 9.0% | 3.9% |
| `vbroadcastsd` from memory | 384 | 6.8% | 0.8% |
| Shuffles and inserts | 554 | 9.3% | 4.2% |
| **Divides** | 299 | 3.1% | **15.0%** |
| **Square roots** | 40 | 0.7% | **3.9%** |
| Compares | 560 | 3.0% | 1.6% |
| Jumps | 810 | 1.5% | 1.2% |
| Calls | 86 | 0.1% | 0.0% |
| Everything else | 1,692 | 9.8% | 12.1% |

Read together:

- **Divides and square roots**: 3.0% of the instructions, 18.1% of the
  samples on or right after a divide and 4.6% for a square root. With a
  window of three instructions after, 24.1% and 4.7%. Both use the one
  divider.
- **Stack traffic**: 17% of the instructions are loads and stores to the
  stack and 15.2% of the samples sit on them. Every vector register is
  caller-saved under System V, and the function makes 86 calls with 81
  `vzeroupper`.
- **Calls themselves are free**: 0.1% of the samples.
- The run's branch misses are 9.80 M of 1,209 M branches (`stat.json`).
  At 17 cycles each that is 2.5% of the run's 6.55 G cycles, for every
  branch in the program. Removing branches on the host buys at most that.
- The top-down split of the same run (`stat.json`): 48% of slots retire
  and 40% are back-end bound. Of those 40 points, 8 wait on memory and 31
  on execution: the divider and dependency chains.

### `exp` and `log` inside it (inferred)

`expInline` and `softLog` take 13.8% of the thread: 849 M cycles. The
Newton evaluation body takes 41.4% and the charge passes 10.9% (page 09,
"Where the cycles go"). Splitting the 849 M in that proportion gives 584
cycles of `exp` and `log` per Newton evaluation. So one evaluation is
about 2,050 cycles of body and 580 of `exp` and `log`: **22% of it is
inside the two kernels**. At 3.29 and 3.77 ns a call, which is 14 to 20
cycles between 4.4 and 5.4 GHz, that is **30 to 40 calls per evaluation**
of the 86 call sites. The count itself was not measured; it is the first
step of [M5](#m5-calls-vector-forms-and-clobbered-registers).

`softLog`'s own samples: 36% in the near-1 series (17 multiplies, 19 adds,
`math.zig:1471-1493`, "the branch a SPICE junction lives in"), 57% in the
table path. Its hottest instruction, at 9.3%, is the second subtraction of
`r = (z - chi - clo) * invc` (`math.zig:897`), the FMA-free form of one
`fma(z, invc, -1)`.

### The machine code

Static counts, one function each, the census build:

| Function | Role | Instructions | Bytes | `exp` calls | `log` calls | Scalar divisions | `sqrt` instructions |
|---|---|---|---|---|---|---|---|
| `stamp.evalRange__func_36` | Newton evaluation, dual | 11,446 | 66,489 | 63 | 23 | 404 | 40 |
| `bsim4va__common__core__func_2227` | whole core, value only | 5,261 | 30,527 | 60 | 25 (and 1 `pow`) | 233 | 38 |
| `bsim4va.q__func_1140` | charges, value only | 1,799 | 9,766 | 15 | 11 | 91 | 25 |
| `DeviceBatch(bsim4va).acceptQOnly` | charges and state staging | 2,138 | 11,860 | 17 | 12 | 94 | 27 |
| `updateRange` | state | 2,048 | 10,786 | 17 | 12 | 94 | 26 |
| `State(bsim4va).limitRangeHook` | limit | 510 | 2,721 | 0 | 0 | 0 | 0 |

- A scalar division is one `vdivsd` or one lane of a `vdivpd`. The Newton
  evaluation has 404: 240 `vdivsd`, 36 two-wide `vdivpd` and 23 four-wide.
  LLVM's SLP pass already packs those 59 groups.
- 42 pairs of adjacent `vdivsd` with the same divisor remain unpacked. They
  are the two divisions of one dual divide, for example
  `vdivsd %xmm0,%xmm11,%xmm1 ; vdivsd %xmm0,%xmm7,%xmm0`.
- The value-only core is **0.46** of the dual evaluation by instruction
  count. The charge slice is 0.34 of the value-only core.
- BSIM4 has 13 instantiations of `stamp.evalRange` in this binary, 64,989
  to 86,554 bytes each, 947 KB together. The `core` is forced inline into
  each (`bsim4va.zig:15638-15655`, `@call(.always_inline, core, ...)`).

### The source

Sites in `core`, host arm. "Always" runs on every evaluation, "flag" behind
a model-card flag (the same arm every evaluation), "data" behind a compare
on the unknowns.

| Model | `exp` (always / flag / data) | `log` | `pow` | `sqrt` | `div` | `div` by a setup constant |
|---|---|---|---|---|---|---|
| BSIM4 | 67 (3 / 16 / 48) | 27 (2 / 17 / 8) | 1 (flag) | 48 (24 / 23 / 1) | 252 (122 / 108 / 22) | 100 |
| PSP103 | 81 (3 / 3 / 75) | 39 | 47, and 2 with a moving exponent | 190 | 434 (79 / 118 / 237) | 10 |
| MOS1 | 2 | 0 | 6 (4 data, 2 flag) | 2 | 25 | 20 |
| MOS2 | 3 | 0 | 15 | 10 | 68 | 46 |
| Diode | 5 (all data) | 0 | 9 | 2 | 21 | 15 |

The same cores on the device arm, where VerA turns a guarded costly arm
into an eager select (`zSpec`):

| Model | `exp` (always / flag / data) | `log` (always / flag / data) |
|---|---|---|
| BSIM4 | 67 (20 / 39 / 8) | 27 (3 / 24 / 0) |
| PSP103 | 81 (15 / 44 / 22) | |

None of the five cores calls `expm1`, `log1p`, `tanh` or `atan`.

## The seven questions

### 1. What a call costs

Counted from the pinned `math.zig`. A flop is one f64 multiply, add or
subtract. Times are OVERHEAD.md's, ns per element.

| Function | Path | Multiplies | Adds | Divides | Table bytes read | Branches every call | Scalar | Vector | glibc |
|---|---|---|---|---|---|---|---|---|---|
| `exp` | `softExp` 1201, `expInline` 1104, `expMain` 865 to 882 | 10 | 11 | 0 | 16 of 2 KB | 3: lines 1206, 1107, 1123 | 3.29 | 1.55 | 3.88 |
| `log`, table path | `softLog` 1502, `logCore` 1468, `logMain` 886 to 910 | 10 | 14 | 0 | 32 of 4 KB | 2: lines 1471, 1453 | 3.77 | 2.25 | 4.13 |
| `log`, near 1 | lines 1471 to 1493 | 17 | 19 | 0 | 0 | 2 | | | |
| `pow` | `powBody` 708, `softPow` 1130, `powLogMain` 986 to 1032, the split 1181 to 1186, `expInline` | 29 | 40 | 0 | 48 | 4 to 5 | 13.80 | 5.26 | 10.91 |
| `sqrt` | `@sqrt`, line 717 | | | the divider | | 0 | | | |

- **Where `pow` loses to glibc.** OVERHEAD.md lines 179 to 183: glibc's
  body uses FMA. The FMA-free port pays for it in three places: the
  reduction `r = z*invc - 1` (lines 1004 to 1008, 5 flops for one `fma`),
  the high and low parts of the first polynomial term (1021 to 1025), and
  the product `y * log(x)` in two parts (1181 to 1186, 7 flops for 4).
- **What explicit `@mulAdd` would save**, by hand count of the mul-add
  pairs that fuse in the ARM reference's FMA form: `exp` 21 flops to 14,
  `log` 24 to 18 with two of the four table columns gone (the table halves
  to 2 KB), `pow` 69 to about 48.
- **Whether that is faster on the host is not shown for `exp` and `log`.**
  Gompute's FMA-free `exp` and `log` already beat glibc's FMA builds. Only
  `pow` and `log2` (4.82 against 3.39) have a measured gap.
- **Branches every call.** `exp` tests the exponent field twice: `softExp`
  for inf and NaN (line 1206), then `expInline` for the tiny and huge range
  (1107). The first is inlined at every call site, about ten instructions
  at each of the 63. One merged test is exact and saves one compare per
  call and about 630 instructions per instantiation.
- **Dead work for compact-model ranges.** None found beyond that. `pow`'s
  first exit, `y == 0 or x == 1` (line 710), is the one a speculated
  junction `pow` takes (see [Closed leads](#closed-leads)).

### 2. Counts per evaluation

The tables above. Three more facts:

- **How the sites group.** A vector call needs sites that are independent
  and run under the same guard. In BSIM4's `core` on the host arm: 10 pairs
  of `exp` and no group of four; 2 pairs of `log`; 22 `sqrt` in groups
  (4 in fours); 146 `div` in groups (72 in fours). 28 `exp` sites are
  mutually independent at chain depth 2 but sit under different data
  guards.
- **What is hoistable to setup.** Almost nothing: VerA's setup tier already
  takes every solve-invariant value (`src/prove/setup.zig:1-8`). What stays
  in `core` with setup-only arguments: one `exp`, one `log` and one `div`
  inside BSIM4's `mtrlMod` loop (up to five iterations, flag-guarded,
  `bsim4va.zig:12255-12289`); 8 `pow` in MOS2 and 4 in the diode, which
  cost one compare each when their arm is not taken.
- **What is evaluated again.** Per accepted step at two Newton iterations
  the call sites visited are 2 × 86, then 29 in `acceptQOnly`, 29 in
  `updateRange` and 26 in `q`. The last three are the same 29 sites three
  times. That is [N3](09-after-the-levers.md#n3-one-charge-evaluation-per-accepted-step)'s
  subject. The limit pass evaluates none.

BSIM4's `log` sites are mostly `ln(1 + exp(x))`: 28 of the 47 textual
`zLnD` sites (both arms counted) have an `exp` in a `1 + ...` argument. 13
`exp` sites are `exp(k * ln(x))`, the model's own cheaper power.

### 3. The dual numbers

The family is `DualFor(lane, pad, collapsed)` in `src/device/dual.zig`. A
value is one `f64` and one `@Vector` of derivative lanes. Its numerics are
pinned per primitive by the contract (`lib/contract/family.zig:31-52`).

| Operation | Value | Lanes | Divider operations | Lines |
|---|---|---|---|---|
| `mul` | `a.v * b.v` | `mulAdd(b.d, a.v, a.d * b.v)`, fused where the target has FMA | 0 | 220 to 226 |
| `div` | `q = a.v / b.v` | `mulAdd(b.d, -q, a.d) * inv`, `inv = 1.0 / b.v` | **2** | 229 to 236 |
| `div` by a value without lanes | `q = a.v / b.v` | `a.d * inv` | **2** | 234 |
| `exp` | one `exp` | `d * e` | 0 | 243 to 246 |
| `log` | one `log` | `d * (1.0 / a.v)` | 1 | 247 to 249 |
| `sqrt` | `@sqrt` | `d * (0.5 / s)` | 2 | 262 to 265 |
| `pow(x, c)` | one `pow` | `d * (c * p / x)` | 1 | 280 to 284 |
| `expm1` | one `expm1` and one `exp` | `d * exp(v)` | 1 (inside `expm1`) | 252 to 254 |

- **One division or one per lane?** Neither: two scalar divisions per dual
  divide, the quotient and the reciprocal, then one multiply for all lanes.
  The contract pins both (`family.zig:41`).
- **Lanes per model.** `deriv_reads`: BSIM4 11 (`0x7ff`,
  `bsim4va.zig:16124`), PSP103 12, MOS1 6, MOS2 6, diode 3.
- **Structural zeros (N5).** Already removed. VerA types every value
  `zOf(S, mask)` and ESPice's `Of(m)` carries the lanes of `m` only
  (`dual.zig:108`). VerA's own table, `lane_masks`
  (`bsim4va.zig:16151-16178`), lists BSIM4's 779 declared reals: 68 with no
  lane, 75 with two, 164 with three, 437 with four, 35 with five, none
  wider. By operation, from the census:

  | Model | Dual operations | 0 lanes | 2 | 3 | 4 | 5 | 6 |
  |---|---|---|---|---|---|---|---|
  | BSIM4 | 1,837 | 29 | 142 | 515 | 1,097 | 54 | |
  | PSP103 | 5,486 | 102 | 1,273 | 356 | 3,714 | 16 | 25 |
  | MOS1 | 236 | 28 | 105 | 25 | 78 | | |
  | MOS2 | 451 | 51 | 104 | 68 | 228 | | |

- **Padding.** The host rounds a value's lanes up to a power of two
  (`stamp.zig:32-41`, measured there: `bsim4va` 4.14 M to 2.32 M
  instructions per instance). Three lanes ride a four-lane register for
  free. Five lanes take two registers; that is 3% of BSIM4's operations.
  The device kernels do not pad (`kernels.zig:88`, `lane_kernels.zig:164`).
- **What a sparser lane set would look like.** There is none to find by
  mask. The next step down is a branch-voltage basis: a MOSFET depends on
  three voltage differences, not four node voltages, so mask `0x170` could
  carry three lanes. On AVX2 three lanes cost what four do. It would pay
  only on a device target with f64 lanes, where
  [G4](05-levers-gpu.md#g4-f32-derivative-lanes-on-fp64-poor-cards) is the
  larger change. Not requested.
- **On AVX2 a lane operation is one µop at any width up to four.** So the
  host cost of the lanes is the number of dual operations and their
  broadcasts, not the lane count: 940 `vbroadcastsd` in the Newton
  evaluation, 15.8% of its samples on them. A register broadcast runs on
  port 5 only (uops.info).

### 4. Strength reductions the compiler could prove

Counted in `core`, host arm, temporaries resolved one definition deep and
`zPick` left opaque.

| Rewrite | Class | BSIM4 | PSP103 | Verdict |
|---|---|---|---|---|
| `pow(x, k)`, `k` a setup constant, as `sqrt` when `k` is one half | rounding | 1 site | 46 | [M1](#m1-pow-as-ngspice-writes-it). MOS1 6, MOS2 15, diode 9 |
| `pow(x, 3.0)` as `x*x*x` | rounding | 0 | 0 | Diode, 2 sites; M1 |
| `x / c`, `c` a setup constant: reciprocal from setup, quotient kept | **exact** | 100 | 10 | [M2](#m2-reciprocals-of-setup-constant-divisors) |
| the same as `x * (1/c)` | rounding | 100 | 10 | M2 |
| `x / c`, `c` a literal power of two, as a multiply | exact | 2 | | Two sites; LLVM is expected to do it already (not checked in the machine code) |
| `(a / b) / c` as `a / (b * c)` | rounding | 7 | 9 | Saves one division each. Small |
| `a / (b / c)` as `a * c / b` | rounding | 5 | 4 | Small |
| `x / exp(y)` as `x * exp(-y)` | rounding | 2 | 18 | Small |
| `exp(a) * exp(b)` as `exp(a + b)` | rounding | 0 | 0 | Not present |
| `ln(a * b)`, `ln(a / b)` split | rounding | 0, 5 | 0, 6 | Splitting adds a `log` |
| `sqrt(a * a)` | exact up to sign | 0 | 0 | Not present |
| `0.5 / s` as `0.5 * (1 / s)` in the `sqrt` slope | **exact** | 6 sites of `x / sqrt(y)` | 27 | [M3](#m3-the-divider-in-the-dual-family) |

Gompute's monotonicity note (`math.zig:660-666`): a shortcut inside `pow`
for chosen exponents made `pow` step down across `y = -64`, and VerA's
prover evaluates `pow` at interval ends. So no rewrite above goes inside
`pow`. Each is a choice of function made by the compiler, for an exponent
that never moves during a run.

### 5. The instance axis

It has been started twice. Both starts are read here, and the section is
built on them.

| Start | Form | Read from |
|---|---|---|
| VerA, 2026-10-01 and 2026-10-02 | A family whose value type is `@Vector(W, f64)`: every value and every derivative lane holds W operating points (struct of arrays). The contract for it is `batch_ok`, `batch_lead`, `batch_inst` | `docs/host/batching.md` and the two measurement notes |
| ESPice `perf/lane-eval`, 2026-11-03 and 2026-11-04 | W scalar duals side by side (array of structs). Only the calls go W wide | `origin/dev/integration`, #258 |

**What the branch does.**

- `src/device/points.zig` (new, 272 lines) is `PointFamily(S1, W, Inst)`.
  A value is `struct { l: [W]T }` with `T` the scalar family's dual. Every
  primitive is the scalar one per point. `exp`, `log`, `expm1` and `pow`
  take the W values in one Gompute vector call, then run each point's own
  `map` or `powFrom` (new in `dual.zig`). `sqrt`, `log1p` and the
  trigonometric functions stay per point. Its header says so: "The win is
  the call count; the arithmetic stays the scalar family's."
- `stamp.evalRange` gains a comptime point count `pw`. Up to `pw`
  consecutive instances that share a Model row (VerA's batch key) run as
  one call. A run of one takes the scalar path. A short run repeats its
  last instance in the spare points. Each instance is then stamped in id
  order, so every plane cell sums the same values in the same order as at
  `pw = 1`.
- A decision on data goes through VerA's lead protocol (`decide`,
  `decideI`, `strip`, `leadBegin`, `leadNext`, `leadMerge`): the first
  unfinished point steers, and a point that disagrees runs again. The
  state is `LeadState(W, false)`: no region signature is kept, so a batch
  is never regrouped.
- `traits.pointWidth(D)` is 4 when `D.batch_ok` holds and `D` is in the
  hand-kept list `traits.point_models`, else 1. Four is VerA's measured
  width for AVX2.
- `Hooks.set_point_eval` and `ESPICE_LANE_EVAL=0` evaluate one instance
  per call in the same binary. That is the W == 1 oracle.
- The test `expectPointsMatchScalar` (`src/device/tests/eval.zig`) logs
  every sink write of 23 random instances at `pw` 1 and 4 and expects the
  same writes in the same order with the same bits, for mesa and the
  diode. The instances carry NaN and overflowing biases, limited and
  unlimited unknowns, grounded terminals, and two Model rows in runs of 1,
  2, 5 and 7. `tests/codegen.zig` gains a probe of the point `exp` and
  `pow` against the hand-written form.

So the branch is [M5](#m5-calls-vector-forms-and-clobbered-registers)
part 1 turned along the instance axis. It gets groups of four with no
scheduling pass and no speculation. It does not vectorize the arithmetic.

**What it measured** (#258: i9-14900HX, P-cores, user cycles, median of 5,
load 7 to 10):

| Deck | Model | Default | `ESPICE_LANE_EVAL=0` | Reading |
|---|---|---|---|---|
| `tran/device_mesa_oscillator` | mesa | 7.70 G | 8.22 G | 6.3% fewer cycles |
| `stress/vacask_graetz` | diode | 5.98 G | 6.07 G | Not a lane measurement, see below |

- The measured binary (`6ff136e5`) lists mesa only. `d8b4a6af` listed mesa
  and the diode. `9daa3b8d` took the diode out with this note in
  `traits.zig`: "vacask_graetz took 14% more (its bridge diodes sit in
  opposite regions, so a batch likely runs both paths)". So #258's "mesa
  and diode only" describes the first commit, and its "diode lanes -1.4%
  vs off" compares two runs of one code path. That 1.5% is the spread of
  the method, and the mesa figure is four times it (inferred from the
  source; nothing was run again).
- All 958 decks gave identical raws against `ESPICE_LANE_EVAL=0`. The full
  ReleaseSafe `zig build test` was not run, and #258 records that the
  agent was stopped mid-step.

**Why it stopped at one model.** Two gates.

The first is `batch_ok`. VerA 0.23 declares it when no lane is pinned and
the device has no per-timepoint cache and no status latch
(`src/codegen/device/codegen/file.zig:355-359`). Of the 88 generated
models in this tree's cache, 28 declare it. What denies the other 60
(counted by a script over the generated files):

| Denied by | Models | Among them |
|---|---|---|
| A `ddx()` in `core` | 31 | BSIM4, PSP103 and PSP104 in all their variants, MOS2, MOS3, MOS9, MEXTRAM, HICUM, BSIM-CMG, BSIM-BULK |
| of which no status latch and no cache | 20 | `bsim4va`, `psp103`, `mos2` |
| A status latch or a per-timepoint cache, and no `ddx` | 6 | The LTRA and TXL lines |
| Another pin: operator history, a host function | 23 | Switches, delays, Laplace and B sources, S-parameter and W lines |

None of the 28 has a `ddx` in `core`. The rule is in the code: `ddx`
renders as `S.con(a.ddxAt(u))`, and
`src/codegen/device/codegen/call_operator.zig:232-235` says "Pins:
`.ddxAt` reads one scalar partial". MOS2 has one such site, the `gm` of its
noise density (`models/mos2.va:554`). BSIM4 has 9 and PSP103 has 50.

`ddx` is sufficient to deny `batch_ok`. Whether it is the only pin in
these models is not determined. VerA's note of 2026-10-02 measured bsim4va
and psp103 as `batch_ok`, so the rule or the generated `core` has changed
since.

The second gate is the list: a model enters `point_models` only when
measured faster. Mesa is in. The diode is out.

**Why the list will not grow to the MOSFETs.** A batch that stays on one
path saves call time only. Per element, the vector forms cost 0.47
(`exp`), 0.60 (`log`) and 0.38 (`pow`) of scalar (OVERHEAD.md: 1.55, 2.25
and 5.26 ns against 3.29, 3.77 and 13.80), and `expm1` gains nothing. Each
run of a batch costs four scalar evaluations, because the arithmetic is
not shared. So a second run costs a whole batch.

| | `chain_bsim4_1k` (page 09's profile) | `vacask_ring`, PSP103 (#258's profile) |
|---|---|---|
| `exp`, `log`, `pow` share of the thread | 7.19%, 6.60%, 0 | 11.45%, 3.87%, 4.95% |
| Saved at one run per batch | 6.5% | 10.7% |
| The Newton evaluation with its calls | 52% | 86% |
| Saved, as a share of one evaluation | 12% | 12% |
| Break-even | 1.14 runs per batch | 1.14 runs per batch |

VerA measured the runs per four-point batch on real bias (the note of
2026-10-02, section 4: ring, chain and logic decks of about 1,000 MOSFETs,
simulated by ESPice, every second accepted timepoint):

| Grouping | BSIM4 | PSP103 | Branch form against scalar |
|---|---|---|---|
| Netlist order, which is what the branch does | 2.13 to 2.57 | 1.82 to 1.85 | 1.6 to 2.3 times the cost |
| By the signature of two accepted steps back | 1.06 to 1.19 | 1.19 to 1.30 | 0.93 to 1.14 times |
| By a fresh `region` call | 1.02 to 1.07 | 1.01 to 1.03 | The call costs 0.27 and 0.50 of a scalar evaluation |

The branch's form loses on both models in the order it batches, and with
the best affordable grouping it runs between 7% faster and 14% slower.
**So `perf/lane-eval` is a mesa lever. Getting `batch_ok` back for the
MOSFETs would not make it pay there.** The 6.5% is the bound M5 already
gives for packed calls, and the diode's 14% loss on a bridge is this
arithmetic at two runs per batch. Its text cost is also real: a four-point
body spells the arithmetic four times. One BSIM4 `evalRange` instantiation
is about 73 KB today (947 KB over 13), so a four-point one is about 290 KB
(inferred).

**The other form.** VerA measured the struct-of-arrays family on these
models: `evalQ`, cycles per instance, a batch on one path, W = 4, each
point with its own instance. The machine was shared and cycles moved by up
to 1.7x between runs, so the instruction ratio is beside each.

| Model | One path, cycles | Instructions | Break-even | With signature groups |
|---|---|---|---|---|
| diode | 1.26x | 1.75x | | 1.26x: it never diverged in the note |
| mos1 | 1.02x to 1.16x | 1.54x | 1.0 to 1.2 runs | Not measured on a deck; 0.51x on the note's mixed set at 3 runs |
| bsim4va | 1.50x | 1.78x | 1.5 runs | 1.26x to 1.42x |
| psp103 | 2.03x to 2.06x | 1.84x | 2.0 runs | 1.56x to 1.71x |

These sit at the roofline, which is kept from this page's first version as
the check. Per dual operation at four lanes and four instances, today is
4 × (1 scalar µop + 1 `ymm` µop) = 8, and a multiply is 5 each with its two
broadcasts, 20. A tile is 1 `ymm` µop for the values and 4 for the lanes,
5, and a multiply is 9. The ceiling is 1.6x on adds and 2.2x on multiplies.
W = 8 on AVX2 spills and gains nothing (both notes).

What stands between those ratios and ESPice:

- **The baseline.** VerA's scalar is its own reference family, not
  ESPice's `DualFor`. ESPice's first research round recorded 1.0x to 1.25x
  on bsimcmg `evalQ` and about 1.05x end to end for the same kind of
  family ([07-prior-work.md](07-prior-work.md#closed-in-this-codebase)).
  The two sets of figures are for different models and are not
  reconciled here.
- **The stamp.** It is a scatter and stays scalar. VerA on MOS1:
  "instance-parallel `S` caps at 1.17x end to end because the sparse stamp
  does not vectorize" (`float/lanes.zig:41-46`).
- **Grouping against bit-identity.** The branch is exact because a batch
  is a run of consecutive ids stamped in id order. A signature group is
  not consecutive. Its results have to be parked and stamped in id order:
  one evaluation's outputs per instance, held until the batch's lowest id
  is due.
- **The signature's age.** "Two accepted steps back" is VerA's figure.
  Between the Newton iterates of one solve it is not measured.
- **`batch_ok`**, the first gate above.

**Bound, if VerA's ratios hold against ESPice's dual.** BSIM4:
0.52 × (1 − 1/1.26) to 0.52 × (1 − 1/1.42), **11 to 15% of one thread on
`chain_bsim4_1k`**. PSP103: 0.86 × (1 − 1/1.56) to 0.86 × (1 − 1/1.71),
**31 to 36% on `vacask_ring`**. If the first round's bsimcmg ratio holds
instead, nothing. Both are upper bounds: the gather and the stamp inside the
evaluation are not subtracted.

**Verdict.**

1. The branch is right for mesa and stays a one-model lever. Do not extend
   its list to the MOSFETs.
2. The form that could pay on PSP103 and BSIM4 is VerA's own batch family.
   ESPice has not started it. From the branch it would keep `evalRange`'s
   `pw` parameter, the `Eval` split into gather, compute and stamp, the
   write-log test and the switch. It would not keep `points.zig`.
3. On AVX-512 and NEON there is no measurement. VerA's calibrated estimate
   is about 1.8x for the diode and 1.3x for MOS1 at W = 8 on `x86_64_v4`,
   and break-even or below at W = 2 on NEON (the note of 2026-10-01).

**First steps, in order.** Each is cheap and each can close the lead.

1. VerA renders `ddx` as a per-point value through a family primitive, so
   a model with `ddx` keeps `batch_ok`. A scalar family implements it as
   today's `S.con(a.ddxAt(u))`: the same bits. Oracle: VerA's fixture suite
   already checks every `batch_ok` device against the scalar result point
   by point (`docs/host/batching.md:105-108`).
2. One number: PSP103's `evalQ` on one path, a struct-of-arrays family at
   W = 4 against ESPice's `DualFor`. Close the lead under 1.3x, which is
   PSP103's measured runs per batch.
3. Runs per batch between Newton iterates, from `LeadState(W, true)` on
   `vacask_ring`.

**For a merge of the branch.** It takes device ABI 41 for
`Hooks.set_point_eval`. The working tree has since taken 41
(`Hooks.track_charges`, `Hooks.charges_clean`) and 42 (`Hooks.census`,
`Hooks.stage_moved`; `src/device/abi.zig:858-863`). A merge takes 43.

### 6. Contract facts

Answered in [M7](#m7-contract-facts), one request per row.

### 7. The GPU

| Change | FP64-poor card (RTX class) | FP64-class card (A100) | Host |
|---|---|---|---|
| f32 lanes (G4, [M6](#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes)) | Yes: 63 to 69% of the FP64 flops are lanes (inferred) | No (FP64 is half of FP32) | No |
| Lazy costly arms ([M6](#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes)) | To measure: up to 1,200 of 4,231 value flops | No: eager is right where registers and divergence bind | Already lazy |
| FMA bodies ([M4](#m4-fused-multiply-add-in-gomputes-pow-exp-and-log)) | Yes: `exp` 21 to 14 FP64 instructions, `log` 24 to 18 | Same ratio, smaller share | `pow` only |
| Reciprocals of setup divisors ([M2](#m2-reciprocals-of-setup-constant-divisors)) | Yes if an FP64 divide is slow there; not measured | Small | Up to 2.5% |
| `pow` as ngspice writes it ([M1](#m1-pow-as-ngspice-writes-it)) | Yes: 69 flops to a square root | Yes | Yes |
| Paired divides, vector calls, register-preserving calls (M3, M5) | No | No | Host only |
| Instance axis ([question 5](#5-the-instance-axis)) | The GPU already has it | | Mesa only today; PSP103 and BSIM4 behind `batch_ok` and one measurement |

## Levers

### M1 `pow` as ngspice writes it

**Class:** rounding. It moves results toward ngspice's operation sequence.
**Files:** `models/mos1.va`, `models/mos2.va`, `models/diode.va` (stage 1);
VerA `src/codegen/device/codegen/render_op.zig:187-204` (stage 2). Not
Gompute.

**Today.** The junction charge, the mobility factor and the reverse diode
current call `pow`:

| ESPice | ngspice at `a9da7bca6` |
|---|---|
| `mos1.va:143-144`: `pow(a, 1.0 - mjx)` | `mos1load.c:580-598`: `1/sqrt(arg)` when the coefficient is `.5`, else `exp(-mj*log(arg))` |
| `mos2.va:143`: `pow(1.0 - v/pbj, 1.0 - mgrad)` | `mos2load.c:1067-1085`: the same |
| `mos2.va:348`: `pow(ucrit_term/udenom, uexp)` | `mos2load.c:724`: `exp(model->MOS2critFieldExp*log(tmp/udenom))` |
| `diode.va:275,282`: `pow(..., 3.0)` | `dioload.c:433`: `arg = arg * arg * arg` |
| `diode.va:337`: `pow(1.0 - vd/vj_t, 1.0 - mt)` | `dioload.c:579`: `exp(-here->DIOtGradingCoeff*log(arg))` |

ngspice's own comment (`mos1load.c:571-577`): "since most users use the
default grading coefficients of .5, and sqrt is MUCH faster than an
exp(log()) we use this special case code to buy time. (as much as 10% of
total job time!)". This is finding 4 of
[06-open-issues.md](06-open-issues.md), with its source.

A `pow` is 69 flops and 13.80 ns. `exp` and `log` together are 45 flops and
7.06 ns. A square root is one divider operation.

**Measured.** `softPow` is 11.57% of one thread on `bench_ngspice_mosamp`
(371 samples) and 4.62% on `chain_psp103_1k`. BSIM4's Newton evaluation
calls it nowhere. `softPow`'s own body is 48 of `pow`'s 69 flops; the rest
is its `expInline`. So `pow` is about 16.6% of the thread on `mosamp`
(inferred: time in proportion to flops). #258's profiles of the integration
build give 13.01% on `mosamp` and add the diode decks: 12.86% on
`vacask_graetz` and 13.07% on `vacask_mul`.

**Change.**

1. Stage 1, no dependency change: write the five sites the way ngspice
   does. A compare on a model parameter becomes a setup flag in VerA, so
   the branch takes the same arm every evaluation.
2. Stage 2, VerA: for `pow(x, k)` whose exponent is a setup constant
   (`par_exp`, `render_op.zig:194`), emit a setup flag `k == 0.5` and a
   select between `sqrt` and `pow`. For a literal exponent of 2 or 3, emit
   the multiplies. This covers models whose source is not ours: PSP103 has
   46 such sites.
3. Not in Gompute's `pow`: see the monotonicity note under question 4.
   Gompute's own comment (`math.zig:648-651`) says its test card's
   exponents never equal one half. A card that leaves `MJ` at its default
   does (`mos2.va:92`, `mj = 0.5`).

**Expected gain.** `mosamp`'s card sets no `MJ` and no `CJSW`
(`mosamp.cir:41-43`), so per Newton evaluation it runs two junction `pow`
at one half and one mobility `pow` at `uexp = 0.1` (inferred from the card
and `mos2.va:140-143`). As ngspice writes them: two square roots with one
divide each, and one `exp` and `log` at 7.06 ns. A square root and a divide
are 13 to 19 cycles of latency each (uops.info lists at most 13 for the
divide), so a pair is 6 to 7 ns at 4.4 GHz. That is 19 to 21 ns for 41 ns,
half of the `pow` time saved: **8 to 9% of one thread on `mosamp`** (0.49
to 0.54 × 16.6%). On a card with a fitted `MJ` every `pow` becomes `exp`
and `log`, which saves 49% of the `pow` time. Nothing on BSIM4.

**Oracle.** ngspice, which computes exactly these forms. A unit test:
`sqrt(x)` against `pow(x, 0.5)` within one ulp over the junction range,
red first on a wrong select. `tests/VERDICTS.tsv` unchanged by name.

**First step.** A census counter in `zPowK`: calls by exponent value on
`mosamp`, `pinv2000` and a diode deck. Done when the share of calls at one
half is a number.

### M2 Reciprocals of setup-constant divisors

**Class:** exact with a new family primitive; rounding without one.
**Files:** VerA codegen and `lib/contract/family.zig`; `src/device/dual.zig`.

**Today.** `x / c` with `c` a setup constant computes `x.v / c` and
`1.0 / c` on every evaluation (`dual.zig:232-234`). BSIM4's `core` has 100
such sites of 252 (the census). The `grep` below finds 46 distinct setup
roots among their divisors; the rest are literals such as `3.0`. MOS1 has
20 of 25, MOS2 46 of 68, the diode 15 of 21, PSP103 10 of 434.

```text
sed -n 12091,13702p bsim4va.zig | grep -o '\.div(S\.con([a-z]*\.[a-z_]*[^)]*))' | sort | uniq -c | wc -l   # 46
```

**Measured.** 18.1% of the Newton evaluation's samples are on a divide or
right after one: 6.9% of the thread on `chain_bsim4_1k`. Its 404 static
scalar divisions are 3% of its instructions.

**Change.**

- Exact: a primitive `divC(a, c: f64, r: f64)` with value `a.v / c` and
  lanes `a.d * r`, where VerA's setup computes `r = 1.0 / c` once per card.
  The same operations per value, so the same bits. It removes the
  reciprocal: at most 46 of the 404 static divisions (LLVM already merges
  reciprocals of one root and folds those of literals).
- Rounding: emit `a.scale(r)`. No contract change. It removes the quotient
  too: 146 of 404.

**Expected gain.** An upper bound, as if the divider were the only thing
those samples wait on: the removed fraction times 6.9%. Exact: 11%, so at
most **0.8% of one thread** on `chain_bsim4_1k`. Rounding: 36%, at most
**2.5%**. On an FP64-poor card the saving is per FP64 divide; its cost
there was not measured.

**Oracle.** Exact form: the `W == 1` family and `RefFamily` bit for bit,
corpus raws byte-identical. Rounding form: `tests/VERDICTS.tsv` unchanged
by name, an owner decision.

**First step.** Divider-busy cycles on `chain_bsim4_1k`: `perf stat` with
the divider event of this CPU (`arith.div_active` in `perf list`; name to
confirm). Done when the share of cycles with the divider busy is a number.
Close M2 and M3 if it is under 5%.

### M3 The divider in the dual family

**Class:** exact. **Files:** `src/device/dual.zig` only. Not a request to
either dependency; it is here because it is the same resource.

**Today.** A dual divide issues `a.v / b.v` and `1.0 / b.v` as two scalar
divisions (`dual.zig:232-233`). A `vdivsd` and a two-wide `vdivpd` both
take the divider for 4 cycles at a latency of 13 or less (uops.info, Alder
Lake-P). LLVM packs some: 36 two-wide divides in the Newton evaluation.
42 same-divisor pairs remain scalar.

**Change.**

1. Compute the pair as one two-lane divide: `@Vector(2, f64){ a.v, 1.0 } /
   @splat(b.v)`. IEEE per lane, so the bits are the same.
2. `sqrt`'s slope `0.5 / s` (`dual.zig:264`) as `0.5 * (1.0 / s)`. For a
   square root of a finite positive number `s` lies in `[2^-537, 2^512]`,
   so `1/s` neither overflows nor underflows and halving is exact: the two
   forms are the same bits. Then `x / sqrt(y)` computes `1.0 / s` once
   instead of `0.5 / s` and `1.0 / s`. BSIM4 has 6 such sites, PSP103 27.

**Expected gain.** 42 of 404 divisions, and 6 more: 12% of the divider
samples, at most **0.8% of one thread** on `chain_bsim4_1k`. The same
bound as M2: it holds only if the divider is busy, not merely late.

**Oracle.** `RefFamily` and the `W == 1` instantiation, bit for bit; the
unit test covers `s` at both ends of its range.

**First step.** M2's.

### M4 Fused multiply-add in Gompute's `pow`, `exp` and `log`

**Class:** rounding, once, an owner decision. **Files:** Gompute
`src/device/math.zig`; VerA `lib/contract/gm/` in the same change (M8).

**Today.** Every f64 body is FMA-free so that every target rounds alike
(`math.zig:19-22`). Gompute's rule allows the other way: one body with
explicit `@mulAdd` and no optional contraction (`Gompute/AGENTS.md:74`).

**Measured.** `pow` 13.80 ns against glibc's FMA body at 10.91; `log2`
4.82 against 3.39. `exp` and `log` already beat glibc.

**Change.** The ARM reference's FMA forms, written as explicit `@mulAdd`:
`exp` 21 flops to 14, `log` 24 to 18, `pow` 69 to about 48 (hand counts,
question 1).

**Expected gain.**

- Host, `pow` only, taking glibc's body as the price of an FMA one: 21% of
  the `pow` time. `chain_psp103_1k`: `softPow` 4.62%, `pow` about 6.6% with
  its `exp`, so **1.4% of one thread**. `mosamp`: 3.5% before M1, under 1%
  after. BSIM4: nothing.
- FP64-poor card, where the FP64 instruction count is the bound: BSIM4's
  device arm runs up to 59 `exp` and 27 `log` sites an evaluation. Seven
  and six fewer instructions each is 575 of the 4,231 value-side FP64
  flops: **14% of what is left after G4**, 5% before it (inferred, static).

**What it costs.** Three shipped x86 targets have no FMA: `x86_64`,
`x86_64_v2` and macOS x86 (`tools/release-targets.json`). There `@mulAdd`
is a library call per operation, many times slower than the two-rounding
form (`dual.zig:36-37` says the same of the lanes). Keeping one set of
value bits means those builds take that call inside every `exp`. The lanes
already differ in their last bit between the FMA and the non-FMA builds
(`dual.zig:217-219`, `family.zig:106-112`); the values do not, and this
would be the first value-side cost of that split.

**Oracle.** Gompute's ulp and monotonicity tests (`math.zig:2942`), and
host against device bit for bit.

**First step.** In Gompute's `BENCH=math`: an FMA-bodied `pow` and `log`
on `x86_64_v3` and on `x86_64`. Done when both prices are numbers. This is
worth doing for the GPU only if G4 lands; on the host it does not pay.

**Decided (owner, 2026-11-11): both bodies, selected at comptime by the
target.** The prices came in higher than the estimate above (1.38x on
`exp`, 1.24x on `log`, 1.64x on `pow` with FMA; 40 times slower without),
so neither single body serves every target. A target with a hardware
fused multiply-add takes the FMA body, the others keep today's, and no
shipped target is dropped. The cost is that value bits are one set per
FMA class, which the derivative lanes already are, and that a constant
fold must produce the target's class while it runs on the build host
([M8](#m8-one-math-provider-for-setup-and-core)). Software `@mulAdd` is
exact, so both bodies are tested on every host.

### M5 Calls: vector forms and clobbered registers

**Class:** exact. **Files:** Gompute (entry points), VerA (scheduling,
family primitives), `dual.zig`.

**Today.** Each `exp` and `log` is a call to an out-of-line function. All
vector registers are caller-saved, so every live dual value is stored
before and loaded after: 1,988 stack moves in the Newton evaluation, 15.2%
of its samples on them, 81 `vzeroupper`. Gompute's vector forms return the
scalar's bits lane for lane and cost 0.47 (`exp`) and 0.60 (`log`) of
scalar per element.

**Change, two independent parts.**

1. Vector calls. A family primitive `expN`/`logN` over a tuple, and a VerA
   pass that brings independent sites together. As generated today the
   groups are small: 20 of 67 `exp` sites and 4 of 27 `log` sites sit in
   same-guard pairs, none in fours. More needs guarded sites run
   speculatively, which VerA refuses on a host for a measured reason
   (`float/lanes.zig:38-46`). The other way to fours is across instances,
   which the `perf/lane-eval` branch does: it needs no scheduling and no
   speculation, and is limited by divergence instead
   ([question 5](#5-the-instance-axis)).
2. An `exp` and `log` entry that preserves vector registers. About half of
   the stack loads follow a call (four to seven reloads after each of the
   86). Whether Zig 0.18 offers such a convention on x86-64 was not
   checked.

**Expected gain.** `exp` and `log` are 13.8% of the thread on
`chain_bsim4_1k`. Part 1 with today's groups: 24 of 94 sites at about half
price is at most **1.7%**; a pair is two lanes, whose price OVERHEAD.md
does not give. With every call packed in fours: 6.5%, which is the bound of
the whole idea. Part 2: half of 15.2% of the evaluation body is at most
**2.9% of one thread**, and less in practice, since a reload from a store
just made is cheap.

**Oracle.** The scalar call, bit for bit (Gompute already tests this);
corpus raws byte-identical.

**First step.** A census counter per call site: `exp`, `log`, `pow`,
`sqrt` and `div` executed per evaluation, per model. It replaces the
inferred 30 to 40 above and is N4's first step. Then Gompute's two-lane
`exp` and `log` in `BENCH=math`. Close part 1 if two lanes cost more than
0.7 of scalar per element.

### M6 FP64-poor cards: the speculation policy and f32 lanes

**Class:** exact (the policy); tolerance (f32 lanes, as G4 says).
**Files:** VerA `src/codegen/device/codegen/kernel_text/math.zig:172-175`,
`lib/contract/build_config.zig`; `src/device/dual.zig`.

**G4 step 2 is not VerA's.** G4 asks VerA for "a dual whose derivative
lanes are f32". The contract already allows it: "Constants and results
cross as `f64` ... and device code never opens a value, so lanes may be
narrower than `f64`" (`family.zig:79-81`), and `RefFamily(comptime L:
type, ...)` takes the lane type. The family is ESPice's: `DualFor` needs a
lane element type. No request.

**G4 step 1, a static estimate of `d`.** A flop model over the source
census of BSIM4's `core`: an add costs 1 value flop and L lane flops, a
multiply 1 and 2L, a divide 2 and 2L, `exp` 21 and L, `log` 25 and L,
`sqrt` 2 and L, `pow` 71 and L, with L the lanes the operation carries.

| | Value flops | Lane flops | `d` |
|---|---|---|---|
| Arithmetic only, BSIM4 | 1,478 | 4,822 | 0.77 |
| Arithmetic only, PSP103 | 4,579 | 15,801 | 0.78 |
| BSIM4 with every divide and transcendental site run | 4,231 | 7,151 | **0.63** |
| BSIM4 with half of the transcendental sites run | 3,118 | 6,980 | **0.69** |

So `d` is about 0.65, not 0.8 (inferred; G4's own step 1 is the
measurement). The lane evaluation falls to 0.35 of itself, not 0.2. And
what remains is half transcendentals: 2,153 of the 4,231 value flops.

**The policy.** `zSpec` is an architecture switch: on NVPTX and AMDGCN a
select with a costly arm runs both arms (`render.zig:412-420`, #81: "a
branch costs the register allocator more than the arm"). On BSIM4 that
turns 3 always-run `exp` sites into 20 and leaves 39 behind model flags,
where the host has 48 behind data guards and runs the taken arm. On a card
whose FP64 rate is 1/64 of FP32, each speculated `exp` is 21 FP64
instructions.

**Change.** Make the policy a build fact the host sets, next to
`validating` in `build_config.zig`, defaulting to today's rule. ESPice
sets it per `-Dcuda-arch`.

**Expected gain.** Unknown sign. If the lazy arm brings the device's count
down to the host's 30 to 40 from as many as 86, that is about 1,000 to
1,200 FP64 flops of 4,231 on the value side: up to **28% of the kernel's
FP64 work after G4** (inferred). Against it stands the divergence and
register cost #81 measured.

**Oracle.** The host path, bit for bit: a select is exact, so both
policies give the same bits.

**First step.** Count `f64` operations in the PTX of BSIM4's lane kernel
under both policies, then time both on the RTX 4060. Done when the eager
policy's cost on that card is a number.

### M7 Contract facts

**Class:** exact, except the `limit_reads` row. Each row is one request:
name, type, meaning, consumer.

| Name | Type | Meaning | Consumer in ESPice |
|---|---|---|---|
| `field_use` | `[n_fields]contract.FieldUse`, one per `Instance` field in declaration order. `FieldUse = packed struct(u8) { res, jac, q, limit, state, w_update, w_commit: bool, _: u1 }` | Read bits: the field can reach a residual value (`res`), any derivative lane of `eval` or `q` (`jac`), a charge site's value (`q`), `limit`'s result, what `updateState` or `acceptQ` stage. Write bits: `updateState` or `acceptQ` writes it; `stateCtl` writes it. A superset; undeclared means every bit set | The bypass key ([C4](04-levers-cpu.md#c4-bypass-that-pays-on-production-models) step 2, findings 6 and 25): compare only fields with `res` or `jac`, since a hit re-reads the charge. `rebase` ([N3](09-after-the-levers.md#n3-one-charge-evaluation-per-accepted-step) part 2): a batch needs the re-read only if a field with a write bit has `q` set |
| `sim_reads` | exists: `contract.SimReads` (`lib/contract/sim_state.zig:94`) | Whether `eval`, `q`, `evalQ` read `t`, `dt`, `iteration` | `batch_bypass.zig:130`. BSIM4, PSP103 and the diode declare all false; MOS1 and MOS2 read `iteration`. No request |
| `limit_reads`, tight | exists: `u64` | BSIM4 and MOS1 declare all ones beside `limit_writes` of `0x170` and `0x3a` (`bsim4va.zig:16003-16004`, `mos1.zig:2554-2555`). MOS2 and the diode are tight | `stamp.zig:296`, `kernels.zig:141`, `lane_kernels.zig:221`. **Class: tolerance**, see below |
| Values-only evaluation | none needed | `eval` and `evalQ` are generic over the family; `RealFor` is the value-only one (`dual.zig:319`) | C2 stage 2. Costs one instantiation, see below |
| Sliced out-of-line cores | codegen, no decl | `core` out of line, one slice per role (`eval`, `q`), as `core__state` and `core__limit` already are | #259 |
| f32 lanes | none needed | [M6](#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes) | G4 |
| `speculate` | a field of `build_config` | M6 | The device kernels |
| `divC` | a family primitive | [M2](#m2-reciprocals-of-setup-constant-divisors) | `dual.zig` |

**What was verified by reading, for BSIM4.**

- **Fields that enter only the charge value.** The ten path latches,
  `pb__0` to `pb__4` and `pq__0` to `pq__4`, are read at
  `bsim4va.zig:13447-13456` and nowhere else in `core`, in the forms
  `(t - pb) * r` and `pq + that`, with `r` a setup constant
  (`model.su.r[112]`). The five sums leave `core` as `f3, f1, f7, f26,
  f28`. Those five are exactly the charge sites of `q`, `evalQ` and
  `acceptQ` (lines 15647, 15655, 15917), and the residual reads none of
  them. A latch is a constant inside the sum, so no derivative lane depends
  on it. So finding 25's condition holds: the latches reach no current and
  no derivative, and can leave the bypass key. Their `field_use` is `q`
  and `w_commit` only.
- **Whether the charge reads a state the commit writes.** Yes: the commit
  writes `pb := wb` and `pq += wq` (lines 15889 to 15903). But at the
  committed point the charge is unchanged by construction: `pb'` is the
  staged `t`, so `(t - pb') * r` is a zero, and `pq' + 0` is the charge
  `acceptQ` returned. The bits can differ only in the sign of a zero
  (inferred from the source; a unit test is the oracle). The third field,
  `bsim4va__held__VxNVt`, is different: `updateState` and `acceptQ` write
  it (15872, 15930) and `core` reads it into the bias-dependent values
  unless one of two model flags is set (line 12892). On a card that reads
  it, the charge after the commit is a new value and the re-read is needed.
  This is why BSIM4's `state_class` is `.history` and not `.path_latch`.
- **The limit core reads no unknown.** `bsim4va__common__core__limit`
  ignores its `x`, instance and `SimState` arguments (line 13705) and
  returns two literals. Its dead loops are gone from the machine code
  (`limitRangeHook`: no divide, no `exp` or `log` call). The ladder reads
  only what it clamps.

**`limit_reads` is inside a formula.** `snapLimited` takes its tolerance
from the largest `|cur[u]|` over the unknowns in `limit_reads`
(`stamp.zig:271-280`). Tightening BSIM4's mask from all ones to `0x170`
shrinks that maximum from 18 unknowns to 4, so the snap threshold moves and
with it the iterations where the limiting correction runs. A VerA change to
this mask changes ESPice's results. Either ESPice takes the scale from a
set of its own first (then the mask is free to tighten, exact), or the
tightening is a tolerance-class change with its gate.

**What a values-only entry costs in size (#259).** BSIM4's value-only core
is 30,527 bytes and already in the binary. Its 13 dual `evalRange`
instantiations are 947 KB. One values-only evaluation per model adds about
3% to that model's evaluation text, not a multiple of it, as long as it is
one instantiation and not one per sink. The multiple is the forced inline
of `core` into every instantiation. Taking `core` out of line as one
shared body would cost the charge passes: `q` keeps 34% of the value-only
core today because the rest is dead to it. So the request is sliced
bodies, one per role.

**First step.** VerA emits `field_use` for BSIM4 and MOS2; ESPice's test
asserts the two facts above (the latches' bits, and MOS2's six
`mos2__held__cap*` fields all clear, per finding 25).

### M8 One math provider for setup and core

**Class:** a determinism gate, not a speedup. **Files:** VerA
`lib/contract/gm.zig`, `lib/contract/gm/arm_{exp,log,pow}.zig`; Gompute
`math.zig`; `src/device/dual.zig`.

**Today.** Two ports of the same ARM routines are linked. Generated setup
code, the scalar limiters and VerA's constant folder call `contract.gm`
(`bsim4va.zig:103-130`; `gm.zig:5-7`: "exp, log and pow fold at compile
time to the bits a device computes at run time"). The dual family calls
`gompute.math` (`dual.zig:243-292`). Both are FMA-free. Nothing under
`src/` compares them (`grep -rn 'contract\.gm' src` finds nothing), and
VerA does not depend on Gompute (its `build.zig.zon` does not name it).

**Why it matters here.** Every "exact" hoist from `core` to setup moves a
call from one library to the other. So does every constant fold. M4 would
change one of the two.

**Change.** Either a differential test in ESPice (both libraries, bit for
bit, over the test inputs Gompute already uses), or VerA takes its math
from the host's module at build time.

**First step.** The test. Done when it is green, or names the first input
where the two differ.

**Decided (owner, 2026-11-11): VerA is going to consume `gompute.math`.**
One provider, so the test's four known differences end with
`contract.gm`. With M4's two classes the folder needs the target's body
by class, which `gompute.math` has to make reachable.

## Closed leads

| Lead | Finding |
|---|---|
| N5: lanes that are structural zeros | Already removed by VerA's masks and `DualFor.Of` (question 3) |
| About 400 `exp` and 630 `div` sites in `bsim4va.zig` | File-wide `grep` counts (403 and 633 in this copy). `core` on the host arm has 67 and 252 |
| `exp` and `log` are far above 20 cycles a call | 14 to 20, at or under glibc. The lever is the count and the divider, not the bodies |
| Hoist the model-only `pow` of the junction code (`f1`, `f2`, `mos2.va:145-146`) | VerA's if-conversion already runs them on the safe argument 1.0 when their arm is not taken, and `pow(1, y)` exits at `math.zig:710`. One compare |
| A dead loop in BSIM4's limit core | Dead in the source, absent from the machine code |
| A `ln(1 + exp(x))` kernel | No cheaper than `exp` and `log` without a new table method, which is new numerics for a 20% saving on those pairs |
| Reverse mode, or folding scale factors along a unary chain | A four-lane multiply is one µop on AVX2, so neither saves a host µop. On a device with f64 lanes they would; G4 is larger |
| Branchless `core` on the host | 0.81% of branches miss; all misses in the program are 2.5% of its cycles |
| Extend `traits.point_models` of `perf/lane-eval` to the MOSFETs | Breaks even at 1.14 runs per batch. VerA measured 1.8 to 2.6 in netlist order and 1.06 to 1.30 with signature groups (question 5) |
| The instance axis is closed on AVX2 (this page's first version) | Not by the arithmetic: VerA measured 1.5x and 2.0x on one path for BSIM4 and PSP103. It is gated, not closed (question 5) |
| Inline `exp`'s main path | 45 instructions at 63 sites is 2,800 more instructions per instantiation, 13 times over (#259), for calls that take 0.1% of the samples |

## Ranking

Gains are for one thread on the named deck. Every bound marked "at most"
assumes the resource it frees was the only thing its samples waited on.

### Gompute

| # | Request | Class | Where it pays | Expected gain | Risk |
|---|---|---|---|---|---|
| 1 | Merge `softExp`'s inf and NaN test into `expInline`'s range test (`math.zig:1206`, `1107`) | exact | Every `exp`, host and device | One compare per call; about 630 instructions per BSIM4 instantiation | None: same bits |
| 2 | A two-lane `exp` and `log` timing in `BENCH=math`, then a tuple entry if it is under 0.7 of scalar ([M5](#m5-calls-vector-forms-and-clobbered-registers)) | exact | Host | At most 1.7% on `chain_bsim4_1k` with today's groups | Needs VerA scheduling to matter |
| 3 | A register-preserving `exp` and `log` entry ([M5](#m5-calls-vector-forms-and-clobbered-registers)) | exact | Host | At most 2.9% on `chain_bsim4_1k` | Zig 0.18 support not checked |
| 4 | FMA bodies for `pow`, then `exp` and `log` ([M4](#m4-fused-multiply-add-in-gomputes-pow-exp-and-log)) | rounding, owner decision | FP64-poor cards after G4; `pow` on FMA hosts | 14% of the device's value-side FP64 work; 1.4% on `chain_psp103_1k` | The three x86 targets without FMA pay a library call per operation, or the value bits split by target |
| 5 | The differential test against `contract.gm` ([M8](#m8-one-math-provider-for-setup-and-core)) | gate | Every exact claim that moves a call | None; it protects the others | None |

Not requested: any shortcut inside `pow` for chosen exponents.

#### Measured (2026-11-11)

All five were built or measured in a Gompute 2.0.1 working tree, left
uncommitted (i9-14900HX, Zig 0.18.0-dev.349, `BENCH=math`, one P-core,
least of five rounds, beside other load; rows whose code did not change
move by up to 3% between two binaries, which is the bench's floor).

| # | Result | Verdict |
|---|---|---|
| 1 | Written, same bits over more than 1M inputs and the specials, red first on a dropped `-inf` case, green on the card (`examples/exhaustive`: 32 passed, each f32 sweep "0 of 2^32 differ"). Scalar `exp` 3.01 ns before and after; `cosh` 4.99 to 4.10 ns, probably because `softExp` is no longer inlined into it (inferred) | **No measurable gain.** It stays in the tree for the owner to take or drop; nothing here depends on it |
| 2 | Per element against scalar: `exp` 2.00 ns against 3.01 (0.66), `log` 2.82 against 3.73 (0.76); four lanes 0.45 and 0.51. The ratios held on three other builds | `exp` passes the 0.7 rule by 0.04 and `log` fails it. With 20 of 67 `exp` sites in pairs and a third off each, M5's bound of 1.7% falls to at most 0.9% of `chain_bsim4_1k`'s thread, and it still needs VerA's scheduling: **closed** |
| 3 | Zig 0.18 has no `preserve_all`, the one LLVM convention that keeps YMM registers. `regcall` keeps xmm8 to xmm15 at two lanes by moving the saves into the callee: 4.63 ns a call against 4.54 for the C convention; at four lanes every convention stores and reloads | **Closed**: not faster |
| 4 | FMA bodies after ARM's, bench-local, same worst ulp as the shipped ones (0.505, 0.508, 0.796 against 0.505, 0.508, 0.794). Scalar ns on `x86_64_v3`: `exp` 2.19 against 3.02, `log` 3.04 against 3.76, `pow` 7.85 against 12.87. On baseline `x86_64` the same bodies take 151, 126 and 338 ns (a library `fma` per operation) | The prices are in: 1.38x, 1.24x and 1.64x where FMA exists, 40 times slower where it does not. **Owner decision**, unchanged: one body on every target means either the three x86 targets without FMA go, or they pay |
| 5 | `exp`, `log`, `pow` (scalar and four lanes), `expm1`, `log1p` and `tanh` agree on every input, 1.47M per function. `log10` (2,636 inputs), `sinh` (26), `cosh` (120,995, the first at x = 1.0) and `atan` (the sign of `atan(-0)`, fixed in Gompute 2.0.1) differ; `sin`, `cos`, `tan` only in NaN payloads | **The gate is green for every exact claim on this page** (they move `exp`, `log` and `pow` only). The four that differ are [finding 28](06-open-issues.md#incidental-findings). The test is `src/device/tests/math_agree.zig`: a named function that stops differing, or an unnamed one that starts, fails it |

### VerA

| # | Request | Class | Where it pays | Expected gain | Risk |
|---|---|---|---|---|---|
| 1 | `field_use` per instance field ([M7](#m7-contract-facts)) | exact | BSIM4 and MOS2 bypass (C4), `rebase` (N3) | Unblocks C4 step 2 on BSIM4; N3 part 2 is part of its 10.5% on `chain_bsim4_1k` | A wrong bit is a wrong hit: the generator of #256 is its oracle |
| 2 | `sqrt` for a setup-constant exponent of one half, multiplies for literal 2 and 3 ([M1](#m1-pow-as-ngspice-writes-it) stage 2) | rounding | Junction charges of every SPICE2-era model; PSP103's 46 sites | 8 to 9% on `mosamp` (stage 1 gets this without VerA); PSP103 to be counted | Every raw with a junction capacitance moves in its last bits, toward ngspice's form |
| 3 | Setup reciprocals for setup-constant divisors: `divC` (exact) or `scale` (rounding) ([M2](#m2-reciprocals-of-setup-constant-divisors)) | exact or rounding | BSIM4 (100 of 252 divides), MOS1, MOS2, diode; FP64-poor cards | At most 0.8% exact, 2.5% rounding, on `chain_bsim4_1k` | The exact form adds a family primitive |
| 4 | The speculation policy as a build fact ([M6](#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes)) | exact | FP64-poor cards | Up to 28% of the kernel's FP64 work after G4; sign unknown | Divergence and registers (#81) |
| 5 | Sliced out-of-line cores ([M7](#m7-contract-facts)) | exact | Binary size (#259) | 947 KB of BSIM4 evaluation text is 13 inlined cores | A shared unsliced body would triple the charge pass |
| 6 | A scheduling pass that groups independent `exp` and `log` sites ([M5](#m5-calls-vector-forms-and-clobbered-registers)) | exact | Host | At most 6.5% on `chain_bsim4_1k` with every call packed | Needs speculation the host policy refuses today |
| 7 | Hoist card-only loops (BSIM4 `mtrlMod`, `bsim4va.zig:12255-12289`) | exact | Cards that set the flag | Up to 5 `exp`, 5 `log` and 5 divides per evaluation on those cards; nothing on default cards | Depends on M8 |
| 8 | Tight `limit_reads` for BSIM4 and MOS1 ([M7](#m7-contract-facts)) | tolerance until ESPice's snap scale stops reading it | The limit pass | Not sized | Moves the snap threshold |
| 9 | `ddx` as a per-point value, so a model with `ddx` keeps `batch_ok` ([question 5](#5-the-instance-axis)) | exact | 31 of the 88 models, BSIM4, PSP103 and MOS2 among them | None alone. It is the gate of every instance-axis measurement on those models. Behind it: at most 31 to 36% on `vacask_ring` and 11 to 15% on `chain_bsim4_1k`, if VerA's own ratios hold against ESPice's dual | Whether `ddx` is the only pin there is not determined |

Row 9 is ranked last because it pays nothing alone. The largest bound on
this page sits behind it, and so does the least certain one.

### In ESPice, with no dependency change

| # | Change | Class | Expected gain |
|---|---|---|---|
| 1 | [M1](#m1-pow-as-ngspice-writes-it) stage 1: the five `pow` sites of `mos1.va`, `mos2.va`, `diode.va` as ngspice writes them | rounding | 8 to 9% on `mosamp`; half of the `pow` time on fitted cards |
| 2 | A values-only evaluation where no Jacobian is used (C2 stage 2) | closed | C2 was rejected by the owner; without the held solve the confirming iteration uses its Jacobian |
| 3 | [M3](#m3-the-divider-in-the-dual-family): the paired divide and the `sqrt` slope | exact | At most 0.8% on `chain_bsim4_1k` |
| 4 | [M6](#m6-fp64-poor-cards-the-speculation-policy-and-f32-lanes): a lane element type in `DualFor` for G4 | tolerance | G4's, at `d` near 0.65 |
| 5 | [Question 5](#5-the-instance-axis): one number, PSP103's `evalQ` on one path in a struct-of-arrays family at W = 4 against `DualFor`. Needs VerA row 9 | exact | Decides a bound of 31 to 36% on `vacask_ring`; closes the lead under 1.3x |
| 6 | [Question 5](#5-the-instance-axis): merge `perf/lane-eval` as it is, mesa only, on the next free device ABI number (44 after wave 3), after the ReleaseSafe gate it never ran | exact | 6.3% fewer cycles on `device_mesa_oscillator` (#258) |

## Not determined

- Calls and divisions executed per evaluation. The 30 to 40 is inferred
  from shares; the census counter of M5 measures it.
- Whether the divider is busy or merely on the critical path. M2 and M3
  are bounds until the divider-busy counter is read.
- Whether `contract.gm` and `gompute.math` return the same bits (M8).
- The cost of an FP64 divide and of both-arm evaluation on the RTX 4060.
- A two-lane vector `exp` and `log`'s price per element.
- Whether `ddx` is the only construct that pins BSIM4, PSP103 and MOS2,
  and why VerA's note of 2026-10-02 could batch bsim4va and psp103.
- The ratio of a struct-of-arrays point family against ESPice's `DualFor`
  on BSIM4 and PSP103. VerA measured 1.5x and 2.0x against its own family;
  ESPice's first round recorded 1.0x to 1.25x on bsimcmg.
- Runs per batch between the Newton iterates of one solve.
- Why `d8b4a6af` measured the diode 14% slower on `vacask_graetz`: the
  commit says "likely" two paths and records no run count.
- Whether Zig 0.18 has an x86-64 calling convention with callee-saved
  vector registers.
- PSP103's `pow` exponents by value. Its 46 sites take setup roots; which
  equal one half on a real card needs the counter of M1.
