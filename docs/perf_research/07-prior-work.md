# Prior work: what is closed, and what the literature measured

Read this before proposing a lever. Part one lists what this codebase
already built or measured and dropped; a brief in
[04-levers-cpu.md](04-levers-cpu.md) or [05-levers-gpu.md](05-levers-gpu.md)
that touches a closed idea names the row here and the new argument. Part two
lists published numbers, each tagged by how it was read.

## Closed in this codebase

The first research round lives in git history: `git show
80d48d80^:docs/performance/TODO/<page>.md` (pages `01` to `10`, `README.md`,
`REMAINING.md`) and `git show 9502bb6f^:dev/solvers/gpu-convergence.md`
(the census and the retired modified-Newton experiment, sections 9 and 10).
Its open items became issues #216 to #231.

| Idea | Verdict | Measured | Re-opens when |
|---|---|---|---|
| Modified (chord) Newton with CVODE's acceptance, publishing `x_k+1`, accepting at iterate 0 (`--solver=native`, branch `retired/native-modified-newton`) | retired | Factors per attempt fell 2 to 40x; Newton iterations rose 22% (chains), 80% (ring), 49% (adder). Cost 0.55 to 0.97x on quiescent and factor-heavy decks, 1.06 to 1.54x on always-active ones. Failed 9 oracle decks. | Never in that form: nine oracles encode ngspice's published iterate `x_k` (below). The confirming solve of [C2](04-levers-cpu.md#c2-the-confirming-solve-on-the-held-factor) keeps `x_k` and is a different mechanism. |
| GMRES on the stale LU, Anderson mixing, as the fallback of the above | closed | More instructions than a plain refactor on 12 of 13 decks | The factor costs more than about 10 solves (it was 12% of an iteration on the chains; on `logic_bsim4_10k` it is most of it) |
| Quadratic predictor | closed | `vacask_mul` 1.26 M to 0.59 M iterations; failed `bench_power_buck_open` and `vacask_mul`, moved the time grid | An edge guard for points straddling a source breakpoint, and a grid-class decision |
| Partial refactor (replay only the columns a changed entry reaches) | closed by census | 31.6% of A entries change per factor; the redo reach holds 99.2 to 99.4% of the flops on the chains | A deck whose changed columns do not reach the supply tail; none found |
| BTF blocks kept through the factor | closed by census | Every post-layout deck is one SCC of n-1 columns plus a singleton | — |
| Level-structure nested dissection | removed | 116x fill on `chain_bsim4_10k` against AMD's 2.6x | A multilevel partitioner (research) |
| f32 host refactor with GMRES-IR (`--lu-fast`) | deleted | Lost 2 to 32% on every deck | — |
| f32 Jacobian planes on the host (`ESPICE_F32_PLANES` census) | open, P2 | +0.22% Newton iterations over the corpus; two decks lost (`vacask_graetz` stops converging, `disto_bjt_ce` third harmonic 1.35% off) | An f64 fallback on a Newton failure, and linearizations (`Circuit.eval`) kept f64. See [G4](05-levers-gpu.md#g4-f32-derivative-lanes-on-fp64-poor-cards). |
| f32 GPU Jacobian (`-Dgpu-jac-f32`) | not in tree | 1.16x on `parallel_inverters_2000`; failed four mos1/mos6 decks (0.8 to 10% off) | Same as above |
| CPU SIMD across instances of a compact model (VerA batch family; `PointFamily` on `perf/lane-eval`) | gated, not closed | The branch widens only the calls and batches mesa only: -6.3% cycles there. `ddx()` pins a lane, so no MOSFET declares `batch_ok`. VerA's struct-of-arrays family measured 1.5x (bsim4va) and 2.0x (psp103) on a one-path batch, 1.26x to 1.71x after signature grouping; the first round's 1.0 to 1.25x on bsimcmg `evalQ` is not reconciled with it ([12, question 5](12-math-and-contract.md#5-the-instance-axis)) | One number: psp103 `evalQ` in a struct-of-arrays family against `DualFor`; closed under 1.3x |
| LaneLu(8) | closed | Instructions -22%, wall 3 to 7% | AVX-512 |
| Dense LU for n ≤ 25 | closed | 2 to 4x slower than the sparse replay | — |
| Level-scheduled host refactor | replaced | 1.3 to 2.1x upper bound at 8 threads | Superseded by subtree lanes with a pipelined tail |
| Right-looking GLU kernel with float atomics | closed | Non-deterministic stamp; Newton did not converge | — |
| Markstein division on the device | removed | Bitwise, but 5 to 7% slower | — |
| Device LU peel hysteresis | not built | `logic` OP 12.0 to 15.1-16.9 s | See #261 for the admission rule that replaces it |
| CUDA graph capture of the eval chain and of the device LU call (#219) | removed | Launch enqueue is under 0.5% of a 6 to 17 ms call | A deck whose kernels take 100 µs to 2 ms with the device LU admitted |
| Resident planes and companion on the device (01 1.2), Newton gates on the device (01 1.3) | measured, not worth it now | With resident A in, the remaining bytes are under 0.3% of an iteration; waits are 0.2% of a step where the device LU runs | A deck class between 1k and 10k instances with the device LU admitted |
| Instance reorder for cache and warps | dropped | Warp mixing costs under 0.5% of a GPU run; the reorder moves every CPU deck within rounding | LU no longer dominates the GPU decks |
| Speculative retry lanes | closed by census | 2 Newton rejections in 3.3 M attempts; LTE rejections 1% | — |
| MATEX routing for linear decks | closed | Up to 3x more work and wrong on pulse edges by 50 to 89,000x tolerance | `.matex` handles a fast edge and `uic` |
| Nonlinear elimination of internal nodes | closed by census | Internal nodes lead 8.6% of the hard-OP iterates | A three-deck prototype (`vacask_ring`, `vacask_graetz`, `bench_mos_series_r`) |
| JFNK as the default or as the GPU solver | closed | Slower on every fixture (`converger.run` doc comment) | — |
| OP and DC lanes on the device | measured not to pay on this card | 10k-point OP sweep: 0.28 ms per point on the CPU pool; lane setup alone 0.23 ms | An FP64-class card (#224) |
| Parareal, MGRIT, waveform relaxation, Rosenbrock or TR-BDF2 as the default | closed | Each moves every time grid | A named opt-in mode with its own oracle set |

### The published-iterate rule

`gpu-convergence.md` section 10.1 is the constraint that sorts every
Newton-level lever. ngspice publishes `x_k`, the last linearization point,
once `x_k+1 - x_k` passes the delta test. A build that published `x_k+1`
(same iterates, same grid, one step closer to the root) failed 10 corpus
decks at rtol 3e-3, because the oracles carry ngspice's per-step Newton
truncation. So a lever belongs to exactly one of:

1. It leaves the iterate sequence, the acceptance verdict and the grid alone.
   The corpus stays byte-identical, or moves within rounding.
2. It changes one of them. It is then a named opt-in mode with its own oracle
   (ngspice at `reltol = 1e-6`, or an analytic solution), never the default.

`converger.newton` shows the rule in code (the copy of `x_old` back into
`x` where a converged lane returns): on acceptance
`@memcpy(x, x_old)` restores `x_k`, so the last solve of every converged step
produces only a verdict.

## Published numbers

Tags: **[T]** tables read, **[A]** abstract only, **[S]** authors' slides,
**[V]** vendor or user claim. Nothing here was reproduced.

| Technique | Best number | Conditions | Bits |
|---|---|---|---|
| Stale-LU-preconditioned GMRES with a refactor window (Li & Shi, DATE 2005) [T] | 3.05 / 4.47 / 7.61x over SPICE3; LU count 4,377 to 63; 3.3 GMRES iterations per solve | P/G mesh plus 20-stage chain, 4k to 62k elements. Small circuits took up to 2x the Newton iterations. Baseline has no refactor replay. | Newton tolerance |
| Successive variable chord (SILCA, TCAD 2006) [A] | 80x less LU cost, about 20x total over SPICE3 | Li & Shi report stability problems | Newton tolerance |
| Multicore sparse LU: NICSLU (TCAD 2013) [A], Basker [A], CKTSO (arXiv 2411.14082) [T] | CKTSO self-scaling 1.27 / 2.23 / 3.5 / 4.86x at 2 / 4 / 8 / 16 threads; Basker 5.91x over KLU at 16 cores | 56 SuiteSparse circuit matrices; triangular solves scale 2.3x at 16 threads | pivot-dependent |
| Partial refactor in KLU (Bruned et al., IPST 2023) [T] | 50% better per-step time than a generated solver | 125x125 EMT matrix; every column after the first changed one is redone | bitwise-capable |
| GPU sparse LU: GLU3.0 (arXiv 1908.00204) [T], SFLU (DAC 2021) [A] | GLU3.0 2.81x geomean over 32-thread NICSLU (0.98 to 10.5x) | TITAN X, **single precision** | FP32 |
| GPU triangular solve (Świrydowicz et al., arXiv 2306.14337) [T] | 0.6x: 40% slower than the CPU | cuSolverGLU against MA57; refactor 3.4x, end to end 1.3 to 1.4x | — |
| GPU device evaluation: Gulati et al. (ASP-DAC 2009) [T], CUSPICE (MOS-AK 2014) [S] | Kernel 32 to 41x, whole simulation 2.36x; CUSPICE 3.1 to 3.7x total | BSIM3 in FP32 on an 8800 GTS; BSIM4v7 on a K20 with KLU on the CPU | FP32, 4.8e-5 |
| Single-precision device kernels (Kapre & DeHon, FPL 2009) [T] | — | Forced `reltol` to 1e-3..1e-2 and `vntol` to 1e-3; about 10% more iterations | tolerance |
| Graph-coloured BSIM4 stamping (EEspice, arXiv 2604.03079) [A] | 45x on 64 cores at low conflict, 4.4x at moderate, under 1x at high | Threads, no reduce | order-dependent |
| WavePipe (Dong, Li, Ye, DAC 2008) [S] | 2.09 to 2.19x at 4 threads | Gear-2, 8-CPU server; mispredicted forward steps are discarded | different grid |
| Exponential Rosenbrock-Euler (Zhuang et al., DAC 2015) [T] | 1.5 to 5.4x typical, 41x on one case | MATLAB against BE plus Newton, 54k to 3.3M unknowns; the 41x case has 40 nonlinear devices | approximation |
| BBD with block bypass (Benk, Denk, Waldherr, J. Math. Industry 2017) [A] | "up to two orders of magnitude" over KLU | Infineon TITAN; per-circuit data not retrieved | Newton tolerance |
| FP32 factor with FP64 refinement, dense (Haidar et al., SC18) [A]; sparse (Zounon et al., 2022) [A] | 2x dense; sparse reaches 2x only on the largest problems | Nothing circuit-specific found | refinement tolerance |
| Batched GMRES on a GPU (Liegeois et al., TPDS 2023) [A] | 76x over one block-diagonal sparse solve; 0.51x of dense batched | 20,000 systems on a V100: dense batched LU is twice as fast where memory allows | iterative tolerance |
| Generated straight-line solver for tiny matrices (IPST 2023) [T] | Parity with KLU at 77x77; loses at 125x125 | Unpivoted solver went unstable | bitwise-capable |
| Vendor GPU SPICE (Spectre X, PrimeSim, ALPS-GT) [V] | 3.5 to 10x | H100, A100, B200 class cards; PrimeSim credits the A100's FP64 | claimed same accuracy |

No published number was found for cross-instance AVX2 or AVX-512 evaluation
of BSIM4, BSIM-CMG or PSP, for FP32 LU with FP64 refinement on circuit
matrices, or for a per-circuit JIT solver at n < 50.

References, in table order:
<https://past.date-conference.com/proceedings-archive/2017/pyear/PAPERS/2005/DATE05/PDFFILES/06F_1.PDF>,
<https://dblp.org/rec/journals/tcad/LiS06a>,
doi:10.1109/TCAD.2012.2217964, <https://arxiv.org/abs/1601.05725>,
<https://arxiv.org/abs/2411.14082>,
<https://www.ipstconf.org/papers/Proc_IPST2023/23IPST040.pdf>,
<https://arxiv.org/abs/1908.00204>, doi:10.1109/DAC18074.2021.9586141,
<https://arxiv.org/abs/2306.14337>,
<https://www.aspdac.com/aspdac2009/archive/pdf/4C-6s.pdf>,
<https://mos-ak.org/venice_2014/publications/T_2_Lannutti_MOS-AK_2014.pdf>,
<https://ic.ese.upenn.edu/abstracts/spice_fpl2009.html>,
<https://arxiv.org/abs/2604.03079>, doi:10.1145/1391469.1391531,
<https://arxiv.org/abs/1511.04515>, doi:10.1186/s13362-017-0042-z,
<https://sc18.supercomputing.org/proceedings/tech_paper/tech_paper_pages/pap464.html>,
doi:10.7717/peerj-cs.778, doi:10.1109/TPDS.2023.3249110.
