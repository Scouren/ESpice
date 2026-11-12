# Language reference

Every element letter and every dot card ESPice reads, in its one dialect:
ngspice's, with the HSPICE cards no ngspice spelling collides with. A deck
in another dialect arrives as SpiceRack's ngspice translation of it (see
[Dialects](dialects.md)). The lists come from the parser's
tables: the card keyword map and the element letter map. A card not listed
here is refused with `UnsupportedCard`, naming the line.

Notation: `n+ n-` are nodes, `[x]` is optional, `...` repeats, and
`key=value` pairs may come in any order. Keywords are case-insensitive.

## Deck structure

```text
Title line (always the first line)
* comment
element cards
.control cards
.end
```

Logical lines: a line starting with `+` continues the one before it.
Comments: `*` at the start of a line; `;` and `//` cut the rest of a line,
and so does `$` after a blank or a comma, outside quotes. A line left
holding only a comment is a comment line.

Values: a number with an optional scale suffix (`t g meg k m mil u n p f a`,
any case; `m` is milli; `1d-3` is `1e-3`), a parameter name, `{expression}`
or `'expression'`. After `key=` an unbraced expression reads too, blanks
around its operators included (`w=2*l`, `r=7k % 4k`); that is an ESPice
extension, since ngspice refuses one that starts with a digit. A number
run straight into `%` or `\` (`r=10%3`) is one ngspice token and reads as
ngspice reads it, 10. A device's value or model field that starts with an
operator (`R1 a b 10 %3`) is refused, as ngspice refuses it; node fields
are names and are read.

Expressions: `+ - * / ^ **`, `%` (remainder) and `\` (integer division),
`== != <> < <= > >=`, `&& || !` and `?:`. Functions: `sqrt exp ln log log10 abs
floor ceil min max pow pwr sin cos tan atan tanh sinh cosh asin acos asinh
acosh atanh sgn nint ternary_fcn` and the user functions of `.func`. `^`
and `**` are |x|^y everywhere; `pow` is C's pow in a `.param` or a value
and |x|^y in a B, E or G expression; `pwr` is |x|^y in a `.param` or a
value and sign(x)·|x|^y in a B, E or G expression, as ngspice 44.2 reads
them (see [Expressions](../learn/parameters.md#expressions)). A `.param` or a value also takes `sqr int arctan`;
a B, E or G expression refuses them, as ngspice's B parser has none, and
refuses `%` and `\` on a probe. A B, E or G expression also takes the B
parser's `u uramp u2 eq0 ne0 gt0 lt0 ge0 le0 pwl ddt`, which a `.param` or a
value refuses, as ngspice's numparam has none. PSPICE's `if`, `|`, `&`, `~`,
`table()` and its predefined `temp`, `vt` and `gmin` are refused, as plain
ngspice refuses them, and so is `ternary()` (`ternary_fcn` is ngspice's).

Braces inside an expression: ngspice strips a brace or quote inside a B, E
or G expression as text, so `2*{1+v(a)}` is 2·1 + v(a) there. ESPice runs
one that strips to the same expression (`{k}*v(a)`, `2*{k}`) and refuses
any other; write parentheses. A B line holding `=pwl(` keeps its braces in
ngspice, which evaluates each one as a `.param` value: there a brace groups
(`v=pwl(v(a),0,0,1,4)*{1+k}` is 8 at v(a) = 0.5, k = 3), and one that reads
a probe is refused, as ngspice stops on it. A brace nested in a `.param`, a `.func` body
or a value is a parse error (ngspice: a syntax error in a `.param`, the
stripped text in a `.func` body, and a value's reading depends on whether
the deck has a `.param`).

Nodes: any word or number; `0`, `gnd` and `ground` are ground. Names inside
a subcircuit instance are prefixed with the instance path (`x1.n3`).

## Elements

The first letter of an element's name selects its kind.

| Letter | Element | Syntax |
|---|---|---|
| `R` | resistor | `R1 n+ n- value [tc1= tc2= m=]`; a negative value stays negative, and \|value\| is at least 1e-12 |
| `C` | capacitor | `C1 n+ n- value [ic=v m=]` |
| `L` | inductor | `L1 n+ n- value [ic=i m=]` |
| `K` | mutual inductance | `K1 L1 L2 k` |
| `V` | voltage source | `V1 n+ n- [DC v] [AC mag [phase]] [waveform] [portnum n z0 Z]` |
| `I` | current source | `I1 n+ n- [DC i] [AC mag [phase]] [waveform] [m=]` |
| `E` | voltage-controlled voltage source | `E1 o+ o- c+ c- gain`, or a nonlinear form |
| `G` | voltage-controlled current source | `G1 o+ o- c+ c- gm`, or a nonlinear form |
| `F` | current-controlled current source | `F1 o+ o- Vsense gain` |
| `H` | current-controlled voltage source | `H1 o+ o- Vsense r` |
| `B` | behavioural source | `B1 n+ n- V={expr}` or `I={expr}` |
| `S` | voltage-controlled switch | `S1 n+ n- c+ c- model [ON\|OFF]` (`.model m SW(VT= VH= RON= ROFF=)`); `ON` starts the switch on when the `.op` control sits inside a positive band |
| `W` | current-controlled switch | `W1 n+ n- Vsense model [ON\|OFF]` (`.model m CSW(IT= IH= RON= ROFF=)`); as in ngspice, the `.op` ignores `ON`/`OFF` |
| `T` | lossless transmission line | `T1 a1 b1 a2 b2 Z0= TD=` or `Z0= F= [NL=]` |
| `O` | lossy transmission line (LTRA) | `O1 a1 b1 a2 b2 model` (`.model m LTRA(R= L= G= C= LEN=)`) |
| `Y` | lossy transmission line (TXL) | `Y1 a1 b1 a2 b2 model` (`.model m TXL(R= L= G= C= LENGTH=)`) |
| `P` | coupled lines (CPL), 2 to 4 conductors | `P1 in1..inN ref1 out1..outN ref2 model` (`.model m CPL(...)`) |
| `U` | uniform distributed RC line | `U1 n1 n2 n3 model [L=len] [N=lumps]` (`.model m URC(K= FMAX= RPERL= CPERL=)`) |
| `D` | diode | `D1 anode cathode [tj] model [area] [thermal] [m=]`; `tj` and `thermal` self-heat it (see [diode self-heating](devices.md#diode-self-heating)) |
| `Q` | bipolar transistor | `Q1 c b e [s] model [area]` |
| `M` | MOSFET | `M1 d g s b model [W= L= AD= AS= PD= PS= NF= m=]` |
| `J` | JFET | `J1 d g s model [area]` |
| `Z` | MESFET, MESA, HFET | `Z1 d g s model [area]` |
| `X` | subcircuit instance | `X1 n1 n2 ... subname [param=value ...]` |
| `N` | Verilog-A module instance | `N1 n1 n2 ... module [param=value ...]` (see [Verilog-A](devices.md#your-own-verilog-a)) |

### Sources

Waveforms for `V` and `I` cards, in `.tran` (and as the drive in `.pss`,
`.hb` and the other periodic analyses):

| Waveform | Arguments |
|---|---|
| `PULSE(v1 v2 [td tr tf pw per [np]])` | `tr`, `tf` default to the `.tran` step and `pw`, `per` to its stop time, also when given as 0; `np` pulses, then `v1` |
| `SIN(vo va [freq td theta phase])` | `theta` is the damping factor in 1/s; phase in degrees; `freq` omitted or 0 is 1/stop time |
| `EXP(v1 v2 [td1 tau1 td2 tau2])` | omitted or 0: `td1`, `tau1`, `tau2` are the `.tran` step, `td2` is `td1` plus the step |
| `PWL(t1 v1 t2 v2 ...) [r=t] [td=t]` | any number of points; `r=` repeats from time `t` (64 points at most with `r=`) |
| `SFFM(vo va [fm mdi fc td phasem phasec])` | ngspice order |
| `AM(vo vmo [vma fm fc td phasem phasec])` | ngspice order; 0 up to and at `td`, `vo` included |
| `PAT(vhi vlo td tr tf tsample data)` | HSPICE bit patterns (`b0101`, `[...]` groups, `R=`/`RB=` repeats), rewritten to PWL |

`DISTOF1 mag [phase]` and `DISTOF2 mag [phase]` on a V card mark the
`.disto` drive tones. `portnum n z0 Z` makes the source an S-parameter
port for `.sp`, `.lin` and `.hblin`. As in ngspice, the port's z0 (default
50 ohm) sits in series with the source in every analysis, and adds no
noise: `V1 a 0 dc 1 portnum 1 z0 50` into 50 ohm gives v(a) = 0.5 V. The
node between z0 and the ideal source publishes as `v(v1#res)`, as in
ngspice, and z0 has no `.noise` or `.sens` row of its own.

### Controlled sources

The linear forms are in the table above. E and G (and where noted F and H)
also take these forms, named by the word in the first control-node slot:

| Form | Example |
|---|---|
| `VALUE={expr}`, also `VOL=` on E and `CUR=` on G; E and G only | `E1 out 0 VALUE={v(a)*v(b)}` |
| `POLY(n) c1+ c1- ... p0 p1 ...` (F, H: `POLY(n) V1 ... p0 p1 ...`) | `E1 out 0 POLY(2) a 0 b 0 0 1 1` |
| `TABLE {expr} = (x1,y1) (x2,y2) ...`, E and G only: corners smoothed over a tenth of the shorter segment, the ends held; one pair is its y | `G1 out 0 TABLE {v(in)} = (0,0) (1,1m)` |
| `LAPLACE c+ c- num... / den...` | `E1 out 0 LAPLACE in 0 1 / 1 1e-3` |
| `POLE c+ c- a az1,fz1 ... / b ap1,fp1 ...` | poles and zeros, roots s = −α + j2πf |
| `DELAY c+ c- TD=t` | `E1 out 0 DELAY in 0 TD=1n` |
| `VCVS`, `VCCS`, `CCVS`, `CCCS` | the type word repeats the letter and is dropped from a whole linear card (`E1 o 0 VCVS a 0 2`) |

A VALUE takes the modifiers `M=`, which multiplies, and `TC1=` and `TC2=`,
temperature coefficients. HSPICE's `SCALE=`, `MAX=`, `MIN=`, `ABS=` and
`IC=`, and any modifier after POLY or TABLE, are refused: plain ngspice
stops on them, or drops one after TABLE. A VALUE whose text starts with a
number (`VALUE=2*v(a)+{k}`) is refused too: ngspice reads it from its first
brace on (k here), or stops when it has none; brace the whole expression.
`FREQ`, `OPAMP`, `PWL`, `NPWL`, `PPWL`, `VCR`, `VCCAP`, `AND`, `NAND`, `OR`,
`NOR` and `TRANSFORMER` are refused: plain ngspice stops on `PWL(1)` and
`VCR PWL(1)`, and runs an E card's `AND(n)`, `NAND(n)`, `OR(n)` and
`NOR(n)` as XSPICE's `multi_input_pwl`, which ESPice does not port.
A form word followed by a linear card's tail is a node name, as in ngspice:
`E1 o 0 vcr 0 2` is 2·v(vcr), and so are `poly`, `laplace`, `pole` and
`delay` there. `value` and `table` are keywords wherever they stand, so do
not name a control node either of them.

Numbers after a linear card's gain are SPICE 2G6's implicit `POLY(1)`
coefficients, as in ngspice: `E1 o 0 a 0 2 3` is 2 + 3·v(a), and
`F1 0 o V1 1m 2` is 1m + 2·i(V1). A number after `M=`, or after the gain
when the first control's name starts with `poly`, `value`, `vol`, `table`,
`laplace`, `cur`, `vccs`, `vcvs`, `ccvs` or `cccs`, is refused, as ngspice
stops on it.

`B` sources: `V=` and `I=` give a voltage or current; any other output,
`Q=` among them, is refused, as ngspice refuses it (a charge is a `C`
card's `q={expr}`). The expression can read `v(n)`, `v(a,b)`,
`i(Vsource)`, `time`, `temper` and parameters. Instance parameters may
follow the braced expression (`tc1=`, `reciproctc=1`, ...).

### Semiconductors and models

`.model name type(params)`: the type and `LEVEL=` select the device. The
[devices page](devices.md) has every type, LEVEL and model. Model bins
(`.model nch.1 ...`, `.model nch.2 ...` with `LMIN LMAX WMIN WMAX`) are
selected by the instance's L and W; `.option scale=` scales them.

## Dot cards

### Structure and parameters

| Card | Syntax | Notes |
|---|---|---|
| `.end` | `.end` | skipped, and the cards after it are read, as in ngspice |
| `.subckt` / `.ends` | `.subckt name ports... [p=v ...]` ... `.ends [name]` | nested up to 32 levels |
| `.param` | `.param name=value [name=value ...]` | global at top level, per instance inside a subcircuit; also `.parameter`, `.parameters`, which ngspice 44.2 reads too |
| `.func` | `.func name(a, b) {expr}`, or `.param name(a, b)=expr` | a user function, expanded where it is called |
| `.macro` / `.eom` | as `.subckt` / `.ends` | as in ngspice 44.2 |
| `.model` | `.model name type [(]params[)]` | |
| `.global` | `.global n1 n2 ...` | nets shared through every subcircuit level |
| `.connect` | `.connect a b` | joins two top-level nets |
| `.if` `.elseif` `.else` `.endif` | `.if (expr)` ... `.endif` | keeps the first branch whose condition is nonzero |

### Files

| Card | Syntax | Notes |
|---|---|---|
| `.include`, `.inc` | `.include "file"` | pastes the file; `.va`, `.vams`, `.veriloga`, `.v` and `.sv` files load as HDL instead |
| `.lib` | `.lib "file" section` | pastes one section; inside a library, `.lib section` ... `.endl` defines it |
| `.endl` | `.endl [section]` | closes the open section |
| `.hdl` | `.hdl "model.va"` | compiles and loads a Verilog-A (or Verilog `.v`) module |
| `.verilog` | `.verilog "design.v"` | loads a digital Verilog design |
| `.load` | `.load [FILE=]f [RUN=]` | HSPICE: pastes a saved `.ic`/`.nodeset` file, `<deck>.ic0` by default and `x.ic0` for `FILE=x.ic`; skipped with a warning when missing |
| `.vec` | `.vec 'file'` | HSPICE digital vector file, rewritten to PWL sources and `.dout` checks |
| `.alter` | `.alter` ... | HSPICE: the cards after it modify the deck for one more run; blocks are cumulative |
| `.osdi_include`, `.pre_osdi` | | refused: OSDI is never loaded |

A relative path is looked for as ngspice looks: in the working directory,
then beside the file that names it. Then, an ESPice extension, beside the
top deck (with a warning). Includes nest up to 32 levels. HSPICE's
`.option search='dir'` is not read: SpiceRack resolves a translated deck's
includes itself.

### Options

`.option`, `.options`, `.opt` and `.opts` are the same card:
`.options name=value ...`.

| Option | Default | Meaning |
|---|---|---|
| `reltol` | 1e-3 | relative convergence tolerance |
| `abstol` | 1e-12 | absolute current tolerance, A |
| `vntol` | 1e-6 | absolute voltage tolerance, V |
| `chgtol` | 1e-14 | charge tolerance, C |
| `gmin` | 1e-12 | conductance added across junctions, S |
| `itl1`, `itl2`, `itl4` | 100, 50, 10 | Newton iteration limits: operating point, DC sweep point, transient step |
| `dv` | none | maximum Newton change of each node voltage per iteration, V, DC and transient (HSPICE `DV`; an iteration it clamps is not accepted). A solve with `dv` set runs on the CPU |
| `trtol` | 7 | transient truncation-error factor |
| `method` | `trap` | `trap` (`trapezoidal`) or `gear`; another name warns and keeps the default, as in ngspice 44.2 |
| `maxord` | 2 | integration order cap; `maxord=1` is backward Euler under `trap` or `gear`, and nothing runs above order 2 (as ngspice) |
| `xmu` | 0.5 | trapezoidal damping, 0 to 0.5 (0 is backward Euler) |
| `temp` | 27 | circuit temperature, °C |
| `tnom` | 27 | model reference temperature, °C |
| `delmax` | | transient step cap when `.tran` gives none |
| `gshunt`, `cshunt`, `rshunt` | | conductance, capacitance and (ngspice) resistance from every net to ground |
| `scale` | 1 | geometry scale for model binning |
| `wnflag` | 0 | bin selection by per-finger W |
| `seed` | 1 | Monte Carlo seed |
| `sampling_method` | | `lhs` for Latin hypercube sampling |
| `runlvl`, `accurate`, `fast` | | HSPICE accuracy presets: set `trtol` |
| `em_recovery` | 1 | recovery factor for `.meas EM_AVG` |
| `search` | | HSPICE: an include search directory |
| `soa` (`warn`) | 0 | 1 checks every device against its model-card SOA limits ([analyses](analyses.md#soa)) |
| `maxwarns` | 5 | most SOA excursion lines printed; every excursion is counted |
| `soalimits` | | `"file.json"`: SOA limits for the models whose cards state none ([analyses](analyses.md#soa)) |

`reltol` and `trtol` must be positive; a zero or negative value fails at its
card. `abstol`, `vntol` and `chgtol` may be 0, as in ngspice.

Other names are ignored, with one warning each.

### Initial conditions

| Card | Syntax | Notes |
|---|---|---|
| `.ic` | `.ic v(n1)=v1 v(n2)=v2 ...` | the start state of a `.tran ... uic` |
| `.nodeset` | `.nodeset v(n)=v ...` | a starting guess for the operating point's first Newton solve |
| `.temp` | `.temp t` | the circuit temperature; the last `.temp` wins over every `.options temp=`. More than one value: a warning, and the circuit runs at 27 °C, as in ngspice 44.2. A sweep is `.dc temp` ([analyses](analyses.md#temp)) |

### Output

| Card | Syntax | Notes |
|---|---|---|
| `.save` | `.save v(out) i(v1) ...` | write only these vectors. With a `TYPE=NODESET\|IC`, `FILE=`, `LEVEL=ALL\|TOP\|SELECT\|NONE` or `TIME=` key, ESPice's: writes the operating point as a loadable file |
| `.print`, `.plot`, `.probe`, `.graph`, `.width`, `.title` | | accepted and ignored: every vector is written |
| `.protect`, `.unprotect`, `.prot`, `.unprot` | | accepted and ignored |
| `.store` | | HSPICE checkpointing: a warning, nothing written |
| `.stim` | `.stim [tran] pwl\|data ...` | HSPICE: writes transient signals as PWL sources or a `.data` table |

### `.meas`

`.meas` and `.measure` are the same card. [Chapter 7](../learn/measure.md)
teaches them.

```text
.meas tran|ac|dc|sp|fft|trannoise|dcmatch|acmatch|lstb|phasenoise|ptdnoise name FUNCTION ...
.meas tran_cont|ac_cont|dc_cont name ...
```

| Function | Form |
|---|---|
| `TRIG` ... `TARG` (also `DELAY`) | `TRIG sig VAL= RISE\|FALL\|CROSS= [TD=] TARG sig VAL= ...` |
| `FIND`, `WHEN` | `FIND sig AT=x`, `FIND sig WHEN sig2=v`, `WHEN sig=v`; `AT=` may name an earlier result |
| `AVG`, `RMS`, `INTEG` (`INTEGRAL`), `MIN`, `MAX`, `PP`, `MIN_AT`, `MAX_AT` | `func sig [FROM= TO=]` |
| `DERIV` (`DERIVATIVE`) | `DERIV sig AT=x` or `WHEN ...` |
| `PARAM` | `PARAM='expr'` over earlier results and parameters; `soa_count()` is the result's SOA excursion count ([analyses](analyses.md#soa)) |
| `ERR`, `ERR1`, `ERR2`, `ERR3` | HSPICE error between two signals |
| `THD`, `SNR`, `SNDR`, `ENOB`, `SFDR` | on an `.fft` plot, with `NBHARM= MINFREQ= MAXFREQ= BINSIZ=` |
| `EM_AVG` | electromigration average current |
| `JITTER` | time interval error of a clock's edges (RMS, peak-to-peak, period): `.jitter tran TRIG v(clk) VAL= [TD=] [RISE\|FALL\|CROSS=]` |

Common keywords: `RISE=`, `FALL=`, `CROSS=` (a count, or `LAST`), `TD=`,
`FROM=`, `TO=`, `AT=`, `VAL=`, `GOAL=`, `WEIGHT=`, `MINVAL=`. Signals:
`v(n)`, `v(a,b)`, `i(Vsource)`, `par('expr')`, and in AC `vdb`, `vm`, `vp`,
`vr`, `vi`. HSPICE's `.check`, `.dout`, `.biaschk`, `.power` and `.jitter`
are read as measurements too:

| Card | Reports |
|---|---|
| `.check rise\|fall\|slew (min max) nodes` | edges whose duration is outside [min, max] |
| `.check setup\|hold (ref RISE\|FALL d RISE\|FALL) nodes` | setup and hold violations |
| `.check edge (ref RISE\|FALL min max RISE\|FALL) nodes` | missing edges |
| `.check irdrop (v d) nodes` | stretches beyond `v` longer than `d` |
| `.check global_level (hi lo hi_th lo_th)` | the default logic thresholds |
| `.dout nd [VTH \| VLO VHI] (t s ...)` | states a node fails to hold |
| `.biaschk 'expr' [max= min= tstart= tstop=]` | stretches of an expression outside its limits |
| `.power signal [FROM= TO=]` | average, RMS, max and min power |

### Sweeps and statistics { #statistics }

| Card | Syntax | Notes |
|---|---|---|
| `.step` | `.step [lin\|dec\|oct] [param] name start stop step`, or `... list v1 v2 ...` | reruns every analysis per point; `name` is a parameter, `temp` or a source/element |
| `.data` / `.enddata` | `.data name p1 p2 ... v11 v12 ... .enddata` | HSPICE table for `SWEEP DATA=name` (also `MER`/`LAM` file forms) |
| `.variation` / `.end_variation` | `.variation .local_variation .element_variation r r=5 % ...` | HSPICE variation block for Monte Carlo and mismatch; a sigma may be `'expr'` over `.param`s and the device's `w`, `l`, `m` |
| `.mc` | `.mc N [sigma]` | see [analyses](analyses.md#mc) |

On any analysis card, HSPICE's `SWEEP` tail runs the card once per point:
`SWEEP DATA=name`, `SWEEP MONTE=n [FIRSTRUN=k]`, `SWEEP MONTE=list(10 20:30)`,
`SWEEP OPTIMIZE=name RESULTS=m1,m2 MODEL=optmod`. On `.dc`, `DATA=` and
`MONTE=` work without the word `SWEEP`. ESPice adds
`SWEEP MONTE=n SIGMA_SCALE=s1,s2,... FAIL='expr'` on `.tran`, `.ac` and a
`.dc` with a sweep: scaled-sigma sampling of a rare failure, see
[analyses](analyses.md#scaled-sigma). `.wcd m1 '>= L1' m2 '<= L2' ...
[MAXITER=20] [TOL=0.01] [TOP=5]` finds each spec's worst-case distance
over the same statistical parameters, see [analyses](analyses.md#wcd).

The `OPT` model takes HSPICE's optimizer options with HSPICE's defaults.
`PARMIN` (default 0.1) floors the parameter scale, so the finite-difference
step is `DIFSIZ * max(|p|, PARMIN)`: a width or current in SI units (4 µm,
10 µA) then steps by 100 µm on the first try and stalls. Size such
parameters with `parmin=1e-7` or so, or give each its own step as the fourth
argument of `opt1(init, lo, hi, dels)`. A start point that cannot be
simulated or measured, or a later trial point that cannot, stops the run
with `optimization failed`.

A fifth argument, `opt1(init, lo, hi, dels, grid)`, is an ESPice extension
(HSPICE stops at `dels`): every value the optimizer simulates for that
parameter is a multiple of `grid` inside `[lo, hi]` (the limits round
inward), as for a W or L on a manufacturing grid. Each parameter has its
own grid, and one without stays continuous. Levenberg-Marquardt steps at
least one grid step for its derivatives, rounds each trial onto the grid,
stops once a step rounds back to where it is, then tries one grid step
either way per parameter. BISECTION and PASSFAIL halve the window in grid
steps and stop at a one-step window. The summary prints each grid.

Statistical functions in expressions: `agauss(nom, abs, sigmas)`,
`gauss(nom, rel, sigmas)`, `aunif(nom, abs)`, `unif(nom, rel)`,
`limit(nom, var)`. They return `nom` unless a Monte Carlo sweep or
`.option seed` is active, so a run is deterministic. ngspice 44.2 differs
there: it draws once for a call on constants, where ESPice keeps `nom`, and
reads 0 for a call on a probe, which a B, E or G expression here refuses. On a `.model` value,
`LOT/GAUSS=x%` and `DEV/GAUSS=y%` draw once per model and once per device.

### Reliability and noise sampling (HSPICE)

| Card | Syntax |
|---|---|
| `.mosra` | `.mosra RelTotalTime= [RelStartTime= RelStep= SimMode=0\|2 RelMode= AgingStart= AgingStop= HciThreshold= NbtiThreshold= DegF=]` |
| `.appendmodel` | `.appendmodel src MOSRA dst NMOS\|PMOS` |
| `.sample` | `.sample FS= [TOL= NUMF= MAXFLD= BETA=]`: noise folding for sampled `.noise` spectra |

### ngspice control blocks

`.control` ... `.endc` is skipped with a warning: ESPice runs the analysis
cards in the deck, not ngspice scripts. A `pre_osdi` line inside the block
is still an error.

## Analysis cards

Each has a section in [Analyses](analyses.md):

`.op` `.dc` `.ac` `.tran` `.noise` `.tf` `.sens` `.pz` `.disto` `.four`
`.fft` `.sp` (`.lin`, `.net`) `.stb` `.lstb` `.pss` (`.sn`, `.snosc`)
`.pac` (`.snac`) `.pnoise` (`.snnoise`, `.ptdnoise`) `.pxf` (`.snxf`) `.hb`
(`.hbosc`) `.hbac` `.hbxf` `.hbnoise` `.hblin` `.phasenoise` `.qpss`
`.envelope` `.matex` `.trannoise` `.mc`
`.dcmatch` `.acmatch` `.dcsens` `.dcxf` `.acxf`
`.dcinc` `.acphasenoise`
