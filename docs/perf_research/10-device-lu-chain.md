# The device LU's chain: counts, roofline, literature, mechanisms

Why the device LU does not speed up on a card with 47 times the FP64 rate,
what the literature does about it, and which of those mechanisms keep the
host's bits. [05-levers-gpu.md](05-levers-gpu.md) holds the work packages
(G2, G7, G9, G5); this page holds their evidence.

Written by a research agent on 2026-11-10 from the recorded GPU trace, the
census logs and the sources in section 9. No GPU ran. One CPU census run
was made (`logic_psp103_10k`) as a held-out check of the timing model.

Tags on every literature number: **[T]** read in the source's table or text,
**[A]** abstract only, **[S]** the authors' own slides, **[V]** vendor or
vendor-staff claim. Numbers about this code are **measured**
(`docs/performance/gpu-phases.tsv`, census logs), **tool** (prediction of
`tools/gpu_extrapolate.py`) or **estimate** (arithmetic on this page,
assumptions stated). Section 8 lists everything that is not verified.

## 0. Findings

1. The chain is not "one step per pivot". `S_r` counts axpy and pivot steps:
   2,959 steps over 910 column levels on `logic_bsim4_10k` (3.25 per level).
   Collapsing source supernode runs alone can shorten it to no less than
   `2 * levels - 1` = 1,819 (1.6x). The larger cut needs the *destination*
   supernode as the unit, so that levels themselves collapse.
2. `T = 0.847 us * S_r + 50.0 ps * F` fits the two target decks exactly (two
   unknowns) and predicts the held-out `logic_psp103_10k` at 9.998 ms against
   8.900 ms measured (+12.3%). One span step costs about 1,730 clock cycles.
   The arithmetic that step needs is 8 cycles (mul, sub) or about 88 (with a
   division). The step is two orders of magnitude from its own latency floor.
3. The solve tail is a pure per-panel chain, independent of the deck: 23.1 to
   25.4 us per 64-row panel forward and 44.0 to 45.3 us back, on all three
   decks. It executes 3,072 sequential row steps per direction where the
   whole solve's dependency depth is 909 (logic) and 1,033 (sram).
4. On an A100 the tool predicts the tail panels as the largest LU term on
   both decks (48 to 73% of LU time per iteration), ahead of the refactor.
5. An axpy-form refactor cannot be FP64-bound on an A100 even with zero
   latency: it does 2 flops per 8 bytes of L (0.25 flop/B) and the card's
   balance point is 1.08 flop/B (L2 estimate) or 2.4 flop/B (DRAM). It
   crosses the balance point only when one loaded L value feeds 5 or more
   multiply-subtract pairs: destination supernodes of 5 or more columns.
6. No published mechanism for the launch or level-synchronisation bound is
   still open here. GLU3.0 pays about 132 us per level [T]; this kernel pays
   0.85 us per span step. What the literature has left to offer is
   supernodal/dense-block structure and batching.
7. Bitwise equality with the host column loop survives any schedule whose
   per-slot subtraction order is the host's stored order. It does not survive
   multifrontal extend-add, vendor BLAS, float atomics, reciprocal pivots,
   partitioned inverses, Jacobi or Neumann sweeps, or a different ordering
   (section 4).

## 1. What binds today (measured)

RTX 4060 Laptop, `gpu-phases.tsv` (commit `681b3ccd`); structure from the
census logs (`ZP_LU_STATS=1`, transient epoch).

| | logic_bsim4_10k | sram_bsim4_10k | logic_psp103_10k (held out) |
|---|---|---|---|
| n | 38,619 | 17,053 | 49,253 |
| L + U entries | 1,675,414 | 826,230 | 1,726,076 |
| F, multiply-subtract pairs per refactor | 155,737,938 | 40,064,439 | 149,498,527 |
| `S_r` (axpy + pivot steps on the critical path) | 2,959 | 3,617 | 2,982 |
| column levels / `S_L` = `S_U` | 910 / 909 | 1,034 / 1,033 | 918 / 917 |
| U entries (axpy steps in total), mean axpy length | 838,076, 185.8 | 413,277, 96.9 | 864,473, 172.9 |
| F per span step | 52.6 k | 11.1 k | 50.1 k |
| supernode links (adjacent column pairs) | 5,649 | 2,964 | 5,832 |
| F in runs of 16+ source columns / `rect_F` / `broken_run_F` | 90.6% / 83.4% / 5.4% | 77.9% / 84.4% / 1.2% | 89.9% / 81.7% / 7.0% |
| `arp_lu_refactor16` per call | 10,289.8 us | 5,065.9 us | 8,900.0 us |
| warp instructions, FP64 share | 599.1 M, 3.2% | 242.1 M, 1.7% | 424.9 M, 3.3% |
| active lanes per FP64 warp instruction, `2F / fp64_warp_inst` | 16.4 of 32 (51%) | 19.7 (62%) | 21.4 (67%) |
| L2 sectors per call (`gsect`) | 409.7 M | 78.3 M | 245.4 M |
| `lpanel` / `upanel` per call, panels | 1,110.0 / 2,111.6 us, 48 | 1,129.2 / 2,176.0 us, 48 | 813.5 / 1,416.3 us, 32 |
| per panel, forward / back | 23.1 / 44.0 us | 23.5 / 45.3 us | 25.4 / 44.3 us |
| `lhead` / `uhead` per call | 668.1 / 940.8 us | 179.0 / 269.7 us | 1,118.9 / 1,660.5 us |
| LU per Newton iteration (refactor + solve) | 15.12 ms | 8.82 ms | 13.91 ms |
| tail panels' share of that | 21% | 37% | 16% |

Two readings of the refactor time, both from measured counts:

| Model | logic | sram | psp103 (held out) |
|---|---|---|---|
| A. `a * S_r + b * F`, a = 0.847 us, b = 49.98 ps (fit to logic and sram) | 2.51 + 7.78 ms | 3.06 + 2.00 ms | predicts 9.998 ms, measured 8.900 (+12.3%) |
| B. tool's FP64 term `fp64_warp_inst * 64 / 207e9`, remainder per span step | 5.88 ms, then 1.49 us/step | 1.26 ms, then 1.05 us/step | 4.31 ms, then 1.54 us/step |

