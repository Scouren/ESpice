# ESPice

A SPICE simulator written in Zig. Every device, from the resistor to BSIM4, is a Verilog-A model
compiled at build time by [VerA](https://github.com/OpenFAT/VerA), and one device kernel runs on
the CPU, CUDA and HIP through [Gompute](https://github.com/OmarSiwy/Gompute).

```sh
nix run github:OpenFAT/ESPice -- deck.sp         # run an ngspice deck (HSPICE and Spectre are detected and translated)
espice -r out.raw deck.sp                        # also write waveforms
espice --backend cuda sweep.sp                   # sweep points as GPU lanes
espice --plan deck.sp                            # print the analysis DAG without solving
```

[Docs](https://openfat.github.io/ESPice/) · [Install guide](https://openfat.github.io/ESPice/using/install/) · [Changelog](CHANGELOGS.md) · [Testing](TESTING.md)

## Install

```sh
nix run github:OpenFAT/ESPice -- deck.sp                     # from source, no install
nix profile install github:OpenFAT/ESPice                    # .#espice-cuda adds CUDA
```

From a checkout (the devshell provides Zig 0.18.0-dev.349; VerA and Gompute are pinned in
`build.zig.zon`):

```sh
nix develop            # .#ci for CPU only
zig build              # zig-out/bin/espice; -Dgpu=false skips the GPU kernels
```

Packages (`.deb`, `.rpm`, `.pkg.tar.zst`, Homebrew, the install script, CUDA and HIP builds) come
with the first release; the [install guide](https://openfat.github.io/ESPice/using/install/) has
every route.

## Analyses

| Group | Cards |
|---|---|
| DC | `.op` `.dc` `.tf` `.sens` `.dcmatch` `.dcsens` `.acmatch` `.dcxf` `.acxf` `.dcinc` `.temp` |
| Small signal | `.ac` `.noise` `.pz` `.disto` `.sp` `.lin` `.net` `.stb` `.lstb` |
| Transient | `.tran` `.four` `.fft` `.trannoise` `.envelope` `.matex` |
| Periodic steady state | `.pss` `.pac` `.pxf` `.pnoise` `.qpss` |
| Harmonic balance | `.hb` `.hbac` `.hbxf` `.hbnoise` `.hblin` `.phasenoise` |
| Variation | `.mc`, scaled-sigma sampling, worst-case distance, safe operating area |

Analyses form a DAG and run on every core (`--jobs`); shared prerequisites, such as the operating
point under an `.ac`, are solved once. Syntax and outputs: [analyses](https://openfat.github.io/ESPice/using/analyses/).

## Models

All in [`models/`](models/), vendored one file per model so a build downloads nothing. Your own:
`.hdl "model.va"` plus an `N` card compiles a Verilog-A module at run time (OSDI is not loaded).

| Device | Models | Derived from |
|---|---|---|
| Passives, sources, switches | R, C, L, K, V, I, E, G, F, H, B, S, W | ngspice / SPICE3 (BSD-3); C, L, Laplace, pole and delay forms written for ESPice |
| Transmission lines | T, LTRA, TXL, CPL (2–4 conductors), uniform RC | ngspice / SPICE3 |
| Data elements | S-parameter blocks (1–4 ports), W-element lines (1–4 conductors) | written for ESPice |
| Diode | junction diode | ngspice / SPICE3 |
| | JUNCAP2 200.6.2 | CMC release (NXP, TU Delft) |
| | DIODE_CMC 3.0 | CMC release |
| | ASM-ESD 101.1.0 | IIT Kanpur release |
| BJT | Gummel-Poon | ngspice / SPICE3 |
| | VBIC 1.3 (4 terminal) | VACASK, from Dietmar Warning's VA-Models |
| | HICUM/L2 3.2.0, HICUM/L0 2.1.0 | HICUM group release |
| | Mextram 505.6.0 | CMC release (NXP, TU Delft, Auburn) |
| MOSFET | MOS 1/2/3/6/9, BSIM1, BSIM2, BSIM3, B3SOI-FD, B3SOI-DD, VDMOS | ngspice / SPICE3 |
| | BSIM4 (`LEVEL=14`/`54`) | Cogenda VA-BSIM48 (**CC-BY-NC 4.0, no commercial use**) |
| | BSIM-CMG 112.1.0, BSIM-IMG 103.1.0, BSIM-BULK 107.2.1, BSIM-SOI 101.0.0 | UC Berkeley release |
| | PSP 103.8.2, PSP 104.1.0 (QS, NQS, self-heating) | CMC release (NXP, TU Delft, CEA) |
| | L-UTSOI 102.9.0 | CEA-Leti release |
| | HiSIM2 | Hiroshima University / STARC |
| | HiSIM_HV 2.5.1, HiSIM_SOI 1.5.0, HiSIM_SOTB 1.3.0 | Hiroshima University release |
| | MOSVAR 1.4.0 | CMC release |
| HEMT | ASM-HEMT 101.6.0 | IIT Kanpur release |
| | MVSG_CMC 5.0.0 | CMC release |
| Resistor | R2_CMC 1.0.2, R3_CMC 1.1.2 | CMC release |
| Other FETs | JFET, JFET2, MESFET, MESA, HFET1, HFET2 | ngspice / SPICE3 |

Releases and licences per file: [models/LICENSES.md](models/LICENSES.md). Card and `LEVEL`
mapping: [devices](https://openfat.github.io/ESPice/using/devices/).

## Accuracy

Measured against other SPICE simulators on the
[conformance corpus](https://github.com/OpenFAT/VAMS-Conformance-Suite) (about 920 decks), per
analysis. Each cell: decks agreeing / decks compared, and the worst relative error among the
agreeing ones.

| Analysis | vs ngspice | vs Xyce | vs VACASK |
|---|---:|---:|---:|
| `.op` | — | — | — |
| `.dc` | — | — | — |
| `.tf` / `.sens` | — | — | — |
| `.ac` | — | — | — |
| `.noise` | — | — | — |
| `.pz` | — | — | — |
| `.disto` | — | — | — |
| `.sp` | — | — | — |
| `.stb` | — | — | — |
| `.tran` | — | — | — |
| `.four` / `.fft` | — | — | — |
| `.pss` / `.pac` / `.pnoise` | — | — | — |
| `.hb` | — | — | — |

Not measured yet. A reference converges at its own tolerance (ngspice at `reltol = 1e-3`), so
errors below it are reported as agreement, not as precision.

## Benchmarks

One chart per analysis: wall time (y) against circuit size in devices after subcircuit expansion
(x), both log, ESPice against each reference simulator.

<!-- bench:start -->
Not measured yet.
<!-- bench:end -->

Reproduce: `nix develop .#benchmarking -c zig build bench`, then `tools/bench_plot.py` (which
rewrites the block above).

## Tests

```sh
git submodule update --init tests/conformance
nix develop .#ci -c zig build test              # unit suites, then the deck corpus
```

Each deck is scored against its `.expected.json`, which records the tool and version that produced
it. What each check proves and when it runs: [TESTING.md](TESTING.md).

## Contributing

Maintained by one person. Branches and how to send a change: [CONTRIBUTING.md](CONTRIBUTING.md).
Vulnerabilities: [SECURITY.md](SECURITY.md).

## License

Apache-2.0 ([LICENSE](LICENSE)). Models in `models/` keep their own licences
([models/LICENSES.md](models/LICENSES.md)); `bsim4va.va` is CC-BY-NC 4.0, so commercial users must
replace it.
