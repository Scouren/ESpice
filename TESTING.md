# Testing

How ESPice proves a result is right, and which gate runs each proof. Rules every change obeys
are in [AGENTS.md](AGENTS.md#testing); this file is the map behind them, after the posts
"Exhaustive Testing" and "Large-Project Maintainer" (2026-10-21).

An **oracle** is the independent thing that says an output is wrong. Every layer below names one.
The main bug class in a simulator is a wrong number inside the plausible range, so certificates
and differential oracles come first; coverage and fuzzing alone cannot see it.

## Domains

| Domain | Components | What "correct" means |
|---|---|---|
| Compiler front end | `src/frontend/` (the ngspice dialect, `.meas`, expressions, `.vec`, Touchstone); `src/spicerack.zig` (every other dialect, as SpiceRack's translation) | every deck parses to the netlist ngspice's reference defines, or is refused with a declared error; a deck in another dialect runs as its translation or fails, and is never read as ngspice |
| Device models | `models/*.va` through VerA, `src/device/` | currents, charges and their Jacobians match the model's equations |
| Numerical solver | `src/solver/` (sparse LU, lanes, GMRES), `src/analysis/` (Newton, integrators, AC, noise, PSS, HB, PZ) | each solve satisfies its equations to the stated tolerance |
| Stateful and parallel | lane batches, `--jobs` scheduler, `Problem` sessions, the C ABI | results equal the serial, one-at-a-time run |
| GPU kernels | CUDA and HIP device eval, LU, lane kernels (Gompute) | equal to the CPU path within each deck's tolerance |
| Output | raw (ASCII, binary), CSV, FSDB, SST2 writers | readers get back every bit written |

## Bug class → oracle → layer → where

| Bug class | Oracle | Layer | Where |
|---|---|---|---|
| Wrong number on a real deck | reference simulator or analytic derivation, recorded in each `.expected.json` with its provenance and the deck's hash | differential corpus | `tests/test_correctness.zig` over `tests/conformance/tests/netlist/` (`zig build test`) |
| A deck silently moving between PASS and XFAIL | the name list `tests/VERDICTS.tsv` | ratchet | full CPU run of `zig build test` |
| A tolerance too loose to see an error | every expected value moved 0.1%: a deck that still passes is LOOSE | perturbation (`--perturb`, reports) | `tests/test_correctness.zig`; nightly |
| A golden tighter than its oracle converged (ngspice at `reltol=1e-3` recorded at `rtol=1e-6`) | ngspice rerun on the deck at `reltol=1e-9`: a golden it fails was checking ngspice's Newton iterates | differential, against the oracle itself | `tests/conformance/tools/ngspice-converged.conf`, when a golden is recorded |
| A missing feature hidden as a skip | `* KNOWN GAP:` line in the deck: XFAIL keeps the run green, XPASS fails it | ratchet | same |
| Wrong Newton point, no crash | independent KCL residual under `abstol + reltol·max\|I\|` | certificate (`-Dcertify=true`) | `src/analysis/Circuit.zig` `kcl_cert`; nightly over the corpus |
| Wrong LU solve | LAPACK scaled residual ≤ 30 | certificate | `src/solver/tests.zig`, `src/solver/direct.zig` probes |
| Wrong device derivative | central finite difference at random voltages | property | `src/device/tests/jacobian_fd.zig` |
| Wrong integrator order | observed order `log2(e_h / e_{h/2})` on RC and RLC | convergence order | `src/analysis/tests/transient.zig` |
| Engine depends on node names, element order, impedance scale | rename, reorder, split, scale by k, 0 A source | metamorphic | `tests/metamorphic.zig` (in `test`) |
| Parser panic, leak, undeclared error | no panic, no leak, error from the declared set; same digest on reparse and after no-op rewrites | fuzz (`std.testing.fuzz`, structured and raw) | `src/frontend/tests/{fuzz,expr,measure,source,vec}.zig`, `src/frontend/fit/tests/sparam.zig`; corpus replay in `test`, `--fuzz` nightly |
| A deck in another dialect read natively, a failed translation read as ngspice, SpiceRack's time folded into ESPice's, or a kit include or other kit file (Touchstone, `.data FILE=`, `.vec`, `.load FILE=`, `soalimits=`, `vpi=`) read from the working directory | the ngspice twin of what a fake `spice2rack` writes, run natively, bit for bit; the contract's coded error and exit 1 with no raw file; the fake's 0.2 s sleep as a floor under both stderr timing lines; a hand-worked divider whose kit include shares its name with a decoy in the working directory, and per file kind a hand-worked value (or the refusal naming the kit's file) whose decoy gives another; the corpus decks' `tokenizer` fields for `detect` | contract, differential | `tests/test_correctness.zig` `spicerack/*` checks over `tests/spicerack/` (in `test`); `src/spicerack.zig` tests |
| A translation that loses input and still runs (HSPICE CTYPE=1, LTYPE=1, RELV, GMINDC through SpiceRack) | ESPice's own drop warning (`ignor…`, `skipped`, `unchanged`) on a routed deck: `DroppedInput` unless its `.expected.json` lists the line as a `stderr_line` check; a field ngspice's behavioural R, C or L network drops is warned, by name, and m= and tc1= are not | contract | `tests/test_correctness.zig` `droppedInput` (unit test) and `netlist/behavioural_dropped`; `src/frontend/reader_rcl.zig` |
| Expression folding wrong | recursive reference evaluator | differential fuzz | `src/frontend/tests/expr.zig` |
| A card split or tokenized differently by the one-scan reader (`Ast.parse`) than by the line rules | the line splitter, PAT rewrite and tokenizer it shortcuts (`tokenizer.Lines`, `pattern.rewrite`, `Split`), card for card and token for token; hand-written line-rule cases and 20,000 seeded byte soups | differential | `src/frontend/Parse.zig` |
| A reader refactor changing what a deck parses to | the reader before the change: the SHA-256 of every deck's dumped `Netlist`, `.alter` runs, error and log lines, byte for byte over the corpus | golden, before and after by hand (`zig build nldump`; `nldump --ast` prints a deck's cards and tokens) | `tools/nldump.zig` |
| A reader refactor changing an error path or a message no corpus deck reaches (found by hand: a codemod rewrote three refusal messages and every corpus dump stayed identical) | the reader before the change, over seeded one-edit mutants of every corpus deck: the same dump, error and log lines; and the tree's string literals before and after, as multisets | differential and diff, before and after by hand (`reader_refactor.py mutants`, then `nldump --list` on both builds; `reader_refactor.py literals`; `--self-test`) | `tools/reader_refactor.py` |
| A per-instance compile cache keyed wrong: a subcircuit instance reads another body card's expression, a wrong number with no crash (found by a planted key bug: the corpus golden and its mutants stayed identical, no deck has two body values at one column or two braced B texts of one length) | values derived by hand for two instances of a cell whose cards collide on the wrong key (same column; same length), and the card's next field read after the cached value | unit, every build (`values:` tests) | `src/frontend/tests/netlist.zig` |
| Swallowed out-of-memory | `checkAllAllocationFailures`: each allocation fails once | fault injection | 38 files under `src/` |
| SIMD lane differs from scalar | the `W == 1` instantiation of the same kernel, bitwise | differential | `src/solver/lane/`, `src/analysis/tests/` lane tests |
| Batch or lane leaks into a neighbour | each lane bitwise equal to its run alone, NaN and failing lanes included | differential | `src/analysis/tests/` "lane batches" tests |
| A `.four`/`.fft` reading a `.tran`'s result (#231) differs from its own run | the reader appended alone, bitwise; a `.tran` with other options, OP, columns or measures is not read | differential | `src/analysis/tests/session.zig` "read a matching .tran" |
| Parallel nondeterminism | `--jobs=1` against N and permuted ready sets: byte-identical | determinism | `src/analysis/tests/session.zig`; whole corpus nightly: `tools/determinism.sh` |
| Threaded device stamp differs from serial, or stalls on an unscheduled lane | the serial stamp, bitwise: the planes at one iterate (a bypass replay on tied terminals included, and against a fresh eval), a pass no worker ever runs, whole decks at 1 to 4 device threads | determinism | `src/analysis/tests/circuit.zig` "threaded", "bypass replay"; `src/tests/espice.zig` "same deck, same bytes"; whole corpus nightly: `tools/determinism.sh` |
| Crash, hang or blow-up on huge or deep input | exit 0 or a diagnostic, never a signal or a timeout, under an 8 GB cap | adversarial sizes | `tools/adversarial.py`; nightly |
| C ABI misuse | model of valid states under random call sequences, forged handles | stateful fuzz | `src/c_api.zig` |
| Output corruption | round trip of every f64 bit pattern | round trip | `src/output/` tests |
| `--measures` JSON disagrees with the printed `.meas` or mislabels a variant | the printed text line for line; the deck's own `.step`/`.data` values bit for bit; RC closed forms | differential | `src/output/measure.zig`, `src/tests/espice.zig` "--measures" tests |
| A corpus `measure` check passes a wrong value its printed 6 or 7 digits round away (tran/meas_param_expr) | the deck's oracle on the exact `--measures` f64 (a `.meas` result, an optimized parameter, a Monte Carlo `mean()`/`sigma()`); each stdout line is that f64 rounded to the 6 or 7 digits it prints | differential | `tests/test_correctness.zig` `measure`, "a measure compares the exact --measures value"; `src/tests/espice.zig` "--measures: an optimized parameter" |
| `--emir` terminal current wrong, mis-signed or mislabelled | Ohm's law on a divider, transient, `.op` and a `.dc`'s first point; Kirchhoff at every internal net, floating sources included; a sine's RMS and half-wave mean; `.meas EM_AVG` of the same branch and window; a CMOS inverter's load EM_AVG and supply average against C·V·f and its peak against the PMOS saturation current; the netlist's own nets and `.model` names under a mixed (partitioned) batch; the `.step` values; 1 job against 4, byte for byte | analytic, certificate, differential | `src/tests/espice.zig` "--emir" tests |
| `.option soa` excursion missed, doubled or mis-windowed, or a `soalimits` file shadowing a card (#238) | a limit set to the solved voltage itself (passes) and 1 mV under it (one excursion); a PWL ramp's crossings; the `.step`/sweep values; ngspice 45 `warn=1` warnings on the same deck | analytic, differential | `src/tests/espice.zig` ".option soa" tests (the ngspice windows inline: no dialect defines SOA output, so the suite keeps no SOA oracle) |
| `.wcd` worst-case distance wrong, or a guess reported as converged (#240) | closed-form β of a linear margin, signed; the exact design point of a parabola; Breitung's factor against a quadrature of the exact P_f; `.dcmatch`'s σ on a 5T OTA within 2 %; tangent rows against a finite-difference batch; 1 job against 8, byte for byte | analytic, differential, metamorphic | `src/core/form.zig`, `src/tests/espice.zig` ".wcd" tests |
| Browser build differs from native | the native espice at the same lane width, within 1e-9 | differential | `tools/playground/compare.js` (`pages.yml`) |
| A target or OS stops building | the compiler for every release target | cross compile | `cross.yml`; the gate on Linux and macOS |
| GPU differs from CPU | the CPU result of the same deck | differential | `zig build test -- --backend auto --jobs 1` (the placement users get) and the cpu-vs-cuda parity sweep, every deck under `--backend cpu` and `--backend cuda` (local; no GPU runner) |
| HIP backend miscompiles | kernel symbols present after an LLVM AMDGPU compile | compile probe | `build.zig`, in `test` |
| Abstraction costs run time | hand-written twin's assembly | codegen probe | `tests/codegen.zig` + `tools/asm_probe.py` (in `test`) |
| Release ships a broken artifact | smoke decks from a clean directory, a container with no `/nix` | smoke | `tools/release_smoke.sh`, `release.yml` |
| Docs example rots | the example compiled and run; every docs deck runs to exit 0 | executed docs | `docs/embed/host.c` in `test`; `tools/doc_decks.sh` in the gate |

## Gates

| Tier | Where | Contents |
|---|---|---|
| Edit loop | local, seconds | `zig build check --watch -fincremental`; `zig build test -Dtest-filter=… -- --filter …` |
| Merge gate | `test.yml`, `cross.yml`, `nix.yml` on every PR, push to `main` and merge queue | on Linux and macOS: `zig build test` in ReleaseSafe (every suite, fuzz-corpus replay, the corpus with its name list, metamorphic rewrites, codegen and HIP compile probes, the C API example, bench-adapter tests), every docs deck, release-matrix unit tests; every release target compiled; `nix flake check` and smoke |
| Nightly | `nightly.yml`, 06:17 UTC | corpus with KCL certificates, the perturbed corpus (LOOSE list in the summary), `zig build test --fuzz=20M` (every fuzz target), `tools/determinism.sh` (1 thread against 8), `tools/adversarial.py`, `zig build bench` against ngspice, VACASK and Xyce |
| Docs deploy | `pages.yml` on `main` | the playground's espice.wasm against native espice over the corpus |
| Release | `release.yml` on `v*` | the merge gate via `workflow_call`, every target at every ISA level with `zig build test` run where the runner can, bundle smoke outside Nix, checksums; `bench.yml` tests the chart scripts on a fixture (`tools/test_bench.py`), attaches the charts and appends the run to `history.tsv` on the `bench-history` release |
| Local only | a machine with a card | `zig build test -- --backend cuda --jobs 1` before any change to a GPU path lands; `tools/gpu_phases.py` refreshes `docs/performance/gpu-phases.tsv`, the input of the charts' GPU extrapolation |

A flaky test is fixed or quarantined the same day, never retried silently. A fuzz or determinism
failure becomes a checked-in input (`src/frontend/tests/fuzz_corpus/`, or a deck in the conformance suite).

## Exit criteria for a release

Each line is a yes or a number a script reads; none is typed from memory.

- `zig build test` passes in ReleaseSafe: the corpus at 100 percent with only `KNOWN GAP` XFAILs, `VERDICTS.tsv` unchanged or moved XFAIL → PASS only.
- The last nightly on the release commit is green: zero certificate misses, zero decks differ between 1 and 8 threads, no fuzz crash in 20M iterations per run.
- `zig build test -- --backend auto --jobs 1` passes on CUDA hardware for the release commit. `auto` runs some decks on the CPU (its price says the GPU loses them), so explicit `--backend cuda` correctness, every eligible device on the GPU, is the cpu-vs-cuda parity sweep over the whole corpus on the same commit. A backend that has never passed the corpus on a card is listed below as untested, and the README says so.
- Zero open crash bugs.

## Not yet tested

- **Debug builds**: the self-hosted backend diverges from LLVM (#25); the gate runs ReleaseSafe only.
- **GPU in CI**: no GPU runner; the GPU corpus runs locally, and HIP is checked by compilation only.
- **Merge gate budget**: a cold 4-core runner takes over an hour, past the 15-minute target.
- **The browser build**: wasm32 does not compile on this branch (the performance round's `u64`/`usize` sites in `src/solver/subtree.zig`, `src/analysis/executor.zig`, `src/analysis/gpu/devices.zig`), so the playground and its differential do not run; `pages.yml` deploys without them.
- **The SpiceRack route**: `spice2rack` is pinned at SpiceRack `espice-kit` (231d9c9c, unmerged there); 37 corpus decks that need it are `KNOWN GAP` XFAILs (Scouren/SpiceRack#24). The release smokes one translated HSPICE deck per archive; the HIP bundle (`tools/hip_bundle.sh`) and the Homebrew formula carry no `spice2rack` yet.
- **Tolerance ratchet**: the LOOSE list is reported, not gated; it becomes a name list like `VERDICTS.tsv` once triaged.
- **Coverage**: no line or branch tool for Zig; kcov over the test binary is the cheap first step.
- **Mutation testing**: no tool; the substitute is a script flipping one comparison at a time.
- **Fuzz bookkeeping**: CPU-hours and corpus growth per target are not recorded, and nightly finds are not saved automatically.
