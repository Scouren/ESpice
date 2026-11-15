# Dialects

ESPice reads two netlist formats, chosen per file by its first line alone.
A file whose first line is `.espice 1` is in
[ESPice's own netlist language](language.md): typed, keyed, and the
format new decks should use. Every other file is read as the legacy
dialect, ngspice's, with the HSPICE cards listed below that no ngspice
spelling collides with; a PDK library or an existing deck needs no
change, and a file in either format may `.include` or `.lib` one in the
other. [Moving a deck to the language](language.md#moving) lists the
spellings that change. A deck in any other dialect (HSPICE, Spectre,
LTspice, Xyce or VACASK) is translated first by
[SpiceRack](https://github.com/Scouren/SPRack)'s `sprack`. ESPice never
runs it itself; the flake builds it from SpiceRack's newest `main` (`nix
build github:OpenFAT/ESPice#sprack`, and `nix develop .#ci` puts it on
`PATH`).

## Other dialects: SpiceRack

```sh
sprack translate --from hspice --to espice deck.sp > deck.espice.sp
espice deck.espice.sp
```

`sprack translate` writes the netlist to stdout and its report to stderr, and
exits 1 when part of the deck has no form ESPice reads. `--to espice`
writes ESPice's legacy dialect, ngspice's plus ESPice's own cards, so
`.alter`, `.hb` and `.pss` pass through; `--to ngspice` targets ngspice
itself. Every difference between ngspice and another dialect is SpiceRack's to translate: HSPICE's
TNOM of 25 °C, `.temp` lists, multi-segment `.tran`, untyped `.measure`
cards and TARG's inherited `TD`, its `P` port, its include search order
and `.option search`, its signed `sqrt`, `log`, `log10` and `pow`, the
`x` (mega) suffix, the `SFFM` and `AM` argument orders, `$` comments and
` \` continuations, and its other spellings of ngspice cards
(`.temperature`, `.dcvolt` and bare `.ic` / `.nodeset` pairs, `.dc src
START= STOP= STEP=`, `.noise v(out) src` and `.pz v(out) src` without a
grid or ports, and the option names `gmindc`, `absv`, `relv`, `absi` and
`method=bdf`), and its other spellings of ESPice's cards: `.sn` (`.pss`),
`.snac` (`.pac`), `.snnoise` (`.pnoise`), `.snxf` (`.pxf v(out)`),
`.snosc` (`.pss v(osc)`), `.hbosc` (`.hb v(osc)`), `.acphasenoise`
(`.noise`; phnoise is 10·log10(onoise²/2)), `.power` (four `.meas tran`
cards), `.stimuli` (`.stim`) and `.jitter` (`.meas ... jitter`);
Spectre's statements, its case-sensitive names and `name:param`
operating-point variables. ESPice reads such a spelling as written and
refuses it like any unknown card. The C API refuses any `dialect` but
ngspice with `UnsupportedDialect` ([The C API](../embed/c-api.md)).

A small HSPICE deck, with parameters used bare, `PULSE` without
parentheses, an untyped `.measure` and an `.alter` run:

```text
--8<-- "examples/hspice_alter.sp"
```

```sh
sprack translate --from hspice --to espice hspice_alter.sp > alter.sp
espice alter.sp
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
sprack translate --from spectre --to espice spectre_rc.scs > rc.sp
espice rc.sp
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
them as written.

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
