# The environment: every variable the simulator reads

Read this when you remove an environment variable, add a switch, or ask
where a run's choice comes from. It is the inventory behind the last step
of [13-implementation.md](13-implementation.md#order-of-the-remaining-work):
no variable makes a choice for the simulator. CPU against GPU and every
placement threshold come from the price model and the calibration file
([08-placement.md](08-placement.md)). A choice that is genuinely the user's
becomes an option. The operating system's path conventions stay.

Measured on `dev/performance` at `9bbd4d7f` with the working tree's
uncommitted changes, 2026-11-11, by reading the code: a search of `src/`,
`tools/`, `tests/`, `build.zig`, `packaging/`, `flake.nix`, the pinned
Gompute 2.0.0 and VerA 0.23.0, and every doc, for `getenv`, `environ`,
`Environ`, `ESPICE_`, `ZP_` and `GOMPUTE_`. Nothing was run. Paths under
`src/` are cited without the `src/` prefix.

## Kinds

- **lever:** names a lever under evaluation (`core.perf`).
- **switch:** forces one side of a choice the simulator otherwise makes:
  CPU or GPU, a solver path, a kernel variant, a thread count.
- **threshold:** a number that replaces a built-in cut.
- **diagnostic:** prints, counts or times.
- **test hook:** exists for a test, often as its oracle.
- **path:** where a file goes.
- **external tool path:** where another program is.

## The variables

37 names. 31 make a choice. 6 only locate a file or a program: `ZIG`,
`ESPICE_SPICERACK`, `ESPICE_CACHE`, `XDG_CACHE_HOME`, `HOME`, `TMPDIR`.

| Variable | Read at | What it chooses | Set by today | Kind | End state |
|---|---|---|---|---|---|
| `ESPICE_PERF` | `espice/config.zig:359`, `:281`; `main.zig:295` | The levers that are on; with `p1`, the calibration file loads by identity keys (`machine.loadKeyed`); under `--timing-in-depth` the CLI echoes it | `build.zig:327` (`-Dperf`), passed by `tests/test_correctness.zig:154` to each child; [11-lever-gate.md](11-lever-gate.md), [13](13-implementation.md) | lever | Deleted with `core/perf.zig` once every lever has its verdict (13 step 4). A tolerance lever that ships becomes a CLI option of its own name. `-Dperf` and the runner's `--perf` go too |
| `ESPICE_SOLVER` | `espice/config.zig:362` | Pins Newton's linear solve to `direct`, `jfnk` or `jfnk-nolu`; a JFNK pin also stops the device hand-off of A and charge staging (`analysis/Circuit.zig:826`, `analysis/circuit_devices.zig:451`) | Nobody. No doc | switch | Deleted: `converger.run` decides (`solver/converger.zig:446`). A JFNK test sets `knobs.newton.pin` through the caller's knobs |
| `ZP_OPDBG` | `espice/config.zig:363` | Prints each operating-point rung and Newton iterate (`analysis/dc/op_ladder.zig:89`, `analysis/dc/op.zig:184`, `solver/converger.zig:312`) | [02](02-baseline.md), [04](04-levers-cpu.md), [06](06-open-issues.md) (the #218 gate), [13](13-implementation.md); `convergence/bench_mos_latch_ladder.sp:33`; `analysis/tests/integration.assets/gmin_ladders.txt:1` | diagnostic | New CLI option `--trace=op` |
| `ZP_NEWTON_DEBUG` | `espice/config.zig:364` | Prints every Newton iterate (`solver/converger.zig:315`) | A deck comment only (`bench_mos_latch_ladder.sp:23`) | diagnostic | `--trace=newton` |
| `ESPICE_NO_BBD` | `espice/config.zig:365` | The flat LU instead of the BBD engine (`solver/direct.zig:405`) | Nobody. No doc | switch | Deleted. The comparison is a unit test passing `.no_bbd = true`, as `solver/lu_reorder_tests.zig:85` does |
| `ESPICE_LU_PAR` | `espice/config.zig:366` | Forces the multicore refactor's admission on or off past its cost model (`solver/direct.zig:719`) | `tests/espice.zig:1393` (`setenv`). No doc | test hook | Deleted. The test sets `knobs.lu.par` through the caller's knobs |
| `ESPICE_LU_PAR_STATS` | `espice/config.zig:367` | Prints the multicore refactor's admission and the subtree plan (`solver/direct.zig:558`, `:720`) | A test comment (`tests/espice.zig:1378`). No doc | diagnostic | `--trace=lu` |
| `ESPICE_LANES` | `espice/config.zig:368` | `1` batches ready operating points and `.dc` sweeps as CPU lanes, as `--lanes` does (`analysis/exec_config.zig:185`); `0` also turns GPU lanes off under every backend (`analysis/gpu/lanes.zig:447`) | `docs/using/gpu.md:81`, `:93`; `include/espice.h:362`; [15](15-design-sweeps.md) | switch | Under `auto`, the calibration file's `lane` rows decide (08 step 5). Explicit: the existing `--lanes`, and a new `--no-lanes`. The C API gets a field when a caller asks for one |
| `ESPICE_HB_TRACE` | `espice/config.zig:369` | Prints the HB and MHB Newton and GMRES iterates (`analysis/pss/hb.zig:239`, `analysis/pss/mhb_newton.zig:319`, `:358`) | `tests/conformance/docs/a09-accepted-rejected-lifecycle.md:202` | diagnostic | `--trace=hb` |
| `ZP_NO_QTAPE` | `espice/config.zig:370` | The LTE over the row plane instead of the charge tape (`analysis/tran/sim_init.zig:101`); refuses GPU lanes (`analysis/tran/gpu_drive.zig:237`) | Nobody. No doc | switch | Deleted. A unit test sets `knobs.no_qtape` on the circuit and compares the two paths |
| `ZP_TRAN_STATS` | `espice/config.zig:371` | Prints the transient step statistics (`analysis/tran/Sim.zig:230`, `analysis/tran/sim_init.zig:168`, `analysis/executor.zig:395`). It also keeps GPU lane step control on the host (`analysis/tran/gpu_step.zig:163`) | [README](README.md), [13](13-implementation.md); a09 doc `:211`; `analysis/tests/transient.zig:1434` | diagnostic | `--trace=tran`, which keeps the host step control |
| `ZP_TRAN_LTE_TRACE` | `espice/config.zig:372` | Prints the first 16 rejected LTE bounds (`analysis/tran/Sim.zig:423`); host step control as above | Nobody. `analysis/tran/host_ops.zig:157` calls it `ESPICE_TRAN_LTE_TRACE` | diagnostic | `--trace=lte` |
| `ZP_NO_TANGENTS` | `espice/config.zig:373` | Optimization and worst-case Jacobians by finite differences, not tangents (`espice/optimizer.zig:154`, `espice/wcd.zig:69`) | Nobody. No doc | switch | Deleted. A unit test sets the knob and compares the two Jacobians |
| `ESPICE_GPU_LU` | `espice/config.zig:374` | `1` forces the device LU on under a GPU backend and any other value off; unset leaves the size gate and the price (`analysis/executor.zig:564`) | `docs/using/cli.md:299`, `docs/using/gpu.md:44`; [08](08-placement.md) step 4's gate | switch | The calibration file's `lu` rows decide, by rent-or-buy (08 step 4). The `=0` gate becomes a GPU test that sets `knobs.gpu_lu = false` |
| `ESPICE_GPU_LU_CHECK` | `espice/config.zig:375` | Checks every device solve against the host LU and counts mismatches (`analysis/gpu/lu.zig:334`, `:434`; `analysis/gpu/context.zig:592`) | [04](04-levers-cpu.md), [05](05-levers-gpu.md), [08](08-placement.md) step 4's gate | test hook | Deleted. A GPU test sets the knob and asserts 0 mismatches |
| `ESPICE_GPU_LU_NOGATHER` | `espice/config.zig:376` | The device refactor without its gather kernel (`analysis/gpu/lu.zig:574`) | Nobody. No doc | switch | Deleted. A GPU test passes `.gather = false` in the kernel options |
| `ESPICE_GPU_LU_TAIL` | `espice/config.zig:377` | The device solve's dense-tail column count, over the fitted cut (`analysis/gpu/lu.zig:575`; the fit is `solver/kernels/lu_tables.zig:84-90`) | Nobody. No doc | threshold | The fitted cut decides. The refit after C1 (08 step 8) is a bench that passes `.tail`; a calibration row if the cut moves per card |
| `ZP_LU_STATS` | `espice/config.zig:379`, `-Dlu-instrument` only | Prints the BBD census and every full factor's fill (`solver/direct.zig:403`, `solver/lu_census.zig`) | `build.zig:44` (option help); [04](04-levers-cpu.md), [10](10-device-lu-chain.md), [13](13-implementation.md) | diagnostic | Build option: an `-Dlu-instrument` build prints it |
| `ESPICE_GPU_LU_BENCH` | `espice/config.zig:380`, `-Dlu-instrument` only | Times the device LU and stops after N samples (`analysis/gpu/lu.zig:194`, `analysis/gpu/lu_bench.zig`) | `build.zig:44` (option help) | diagnostic | Build option `-Dlu-bench=N` |
| `ESPICE_GPU_LU_THREADS` | `espice/config.zig:381`, `-Dlu-instrument` only | The host refactor threads the bench compares against, default 8 (`analysis/gpu/lu.zig:194`) | Nobody. No doc | threshold | Deleted. The bench compares at `ThreadPool.per_query` lanes, as the calibration's host LU row does (08 section 3) |
| `ESPICE_GPU_STATS` | `espice/config.zig:383` | Prints GPU admission, price rows, rounds and graph replay (`analysis/gpu/context.zig:404`, `analysis/gpu/context_cost.zig:273`, and every other `gpu-` line). `phases` also turns graph replay off and waits between stages (`analysis/gpu/lanes_init.zig:207`, `analysis/gpu/lanes_step.zig:159`), which changes the timing | `docs/using/gpu.md:94-95`; `tools/gpu_phases.py:33` | diagnostic | `--trace=gpu` and `--trace=gpu-phases` |
| `ESPICE_GPU_BLOCK` | `espice/config.zig:384` | The CUDA block width of per-instance kernels, 1 to 1024, default 64 (`analysis/gpu/context_batch.zig:312`) | Nobody. No doc | threshold | Deleted: 64, measured (`analysis/gpu/context_batch.zig:300-307`) |
| `ESPICE_GPU_EVAL_CHECK` | `espice/config.zig:385` | Replays each device evaluation at the same x and reports the worst cell that moved (`analysis/gpu/context.zig:537`) | Nobody. No doc | test hook | Deleted. A GPU test sets the knob and asserts no cell moved |
| `ESPICE_GPU_NOFUSE` | `espice/config.zig:386` | A host wait per device evaluation instead of the limit pass's, and no constant-Jacobian kernel (`analysis/gpu/context.zig:591`, `analysis/gpu/context_batch.zig:198`) | Nobody. No doc | switch | Deleted. A GPU test compares fused against unfused bytes |
| `ESPICE_GPU_NOGRAPHS` | `espice/config.zig:387` | Direct launches instead of graph replay (`analysis/gpu/lanes_step.zig:159`, `analysis/gpu/lanes_newton.zig:154`) | `docs/using/gpu.md:96` | switch | Deleted. A GPU test compares graph against direct bytes |
| `ESPICE_GPU_HOST_STEP` | `espice/config.zig:388` | GPU lanes keep step control on the host, the bitwise oracle of device step control (`analysis/tran/gpu_step.zig:163`) | Nobody. No doc | test hook | Deleted. The GPU lane test sets the knob and compares bytes |
| `ESPICE_PARSE_THREADS` | `espice/config.zig:259` | N threads scan every deck's device cards; `0` reads each card whole (#230, through `espice/Problem.zig:403`) | Nobody. No doc | switch | Deleted. A frontend test calls `frontend.prepare` with `.threads = N, .scan_min = 0` and compares the decks |
| `ESPICE_CACHE` | `espice/config.zig:229` | The `.hdl` build cache root, ahead of `XDG_CACHE_HOME` | `tools/release_smoke.sh:9`, `tools/doc_decks.sh:10`, `tools/determinism.sh:12`, `flake.nix:234`; `docs/using/cli.md:298`, `docs/using/devices.md:232`, `docs/embed/packages.md:57` | path | Kept, for the owner to confirm. It moves a content-keyed cache and no result. Scripts use it to isolate the `.hdl` cache without moving the calibration file, which setting `XDG_CACHE_HOME` would do. The C API has no cache field |
| `ESPICE_THREADS` | `main.zig:370`, `:377` | Fixed device-evaluation threads. Set, it or the next turns off the borrowed pool (`auto_threads`, `espice/Problem.zig:422`) | `tools/determinism.sh:18` (nightly); `tests/benchmark/runner.zig:720`; `docs/using/cli.md:295`, `docs/using/gpu.md:170`; [02](02-baseline.md), [README](README.md) | switch | New CLI option `--threads=N`: N device threads, min(N, 16) solver threads, no pool. Without it the pool decides, as with both variables unset today |
| `ESPICE_SOLVER_THREADS` | `main.zig:369`, `:377` | The BBD factor threads (at most 16) and the multicore refactor's lanes (`analysis/executor.zig:208-210`); turns off the pool | `tools/determinism.sh:18`; `docs/using/cli.md:296`, `docs/using/gpu.md:171`; [02](02-baseline.md) | switch | Folded into `--threads=N`. Every script sets both to the same N |
| `ESPICE_SPICERACK` | `main.zig:334` | The `spice2rack` binary, after `--spicerack` | `flake.nix:26`; `tests/benchmark/runner.zig:427` (its own read); `docs/using/cli.md:42`, `:300`, `docs/using/dialects.md:40`, `docs/using/diagnostics.md:26` | external tool path | Kept: it finds a program and chooses nothing, as `PATH` does. `--spicerack` already overrides it |
| `ESPICE_TEST_THREADS` | `main.zig:631-637` | The name `envThreads`' unit test sets | The test itself | test hook | Deleted with `envThreads`; a parse test of `--threads=` replaces it |
| `GOMPUTE_FAKE_DEVICES` | Gompute 2.0.0 `src/runtime/cuda.zig:286`, `src/runtime/hip.zig:329` | k contexts on device 0 pose as k cards (`analysis/gpu/devices.zig:164`) | [06](06-open-issues.md) (the #220 gate), [15](15-design-sweeps.md) | test hook | Deleted from the environment: Gompute takes the count as an init parameter and the #220 GPU test passes it. A Gompute release and a pin bump |
| `ZIG` | `espice/config.zig:237` | The Zig compiler a runtime `.hdl` builds with, after `hdl_toolchain.zig` | `build.zig:238`, `:242`, `:370`; `tests/test_correctness.zig:153`; `docs/using/cli.md:297` | external tool path | Kept, as `ESPICE_SPICERACK`. The API's `zig_path` overrides it |
| `XDG_CACHE_HOME` | `espice/config.zig:231`, `:278`, `:389`; `main.zig:570`; `tests/espice.zig:3605` | The root of the calibration file, the GPU JIT markers and the `.hdl` cache | `tests/espice.zig:3607` (`setenv`) | path | Kept: an OS convention |
| `HOME` | `espice/config.zig:233`, `:278`, `:390`; `main.zig:571` | The fallback of `XDG_CACHE_HOME` | | path | Kept: an OS convention |
| `TMPDIR` | `espice/config.zig:236`; `main.zig:338` | The last `.hdl` cache root, and where the spice2rack kit goes | `flake.nix:122` | path | Kept: an OS convention |

By kind: 1 lever, 12 switches, 3 thresholds, 9 diagnostics, 6 test hooks,
4 paths, 2 external tool paths.

By end state: 6 kept. 10 become CLI options: `--trace=LIST` takes 7,
`--threads=N` takes 2, and `--no-lanes` beside `--lanes` takes 1, with the
calibration file's `lane` rows deciding under `auto`. 2 become build
options. The calibration file's `lu` rows decide `ESPICE_GPU_LU`.
`ESPICE_GPU_BLOCK` and `ESPICE_GPU_LU_TAIL` give way to built-in measured
constants. The other 16 are deleted, `ESPICE_PERF` among them with the
lever verdicts. Where one served a comparison or an oracle, a test sets
the field instead.

## Where the rule is broken

[11-lever-gate.md](11-lever-gate.md#how-a-lever-reads-it) says nothing
below the facade reads the environment, and `espice/config.zig:4-8` says
that file reads all of it but two names, which it lists.

- **Below the facade:** `GOMPUTE_FAKE_DEVICES`, read inside Gompute's
  runtime, which links into `espice` and `libespice.a`. No ESPice file
  below the facade reads one: `analysis/`, `solver/`, `device/`, `core/`
  and `frontend/` have no `getenv`.
- **Beside the facade:** the CLI (`main.zig`) reads one name itself,
  `ESPICE_SPICERACK`, the default of its `--spicerack`. Only the CLI runs
  spice2rack (the library refuses other dialects, `c_api.zig:339`), so it
  has no library counterpart. Until 2026-11-11 `main.zig` also read
  `ESPICE_PERF`, `ESPICE_THREADS`, `ESPICE_SOLVER_THREADS`, `TMPDIR`,
  `XDG_CACHE_HOME` and `HOME`, and `ESPICE_THREADS` did nothing to a C API
  caller. The facade now reads them for every caller: `threadsFromEnv` and
  `printLevers` run first in `Problem.init`, `tmpDir` serves the SpiceRack
  kit, and `cacheRoots` serves `calibrate.run`. The CLI keeps
  `auto_threads = true` as its own default; a library caller with the
  variables unset runs one thread.
- **Tests through the environment:** `tests/espice.zig:1405`, `:1430` and
  `:3643` `setenv` `ESPICE_LU_PAR`, `ESPICE_THREADS` and `XDG_CACHE_HOME`.
  Each is a process-wide write inside a test binary. `ESPICE_TEST_THREADS`
  is gone with `main.zig`'s `envThreads`.

## Read with no doc

No doc outside the source names 15 of them: `ESPICE_SOLVER`,
`ESPICE_NO_BBD`, `ESPICE_LU_PAR`, `ESPICE_LU_PAR_STATS`, `ZP_NO_QTAPE`,
`ZP_TRAN_LTE_TRACE`, `ZP_NO_TANGENTS`, `ESPICE_GPU_LU_NOGATHER`,
`ESPICE_GPU_LU_TAIL`, `ESPICE_GPU_LU_THREADS`, `ESPICE_GPU_BLOCK`,
`ESPICE_GPU_EVAL_CHECK`, `ESPICE_GPU_NOFUSE`, `ESPICE_GPU_HOST_STEP`,
`ESPICE_PARSE_THREADS`. Three more appear only in a deck comment, a
conformance doc or a build option's help: `ZP_NEWTON_DEBUG`,
`ESPICE_HB_TRACE`, `ESPICE_GPU_LU_BENCH`.

Doc comments that named the wrong thing, fixed 2026-11-11:
`analysis/tran/host_ops.zig:157` said `ESPICE_TRAN_LTE_TRACE` for
`ZP_TRAN_LTE_TRACE`, and `analysis/knobs.zig:2`, `solver/converger.zig:84`,
`solver/direct.zig:76` and `device/Library.zig:134` called the facade
`espice.zig` where it is `espice/config.zig`.

## Not a choice, or not in the binary

- `espice/config.zig:315` writes `CUDA_CACHE_MAXSIZE` for the driver and
  leaves a user's own value. A write, not a read. It stays.
- `c_api/Handle.zig:97` copies `environ` so the `.hdl` build's child gets
  an environment. It passes the variables through and chooses nothing.
- `packaging/espice-hip.sh:11-13` reads `ESPICE_HIP_ARCH` (documented,
  `docs/using/install.md:60`), `ESPICE_HIP_BIN` and `ESPICE_KFD_TOPOLOGY`
  (set by `tools/test_release_hip.py:31`) to pick which build to run.
  `tools/install.sh:24-27` reads the four `ESPICE_INSTALL_*` names
  (`docs/using/install.md:22`). These belong to the package's launcher and
  the installer. The simulator reads none of them, so step 5 of 13 leaves
  them alone.
- VerA's VPI host reads `VERA_VPI_WORK`, `VERA_ZIG` and
  `VERA_PROTECT_KEYS` (`src/vpi/host.zig:417`, `:436`, `:504`). That file
  is VerA's own executable. ESPice imports the `vpi` module, whose root
  only re-exports (`src/vpi/root.zig:3`), so those reads are not linked.
- `ESPICE_NGSPICE` is not a variable. It is the C header's dialect
  constant (`include/espice.h:46`). `ESPICE_HELD_EPS`,
  `ESPICE_LINEAR_CACHE` and `ESPICE_LANE_EVAL` are gone from the code and
  remain only in docs and `CHANGELOGS.md`.

## The route for tests

Today `execution` builds the knobs from the environment and takes one
field from the caller, `bypass` (`espice/config.zig:134-136`). Every
deletion above needs a test to set a field without a variable. The route:
the knobs start from `options.backend.knobs`, the caller's, and the CLI
sets its options' fields there. A test then sets any field, as the bypass
tests already do (`tests/espice.zig:2816`). `knobsFromEnv` shrinks by one line per step and is gone
at the end. Only the two cache paths remain, read where they are read now.

## Order of removal

Each step is one pull request. Each keeps `tests/VERDICTS.tsv` unchanged
by name. "Raws identical" means the old binary with the variable set and
the new binary with its replacement write the same raw bytes (`cmp`). The
named decks are under `tests/conformance/tests/netlist/`. Steps 1 to 5
need no card and wait on no lever verdict. Steps 6 to 9 need a GPU
session. Step 10 is 13's step 5 itself.

1. **The route for tests, and the name list.** The knobs start from the
   caller's. `tests/espice.zig:1393` sets `knobs.lu.par` instead of
   `setenv`. `env` (`espice/config.zig:396`) takes its name at comptime and
   checks it against a list of allowed names, so reading an unlisted name
   fails the build. `main.zig`'s seven reads go through the same `env`.
   Each later step deletes names from that list. Gompute's read stays
   outside it until step 9.
   *Proof:* CPU corpus raws identical. The "same deck, same bytes" test
   asserts the multicore refactor ran (`admitted_lanes`,
   `solver/direct.zig:563`). It goes red when the facade drops the field.
2. **The CPU switches with no doc.** Delete `ESPICE_SOLVER`,
   `ESPICE_NO_BBD`, `ZP_NO_QTAPE`, `ZP_NO_TANGENTS` and
   `ESPICE_PARSE_THREADS`. Add the parse test: N threads against 0 give the
   same deck (#230).
   *Proof:* no CI job, script or doc sets them, so the corpus raws are
   identical by construction. The comptime list shows the five names gone.
3. **CPU diagnostics to `--trace=LIST`.** `op`, `newton`, `hb`, `tran`,
   `lte`, `lu`. An unknown name is a usage error (exit 2), the way
   `UnknownLever` stops a typo. Update the recipes in 02, 04, 06 and 13,
   the header of `gmin_ladders.txt` and the deck comments.
   *Proof:* the stderr trace lines are byte-identical, old with the
   variable against new with the flag, on `convergence/bench_mos_latch_ladder.sp`
   (op, newton), `hb/diode_clipper.sp` (hb),
   `tran/device_mos6_inverter.sp` (tran, lte) and
   `stress/sweep_opamp_wl_200.sp` at `--threads=8` (lu). Raws identical
   with and without each flag.
4. **Thread counts to `--threads=N`.** Delete `ESPICE_THREADS`,
   `ESPICE_SOLVER_THREADS`, `envThreads` and `ESPICE_TEST_THREADS`.
   Rewrite `tools/determinism.sh:18` and the variant test at
   `tests/benchmark/runner.zig:720`. Update `docs/using/cli.md`,
   `docs/using/gpu.md` and `CHANGELOGS.md`: the variables were documented
   for users.
   *Proof:* raws identical between `ESPICE_THREADS=8
   ESPICE_SOLVER_THREADS=8` and `--threads=8` on the five decks of
   `tests/espice.zig:1384-1391`. The nightly's `tools/determinism.sh` passes
   at N = 8. Without the flag, the lane counts `--timing-in-depth` prints
   equal those of an unset environment.
5. **The instrumented build.** `-Dlu-instrument` prints the census, and
   `-Dlu-bench=N` sets the sample count. Delete `ZP_LU_STATS`,
   `ESPICE_GPU_LU_BENCH` and `ESPICE_GPU_LU_THREADS`.
   *Proof:* the default build is unchanged, since the reads were already
   comptime-dead there. The census lines on
   `stress/scaling_parallel_inverters_100.sp` are byte-identical, old with
   `ZP_LU_STATS=1` against the new instrumented build. The bench's own
   lines need a card and are checked in step 6's session.
6. **GPU switches and oracles.** GPU. Delete `ESPICE_GPU_LU_NOGATHER`,
   `ESPICE_GPU_LU_TAIL`, `ESPICE_GPU_BLOCK`, `ESPICE_GPU_NOFUSE` and
   `ESPICE_GPU_NOGRAPHS`. `ESPICE_GPU_LU_CHECK`, `ESPICE_GPU_EVAL_CHECK`
   and `ESPICE_GPU_HOST_STEP` become GPU tests that set their fields.
   `ESPICE_GPU_STATS` becomes `--trace=gpu` and `--trace=gpu-phases`, and
   `tools/gpu_phases.py` passes the flag.
   *Proof:* raws identical under `zig build test -- --backend cuda --jobs 1`
   and `-- --backend auto --jobs 1`. Each new test goes red on a planted
   fault, such as one flipped bit in a device solve. The rows of
   `docs/performance/gpu-phases.tsv` keep their names.
7. **Lanes.** GPU. `ESPICE_LANES` goes. `--no-lanes` turns GPU lanes off,
   and `--lanes` keeps the CPU side. Update `include/espice.h:362` and
   `docs/using/gpu.md`.
   *Proof:* raws identical between `ESPICE_LANES=0 --backend cuda` and
   `--no-lanes --backend cuda` on the six sweep decks of 08 step 5, and
   between `ESPICE_LANES=1` and `--lanes` on `stress/sweep_opamp_wl_200.sp`.
   The `gpu-lanes:` lines under `--trace=gpu` report the same admission.
   Under `auto` the `lane` rows decide once 08 step 5 lands.
8. **The device LU by price.** GPU, with 08 step 4. First the gate
   becomes a GPU test that sets `knobs.gpu_lu = false` against the default
   on the five device-LU decks. Then the read goes, and so do
   `docs/using/cli.md:299` and `docs/using/gpu.md:44-45`.
   *Proof:* 08 step 4's done-when, with the test in place of the variable.
9. **Fake devices.** GPU. A Gompute release takes the device count as an
   init parameter, the pin moves, and the #220 test passes k.
   *Proof:* #220's gate. k = 2 against unset gives identical raws on the
   four decks the issue names.
10. **`ESPICE_PERF`, last.** When every lever has its verdict, delete
    `core/perf.zig`, the `p1` branch of `loadMachine`
    (`espice/config.zig:281`), the echo at `main.zig:295`, `-Dperf` and the
    runner's `--perf`.
    *Proof:* the final binary's raws, CPU and GPU tiers, are identical to
    the last `-Dperf=<accepted exact set>` run. The comptime list then
    holds exactly `ZIG`, `XDG_CACHE_HOME`, `HOME`, `TMPDIR`, `ESPICE_CACHE`
    and `ESPICE_SPICERACK`.