So the chain is 24 to 52% of the refactor on the two logic decks and 60 to 75%
on sram, at 0.85 to 1.5 us per span step, which is 2.8 to 5 us per column
level. The flop-proportional part is close to the 4060's FP64 pipe once the
half-empty warps are counted (b = 50 ps per pair against the pipe's 19.3 ps
is 39% of the pipe; lane occupancy is 51%).

What sits on one column level of the chain today (`kernels/lu.zig`,
`column`, `refactor`, with `refactor_growth_limit` = 1e-12 by default so the
growth test runs): the source's release store, the waiter's poll (`pause` is a
64 ns backoff, `lu_device.zig`), a barrier, the axpy's `dmap` and L loads from
global memory issued only after that barrier, the mul and sub, a barrier, the
L divisions (3 in sequence per lane for a 186-row L column), a 7-barrier
column-max tree, a barrier, the nonfinite scan and copy-out to `val`, a
barrier, the release. About 12 barriers, 2 to 3 dependent global-memory round
trips and 3 divisions per level, plus one barrier and one round trip per
further axpy step. A column wider than `col_max` (256 slots) works in `val`
itself, so there each step's `u` is a global store by one lane and a global
load by the others across the barrier, and every flop reads and writes its
destination in global memory. Trunk columns can be that wide (widest U
1,142 on logic, 2,000 on sram); how much of F and of the chain they hold is
not in the census. Which of these dominates is not measured (section 6, M0).

L2 sectors: the flops need about 0.31 sector per pair when the column works in
shared memory and a warp's loads coalesce (2 sectors of u16 `dmap` and 8 of
f64 L per 32 pairs), and at least 0.81 when it works in `val` (8 more to
load and 8 to store the destinations). That is 49 M to 126 M of logic's
409.7 M. The other 69 to 88% are consistent with done-stamp polls. That
reading of `gsect` (coalesced, per warp instruction) is inferred: the
per-lane reading would need 299 M sectors for psp103's flops alone and the
deck shows 245 M.

## 2. Roofline for the refactor

