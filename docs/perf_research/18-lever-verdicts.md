# Lever verdicts

One row per field of `core.perf.Levers` (`src/core/perf.zig`), 2026-11-11:
its class, the measured evidence, whether that evidence decides it, and the
verdict or the run that would. Nothing here was run for this page. Every
number is quoted from the page and section cited; "13" is
[13-implementation.md](13-implementation.md). The rows of `n2`, `n4`, `n9`,
`g8` and `g9` name bits deleted on 2026-11-11; `Levers` now has 16 fields.

## Rules applied

- An exact lever must leave every raw byte-identical. Accepted, its path is
  the only path and its bit goes; rejected, its path and bit go
  ([11-lever-gate.md](11-lever-gate.md), 13 "Order of the remaining work"
  step 4).
- A tolerance lever (C4, C8) graduates to a named option, off by default,
  only if it decides on SPICE's own options (`reltol`, `abstol`, `vntol`,
  `chgtol`, `trtol`, `gmin`, `pivrel`, `pivtol`, `itl1` to `itl4`). Its gate
  is the corpus passing with every moved deck named with its largest move
  ([README.md](README.md#classes)).
- A rounding lever (N2) is the owner's decision once it is measured.
- A cell within 0.05 of 1 is no change: 13's tables ran beside another
  project's builds.
- "Base" below is 13's wave-5 base set, `c1,c3,c6,c7,n1,n3,n7,n8`.

## Verdicts

| Lever | Class | Evidence | Enough? | Verdict |
|---|---|---|---|---|
| `c1` | exact | 13 "Wave 2, one ReleaseFast binary": 8 lanes `logic_bsim4_1k` 0.91, `sram_bsim4_1k` 0.94; 1 lane 1.14, 1.08, `logic_psp103_1k` 1.11; `sram_bsim4_10k` 1.17 (8 lanes) and 1.47 (1 lane); `chain_bsim4_10k` 0.91 (1 lane). 13 "Wave 3 binary: C1 and C5 by phase", factor phase at 8 lanes: `sram_bsim4_10k` 2.11, `logic_bsim4_1k` 1.39, `chain_bsim4_1k` 0.97, `chain_bsim4_10k` 0.95, "one round on the E-cores beside a build". Wave 5 admits a factor at a run share of 0.7; 13 "Wave 6 binary": the 10k chains hold 23.6% and 23.7%, declined | No. 13 wave 2 calls the 8-lane sign on a small thick factor "open" until "a quiet window"; the admission rule that should remove the chain loss was never timed | Needs CPU-8. Accept if no cell is under 0.95 |
| `c3` | exact | 13 wave 2 (stage 1): 0.98 to 1.01 at 8 lanes, 0.98 to 1.02 at 1 lane, every deck. 13 "Wave 3", C3 stage 2: "evaluations, factor calls and solves 1, 1, 1 against 2, 2, 2", and stage 2 runs only with `n3` off. No timing of stage 2 found | No | Needs CPU-2, before N3's bit goes (with N3 the only path, stage 2 never runs again). Reject if `c3` is under 1.05 on both linear decks |
| `c4` | tolerance | 13 wave 2: `sram_bsim4_1k` 1.17 (8 lanes) and 1.13 (1 lane), `sram_bsim4_10k` 1.22, `vacask_graetz` 0.86 and 0.87. 13 "Wave 5 binary: C4, first look": eval 162.0 to 159.1 ms (`chain_bsim4_1k`), 343.9 to 349.9 ms (`logic_bsim4_1k`). The owner's rule, 13 "Decisions of 2026-11-11": "Keep if `c4,c4h` takes 10% off the eval phase of both BSIM4 1k decks with the corpus name list intact; else delete". Wave 9's `all` corpus run, which holds `c4` and `c4h`: 953 pass, 5 xfail | Half. The name list is intact; the eval phase under `c4,c4h` has no measurement; no moved-deck list | Needs CPU-1. Pass: graduate as `.options latent_bypass` (proposed name; it decides on `reltol`, `vntol`, `abstol`, `executor.zig:415`). Fail: delete `c4`, `c4h` and the code |
| `c4h` | measurement-only | `perf.zig`: "Deleted with C4's verdict" | Yes | Reject: delete after CPU-1, whatever C4's verdict |
| `c6` | exact | 13 wave 2, 8 lanes: `chain_bsim4_1k` 1.07, `logic_bsim4_1k` 1.10, `sram_bsim4_1k` 1.19, `logic_psp103_1k` 1.17; other decks 1.00 to 1.03; 1 lane 0.99 to 1.01. Read from code, not run: the pool is half the CPUs (`exec_config.zig:123`, `Problem.zig:422`), so under the bench's `taskset -c 0-15` a `c6` query took at most 9 lanes. `per_query_wide = 16` says "its runs decide the shipped cap" (`exec_config.zig:116`). No run past 9 lanes found | Steps 1 and 2: yes. The cap: no | Needs CPU-7 for the cap. Steps 1 and 2 (park after 256 pauses, LU-only lanes returned) pay as measured; the cap is 16 or 8 by CPU-7 |
| `c7` | exact | 13 wave 2: 0.97 to 1.04 at 8 lanes, 0.99 to 1.02 at 1 lane; "C3, C5, C7, N7, N8 are inside the noise alone". 1.00 on `scaling_rc_ladder_100k`, where the load is 13% of Newton time (04 C7 "Today"). Not timed alone on a 10k deck. Step 2 "unpriced still" (13 "Wave 3 censuses") | No: its thin 10k targets are unmeasured | Needs CPU-6. Reject unless eval plus load falls by 5% of Newton time on one deck |
| `c8` | tolerance | 13 "Wave 5 binary: C8 by part": `logic_bsim4_10k` 42.2 to 30.3 s, raw differs; `sram_bsim4_10k` 12.5 to 12.5 s, raw identical; the chain rows include the rung budget, since deleted. 13 "Wave 3 binary: the C8 guard": `chain_bsim4_10k` 6.12 to 5.55, `chain_psp103_10k` 13.0 to 13.3. 13 "Wave 6 binary": the judge "ranks the orders the way the run does"; both chains end on the original order. `chain_bsim4_10k`'s operating point is "a lottery". 13 wave 2: one cell at 0.93 (`scaling_rc_ladder_100k`, 1 lane, 3 rounds, raw unchanged). Corpus with `c8` alone: no deck moved (waves 2, 3, 5, 9). Budget and cycle watch rejected (04 C8 "Verdict on change 2"); the code matches: no `stepBudget`, no `solver/cycle.zig` | No. No wall time of today's form (reorder, judge, kept order) on the chains; no moved-deck list | Needs CPU-4 and CPU-10's moved list. Pass: graduate as `.options pivot_reorder` (proposed name; carries no number) |
| `n1` | exact | 13 "Wave 6 binary": `logic_bsim4_10k` refactor 27.0 to 23.8 ms on the original order; declined on `c8`'s order and on `sram_bsim4_10k`. Wave 9 admits both: "Whether the admitted tile pays on these two decks is a timing question ... not a count." Corpus with base: no deck moved (waves 5, 9) | No | Needs CPU-5 |
| `n2` | rounding | No reader of `n2` in `src/`. 09 N2: "measure pairs per cycle with and without contraction. Close it under 1.3x", on C1 stage 2, which 13 "Wave 3 censuses" closed | No code to judge | **Deleted 2026-11-11.** The lever stays in 13 "Later" and gets a bit when built |
| `n3` | exact | 13 wave 2, 8 lanes: `vacask_graetz` 1.11, `chain_bsim4_1k` 1.06, `scaling_rc_ladder_100k` 1.06, `bench_ngspice_mosamp` 1.04; 1 lane: `vacask_graetz` 1.11, `chain_psp103_1k` 1.09; lowest cell 0.97. Raws byte-identical on every bench deck at 1 and 8 lanes. Corpus with the exact set: no deck moved (waves 1 to 9) | Yes for speed; bytes on the bench decks only | Accept: only path, bit deleted, after CPU-2 and with CPU-9 and CPU-10 clean. 16 §3: the lane loop has no twin, so it lands with a written blocker |
| `n4` | exact or rounding | No reader of `n4` in `src/`. Decided in Gompute: 13 "Decisions of 2026-11-11", "both bodies stay, selected at comptime by the target's FMA class. FMA targets take 1.38x, 1.24x and 1.64x"; 12 M4 "Decided" | Yes | **Deleted 2026-11-11.** The work is Gompute's and VerA's pins |
| `n7` | exact | 13 wave 2 (the first form): 0.98 to 1.01 at 8 lanes, 0.99 to 1.01 at 1. 13 "Wave 3 censuses": "`bound` costs 17 to 21 ns per charge state per attempt on every deck, the same at 1 and at 8 lanes and with `n7` on or off". Wave 5 rebuilt it (a minimum per lane chunk, at 16,384 charge states or more); no timing of that form found | No | Needs CPU-3. Reject if `bound` does not fall |
| `n8` | exact | 13 wave 2: 0.99 to 1.04 at 8 lanes, 0.99 to 1.01 at 1. Its target, `chain_bsim4_10k` at 8 lanes ("18% of all cycles", 09 N8), was never timed with `n8` alone | No | Needs CPU-6 |
| `n9` | exact | No reader of `n9` in `src/`. 13 "Wave 3 censuses": "N9: not now ... Read the census again on what C8 leaves" | No code to judge | **Deleted 2026-11-11** |
| `g1` | exact | Host test only: "The serial loop, bitwise, at 1 to 64 threads" (13 "Wave 3"). 13 "State of the checks": "G1, G2, G3, G7 on a device, with their levers on: Not run" | No | Needs GPU-4, whose decks are not in the tree |
| `g2` | exact | Host-thread tests, `refactorColumns` and `solve` bitwise (13 "Wave 1", "Wave 2"). No device run. 05 G2: on the 4060 "the verdict after C1 is expected to be 'host'" | No | Needs GPU-1. Flat on the 4060: needs an FP64-class card |
| `g3` | exact | 16 "What the census sizes": the 16 refactors were "never measured"; "Under `p1` the rent rule replaces it"; both outcomes of the card run delete it. 16 "State": "Its deletion is a held patch, applied after the card measurement". 16 §3: "Conflicts with the new rule". Code: `hold_refactors = 16`, "provisional, not measured" (`lu_admit.zig:90`) | Yes | Reject. GPU-2 prices P1's rent rule, not G3. Until P1's LU half works, deleting G3 leaves 05 G3's "6.0 s of `load_ms` and 3.1 s of `build_ms`" on `logic_bsim4_10k` under `cuda` |
| `g7` | exact | As G2 (13 "Wave 1"); no device run | No | Needs GPU-1 |
| `g8` | exact | No reader of `g8` in `src/`; 05 G8 unbuilt | No code to judge | **Deleted 2026-11-11** |
| `g9` | exact | No reader of `g9` in `src/`; 05 G9 step 1 not run | No code to judge | **Deleted 2026-11-11** |
| `p1` | placement | 13 "Wave 3": `price.place` tested "against a hand-written fixture of this machine's numbers"; `espice calibrate`: "It has never run: it needs the card". LU half inert: `machine.lu_host_key = 0` (`machine.zig:221`); 16 "State" row 1 says the same | No | Needs `lu_host_key` built from a hash of the solver's kernel sources (code), then GPU-2 and GPU-5. It is 13 step 5's end state, so the expected verdict is accept |

Counts over the 16 bits left: accept 1 (`n3`), reject 2 (`c4h`, `g3`),
graduate 0 now with 2 candidates (`c4`, `c8`), needs 13. The 5 bits with
no reader (`n2`, `n4`, `n9`, `g8`, `g9`) were deleted on 2026-11-11.

## What no lever has yet

- **Byte identity over the corpus.** 11's exact gate is "`-Dperf=<lever>`
  against no `-Dperf`". The runner (`tests/test_correctness.zig`,
  `runCase`) compares each raw with its `.expected.json` within tolerance
  and deletes it, so "no deck moved" means the verdict list held, not the
  bytes. Byte identity is recorded only on wave 2's bench decks: "Every
  exact lever, alone and as a set, left the raw file byte-identical on
  every deck, at 1 and at 8 lanes" (13 "Wave 2"). CPU-10 closes it.
- **1 thread against N with levers on**, over the corpus: no record.
  CPU-9.
- **Corpus runs per lever.** Recorded: the exact set (waves 1, 2, 3, 5, 9),
  `c3`, `c4` and `c8` alone, `all` (wave 9). No run with `c1`, `c6`, `c7`,
  `n1`, `n3`, `n7` or `n8` alone, and none of `g1`, `g2`, `g3`, `g7`, `p1`
  on the GPU corpus.
- **Red-first.** Waves 2 and 3 only. Wave 4 and 5 work (C1's admission,
  N1, N7 on lanes, C8's judge and kept order, C4's doubling, `c4h`) has no
  recorded round; 13 "Wave 5": "the corpus, the red-first check and the
  timings are next".
- **ReleaseSafe gate**: "Not run" (13 "State of the checks").
- **Moved-deck lists** with the largest move, for `c4` and `c8`: none. No
  tool in the tree reports the largest move between two raws;
  `tests/benchmark/compare.zig`'s `max_rel` is the nearest.

## Code and doc mismatches

1. **Fixed 2026-11-11.** Five bits have no reader: `n2`, `n4`, `n9`, `g8`, `g9`. `Levers.all`
   turns them on, so wave 9's `all` corpus run counts them while nothing
   ran. `perf.zig`'s rule ("deleted when its lever is accepted ... or
   rejected") has no case for an unbuilt lever.
2. **Fixed 2026-11-11.** 13 "Later": "N2 (rounding class, behind its bit, after N1)". The bit
   exists; the path does not.
3. **Fixed 2026-11-11.** 11-lever-gate.md lists the names "`n1` to `n4` and `n6` to `n9`". `n6`
   was deleted in wave 6 (`perf.zig`'s test rejects it); `c4h` is not
   listed.
4. **Fixed 2026-11-11.** [08-placement.md](08-placement.md) section 1 says `espice calibrate` is
   "Absent" and `price.place` "Not started". The tree has
   `src/espice/calibrate.zig`, `src/analysis/gpu/calibrate.zig`,
   `src/analysis/price.zig` and `lu_price.zig`, as 13 "Wave 3" says.
5. 09 N2 puts the fused operation "on the host and on the device together,
   so the two stay bitwise equal"; 16 §3 says "Device FMA would break
   host-bitwise device LU: by construction, no twin".
6. README "Classes" lets a tolerance lever ship "as the default when it
   selects itself by whether it applies"; 13 step 4 and 11 say it "becomes
   a named user option". C8 selects itself, so the two give different
   answers for it. The owner's call.
7. **Fixed 2026-11-11.** 16 §3 labels `c3` "confirm on the held factor (c2 deleted)"; `c3` is
   linear circuits (04 C3). It labels `c8` "operating-point policy, host
   ladder"; `c8` is the reorder alone (04 C8 "Verdict on change 2").
8. **Fixed 2026-11-11.** `build.zig:322` gives `-Dperf=c1,c2` as its example; `c2` is deleted and
   fails with `error.UnknownLever`.
9. `perf.zig` and 11 say the facade parses `ESPICE_PERF` once. It is parsed
   at `config.zig:359` and again at `config.zig:281` (`loadMachine`, which
   drops `UnknownLever` on purpose, per its comment), and read at
   `main.zig:295`.
10. The C4 rule names "both BSIM4 1k decks". Four exist (`chain`, `ring`,
    `sram`, `logic`); the wave-5 table holds two (`chain`, `logic`). CPU-1
    runs all four and judges on those two.

## Measurements to run

Cheapest decisive run first in each group.

### CPU

Build and decks ([README.md](README.md#reproducing-a-number)):

```text
nix develop .#ci -c zig build exe -Doptimize=ReleaseFast -Dgpu=false -Dcuda-arch=none -Dhip-arch=none
python3 tests/conformance/external/spice-bench/postlayout/gen.py zig-out/postlayout
E=$PWD/zig-out/bin/espice
```

One cell, from the deck's directory, one warm-up and then the rounds; the
wall is the median:

```text
time ESPICE_PERF=<value> taskset -c 0-15 $E --backend cpu --timing-in-depth -b -r out.raw <deck>.sp
```

"8 lanes" leaves `ESPICE_THREADS` unset under `taskset -c 0-15` (02's 8
lanes). "1 lane" adds `ESPICE_THREADS=1 ESPICE_SOLVER_THREADS=1`. Phases
come from `timing: <job> newton:` (eval, load, factor, solve, update) and
`timing: tran step:` (begin, charges, bound, ring, record). Corpus decks sit
in `tests/conformance/tests/netlist/stress/` (`vacask_*`, `scaling_*`) and
`.../tran/` (`bench_ngspice_mosamp`); post-layout decks in
`zig-out/postlayout/`. Run in a quiet window: no build in any worktree.

| Run | Decides | Decks | `ESPICE_PERF` | Lanes, rounds | Read | Rule |
|---|---|---|---|---|---|---|
| CPU-1 | C4, `c4h` | `chain_bsim4_1k`, `logic_bsim4_1k`, `sram_bsim4_1k`, `ring_bsim4_1k` | `base` and `base,c4,c4h` | 8, 5; one more round with `ZP_TRAN_STATS=1` for `bypass-stats:` | transient eval phase | Graduate if eval falls 10% on `chain` and `logic`; else delete both bits |
| CPU-2 | C3 | `vacask_rc`, `scaling_rc_ladder_100k` | `none`, `c3`, `n3`, `c3,n3` | 1 and 8, 5 each | wall; iterations per step | Reject if `c3` is under 1.05 on both. If `c3` pays and `c3,n3` equals `n3`, stage 2 must run beside N3 first |
| CPU-3 | N7 | `scaling_rc_ladder_100k`, `chain_bsim4_10k`, `chain_psp103_10k`, `sram_bsim4_10k` | `none`, `n7` | 8, 3 | `bound` | Accept if `bound` falls a quarter on one deck and no wall is under 0.95; else reject |
| CPU-4 | C8 | `logic_bsim4_10k`, `sram_bsim4_10k`, `chain_psp103_10k`, `logic_psp103_10k`; `chain_bsim4_10k` by transient phases only ("never one wall time", 13 wave 5); `scaling_rc_ladder_100k` at 1 lane, 3 rounds | `base`, `base,c8` | 8, 2 | wall; operating-point iterations; transient factor phase | Graduate if `logic_bsim4_10k` holds 1.2 and nothing is under 0.95, with CPU-10's moved list |
| CPU-5 | N1 | `logic_bsim4_10k`, `sram_bsim4_10k` | `c1,c3,c6,c7,n3,n7,n8`, with and without `n1`, each with and without `c8` | 8, 3 | transient factor phase per refactor | Accept if `n1` cuts it 5% on one deck under either order and raises none 5% |
| CPU-6 | C7, N8 | `chain_bsim4_10k`, `sram_bsim4_10k`, `chain_psp103_10k`, `scaling_inverter_chain_4k`, `scaling_rc_ladder_100k` | `none`, `c7`, `n8`, `c7,n8` | 8, 3 | eval and load phases | Accept a lever whose eval plus load falls by 5% of Newton time on one deck, no wall under 0.95; reject the other |
| CPU-7 | C6's cap | `chain_bsim4_10k`, `ring_bsim4_10k`, `sram_bsim4_10k`, `logic_bsim4_10k` | `none`, `c6` | default threads, once with no `taskset` (32 CPUs, a pool of 16) and once under `taskset -c 0-15`; 2 rounds | wall and CPU-seconds | Cap 16 if unpinned `c6` gains 1.05 on two decks with no loss; else the cap stays 8 and `per_query_wide` goes. Accept C6 either way |
| CPU-8 | C1 | 8 lanes 5 rounds and 1 lane 3: `logic_bsim4_1k`, `sram_bsim4_1k`, `logic_psp103_1k`, `chain_bsim4_1k`. 8 lanes 2 rounds and 1 lane 1: `sram_bsim4_10k`, `logic_bsim4_10k`, `chain_bsim4_10k`, `chain_psp103_10k` | `none`, `c1` | as listed | wall; factor phase | Accept if no wall cell is under 0.95 |

CPU-9, 1 thread against 8 with the exact levers on (the existing
determinism oracle):

```text
nix develop .#ci -c zig build exe -Doptimize=ReleaseSafe -Dgpu=false -Dcuda-arch=none -Dhip-arch=none
nix develop .#ci -c env ESPICE_PERF=c1,c3,c6,c7,n1,n3,n7,n8 tools/determinism.sh zig-out/bin/espice tests/conformance/tests/netlist 8
```

CPU-10, lever off against on, raw bytes over the corpus, same ReleaseSafe
binary. Its deck list and arguments are `tools/determinism.sh`'s, so decks
in another dialect are left out as there. A `MOVED` line for an exact lever
fails it; the `c4`, `c8` and `c4,c4h` lines are the tolerance gate's moved
list:

```text
nix develop .#ci -c bash -c '
export E=$(realpath zig-out/bin/espice) W=$(mktemp -d) ZIG=$(command -v zig)
export ESPICE_CACHE=$W/cache LEVERS="c1,c3,c6,c7,n1,n3,n7,n8 c1 c3 c6 c7 n1 n3 n7 n8 c4 c4,c4h c8"
one() { k=$(printf %s "$1" | tr / _)
  for v in none $LEVERS; do
    (cd "$(dirname "$1")" && ESPICE_PERF=$v timeout 900 "$E" --backend cpu --format=binary -b \
      -r "$W/$k.$v.raw" --tokenizer ngspice "$(basename "$1")" >/dev/null 2>&1; echo $? >"$W/$k.$v.rc")
  done
  for v in $LEVERS; do
    cmp -s "$W/$k.none.rc" "$W/$k.$v.rc" &&
      { [ ! -e "$W/$k.none.raw" ] || cmp -s "$W/$k.none.raw" "$W/$k.$v.raw"; } || echo "MOVED $v $1"
  done; rm -f "$W/$k".*; }
export -f one
find tests/conformance/tests/netlist -name "*.sp" | while read -r d; do j=${d%.sp}.expected.json
  [ -e "$j" ] && ! grep -Eq "\"tokenizer\": *\"(hspice|spectre)\"" "$j" && echo "$d"; done | sort |
  xargs -P "$(nproc)" -I{} bash -c "one \"\$1\"" _ {} | sort > lever-bytes.txt
! grep -E "^MOVED (c1|c3|c6|c7|n1|n3|n7|n8|c1,c3,c6,c7,n1,n3,n7,n8) " lever-bytes.txt'
```

### GPU

Builds, in the GPU shell (the wave-3 GPU check took 41 min of `ptxas`):

```text
nix develop -c zig build exe -Doptimize=ReleaseFast -Dhip-arch=none -p zig-out/gpu
nix develop -c zig build exe -Doptimize=ReleaseFast -Dhip-arch=none -Dlu-instrument=true -p zig-out/gpu-instr
```

| Run | Decides | Decks | `ESPICE_PERF` | Command | Read | Rule |
|---|---|---|---|---|---|---|
| GPU-1 | G2, G7 | `logic_bsim4_10k`, `sram_bsim4_10k`, `logic_psp103_10k` | `none`, `g2`, `g7`, `g2,g7` | `ESPICE_GPU_LU=1 ESPICE_GPU_LU_CHECK=1 ESPICE_GPU_LU_BENCH=200 zig-out/gpu-instr/bin/espice --backend cuda --timing-in-depth -b -r <deck>.<v>.raw <deck>.sp`, then `cmp` each raw against `none`'s | `gpu-lu-bench:` device refactor and solve medians; `mismatches=` | Accept a bit if mismatches are 0, raws equal, and its kernel median falls 5% on two decks and rises on none. Flat: needs an FP64-class card (05 G2) |
| GPU-2 | P1's rent rule (and the G3 premise) | the same three | `none`, `g3` | `zig-out/gpu/bin/espice calibrate`, twice; compare the two files by row name (08 step 1). Then `ESPICE_GPU_LU=1 ESPICE_GPU_STATS=1 zig-out/gpu/bin/espice --backend cuda --timing-in-depth -b -r out.raw <deck>.sp` | `gpu-lu:` `refactors`, `epochs`, `load_ms`; operating-point time | 16: refactors per operating-point epoch against the calibrated table build |
| GPU-3 | correctness of G1, G2, G7 | the corpus | `-Dperf=g1,g2,g7`, and none | `nix develop -c zig build test -Doptimize=ReleaseSafe -Dhip-arch=none -Dperf=g1,g2,g7 -- --backend cuda --jobs 1` | failing deck names | The two name lists are equal |
| GPU-4 | G1 | `hb_2048`, `ac_8192` (study ids in `docs/performance/gpu-phases.tsv`; outside the tree, 08 step 2) | `none`, `g1` | `time env ESPICE_PERF=<v> zig-out/gpu/bin/espice --backend cuda -b -r <deck>.<v>.raw <deck>.sp`, and once `--backend cpu`; `cmp` each cuda raw with the cpu raw | wall, user CPU | 05 G1: `hb_2048` under `cuda` within 10% of the `cpu` wall, user CPU at least 10 times wall, raws identical |
| GPU-5 | P1 | `src/analysis/gpu/placement.tsv`'s decks and the three thick 10k decks | `p1` under `auto`; none under `cpu` and `cuda` | after `lu_host_key` exists and GPU-2's file is in place: `--backend cpu`, `cuda`, `auto` walls, 3 rounds; `nix develop -c zig build test -Doptimize=ReleaseSafe -Dhip-arch=none -Dperf=p1 -- --backend auto --jobs 1` | walls; name list | 08 steps 3 and 4 "Done when" |

### Unbuilt levers

Their bits were deleted on 2026-11-11; these are the first steps the docs
give, for when one is built.

- N2: pairs per cycle with and without contraction on C1's run kernel;
  close under 1.3x (09 N2).
- N9: `lu-subtree-census:` (`ZP_LU_STATS`, `-Dlu-instrument=true`) on
  `c8`'s kept order of `logic_bsim4_10k` (13 "Wave 3 censuses").
- G8: colours per lane deck in the corpus, offline (05 G8 step 1).
- G9: a 64-point sweep of `logic_bsim4_1k` and `sram_bsim4_10k` on the CPU
  and under `--backend cuda` (05 G9 step 1).
- N4: nothing in ESPice. The Gompute FMA release and the VerA release that
  consumes it enter the pins together (13 "Decisions of 2026-11-11").
