# Dialects

ESPice reads one netlist dialect, ngspice's, with the HSPICE cards listed
below that no ngspice spelling collides with. A deck in any other dialect
(HSPICE, Spectre, LTspice, Xyce or VACASK) runs as SpiceRack's ngspice
translation of it: the CLI hands it to `spice2rack` first and reads only
what comes back. Without `--tokenizer` the CLI picks the dialect from
markers in the deck's own file, ngspice when none is present (see
[`--tokenizer`](cli.md#options)). A marker is a spelling ESPice's own
reader refuses, and ngspice 44.2 too: Spectre's `simulator lang=` or `r1
(a b) resistor` form, or HSPICE's `.dcvolt`, `.temperature`, `.sn`,
`.snac`, `.snnoise`, `.snxf`, `.snosc`, `.hbosc`, `.acphasenoise`,
`.power`, `.stimuli`, `.jitter`, `.dc ... START=`, a `P` card's
`PORT=`, or an `E` or `G` card's `SCALE=`, `MAX=`, `MIN=` or `ABS=`. So a
deck that runs as written is never
translated, and the stderr note names the line and spelling that sent a
deck to SpiceRack. Name the dialect to be sure:

```sh
espice deck.sp                        # detected; ngspice without markers
espice --tokenizer=hspice deck.sp     # or hs: translated by spice2rack
espice --tokenizer=spectre deck.scs   # or scs
espice --tokenizer=ngspice deck.sp    # read as written, never translated
```

## Other dialects: SpiceRack

For a deck in another dialect the CLI runs

```sh
spice2rack --dialect <d> --to espice --kit -o <dir> <deck>
```

into a fresh directory under `$TMPDIR` (else `/tmp`). The kit holds the
translated deck and a translated copy of every file it reaches, in their
relative layout, with every `.include` and `.lib` path rewritten to an
absolute path into the kit (an absolute PDK path is mirrored under it).
ESPice reads the entry SpiceRack prints, so each include resolves to its
copy and never to a file of the same name in the working directory, and
deletes the directory when the deck ends. Output paths (`-r`, `.stim`
files, `--measures=FILE`) stay relative to the working directory.

The binary is `--spicerack=PATH`, else `$ESPICE_SPICERACK`, else
`spice2rack` on `PATH`. SpiceRack is installed separately: the flake does
not ship it until a SpiceRack release with `--to espice --kit` is pinned.

SpiceRack's notes pass through on stderr as it wrote them, and two lines
there keep its time apart from ESPice's:

```text
espice: spicerack translated <deck> (<d> -> ngspice, <n> files) in <s> s
espice: finished <deck> in <s> s, plus <s> s in spicerack
```

A deck SpiceRack refuses stops with `SpiceRackRefused` and SpiceRack's
coded line; one it cannot translate, with `SpiceRackFailed`,
`SpiceRackNotFound` or `SpiceRackNoEntry` (see
[Diagnostics](diagnostics.md)); it is never read as ngspice instead. A deck
in another dialect is read from a file: one through a pipe or FIFO is
refused with `SpiceRackNeedsFile`, as spice2rack would read it empty.
spice2rack gets the deck's real path, so `espice --tokenizer=hspice
/dev/stdin < deck.sp` translates `deck.sp` itself, includes and all.

Every difference between ngspice and another dialect is SpiceRack's to
translate: HSPICE's TNOM of 25 °C, `.temp` lists, multi-segment `.tran`,
untyped `.measure` cards and TARG's inherited `TD`, its `P` port, its
include search order and `.option search`, its signed
`sqrt`, `log`, `log10` and `pow`, the `x` (mega) suffix, the `SFFM` and
`AM` argument orders, `$` comments and ` \` continuations, and its other
spellings of ngspice cards (`.temperature`, `.dcvolt` and bare `.ic` /
`.nodeset` pairs, `.dc src START= STOP= STEP=`, `.noise v(out) src` and
`.pz v(out) src` without a grid or ports, and the option names `gmindc`,
`absv`, `relv`, `absi` and `method=bdf`), and its other spellings of
ESPice's cards: `.sn` (`.pss`), `.snac` (`.pac`), `.snnoise` (`.pnoise`),
`.snxf` (`.pxf v(out)`), `.snosc` (`.pss v(osc)`), `.hbosc` (`.hb
v(osc)`), `.acphasenoise` (`.noise`; phnoise is 10·log10(onoise²/2)),
`.power` (four `.meas tran` cards), `.stimuli` (`.stim`) and `.jitter`
(`.meas ... jitter`); Spectre's
statements, its case-sensitive names and `name:param` operating-point
variables. The library reads ngspice only: the C API refuses any other
`dialect` with `UnsupportedDialect` ([The C API](../embed/c-api.md)), and
the Zig `Options` has none.

A small HSPICE deck, with parameters used bare, `PULSE` without
parentheses, an untyped `.measure` and an `.alter` run:

```text
--8<-- "examples/hspice_alter.sp"
```

```sh
espice --tokenizer=hspice hspice_alter.sp
```

```text
  Measurements for Transient Analysis

t50                 =   1.39130e-09

  Measurements for Transient Analysis

t50                 =   2.77759e-09
RC step response in the HSPICE dialect: 3 devices
  Transient Analysis: 2012 points, 4 variables
  Transient Analysis (alter=1): 2012 points, 4 variables
```

The `.alter` run doubles R, and the 50 % crossing moves from RC ln 2 =
1.39 ns to 2.77 ns. A Spectre netlist runs the same way:

```text
--8<-- "examples/spectre_rc.scs"
```

```sh
espice --tokenizer=spectre spectre_rc.scs
```

## ngspice

The dialect follows ngspice 45, including the conveniences the open PDKs
(sky130, GF180, IHP SG13G2) are written against:

- `.endl` closes the open `.lib` section whatever name follows it.
- `.if` / `.elseif` / `.else` / `.endif` keep the first branch whose
  condition is nonzero.
- `.model <name> psp103va` (the OSDI module name) selects the built-in PSP
  103.
- An R card whose braced value reads `v(`, `i(`, `time`, `temper` or
  `hertz` becomes a behavioural B source, as ngspice's `inp_compat` does.
- `x^y` and `x**y` are |x|^y everywhere, integer exponents included.
  `pow(x, y)` is C's pow in a `.param` or a value (`pow(-2,3)` is -8, and
  a card that reads a negative base to a fractional power fails the deck)
  and |x|^y in a B, E or G expression; `pwr(x, y)` is |x|^y in a `.param`
  or a value and sign(x)·|x|^y in a B, E or G expression. A `.param` keeps its meaning where a B source
  reads it, and a `.func` body takes its caller's, as in ngspice 44.2 and
  45 (measured).
- `.option seed=N` without a Monte Carlo sweep draws the statistical
  functions once from the seed, instead of folding them to their nominal.
- Unknown `.option` names are ignored with one warning each.

The sky130 PDK decks run as written. The suffix table is `t g meg k m mil
u n p f a` (case-insensitive), and `d` works as an exponent (`1d-3`).

## HSPICE cards ESPice reads as written

These HSPICE features are part of ESPice's own dialect, because none of
them collides with an ngspice spelling. The CLI reads a deck that uses
them as written; `--tokenizer=hspice` sends it through SpiceRack instead.

- **Runs and sweeps:** `.alter` blocks (cumulative, one run each, plots
  named `(alter=n)`); `.data` tables with `SWEEP DATA=name`; `SWEEP
  MONTE=n` and `MONTE=list(...)`; `SWEEP OPTIMIZE=` with `.param p =
  name(init, lo, hi[, dels[, grid]])` (the grid is ESPice's) and `.meas ... GOAL=`.
- **Analysis cards:** `.op t1 t2 ...` (operating points at times),
  `.dc ... POI`, `.ac POI` (and `POI` on `.pac`, `.pxf`, `.pnoise`),
  `.four f v(a) v(b) ...`, `.fft`, `.lin`, `.net`, `.hb TONES= NHARMS=`,
  `.hbac`, `.hbxf`, `.hbnoise`, `.hblin`, `.phasenoise`, `.ptdnoise`,
  `.lstb`, `.dcmatch`, `.acmatch`, `.dcsens`, `.trannoise`.
- **Measurements:** `INTEGRAL`, `DERIVATIVE`, `ERR`, `ERR1`-`ERR3`, `PARAM=`,
  `TRAN_CONT`/`AC_CONT`/`DC_CONT`, `EM_AVG`, `par('expr')`, values that name
  earlier results, `TD=TRIG`, and measures of FFT, LSTB, DCMATCH, ACMATCH,
  PHASENOISE and PTDNOISE plots.
- **Digital stimuli:** `PAT (vhi vlo td tr tf tsample data)` sources and
  `.vec` vector files, rewritten to PWL sources and `.dout` checks. A
  pattern nests at most 32 `[ ]` levels, counted through the `.pat` names
  it reads.
- **Checks and reports:** `.check rise|fall|slew|setup|hold|edge|irdrop`,
  `.dout`, `.biaschk`, `.stim`.
- **Statistics:** `agauss`, `gauss`, `aunif`, `unif`, `limit`; `DEV` and
  `LOT` tolerances on `.model` values; the `.variation` block.
- **Other:** `.load` (inline a saved `.ic`/`.nodeset` file), `.save
  TYPE=IC|NODESET [FILE=] [LEVEL=] [TIME=]` (write the operating point:
  a `.save` with one of these keys, as ngspice's vector list never has
  one), `.connect`, `.global`, `.mosra` and `.appendmodel`
  (reliability aging), `.sample`, `.option runlvl|accurate|fast`.

These follow the HSPICE manuals; most have not been run against HSPICE
itself, so treat an HSPICE-only result with the same care as any new
simulator's.

## What is not supported, or differs

ESPice refuses what it cannot simulate with `UnsupportedCard`, naming the
line; it never drops a card silently. Output-only cards (`.print`,
`.plot`, `.probe`, `.graph`, `.width`, `.title`, `.protect`,
`.unprotect`) are accepted and ignored, because every vector is written
anyway.

| Input | ngspice or HSPICE | ESPice |
|---|---|---|
| OSDI (`pre_osdi`, `.osdi_include`) | loads a compiled `.osdi` | refused with `OsdiUnsupported`, naming the `.hdl` card to use instead; see [Verilog-A](devices.md#your-own-verilog-a) |
| `.control` ... `.endc` | runs ngspice scripts | skipped with a warning (`pre_osdi` inside it is still an error) |
| E/G `FREQ`, `OPAMP`, `NPWL`, `PPWL`, `AND`, `NAND`, `OR`, `NOR`, `TRANSFORMER` | HSPICE behavioural forms | refused |
| `0e400` (zero mantissa, huge exponent) | NaN (0 × inf) | 0 |
| URC model with `K <= 0` or `K = 1` | NaN or meaningless ladder | `InvalidParameterValue` |
| URC card without `l=` | zero length | unit length |
| Verilog-A `$simparam("gmin")` during gmin stepping | the deck gmin | the stepped gmin |
| `.options vpi="app.so"` | not an option | ESPice's own: loads a VPI application, as `--vpi` does; see [VPI applications](devices.md#vpi-applications) |
| two V cards on one `portnum` | ngspice 44.2 refuses: `duplicate port Index` | ESPice's own: one balanced port for `.sp` and `.lin`, HSPICE's mixed-mode P element; see [`.sp`](analyses.md#sp) |
| `.ic` with `.tran` but without `uic` | held during the transient's operating point | used only under `uic` |
| `.store` | checkpoints the process | warning; no checkpoint written |
| `.powerdc` | per-instance port currents | refused |
| `.connect` inside a subcircuit | joins nets | refused (top level only) |
| a `.param` or `.model` inside a subcircuit's `.if` | conditional | applies unconditionally |
| `PAT` Z states, K-strings, `R=-1`, LFSR; `.vec` bidirectional signals, Z/L/H inputs | supported | refused |
| PWL with `r=` past 64 points | repeats | refused |
| `.dout` with no threshold | n/a | 1.65 V |
| `.vec` edges with no rate given | 0.1 ns | 0.1 ns |
| `.measure DERIV` | ngspice 45 rejects it | slope of the sample pair around the point |
| `.measure ERR3` | the manual gives no reduction | RMS, as `ERR1` |
| `.meas` with `-r` in batch mode | ngspice refuses | always evaluated and printed |
| HSPICE `.mt0`, `.ic0` listings, `.err` files | written | not written; results print on stdout |