Conventions. A pair is one multiply and one subtract, never contracted, so it
is two FP64 instructions: the usable rate is half the DFMA figure (4060:
103.5 GFLOP/s, 51.75 G pairs/s; A100: 4.85 TFLOP/s, 2.425 T pairs/s).
Memory per refactor: `dmap`, 2 B per pair, streamed from DRAM (311 MB on
logic, larger than any L2); L values, 8 B per pair, from an L2-resident 13.7 MB
(logic) or 6.7 MB (sram) value array. A100 L2 rate is the 4.5 TB/s estimate in
`tools/gpu_devices.json`, not a measurement. "Chain, ideal" is an estimate:
`(S_r - levels) * 8 + levels * 88` cycles, with the tool's CPI of 4 and an
assumed 20 dependent instructions for an IEEE division. "Chain, today's step"
is `0.847 us * S_r`, scaled by 1.0 to 1.45 on the A100 (clock 2.04 against
1.41 GHz; the tool's rule for latency-bound kernels).

| | logic, 4060 | sram, 4060 | logic, A100 | sram, A100 |
|---|---|---|---|---|
| Arithmetic, `2F / rate` | **3.01 ms** | **0.77 ms** | 0.064 ms | 0.017 ms |
| `dmap` from DRAM, `2 B * F / DRAM` | 1.37 ms | 0.35 ms | 0.153 ms | 0.039 ms |
| L values through L2, `8 B * F / L2` | 1.25 ms | 0.32 ms | **0.277 ms** (est.) | 0.071 ms (est.) |
| Chain, ideal (estimate) | 0.05 ms | 0.06 ms | 0.07 ms | **0.08 ms** |
| **Best possible, binding term** | **3.0 ms, arithmetic** | **0.77 ms, arithmetic** | **0.28 ms, memory** (0.15 ms if the L2 estimate is low) | **0.08 ms, chain latency** (memory 0.07 ms) |
| Chain at today's step | 2.51 ms | 3.06 ms | 2.5 to 3.6 ms | 3.1 to 4.4 ms |
| Now | 10.29 ms measured | 5.07 ms measured | 2.29 to 4.57 ms (tool) | 1.13 to 3.12 ms (tool), 3.1 to 4.4 ms (model A) |
| Distance from best possible | 3.4x | 6.6x | 8x to 16x | 14x to 55x |
| FP64 pipe in use | 29% | 15% | 1.4 to 2.8% | 0.4 to 1.5% |

Reading it:

- **4060.** Arithmetic binds at best. logic is 3.4x away: 1.95x is half-empty
  FP64 warps (the tool's FP64 term, 5.88 ms) and 1.75x is everything else.
  sram's practical bound today is
  its chain (3.06 ms, larger than its arithmetic): the measured 5.07 ms is
  1.65x from `max(chain today, arithmetic)`. No exact mechanism takes the
  4060 below 3.0 ms on logic, and the host P-cores' nominal no-FMA rate
  (288 GFLOP/s) puts the same flops at 1.1 ms. The G2 brief's expectation
  ("host" on this card) stands.
- **A100.** The chain binds by 10x (logic) to 50x (sram) over every hardware
  term. For sram the tool's optimistic end (1.13 ms) treats the kernel as
  throughput-bound; model A says 60% of its 4060 time is chain, so expect the
  conservative end. A faster FP64 pipe (H100: tool says 1.71 to 3.43 ms on
  logic) buys nothing further.
- **What "arithmetic-bound" would take on the A100.** At 8 B per pair through
  L2 the memory term is 1.78 ps per pair against 0.41 ps of arithmetic. The
  kernel needs each loaded L value to feed at least 4.3 pairs before FP64
  binds. That is a destination supernode of 5 or more columns under one
  source panel (M1), or dense tiles. A wider batch does not do it: each lane
  has its own values.

The solves (logic): 1.68 M pairs is 32 us of arithmetic on the 4060 and
0.7 us on the A100; 27 MB of values and indices is 0.12 ms at the 4060's DRAM
rate; measured 4.83 ms per call. A100 (tool): `upanel` 2.11 to 3.06,
`lpanel` 1.02 to 2.04, `uhead` 0.21 to 0.42, `lhead` 0.15 to 0.59 ms, total
3.5 to 6.1 ms against the refactor's 2.3 to 4.6. sram: tail panels 3.3 to
4.8 ms against a refactor of 1.1 to 3.1. Whole LU per iteration on the A100:
5.8 to 10.7 ms (logic), 4.5 to 8.3 ms (sram), against 15.1 and 8.8 ms on the
4060.

## 3. Mechanisms in the literature

"Order" answers: can each value slot receive its subtractions in a fixed,
host-defined order, so that bits can equal a column loop?

### 3.1 Circuit-matrix LU, column level

| Mechanism (source) | Bound it removes | Requires | Order | Reported |
|---|---|---|---|---|
| Level sets with two modes: cluster mode, one kernel per level; pipeline mode, one kernel in which columns wait on their dependents (Chen, Ren, Wang, Yang, TPDS 2015; modes from NICSLU) | Launches and idle threads in narrow levels | Frozen pivots, left-looking refactor | Yes (left-looking columns) | GPU refactor against KLU refactor 24.24x (GTX580), 19.86x (K20x) average [T]; against 16-thread NICSLU 0.78x [T]; K20x has about 6x the GTX580's FP64 peak yet similar speed, bandwidth-bound at 51 to 54 GB/s achieved [T]; triangular solves stay on the host: the host is 3.16x faster than cuSPARSE on K20x [T] |
| GLU3.0, three modes by level size: small block (block per column, warps per block grown 2 to 32), large block (warp per subcolumn), stream mode (kernel per column on 16 streams once a level has 16 or fewer columns) (Peng, Tan, arXiv 1908.00204) | Idle warps and launch count in narrow levels | Hybrid right-looking, level sets with double-U dependency detection | **No**: right-looking updates through float atomics | TITAN X (Maxwell), single precision: 13.0x / 6.7x (arithmetic / geometric mean) over GLU2.0, 3.51x / 2.81x over 32-thread NICSLU [T]; ASIC_100ks 215.5 ms over 1,626 levels (1,557 in stream mode), about 132 us per level [T]; rajat15 (n 37,261, 968 levels) 71.1 ms [T]; first CUDA call is 40% of GPU time on ASIC_100ks [T] |
| SFLU, synchronisation-free: one launch, one block per column, busy-wait on a per-column dependency array in global memory (Zhao, Wen, Luo, Jin, Liu, Zhou, DAC 2021) | Per-level launches and barriers | Frozen pattern | Left-looking in stored `indexU` order per the slides [S]; paper not read | Titan RTX: 155.71x average over SuperLU, 8.21x over GLU, more than 1,000 matrices [A] |
| CKTSO-GPU (Chen; closed source, results document 2022-12-07) | Not described | "Slightly-dense" circuit matrices, flops per nonzero of L+U above 50 | Unknown | RTX 3090 against Xeon Gold 6130, 29 matrices: refactor 12.01x / 6.11x over CKTSO on 1 thread, 28.80x / 13.29x over KLU; solves 1.98x / 1.46x over CKTSO on 1 thread [T] |
| CKTSO on CPU: cluster and pipeline modes, no supernodes (arXiv 2411.14082) | Idle threads | — | Yes | Refactor 1.27 / 2.23 / 3.5 / 4.86x at 2 / 4 / 8 / 16 threads; triangular solve 1.2 / 1.63 / 2.04 / 2.3x [T] |
| HYLU: row-row, sup-row and sup-sup kernels chosen by sparsity; bulk and pipeline scheduling (Chen, arXiv 2509.07690; CPU only) | Low arithmetic intensity where supernodes exist, scalar code where they do not | Supernodes | Kernel-dependent: BLAS in sup-sup changes rounding | Xeon Gold 6130, 37 SuiteSparse matrices: 2.36x (one factorization) and 2.90x (repeated) geometric mean over MKL PARDISO [T] |

### 3.2 Supernodal and multifrontal on GPUs

| Mechanism (source) | Bound it removes | Requires | Order | Reported |
|---|---|---|---|---|
| cuDSS (NVIDIA documentation): default METIS nested dissection (`ND_NLEVELS` default 10), also AMD, COLAMD, BTF_COLAMD; hybrid execute mode decides CPU or GPU per part in the analysis and is "recommended for factorization and solving of small and medium-sized matrices"; uniform batch; superpanels on by default (internals not documented); `MULTIBLOCK` factorization for very sparse matrices | Latency of small parts (by not running them on the GPU), intensity (supernodes), batch | Its own ordering and pivoting | **Self-consistent only**: default kernels use atomics and differ run to run; `DETERMINISTIC_MODE` gives the same bits on the same GPU architecture and SM count, is "often slower", single GPU and single right-hand side, not with hybrid modes [T, docs]. Never the bits of an external column loop | No numbers in the docs. `PHASE_REFACTORIZATION` differs from `FACTORIZATION` only for COLAMD and BTF_COLAMD [T, docs]. Forum, RTX 3070 Ti, cuDSS 0.6.0: a user saw cuSPARSE faster on SuiteSparse circuit matrices; staff: "cuDSS can indeed have extra overhead compared to cuSPARSE, especially for smaller systems" [V] |
| cuSolverRF (NVIDIA documentation) | — | Same pattern, same pivoting across the sequence; a batched refactor API exists | Not stated | Deprecated in favour of cuDSS [T, docs] |
| SuperLU_DIST, GPU offload of the Schur-complement GEMMs above a size threshold; relaxed supernodes `NSUP`, `NREL` (Li, Lin, Liu, Sao, TOMS 2023, authors' preprint) | Arithmetic intensity | Supernodes | No (GEMM) | The offload "fails to fully utilize" the GPU "because each GEMM is too small"; larger supernodes and less offload are faster; GPU triangular solve on a V100 is "comparable to 8-Core CPU results" [T] |
| STRUMPACK: level-by-level traversal on the device; fronts of dimension 32 or less in a custom kernel, one thread block per front, one launch per size class per level; larger fronts through cuBLAS/cuSOLVER (Ghysels, Synk, Parallel Computing 2022) | Launch count and library latency for small fronts | Multifrontal, nested dissection | No (extend-add, vendor BLAS) | RTX 2060, level 1: 3.418 TFlop/s, 53% of the 6.451 single-precision peak [T]; V100, 17 matrices: 5x average, 4x median over SuperLU [T]; small problems lose to the CPU through allocation, copies, launch latency and synchronisation [T] |
| PanguLU: regular 2D blocks stored sparse, 17 sparse kernels chosen by decision trees, synchronisation-free block scheduling (Fu et al., SC'23) | Index traffic, low intensity, level barriers | A 2D blocking of the reordered matrix; no supernodes needed | Not as published (kernel choice changes association). A tile-task DAG with ordered per-entry chains could keep it | 2.53x geometric mean over SuperLU_DIST on 128 A100, 2.79x on 128 MI50; single-GPU kernel time 6.54x average; kernel selection plus sync-free scheduling 2.3 to 5.4x [T] |
| SSIDS: multifrontal, level-based task lists, one kernel per task type, child completion through atomically incremented counters (Hogg, Ovtchinnikov, Scott, RAL-P-2014-006; TOMS 2016) | Launch count | Symmetric indefinite | **Bit-compatible with itself** by "a defined order on each assembly operation" [T]; "not bit-compatible" with MA97, which uses the same rule [T] | K20: up to 7x over a multicore multifrontal code [T, preprint]; 4.6x in the journal abstract [A] |
| Subtree batching: whole elimination-tree branches on the device, small BLAS calls batched into one kernel, several batched kernels concurrently (Rennich, Stosic, Davis, IA3 2014 preprint) | Launch latency, "typically 4-15 usec" per kernel [T], and small-BLAS under-use | Supernodal Cholesky, subtrees that fit the device | No | K40: 16x16x16 DGEMMs at 100 Mflops with host round trips, 500 Mflops device-resident, 1.2 Gflops as one batch of 8,192, 34 Gflops as 64 concurrent batches ("340-fold") [T]; whole factorization 1.75x average over CPU on 94 matrices [T] |

### 3.3 Triangular solve

| Mechanism (source) | Bound it removes | Requires | Order | Reported |
|---|---|---|---|---|
| Level sets (cuSPARSE and predecessors) | — (the baseline) | Level analysis | Yes | Host 3.16x faster than cuSPARSE 5.0 on K20x for circuit matrices [T, Chen 2015] |
| Synchronisation-free, CSC push form, busy-wait on in-degree (Liu, Li, Hogg, Duff, Vinter, Euro-Par 2016) | Level barriers and analysis time | — | **No**: float atomic adds into `left_sum` | Titan X: 2.3x (single) and 2.14x (double) average over cuSPARSE, up to 5.95x / 3.65x; preprocessing 43.7x faster [T] |
| CapelliniSpTRSV: one thread per row on CSR (pull form), busy-wait, no level analysis (Su et al., ICPP 2020) | Barriers, idle lanes on thin levels | Many thin rows per level | **Yes**: each row is one thread's sequential chain | 245 matrices, GTX 1080, V100, RTX 2080 Ti: 6.84 GFLOPS, 4.97x over SyncFree, 4.74x over cuSPARSE [T] |
| Column, row and recursive block SpTRSV: triangular diagonal blocks, SpMV on square blocks (Lu, Niu, Liu, ICPP 2020) | Dependency depth per block, memory locality | Level-set reordering inside blocks | No as published (SpMV association, reordering); yes if each row keeps one ordered chain | Titan X (Pascal), Titan RTX, 159 matrices: recursive block 4.72x average (up to 72.03x) over cuSPARSE v2, 9.95x over SyncFree [T] |
| AG-SpTRSV: automatic scheduling framework (ACM TACO 2024) | — | — | Not read | A100, RTX 3080 Ti: 2.12x to 3.99x geometric mean over the state of the art [A] |
| Supernodal SpTRSV on GPU (SuperLU_DIST) | Intensity | Supernodes | No (BLAS) | V100 "comparable to 8-Core CPU" [T] |
| Partitioned inverse (Alvarado, Schreiber, SIAM J. Sci. Comput. 1993) | Depth: solve becomes a few sparse products | Factored inverse partitions | **No: different rounding** | [A] |
| Jacobi sweeps as an approximate triangular solve (Anzt, Chow, Dongarra, Euro-Par 2015); Neumann series | Depth | Tolerates an inexact solve (preconditioning) | **No: a different class, an approximation** | [A] |

### 3.4 Shortening the chain, and keeping the loop on the device

| Mechanism (source) | Bound it removes | Note for this code |
|---|---|---|
| Supernode amalgamation and relaxed supernodes (SuperLU `NREL`; HYLU) | Chain length and intensity, at the price of stored zeros | Relaxed supernodes add explicit zeros to L: `x - 0*u` keeps the value but can flip a signed zero and adds NaN paths; exact only for true supernodes |
| Subtree-to-subcube, subtree-level batching (Rennich; STRUMPACK; SSIDS) | Launches, by doing a tree level per launch | Already exceeded: one launch per refactor |
| Task DAG with busy-wait (SFLU, SSIDS counters, PanguLU scheduling array) | Level barriers | This is the present design |
| Persistent kernels (Gupta, Stuart, Owens, InPar 2012) | Launches | Present design. [A] only |
| Several columns per block (GLU3.0 small-block mode; Capellini's thread per row) | Idle lanes on thin columns | Levels of 64 or more columns hold 0.9% of F here (`narrow_F` = 99.1%) |
| CUDA graphs | Launch enqueue | Closed in this code (#219: under 0.5% of a call) |
| Uniform batch (cuDSS `UBATCH_SIZE`; cuSolverRF batch; Rennich) | Flops per chain step | Section 5, M4 |
| GPU-resident Newton or interior-point loop: Świrydowicz et al. (arXiv 2306.14337), refactorization-based solvers kept on the device for ACOPF | Host round trips | Factorization 2.4 to 3.4x, triangular solve 3.2 to 5.8x, 1.6 to 1.9x overall projected [T]; on a V100 cuSolverGLU is 1.3 to 1.4x and Ginkgo 1.05 to 1.3x faster overall than MA57; cuSolverGLU's factorization is about 3.4x faster while its triangular solves are about 40% **slower** than the CPU's [T]. Same shape as section 2: after the factor moves, the solves are the wall |
| MadNLP.jl with ExaModels.jl: data kept in device memory (Shin, Pacaud, Anitescu, arXiv 2307.16830) | Host round trips | "An order of magnitude" over CPU tools [A] |

No primary source read in full for this page keeps a whole circuit Newton
iteration (device evaluation, stamp, refactor, solve, convergence gate) on the
device with numbers. The two circuit-solver papers read both leave the solves
or the loop on the host (Chen 2015 [T]; GLU3.0 [T]).

## 4. The bitwise rule

A slot's final bits depend only on the order of its own subtractions and on
each product being rounded before the subtraction. Which thread, block, warp
or time a subtraction runs in is free. So:

| Keeps the host's bits | Cannot keep them |
|---|---|
| Any left- or right-looking schedule whose per-slot order is the host's stored U order | Multifrontal extend-add (sums children before the parent's own terms) |
| Supernode panels and dense tiles with a sequential `acc -= l * u` chain per entry in stored order (the host's `panelRows`) | Vendor BLAS GEMM, TRSM, GETRF (FMA and internal order) |
| A batch of value sets, each lane running the column loop (`W == 1` is the oracle) | Float atomics (not even run-to-run stable; cuDSS documents this) |
| Loads, waits and publishes moved in time | Reciprocal pivots (measured here: 12% faster, not bitwise), Markstein division is bitwise but measured 5 to 7% slower |
| | Partitioned inverses, Jacobi or Neumann triangular solves (approximations) |
| | A different ordering, including one that only shortens the trunk, unless the host adopts it |
| | Relaxed supernodes with stored zeros (signed zero, NaN paths) |

One subtlety in this code: the host's stored U order is the DFS topological
order, not ascending. A supernode's columns can be non-adjacent in it:
`broken_run_F` is 5.4%, 1.2% and 7.0% of F on the three decks. Those flops
must stay on a per-column path, or the host's order must be made
supernode-contiguous, which moves rounding on both backends (the repo's
"rounding" class; `lu_panel.enter` already documents such a move under
`sn_dfs`).

## 5. Mapping onto `kernels/lu.zig` and `lu_tables.zig`

### M1. Supernode chunk as the refactor's ticket unit, with source runs

Removes: chain length (levels collapse inside a chunk), index traffic
(`dmap` for the rectangular part), low intensity (one L value feeds every
column of the chunk). Sources: SuperLU supernodes, HYLU sup-sup, PanguLU's
scheduling, this repo's `lu_panel.panelRun`.

- **Tables** (`lu_tables.build`, from `SparseLu.panels`, `sn_of`,
  `panel_rows` and the per-epoch run table of [C1](04-levers-cpu.md#c1-supernode-panels-in-the-refactor-replay)):
  a chunk table (first column, column count; a chunk is consecutive columns of
  one supernode with `columns * width` inside the shared-memory budget); per
  destination column a run list (source supernode, first source column, run
  length), a run being U entries of one supernode adjacent in stored order,
  which is the census's definition; per (chunk, source supernode) one
  row-to-slot map instead of one `dmap` entry per flop. `dmap`, `ul0`, `ulen`
  stay for single columns and broken runs.
  Index bytes on logic: 311 MB today; at most `311 * (0.166 + 0.834 / 16)` =
  68 MB when the 83.4% rectangular flops share a map across runs of 16.
- **Block shape.** 64 lanes stay (128 and 256 measured slower). Lanes stride
  destination rows; a lane runs `acc -= L[i, s_j] * u_j` for j in run order,
  which is `panelRows(1, ...)`: the kernel body is the host's, with the lane
  axis on rows instead of SIMD width. Phase 1, external runs, for all columns
  of the chunk with no barrier inside a run's rectangular part. Phase 2, the
  in-chunk sweep: for each column in order, apply it to the chunk's later
  columns, test the pivot, divide; one in-block step per column.
- **Shared memory.** `Shared.w` is `col_max` = 256 slots today; a chunk needs
  `columns * width` slots and 48 KB holds about 5,900. Columns wider than
  256 slots already work in `val` (`local == false`), so a chunk of wide
  columns works in `val` too, with the next pivot column and the run's U
  values staged in shared memory (one column of 2,000 slots is 16 KB). A
  larger scratch costs resident blocks: the 2,048-slot scratch measured
  slower before. The width distribution along the critical path belongs in
  the census.
- **Ticket granularity.** `takeTicket(sy, 0, ...)` hands out chunks. Simplest
  publish: keep one done stamp per column and release the chunk's stamps
  together, so waiters and `syncLen` do not change.
- **Constraints touched.** Bitwise holds when, for every column of a chunk,
  the in-chunk sources are the last entries of its stored U order and each
  external run is adjacent. `build` tests this per column and falls back to
  today's per-column path otherwise. No FMA: the chain is a mul then a sub as
  today. No float atomics. Written once in Zig: yes, `panelRows` is the
  shared body.
- **Cannot keep bitwise if**: relaxed supernodes are used to lengthen chunks,
  or the fallback is avoided by reordering only on the device.

### M2. Solve tail: loads off the chain, sweep by in-panel level

Removes: latency per panel. Sources: block SpTRSV (Lu, Niu, Liu), Capellini's
ordered row chains.

- **(a) `loadBlock` before the waits.** In `lpanel` and `upanel` the dense
  in-panel block is loaded from global memory after the last earlier panel
  has published, one entry at a time, three loads per entry, not unrolled. Its
  inputs (`val` after the refactor, the index tables) are final before the
  kernel starts. Table change: one u32 per tail row and direction, the first
  in-panel entry (`tl_in`, `tu_in`, 24.6 KB for 3,072 rows), so the block
  loads first and `gatherUntil` stops at that offset. Kernel change: move the
  call above the `while (j < b)` loop and unroll it like `gather`. Exact.
- **(b) Sweep by in-panel dependency level.** Today each panel takes 64
  barrier steps forward and 128 back (the back sweep divides one row per step
  under two barriers), whatever the block's sparsity. Table change: per panel
  the rows grouped by in-panel level. Kernel change: at each level the lanes
  owning its rows apply their masked entries in ascending (forward) or
  descending (back) column order with the same `yc == 0` skip, and in the
  back sweep divide. Per-row order is unchanged, so exact. Steps per
  direction fall from 3,072 to the sum of in-panel levels, which is at least
  the tail's dependency depth (at most `S_L` = 909 on logic, 1,033 on sram)
  and at most 3,072.
- **(c) The back sweep's division** stays an IEEE `/` on the chain. A
  reciprocal is the "rounding" class.
- **Constraints touched.** None. `PanelShared` keeps its size.

### M3. Shorter steps in today's per-column kernel

All exact, all inside `column` and `refactor`.

- **Release before the growth test.** Order today: divisions, 7-barrier
  column-max tree, barrier, copy-out, barrier, release. The waiters need the
  values, not the verdict; the fail word is a max read after the launch.
  Reorder to copy-out, barrier, release, then the tree and the fail RMW.
- **Loads issued before the barrier.** The stored-order loop preloads only
  the next step's `ul0` and `ulen`. Issue the next step's first `dmap` and L
  loads (the code already groups 4 per lane) ahead of the step-end barrier.
  Cost: registers, 48 today. With a 65,536-word register file per SM (from
  memory of the CUDA capability table, not re-read) that is 21 blocks of 64
  threads at 48 registers and 17 at 60, and fewer resident blocks measured
  slower before.
- **The U part of a wide column in shared memory.** For a column wider than
  `col_max` the chain's `u` values cross the barrier through global memory.
  Keep the first `nuk + 1` slots (at most 1,143 on logic, 9 KB) in shared
  memory and only the L part in `val`. Same resident-block cost as above.
- These shorten `a` for whatever stays per-column after M1 (single columns,
  broken runs) and are the cheapest way to learn what a step is made of.

### M4. Batch axis: a lane is a value set

Removes: flops per chain step, by W. Sources: cuDSS uniform batch,
cuSolverRF batch, Rennich's batching; in this code, the existing lane
refactor.

- **Tables.** `Tab` and every index table unchanged, shared by the batch.
  `val` and `a` gain a lane dimension, interleaved (`slot * W + lane`) so a
  warp's loads coalesce.
- **Block shape.** W lanes walk one column sequentially in host order; index
  loads happen once per warp, control flow is uniform, FP64 warps are full.
  The `W == 1` instantiation is `refactorColumns` itself.
- **Constraints.** Bitwise by construction. Fail word per lane. Memory W times
  13.7 MB (logic).
- **Limit.** Only for workloads with many value sets on one pattern (sweeps,
  corners, Monte Carlo). A single transient has W = 1. And it ends
  memory-bound on an A100, not FP64-bound (section 2).

### M5. Resident Newton loop

[G5](05-levers-gpu.md#g5-a-resident-newton-loop-where-the-host-is-the-bound)'s brief, unchanged.

After M1 and M2 an A100 iteration's LU is a few milliseconds at most against
86 us of host work plus 219 us of waiting per evaluation. The brief's 30%
threshold is reached only if the device side of an iteration (evaluation
included) falls to about 0.7 ms.

### M6. 4060 only: full FP64 warps

Active lanes per FP64 warp instruction are 51 to 67%. If the FP64 pipe's cost
is per warp instruction (the tool's model, not verified), a uniform trip
count per lane with the discard slot for the padding saves at most
`fp64 term * (1 - occupancy)`: 2.9 ms (logic), 0.48 ms (sram), 1.4 ms
(psp103). Irrelevant on an FP64-class card (FP64 term 0.13 ms on logic).

### Not worth taking

| Mechanism | Why |
|---|---|
| GLU3.0's three modes | They trade launches against idle warps. This kernel has one launch and pays 0.85 us per step against about 132 us per level |
| CUDA graphs, persistent kernels | Closed (#219) and already the design |
| Float-atomic right-looking or push-form updates | Not reproducible, closed |
| Multifrontal, vendor BLAS, cuDSS | Cannot give the host's bits; cuDSS's deterministic mode is self-consistency, slower, and excludes hybrid |
| Partitioned inverse, Jacobi, Neumann | A different class: rounding or approximation |
| Many thin columns per block | 0.9% of F; not measured as a share of time |

## 6. Ranked list for an FP64-class card

A100 figures are tool predictions per Newton iteration: logic LU 5.8 to
10.7 ms (refactor 2.3 to 4.6, tail panels 3.1 to 5.1, heads 0.4 to 1.0);
sram LU 4.5 to 8.3 ms (refactor 1.1 to 3.1, tail 3.3 to 4.8, heads 0.1 to
0.4). Scenario lines are illustrations of the formula, not predictions.

| # | Mechanism | Class | Expected gain, as arithmetic | Measurement that confirms it before building |
|---|---|---|---|---|
| 0 | **M0, measure the step** (not a mechanism; prices 1 to 3) | — | — | On the 4060: (i) refactor with `refactor_growth_limit = 0` against the default; the difference is `levels * 7 * t_barrier` (910 and 1,034 levels), which yields `t_barrier`. (ii) A two-block ping-pong through a done stamp, for the handoff time. (iii) A 64-lane block doing K barrier steps of one mul-sub each, once through shared memory and once through global memory, for `t_in` and for the wide-column step. One kernel each, no solver change. (iv) Host census: the share of F and of critical-path steps in columns wider than `col_max` |
| 1 | **M1, supernode chunks with source runs** | exact, with per-column fallback | Chain term today: `0.847 us * S_r` = 2.5 ms (logic), 3.1 ms (sram); on the A100 2.5 to 3.6 and 3.1 to 4.4 ms, which is 55 to 100% of the predicted refactor. After: `H * a + (S_r - H) * t_in`, H = handoffs on the critical path with chunks as nodes, `t_in` at least 88 cycles (62 ns at 1.41 GHz). Scenarios on logic, A100: H = levels/4, `t_in` = 0.3 us gives 1.1 ms; H = levels/16, `t_in` = 0.1 us gives 0.36 ms. Flop term: L traffic falls by the chunk's column count m (0.277 ms / m), `dmap` to under a quarter; with m of 5 or more the kernel is past the A100's balance point. Refactor 2.3 to 4.6 ms becomes about 0.4 to 1.2 ms. Source runs alone (no destination chunks) are capped at `S_r / (2 * levels - 1)`: 1.63x (logic), 1.75x (sram) | Host census, no GPU: (i) H, the critical path with chunks as nodes (G2 step 2); (ii) the chunk-size distribution along that path; (iii) the share of F in columns whose in-chunk sources are last in stored order (the analogue of `broken_run_F`). Then `t_in` from M0. Go if `H * a + (S_r - H) * t_in` is under half of `a * S_r` |
| 2 | **M2, solve tail** | exact | Tail today: 48 panels * (23.1 + 44.0 us) = 3.2 ms on the 4060 (21% of logic's LU, 37% of sram's); A100: 3.1 to 5.1 ms (logic), 3.3 to 4.8 ms (sram), the largest LU term there. After: `tail * (1 - l - s * (1 - L_p / 64))`, l = `loadBlock`'s share of a panel's time, s = the sweep's share, L_p = mean in-panel levels. Bound from the census: sweep steps 3,072 per direction against a dependency depth of at most 909 (logic), 1,033 (sram). Scenario l = 0.35, s = 0.4, L_p = 19: tail * 0.37, saving 2.0 to 3.2 ms per iteration on logic | (i) Three variants of `lpanel` on the 4060 with all stamps pre-published: as is, `loadBlock` skipped, sweep skipped; gives l and s. (ii) Host census: in-panel level count per panel. Go if `l + s * (1 - L_p / 64)` is above 0.3 |
| 3 | **M3, release before the growth test; loads before the barrier** | exact | `levels * 7 * t_barrier` plus `(S_r - levels) * t_load`: with 100 ns barriers and 150 ns loads (assumed, see M0), 0.64 + 0.31 = 0.95 ms of logic's 2.5 ms chain, 0.72 + 0.39 = 1.1 ms of sram's 3.1 ms. The shared-memory U part removes a further global round trip per step on wide columns. Applies to what M1 leaves per-column | M0 (i) is the measurement for the first half. For the second: the A/B itself, 20 lines; watch resident blocks (registers) |
| 4 | **M4, batch of W value sets** | exact | Flops per chain step times W, time per step unchanged. FP64 work equals chain time at W = `t_step * 2.425e12 / (F / S_r)`: 55 lanes (logic), 263 (sram) at a 1.2 us step. Throughput then ends at the L2: 1.78 ps per pair (5.6e11 pairs/s), 4.3x under the FP64 pipe | Count the workloads: sweeps over decks of this size with a shared pattern. No GPU measurement needed for the arithmetic |
| 5 | **M5, resident Newton loop** | exact | Host and wait 305 us per evaluation: 3 to 5% of today's predicted A100 LU, 13 to 23% once the LU is 1 to 2 ms | After 1 and 2: per-iteration host share on the card, as the G5 brief says |
| 6 | **Ordering that cuts the trunk** (dissect the etree's chain into p parts) | mode or rounding; **not bitwise with the AMD host** | Chain `S_r` to about `S_r / p` plus separator work; flops on the dissected part up by as much as 4x (fronts of 2w instead of w; an estimate). On the A100 logic's chain is 9x to 13x above the memory term and 40x above arithmetic, so the trade is favourable there and wrong on the 4060. The general form is closed here (level-structure ND: 116x fill) | Host census only: F, `S_r` and levels under a p-way split of the AMD etree's trunk, p = 2, 4, 8. Go only if the owner accepts a backend-specific ordering |

Order of work: M0, then 2 and 3 (days each, exact, no fallback path), then
the census for 1, then 1.

Even with 1 to 3 done, a single transient does not make an A100 FP64-bound on
these decks: the refactor would sit near 0.4 to 1.2 ms against 0.064 ms of
arithmetic, and the solves have 0.7 us of arithmetic in milliseconds of chain.
What these mechanisms buy on that card is an LU of roughly 2 to 4 ms per
iteration instead of 6 to 11 ms.

## 7. What this changed in the briefs

- [G2](05-levers-gpu.md#g2-supernode-panels-in-the-device-lu) takes the
  destination supernode chunk (M1) as its unit, since source runs alone cut
  the chain by at most 1.63x to 1.75x; its panel works in `val`, not in
  shared memory; M0 and M3 are its first steps.
- [G7](05-levers-gpu.md#g7-the-dense-tail-of-the-device-solves) starts
  with M2, which needs no new storage.
- [G9](05-levers-gpu.md#g9-lanes-of-a-thick-circuit) is M4, and ends bound
  by L2 traffic, not by the FP64 pipe.
- The page's first reading of the refactor ("memory traffic") is kept
  beside the chain model in
  [05-levers-gpu.md](05-levers-gpu.md#what-binds-each-kernel): the sector
  count explains the two logic decks and misses `sram_bsim4_10k` by 2x.

## 8. Not verified

Literature:

- SFLU (DAC 2021): paywalled; abstract, the authors' ASP-DAC 2024 slides and
  the repository README only. Its per-entry order is read from slides.
- Abstract only: AG-SpTRSV (TACO 2024), Anzt, Chow, Dongarra (2015), Alvarado
  and Schreiber (1993), Shin, Pacaud, Anitescu (2023), Gupta, Stuart, Owens
  (2012), the SSIDS journal figure.
- Not retrieved: SuperLU_DIST 3D triangular solve (SC'23, 404); NICSLU's own
  papers (described through Chen 2015 and CKTSO); Demmel et al. 1999 (cited
  through `lu_panel.zig`); an MDPI paper on a GPU nonlinear circuit solver
  that a search surfaced (HTTP 403), so no circuit-simulation source for a
  device-resident Newton loop is cited.
- cuDSS: superpanels are not described; pivot reuse in refactorization for
  orderings other than COLAMD is not stated; only the `/latest` docs were
  read. cuSolverRF: the batch functions' descriptions were not read.
- CKTSO-GPU is closed source: results document and README only.

This code:

- The split of a span step into barriers, memory round trips, divisions and
  poll latency is from reading the code. No barrier, load or handoff time is
  measured (M0).
- `a = 0.847 us` and `b = 50 ps` come from two decks; one held-out deck is
  +12.3%. Model B gives 1.05 to 1.54 us per step. The census decks were
  matched to the measured decks by n only.
- The A100 L2 rate (4.5 TB/s) is an estimate in `tools/gpu_devices.json`;
  every A100 memory term and the 1.08 flop/B balance point inherit it.
- The ideal-chain floor uses CPI 4 and a 20-instruction division: assumed.
- `gsect` as coalesced sectors per warp instruction, and so "69 to 88% of
  sectors are polls", is an inference from the psp103 arithmetic. The share
  of F in columns wider than `col_max` is not in the census.
- The SM register-file size used in M3 is from memory.
- That the FP64 pipe costs per warp instruction regardless of active lanes
  (M6) is the tool's assumption.
- H, in-panel level counts, chunk eligibility, and `loadBlock`'s share are
  not in any census or trace read for this page. The scenarios in section 6 are
  illustrations.
- The 4x flop growth for item 6 is an estimate, not a count.

## 9. References

1. S. Peng, S. X.-D. Tan. GLU3.0: Fast GPU-based Parallel Sparse LU Factorization for Circuit Simulation. arXiv:1908.00204 (IEEE Design & Test 2020). https://arxiv.org/abs/1908.00204
2. J. Zhao, Y. Wen, Y. Luo, Z. Jin, W. Liu, Z. Zhou. SFLU: Synchronization-Free Sparse LU Factorization for Fast Circuit Simulation on GPUs. DAC 2021. https://doi.org/10.1109/DAC18074.2021.9586141 ; code https://gitee.com/ssslab/sflu
3. Z. Jin et al. Machine Learning and GPU Accelerated Sparse Linear Solvers for Transistor-Level Circuit Simulation: A Perspective Survey. ASP-DAC 2024, slides. https://www.aspdac.com/aspdac2024/archive/pdf/1E-4.pdf
4. X. Chen, L. Ren, Y. Wang, H. Yang. GPU-Accelerated Sparse LU Factorization for Circuit Simulation with Performance Modeling. IEEE TPDS 26(3), 2015. https://nicsefc.ee.tsinghua.edu.cn//nics_file/pdf/publications/2015/IEEE%20TPDS_147.pdf
5. X. Chen. CKTSO: High-Performance Parallel Sparse Linear Solver for General Circuit Simulations. arXiv:2411.14082. https://arxiv.org/abs/2411.14082
6. X. Chen. CKTSO-GPU, results document (version 20221207) and README. https://github.com/chenxm1986/cktso-gpu
7. X. Chen. HYLU: Hybrid Parallel Sparse LU Factorization. arXiv:2509.07690. https://arxiv.org/abs/2509.07690
8. NVIDIA. cuDSS documentation: general, advanced features, types. https://docs.nvidia.com/cuda/cudss/latest/general.html , https://docs.nvidia.com/cuda/cudss/latest/advanced_features.html , https://docs.nvidia.com/cuda/cudss/latest/types.html
9. NVIDIA Developer Forums, cuDSS thread, August 2025. https://forums.developer.nvidia.com/t/cudss/341462
10. NVIDIA. cuSOLVER documentation (cuSolverRF). https://docs.nvidia.com/cuda/cusolver/index.html
11. X. S. Li, P. Lin, Y. Liu, P. Sao. Newly Released Capabilities in the Distributed-Memory SuperLU Sparse Direct Solver. ACM TOMS 2023, authors' preprint. https://piyush314.github.io/assets/pdf/superlu-v7-toms.pdf
12. P. Ghysels, R. Synk. High performance sparse multifrontal solvers on modern GPUs. Parallel Computing 110, 2022. https://escholarship.org/content/qt7tv84567/qt7tv84567.pdf
13. X. Fu et al. PanguLU: A Scalable Regular Two-Dimensional Block-Cyclic Sparse Direct Solver on Distributed Heterogeneous Systems. SC'23. https://doi.org/10.1145/3581784.3607050 ; authors' copy http://www.ssslab.cn/assets/papers/2023-fu-PanguLU.pdf
14. J. Hogg, E. Ovtchinnikov, J. Scott. A sparse symmetric indefinite direct solver for GPU architectures. RAL-P-2014-006 (ACM TOMS 42(1), 2016). https://epubs.stfc.ac.uk/manifestation/12369998/RAL-P-2014-006.pdf
15. S. Rennich, D. Stosic, T. Davis. Accelerating Sparse Cholesky Factorization on GPUs. IA3 2014 preprint (Parallel Computing 59, 2016). https://people.engr.tamu.edu/davis/publications_files/IA3_2014_Workshop_Rennich_Stosic_Davis_preprint.pdf
16. W. Liu, A. Li, J. Hogg, I. Duff, B. Vinter. A Synchronization-Free Algorithm for Parallel Sparse Triangular Solves. Euro-Par 2016. http://www.ssslab.cn/assets/papers/2016-liu-sptrsv.pdf
17. J. Su et al. CapelliniSpTRSV: A Thread-Level Synchronization-Free Sparse Triangular Solve on GPUs. ICPP 2020. https://doi.org/10.1145/3404397.3404400 ; http://www.ssslab.cn/assets/papers/2020-su-capellinisptrsv.pdf
18. Z. Lu, Y. Niu, W. Liu. Efficient Block Algorithms for Parallel Sparse Triangular Solve. ICPP 2020. https://doi.org/10.1145/3404397.3404413 ; http://www.ssslab.cn/assets/papers/2020-lu-sptrsv.pdf
19. AG-SpTRSV: An Automatic Framework to Optimize Sparse Triangular Solve on GPUs. ACM TACO 2024. https://doi.org/10.1145/3674911
20. H. Anzt, E. Chow, J. Dongarra. Iterative Sparse Triangular Solves for Preconditioning. Euro-Par 2015. https://doi.org/10.1007/978-3-662-48096-0_50
21. F. Alvarado, R. Schreiber. Optimal Parallel Solution of Sparse Triangular Systems. SIAM J. Sci. Comput. 14(2), 1993. https://doi.org/10.1137/0914027
22. K. Świrydowicz et al. GPU-Resident Sparse Direct Linear Solvers for Alternating Current Optimal Power Flow Analysis. arXiv:2306.14337. https://arxiv.org/abs/2306.14337
23. S. Shin, F. Pacaud, M. Anitescu. Accelerating Optimal Power Flow with GPUs: SIMD Abstraction of Nonlinear Programs and Condensed-Space Interior-Point Methods. arXiv:2307.16830. https://arxiv.org/abs/2307.16830
24. K. Gupta, J. Stuart, J. Owens. A Study of Persistent Threads Style GPU Programming for GPGPU Workloads. InPar 2012. https://doi.org/10.1109/InPar.2012.6339596

Local inputs: `docs/performance/gpu-phases.tsv`, `tools/gpu_extrapolate.py`,
`tools/gpu_devices.json`, `src/solver/kernels/lu.zig`, `lu_tables.zig`,
`src/solver/lu_panel.zig`, `lu_census.zig`, `lu_device.zig`, and census
logs of the three decks (`ZP_LU_STATS=1` on a build with
[census.patch](census.patch)).
