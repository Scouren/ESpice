# The lever gate: `ESPICE_PERF`

Read this when you implement a lever, or when you compare a lever against
the shipped path. One binary holds both paths, so a comparison is two runs
of the same build.

## What it is

`ESPICE_PERF` is a developer variable. It names the levers that are on.
Unset, every lever is off and the engine runs the shipped path, bit for
bit.

```text
ESPICE_PERF=c1            one lever
ESPICE_PERF=c1,c7,n8      several
ESPICE_PERF=all           every lever
ESPICE_PERF=all,-c4       every lever but one; applied left to right
ESPICE_PERF=none          same as unset
```

A name that is not a lever stops the run with `error.UnknownLever`. A typo
must never run the shipped path under a lever's label.

The names are the briefs' names: `c1`, `c3`, `c4`, `c4h` (C4's
measurement bit) and `c6` to `c8`
([04-levers-cpu.md](04-levers-cpu.md); `c2` and `c5` were rejected and deleted with their code), `g1`, `g2`, `g3`, `g7`
([05-levers-gpu.md](05-levers-gpu.md)), `n1`, `n3`, `n7`, `n8`
([09-after-the-levers.md](09-after-the-levers.md); `n6` was rejected and
deleted with its code), and `p1`, the pure
price under `--backend auto` ([08-placement.md](08-placement.md)). The levers that are
decisions, measurements or VerA work have no bit: G4, G5, G6, N5, N10.
A lever gets its bit with its code: `n2`, `n4`, `n9`, `g8` and `g9` had
bits and no code, and were deleted on 2026-11-11
([18-lever-verdicts.md](18-lever-verdicts.md)).

`c2` and its number `ESPICE_HELD_EPS` are gone: the owner rejected the
lever (2026-11-11) because it needed an accuracy bound of its own. No
lever carries a number beside its bit.

## Before and after

```text
# before
espice --timing-in-depth -b deck.cir
# after
ESPICE_PERF=c1 espice --timing-in-depth -b deck.cir
```

With `--timing-in-depth` the run prints `timing: ESPICE_PERF=<value>`, so a
log says which path produced it.

The corpus, with levers on:

```text
nix develop .#ci -c zig build test -Dperf=c1,c7
```

`-Dperf` sets the variable on the corpus and metamorphic run steps. Use it
rather than exporting the variable: the build caches a run step on its
declared inputs, and an exported variable is not one of them.

An **exact** lever must leave every raw byte-identical with the lever on,
so its corpus gate is `-Dperf=<lever>` against no `-Dperf`. A **tolerance**
lever names each deck that moves and its largest move.

## How a lever reads it

`src/core/perf.zig` holds `core.perf.Levers`, one bool per lever. The
facade parses the variable once (`espice/config.zig`, `knobsFromEnv`) and
the value travels in the knobs. Nothing below the facade reads the
environment.

| Layer | Where |
|---|---|
| LU (`src/solver`) | `direct.Knobs.perf` |
| Newton (`src/solver`) | `converger.Knobs.perf` |
| Analysis | `analysis.Knobs.perf` (the circuit's `knobs`) |
| Device | A plain bool in an existing options struct, since the device layer does not import `core`'s root. `abi.BypassTol.c4` is the first. |
| Device LU kernels | `lu_tables.Options` |

Rules:

- Lever off is the shipped path. The new path sits beside it.
- Read the bool once per call or per batch, above the hot loop.
- A unit test sets the bool directly and compares the two paths in one
  process. The lever-off path is the oracle of an exact lever.

## Why a variable, against the standing rule

The briefs say "no new user-facing flag or environment variable". That rule
is about what ships. This variable is how a lever is judged before it
ships, and it is temporary by construction: when a lever is accepted, its
path becomes the only path and its field is deleted; when it is rejected,
its path and its field are deleted. `Levers` empty means the round is over
and `perf.zig` goes with it.

The round ends one step further (the owner's decision, 2026-11-10): with
`perf.zig`, every other variable the simulator reads to make a choice goes
too, the GPU switches included. The simulator makes those choices itself
or offers them as its own options
([the order](13-implementation.md#order-of-the-remaining-work)).

A tolerance lever (C4, C8) follows a different end. The owner's decision
(2026-11-10) is that a tolerance lever may stay reachable by the user: one
that passes its gate graduates to a named, documented opt-in, off by
default, instead of becoming the only path. Its bit in `Levers` is then
replaced by that option, with a name a user can read where `c4` is a
brief's name. Until it graduates, `ESPICE_PERF` is the only way to reach it.

The owner narrowed this on 2026-11-11, when rejecting C2: the accuracy a
user sets is SPICE's own option set (`reltol`, `abstol`, `vntol`,
`chgtol`, `trtol`, `gmin`, `pivrel`, `pivtol`, `itl1` to `itl4`). A lever
that is safe only under a new accuracy number does not ship. C4 decides on
the Newton tolerances the deck already sets, and C8 (the reorder alone,
since its rung budget and cycle watch were measured and deleted) carries
no number a user would set, so both stay candidates under that rule.

A rounding lever (N2) gets a bit the same way when its code is written, so
it can be built and measured without a decision; the decision is whether it becomes the
default, since every raw then moves once in its last bits.
