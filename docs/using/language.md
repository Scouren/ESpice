# The ESPice netlist language

ESPice's own netlist format, version 1. It keeps SPICE's vocabulary
(`.tran`, `.meas`, `.param`, `.model`, `pulse`, `v(out)`) and gives it one
regular grammar: every argument has a name and a type, a device's kind
comes from the model it names, and nothing is read by position unless this
page says so.

```espice
.espice 1
.title "Inverter delay across process"

.lib "pdk.lib" tt                     // a legacy library, read as before
.option reltol=1e-4 temp=27C

.param vdd = 1.8V
.param wn  = agauss(420nm, 5nm, 3)

.subckt inv (in out vdd vss) wn=420nm wp=1um {
    Mn (d=out g=in s=vss b=vss) nch w=wn l=150nm
    Mp (d=out g=in s=vdd b=vdd) pch w=wp l=150nm
}

Vdd (vdd 0)        vsource   dc=vdd
Vin (in 0)         vsource   pulse(0, vdd, td=1ns, tr=20ps, tf=20ps, pw=2ns, per=4ns)
X1  (in out vdd 0) inv       wn=wn
Cl  (out 0)        capacitor 5fF

.tran stop=8ns step=10ps sweep monte(200)

.meas tran tphl = cross(v(out), vdd/2, fall=1) - cross(v(in), vdd/2, rise=1)
.meas tran ipk  = max(i(Vdd), from=1ns)
.probe v(out) i(Vdd)
```

A file is in this language when its first line is `.espice 1`. Every other
file is read as the [legacy dialect](reference.md) (ngspice's), exactly as
before. The two mix freely: a deck in either one may `.include` or `.lib` a
file in the other, and subcircuits, models and parameters defined in one
are used by name from the other. A PDK library needs no change.

Each construct below gives its legacy card under **Legacy**. That card is
what the statement means: ESPice reads a file in this language by writing
it as legacy cards, so the two spellings always simulate to the same
result.

## Files and statements { #files }

```text
file       = ".espice" version  statement...
statement  = instance | directive
instance   = name "(" ports ")" master [value] setting... [ "{" setting... "}" ]
directive  = "." word subject... setting... [ "sweep" sweep ] [ block ]
setting    = key "=" value | flag
```

- **Header.** Line 1 is `.espice 1`. A version this build does not read is
  refused. There is no title line and no `.end`: the file ends where it
  ends. `.title "text"` names the deck.
- **Lines.** A statement ends at the end of its line. It continues over
  lines inside `( )` and `[ ]`, and its settings may move into a trailing
  `{ }`, where line breaks are free. There is no `+` line.
- **Comments.** `//` to the end of the line.
- **Blocks.** `.subckt`, `.lib`, `.if`, `.elseif`, `.else`, `.alter`,
  `.variation` and `.data` own a block of statements between `{`, which closes their
  line, and `}`, on a line of its own.
- **Case.** Names of nodes, instances, models, subcircuits and parameters
  ignore case, as they do in the legacy dialect. Directives, masters,
  functions, keys and enum values are written in lower case. Prefixes and
  units of numbers are case-sensitive.

```espice
.model nch bsim4 type=n {
    vth0 = 0.45
    tox  = 4n
}
X1 (in out
    vdd 0) inv wn=1um
```

### Names { #names }

A name is a letter or `_` followed by letters, digits, `_`, `.`, `$`, `#`
and `!`. A node may also be a number (`0`, `12`). `0`, `gnd` and `ground`
are ground. Any other spelling is written in double quotes where a name is
expected: `"net<3>"`. A quoted name may not hold a blank, `(`, `)`, `,`,
`=`, a quote or a brace, and may not be empty.

An instance name is free: `load`, `M1` and `Rbias` are all fine, and the
first letter means nothing. Two instances of one block may not share a
name.

### Numbers and units { #numbers }

```text
number = digits [ "." digits ] [ ("e"|"E") ["+"|"-"] digits ] [ prefix ] [ unit ]
```

| Prefix | `a` | `f` | `p` | `n` | `u` | `m` | `k` | `M` | `G` | `T` |
|---|---|---|---|---|---|---|---|---|---|---|
| Factor | 1e-18 | 1e-15 | 1e-12 | 1e-9 | 1e-6 | 1e-3 | 1e3 | 1e6 | 1e9 | 1e12 |

| Unit | `V` | `A` | `s` | `Hz` | `Ohm` | `S` | `F` | `H` | `m` | `C` | `deg` | `%` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Quantity | voltage | current | time | frequency | resistance | conductance | capacitance | inductance | length | temperature, °C | angle | ratio, ×0.01 |

`1.8V`, `10ns`, `5fF`, `1MHz`, `2.2kOhm`, `150nm`, `27C`, `90deg`, `5%`.
A lone letter that is a prefix is the prefix: `1m` is 1e-3, `1mm` is a
millimetre.

Three rules keep a SPICE habit from turning into a wrong number:

- `M` is mega and `m` is milli. A bare `M` with no unit is refused: write
  `1MHz`, `1MOhm` or `1e6`.
- `meg`, `mil`, `x` and an upper-case `K`, `U`, `N`, `P` are refused, each
  with the spelling to use. So is a prefix before `%` (`5k%`).
- `1F` is one farad. It reads, with a warning that femto is `1f` or `1fF`.

A number's value is its mantissa times its prefix's factor, the product
the legacy suffix gives (`5fF` is `5f`, `1MHz` is `1meg`).

### Types { #types }

Every slot on this page has one of these types.

| Type | Written | Checked |
|---|---|---|
| quantity (`voltage`, `current`, `time`, `frequency`, `resistance`, `conductance`, `capacitance`, `inductance`, `length`, `temperature`, `angle`, `ratio`) | a number, with or without its unit, or an expression | a unit that is not the slot's is an error: `c=10pH`, `stop=1.8V` |
| `real`, `integer` | a number or an expression | a unit is an error (a `real` takes `%`); an integer slot also refuses a fraction |
| `flag` | the bare key: `uic` | |
| enum | one of the listed words: `method=gear` | any other word is an error |
| `string` | `"text"` | |
| `node` | a name or a number | |
| `probe` | `v(n)`, `v(a,b)`, `i(name)`; in `.ac` results also `vdb`, `vm`, `vp`, `vr`, `vi` | |
| reference | the name of an instance, model, subcircuit, parameter or measurement | resolved when the deck is built |
| `range` | `lin(...)`, `dec(...)`, `oct(...)` or a list ([Ranges](#ranges)) | |
| `wave` | `pulse(...)` and the others ([Waveforms](#waves)) | |
| list | `[a, b, c]` | each element by the slot's element type |
| pair | `(a, b)` | |

A parameter keeps the unit of the literal that defines it, so after
`.param vdd = 1.8V` the setting `stop=vdd` is an error in the same file.
The check is deliberately shallow: a number without a unit fits every
quantity, and so does anything computed (`vdd/2`, `2*l`). No expression is
ever refused for its units.

A unit on a parameter of a model, module or subcircuit instance (`w=1um`)
is read and not checked: those parameters carry no declared quantity.

## Expressions { #expressions }

A value is an expression. It may contain blanks; it ends where the next
token cannot continue it. Parentheses group, and carry an expression over
lines.

| | |
|---|---|
| Arithmetic | `+` `-` `*` `/` `%` (remainder), `**` (power) |
| Comparison | `==` `!=` `<` `<=` `>` `>=` |
| Logic | `&&` `\|\|` `!` and `cond ? a : b` |
| Functions | `sqrt exp ln log log10 abs floor ceil min max pow pwr sin cos tan atan tanh sinh cosh asin acos asinh acosh atanh sgn nint sqr int idiv` |
| Statistics | `agauss gauss aunif unif limit` ([Statistics](#statistics)) |
| In a behavioural source only | `v(n)`, `v(a,b)`, `i(name)`, `time`, `temper`, `hertz`, and `u uramp u2 eq0 ne0 gt0 lt0 ge0 le0 pwl ddt` |

One table serves `.param`, every value and every behavioural source:

- `x ** y` and `pow(x, y)` are the real power. A negative base with a
  fractional exponent has no real value: it fails the deck in a parameter
  and is not defined in a behavioural source.
- `pwr(x, y)` is sign(x)·|x|^y.
- `idiv(a, b)` is trunc(|a/b|), the legacy `\`: `idiv(-7, 2)` is 3.
  `int(x)` drops the fraction and `sqr(x)` is x·x.
- `log` is the natural logarithm, as `ln`; `log10` is base 10.

`^`, `<>`, `\`, `'...'`, `{...}` and `ternary_fcn` are not in the language:
use `**`, `!=`, `idiv`, parentheses and `?:`.

**Legacy.** The same expression in the form its place takes, `'...'` on a
card or `{...}` in a B source, with each function written so the legacy
reader gives the value above: `x**y` in a parameter is `pow(x,y)`, and in a
behavioural source `pow(x,y)` for an even whole exponent and `pwr(x,y)` for
an odd one.

## Instances { #instances }

```text
name (ports) master [value] setting...
```

`ports` are node names in the master's port order, or `port=node` pairs in
any order; one list does not mix the two, and blanks separate them, not
commas. `master` is a [primitive](#primitives), a `.model`, a `.subckt` or
a Verilog-A module; a module's instance takes its ports by position, as
its ports are known only once `.hdl` has compiled it. `value`, a
primitive's principal parameter (its table
marks it), is for primitives only: any other master takes `key=value`
settings and flags.

```espice
R1  (in out)                resistor 1k
M1  (d=out g=in s=0 b=0)    nch w=1um l=180nm
X1  (in out vdd 0)          inv wn=2um
D1  (a k)                   dmod area=2
N1  (d g s b)               psp103va w=1um
Q1  (c b e)                 q1 area=2
J1  (d g s)                 jm
Z1  (d g s)                 zm area=2
S1  (p n cp cn)             sw1 initial=on
W1  (p n)                   cs1 probe=Vsense initial=off
O1  (a1=a b1=0 a2=b b2=0)   lt
Y1  (a 0 b 0)               tx
P1  (i1 i2 0 o1 o2 0)       cp
U1  (n1=a n2=b n3=0)        rc l=1mm
```

A primitive's name is reserved. A model or subcircuit of a legacy file that
shares one is named in quotes: `X1 (a b) "resistor"`.

The ports of a modelled device, by the kind of its model:

| Model kind | Ports |
|---|---|
| MOSFET | `d g s b` |
| VDMOS | `d g s`, then `tj tc` when given |
| BJT | `c b e`, then `s` when given |
| diode | `a k`, then `tj` when given |
| JFET, MESFET, HFET | `d g s` |
| voltage-controlled switch | `p n cp cn` |
| current-controlled switch | `p n`, with `probe=` naming the sensing source |
| resistor, capacitor, inductor | `p n` |
| LTRA, TXL line | `a1 b1 a2 b2` |
| URC line | `n1 n2 n3` |
| subcircuit | the names it declares |
| CPL lines, a Verilog-A module, and every family whose legacy type is a module's name (`psp104`, `hicuml0`, `diode_cmc`, ...) | positional only |

Settings of a modelled device are its instance parameters (`w=`, `l=`,
`area=`, `m=`, ...). A switch also takes `initial=on|off`, and any device
that has one, the flag `off`.

**Legacy.** The device card of the model's kind, with the same name:
`M1 d g s b nch w=1u l=180n`, `X1 in out vdd 0 inv wn=2u`,
`W1 p n Vsense swmod OFF`.

### Primitives { #primitives }

The masters that need no model. The principal parameter is in bold.

| Master | Ports | Settings | Legacy |
|---|---|---|---|
| `resistor` | `p n` | **`r`** resistance; `tc1` `tc2` `m` and the device's other parameters | `R1 p n r tc1=...` |
| `capacitor` | `p n` | **`c`** capacitance; `ic` voltage; `m`; or `q=` an expression for the charge | `C1 p n c ic=...` |
| `inductor` | `p n` | **`l`** inductance; `ic` current; `m` | `L1 p n l ic=...` |
| `mutual` | none | **`k`** coupling; `inductors=[L1, L2]` | `K1 L1 L2 k` |
| `vsource` | `p n` | **a voltage or a wave**; `dc` `ac` `acphase` `port` `z0` `distof1` `distof2` ([Sources](#sources)) | `V1 p n DC ... AC ...` |
| `isource` | `p n` | **a current or a wave**; `dc` `ac` `acphase` `m` `distof1` `distof2` | `I1 p n DC ... AC ...` |
| `vcvs` | `p n cp cn` | **`gain`** | `E1 p n cp cn gain` |
| `vccs` | `p n cp cn` | **`gm`** conductance; `m` | `G1 p n cp cn gm` |
| `cccs` | `p n` | **`gain`**; `probe=` a voltage source | `F1 p n Vsense gain` |
| `ccvs` | `p n` | **`r`** resistance; `probe=` a voltage source | `H1 p n Vsense r` |
| `bsource` | `p n` | `v=` or `i=` an expression ([Behavioural sources](#behavioural)) | `B1 p n V={...}` |
| `tline` | `a1 b1 a2 b2` | `z0` resistance; `td` time, or `f` frequency with `nl` | `T1 a1 b1 a2 b2 Z0= TD=` |
| `sparam` | 1 to 4 ports and a reference | `mname=` or the data keys of the S element | `S1 ... mname=` |
| `wline` | the W element's nodes | `n=` `l=` `rlgcmodel=` and its other keys | `W1 ... N= L= RLGCMODEL=` |

```espice
R1  (a b)        resistor  1k tc1=1e-3
C1  (a 0)        capacitor 1pF ic=0.9V
K1  ()           mutual    0.99 inductors=[L1, L2]
E1  (out 0 a b)  vcvs      2
F1  (out 0)      cccs      5 probe=Vsense
T1  (a 0 b 0)    tline     z0=50Ohm td=1ns
L1  (a b)        inductor  1nH ic=1mA
G1  (out 0 a b)  vccs      1mS
H1  (out 0)      ccvs      1kOhm probe=Vsense
```

### Sources { #sources }

```text
name (p n) vsource [dc-value | wave] [dc=] [ac=] [acphase=] [port= z0=] [distof1=] [distof2=]
```

| Key | Type | Meaning |
|---|---|---|
| `dc` | voltage (current on an `isource`) | the operating-point value; the bare value is the same |
| `ac` | voltage or current | small-signal magnitude |
| `acphase` | angle | small-signal phase, default 0 |
| `port` | integer | makes the source S-parameter port `n` for `.sp`, `.lin`, `.hblin` |
| `z0` | resistance | the port's reference impedance, default 50 Ω |
| `distof1`, `distof2` | real, or the pair `(mag, phase)` | marks a `.disto` drive tone |

`acphase` needs `ac` and `z0` needs `port`; an `isource` takes neither
`port` nor `z0`.

```espice
Vdd (vdd 0) vsource 1.8V
Vin (in 0)  vsource dc=0 ac=1 pulse(0, 1.8V, td=1ns, tr=20ps, tf=20ps, pw=2ns, per=4ns)
Vp  (a 0)   vsource dc=1 port=1 z0=50Ohm
Ib  (0 n1)  isource 10uA
```

**Legacy.** `Vin in 0 DC 0 AC 1 PULSE(0 1.8 1n 20p 20p 2n 4n)`;
`Vp a 0 DC 1 portnum 1 z0 50`.

### Waveforms { #waves }

A wave's first arguments are positional values (volts on a `vsource`,
amperes on an `isource`); the rest are keyed, and one left out takes the
default shown, else 0. A keyed time is a `time`, a frequency a
`frequency` and a phase an `angle` in degrees.

| Wave | Arguments | Legacy |
|---|---|---|
| `pulse(v1, v2, td=, tr=, tf=, pw=, per=, phase=)` | `tr`, `tf` default to the `.tran` step, `pw` and `per` to its stop time, also when 0; `phase` starts the train that far into its period | `PULSE(v1 v2 td tr tf pw per phase)` |
| `sin(vo, va, freq=, td=, theta=, phase=)` | `theta` is the damping in 1/s, a `real`; `freq` omitted or 0 is 1/stop time | `SIN(vo va freq td theta phase)` |
| `exp(v1, v2, td1=, tau1=, td2=, tau2=)` | omitted or 0, `td1`, `tau1` and `tau2` are the `.tran` step and `td2` is `td1` plus the step | `EXP(v1 v2 td1 tau1 td2 tau2)` |
| `pwl((t1, v1), (t2, v2), ..., r=, td=)` | `r=` repeats from that time; `td=` delays the whole table | `PWL(t1 v1 t2 v2 ...) r= td=` |
| `sffm(vo, va, fm=, mdi=, fc=, td=, phasem=, phasec=)` | `fm` modulates `fc`, the carrier, with index `mdi`, a `real`; `fm` defaults to 5/stop time but must be given when a later key is, `mdi` to 90, `fc` (also when 0) to 500/stop time | `SFFM(vo va fm mdi fc td phasem phasec)` |
| `am(va, vo, fm=, fc=, td=, phasec=, phasem=, off=)` | `off` + `va`·(`vo` + sin(2π`fm`t + `phasem`))·sin(2π`fc`t + `phasec`) after `td`, 0 up to it: `va` the amplitude, `vo` the envelope's offset (a `real`), `off` the output's offset (a value, as `va`) | `AM(va vo fm fc td phasec phasem off)` |
| `pat(vhi, vlo, td=, tr=, tf=, tsample=, data=)` | every key is required; `data` is the pattern, a string | `PAT(vhi vlo td tr tf tsample data)` |

```espice
V1 (a 0) vsource sin(0, 1V, freq=1kHz)
V2 (b 0) vsource pwl((0, 0), (1ns, 1.8V), (2ns, 0), r=0)
V3 (c 0) vsource pat(1.8V, 0, td=0, tr=50ps, tf=50ps, tsample=1ns, data="b0101")
V4 (d 0) vsource pulse(0, 1V, tr=10ps, tf=10ps, pw=1ns, per=2ns, phase=90deg)
V5 (e 0) vsource am(1V, 0.5, fm=1kHz, fc=1MHz, off=0.1V)
```

### Behavioural sources { #behavioural }

```espice
B1 (out 0) bsource v=v(a)*v(b)
B2 (out 0) bsource i=v(ctl) > 0.5 ? 1mA : 0
B3 (out 0) bsource v=laplace(v(in), num=[1], den=[1, 1ms])
```

`v=` makes a voltage, `i=` a current. The expression reads the circuit
through `v(n)`, `v(a,b)`, `i(source)`, `time`, `temper` and `hertz`.
Instance parameters may follow (`tc1=`, `tc2=`, `m=`).

These forms stand alone as the whole value:

| Form | Meaning | Legacy |
|---|---|---|
| `laplace(v(a,b), num=[...], den=[...])` | a transfer function, coefficients in rising powers of s | `E1 p n LAPLACE a b num / den` |
| `pole(v(a,b), gain, zeros=[(alpha, f), ...], poles=[...])` | poles and zeros, roots s = −α + j2πf | `E1 p n POLE a b ...` |
| `table(expr, (x1, y1), (x2, y2), ...)` | a piecewise-linear table of an expression | `E1 p n TABLE {expr} = (x1,y1) ...` |
| `delay(v(a,b), td=)` | a delayed copy | `E1 p n DELAY a b TD=` |
| `poly([v(a), v(c,d)], coeffs=[p0, p1, ...])` | SPICE's polynomial of its controls; the controls are all voltages or all currents `i(V1)` | `E1 p n POLY(n) ...` |

With `v=` they are the E card (H for current controls), with `i=` the G
card (F).

A `resistor`, `capacitor` or `inductor` whose value reads the circuit is
behavioural too: `R1 (a b) resistor 1k*(1 + v(ctl))`.

## Models { #models }

```text
.model name family [type=] setting...
```

`family` names the device model; `type` its polarity where it has one
(`n` or `p`; `npn` or `pnp`), and a family with a polarity requires it.
The settings are the model's parameters. `level=` is refused: the family
names it.

```espice
.model dmod diode is=1e-14 n=1.05
.model nch  bsim4 type=n vth0=0.45 tox=4n
.model q1   gummel_poon type=npn bf=120
.model sw1  vswitch vt=0.5 vh=0.1 ron=1 roff=1G
.model pn   psp104 type=p
.model hb   hicuml0 type=pnp
.model jm   jfet type=n
.model zm   mesfet type=n
.model cs1  cswitch it=1mA ih=0.1mA ron=1 roff=1G
.model lt   ltra r=0.1 l=1n g=0 c=1p len=1
.model tx   txl r=0.1 l=1n g=0 c=1p length=1
.model cp   cpl length=1
.model rc   urc k=1.2 fmax=1G rperl=1k cperl=1p
```

Every built-in model of [Devices](devices.md) has a family. Where the
legacy type is a Verilog-A module's name, the polarity is that module's
own `TYPE`, written `type=1` for `n` and `npn`, `type=-1` for `p` and
`pnp`.

| Family | Polarity | Legacy `.model` type |
|---|---|---|
| `mos1` `mos2` `mos3` `mos6` `mos9` | `n` `p` | `NMOS`/`PMOS` `LEVEL=1`, `2`, `3`, `6`, `9` |
| `bsim1` `bsim2` `bsim3` `bsim4` | `n` `p` | `LEVEL=4`, `5`, `8`, `14` |
| `bsimsoi` `b3soifd` `b3soidd` | `n` `p` | `LEVEL=10`, `55`, `56` |
| `hisim2` `hisimhv` | `n` `p` | `LEVEL=68`, `73` |
| `bsimcmg` `bsimbulk` `bsimimg` `l_utsoi` | `n` `p` | `LEVEL=72`, `77`, `78`, `76` |
| `psp103` | `n` `p` | `LEVEL=1040` |
| `psp103_nqs` `psp103_t` | `n` `p` | `pspnqs103va`, `psp103tva` and `TYPE` |
| `psp104` `psp104_nqs` `psp104_t` | `n` `p` | `psp104va`, `pspnqs104va`, `psp104tva` and `TYPE` |
| `hisimsoi` `hisimsotb` | `n` `p` | `hisimsoi_va`, `hisimsotb_va` and `TYPE` |
| `mosvar` | | `mosvar`; its `type` and `typep` are doping, numbers |
| `vdmos` | `n` `p` | `VDMOS`, `VDMOSP` |
| `asmhemt` | | `asmhemt` |
| `mvsg` | `n` `p` | `mvsg_cmc` and `type` |
| `gummel_poon` `vbic` `hicuml2` `mextram` | `npn` `pnp` | `NPN`/`PNP` `LEVEL=1`, `4`, `8`, `6` |
| `mextram_t` `hicuml0` | `npn` `pnp` | `bjt505t`, `hicuml0va` and `type` |
| `asmesd` | `npn` `pnp` | `asmesd` and `type` |
| `diode` | | `D` `LEVEL=1` |
| `juncap200` | `n` `p` | `D` `LEVEL=6` and `TYPE` |
| `diode_cmc` `asmesd_dio` | | `diode_cmc`, `asmesd_dio` |
| `r2_cmc` `r3_cmc` | | `r2_cmc`, `r3_cmc`; R3_CMC's `type` is its body doping, a number |
| `jfet` `jfet2` | `n` `p` | `NJF`/`PJF` `LEVEL=1`, `2` |
| `mesfet` `mesa` `hfet1` `hfet2` | `n` `p` | `NMF`/`PMF` `LEVEL=1`, `2`, `5`, `6` |
| `vswitch` `cswitch` | | `SW`, `CSW` |
| `ltra` `txl` `cpl` `urc` | | `LTRA`, `TXL`, `CPL`, `URC` |
| `resistor` `capacitor` `inductor` | | `R`, `C`, `L` |
| `opt` | | `OPT`, the optimizer's settings |
| `mosra` | | `MOSRA` `LEVEL=1`, the aging model of [Reliability](#reliability) |
| a Verilog-A module | | the module's name |

Model bins are models named `base.1`, `base.2`, ... with `lmin`, `lmax`,
`wmin`, `wmax`; an instance names `base` and its `l` and `w` pick the bin.

A model value takes a tolerance for Monte Carlo with `tol`:

```espice
.model rmod resistor r=tol(1k, lot=gauss(5%), dev=unif(2%))
```

`lot` draws once per model and `dev` once per device; the distribution is
`gauss(x)`, `unif(x)` or `limit(x)`, `x` a number, relative with `%` and
absolute without. **Legacy.** `r=1k LOT/GAUSS=5% DEV/UNIF=2%`.

## Subcircuits { #subckt }

```espice
.subckt inv (in out vdd vss) wn=420nm wp=1um {
    Mn (out in vss vss) nch w=wn l=150nm
    Mp (out in vdd vdd) pch w=wp l=150nm
}
X1 (in=a out=b vdd=vdd vss=0) inv wp=2um
```

The settings after the ports are the subcircuit's parameters and their
defaults. Subcircuits nest 32 levels. **Legacy.** `.subckt inv in out vdd
vss wn=420n wp=1u` ... `.ends`.

## Parameters and functions { #param }

```espice
.param vdd = 1.8V  tr = 20ps
.param half = vdd/2
.func  par(a, b) = a*b/(a + b)
```

A parameter is global at the top level and local inside a subcircuit. A
function is expanded where it is called; one `.func` defines one.
**Legacy.** `.param vdd=1.8
tr=20p`, `.func par(a, b) {a*b/(a + b)}`.

## Structure { #structure }

| Statement | Meaning | Legacy |
|---|---|---|
| `.title "text"` | the deck's title, once, in the top file | the title line |
| `.global n1 n2 ...` | nets shared through every subcircuit level | `.global` |
| `.connect a b` | joins two top-level nets | `.connect` |
| `.if cond { ... }` then `.elseif cond { ... }` and `.else { ... }` | keeps the first block whose condition is nonzero | `.if` ... `.endif` |

```espice
.param corner = 1
.if corner == 1 {
    R1 (a b) resistor 1k
}
.elseif corner == 2 {
    R1 (a b) resistor 1.5k
}
.else {
    R1 (a b) resistor 2k
}
.global vdd vss
.connect a b
```

## Files { #include }

| Statement | Meaning | Legacy |
|---|---|---|
| `.include "file"` | reads a netlist file in place, in its own dialect | `.include` |
| `.lib "file" section` | reads one section of a library | `.lib 'file' section` |
| `.lib section { ... }` | defines a section, inside a library file | `.lib section` ... `.endl` |
| `.hdl "model.va"` | compiles and loads a Verilog-A or Verilog module | `.hdl` |
| `.verilog "design.v"` | loads a digital Verilog design | `.verilog` |
| `.vec "file"` | a digital vector file: sources and output checks | `.vec` |
| `.load file="x.ic"` | reads a saved operating point; without `file`, the deck's own | `.load FILE=` |
| `.save type=ic\|nodeset file="x.ic" level=all\|top\|select\|none time=` | writes the operating point as a file `.load` reads; every key is optional | `.save TYPE=` |
| `.alter { ... }` | one more run with the block's statements applied; blocks are cumulative. It stands at the top level of the top file, and only another `.alter` follows it | `.alter` |

A relative path is looked for in the working directory, then beside the
file that names it, then beside the top deck. A Verilog-A file (`.va`,
`.vams`, `.veriloga`) is loaded with `.hdl` and a Verilog file (`.v`,
`.sv`) with `.verilog`; `.include` of either is refused.

```espice
.include "cells.sp"
.lib "models.lib" tt
.hdl "model.va"
.verilog "design.v"
.vec "stim.vec"
.load file="x.ic"
.save type=ic file="x.ic" level=all
.lib tt {
    .param corner = 1
}
.alter {
    .param corner = 2
}
```

## Options { #options }

```espice
.option reltol=1e-4 method=gear temp=27C
```

An option this table does not list is an error.

| Option | Type | Default | Meaning |
|---|---|---|---|
| `reltol` | real | 1e-3 | relative convergence tolerance |
| `abstol` | current | 1e-12 | absolute current tolerance |
| `vntol` | voltage | 1e-6 | absolute voltage tolerance |
| `chgtol` | real | 1e-14 | charge tolerance, C |
| `gmin` | conductance | 1e-12 | conductance across junctions |
| `itl1` `itl2` `itl4` | integer | 100, 50, 10 | Newton limits: operating point, DC sweep point, transient step |
| `dv` | voltage | none | largest Newton change of a node voltage per iteration |
| `trtol` | real | 7 | transient truncation-error factor |
| `method` | `trap` `gear` | `trap` | integration method |
| `maxord` | integer | 2 | integration order cap |
| `xmu` | real | 0.5 | trapezoidal damping, 0 to 0.5 |
| `temp` | temperature | 27 | circuit temperature |
| `tnom` | temperature | 27 | model reference temperature |
| `delmax` | time | | transient step cap when `.tran` gives none |
| `tran_ceiling` | `compatibility` `duration` | `compatibility` | the default step-cap policy |
| `gshunt` `cshunt` `rshunt` | conductance, capacitance, resistance | | from every net to ground |
| `scale` | real | 1 | geometry scale for model binning |
| `wnflag` | integer | 0 | bin selection by per-finger W |
| `seed` | integer | 1 | Monte Carlo seed |
| `sampling_method` | `lhs` | | Latin hypercube sampling |
| `runlvl` | integer | | accuracy preset; `accurate` and `fast` are flags |
| `em_recovery` | real | 1 | recovery factor of `em_avg` |
| `search` | string | | an include search directory |
| `soa` | flag | off | checks every device against its SOA limits |
| `maxwarns` | integer | 5 | most SOA lines printed |
| `soalimits` | string | | a JSON file of SOA limits |
| `vpi` | string | | a VPI application to load |

**Legacy.** `.options` with the same names; `temp` is also what `.temp`
set.

## Initial conditions and output { #state }

| Statement | Meaning | Legacy |
|---|---|---|
| `.ic v(n)=value ...` | the start state of a `.tran ... uic` | `.ic` |
| `.nodeset v(n)=value ...` | a first guess for the operating point | `.nodeset` |
| `.probe v(out) i(Vdd) ...` | write only these vectors; without one, every vector is written | `.save v(out) i(Vdd)` |

```espice
.ic v(out)=0.9V v(x1.q)=0
.nodeset v(out)=0.9V
.probe v(out) i(Vdd)
```

## Ranges { #ranges }

One spelling for every sweep and every frequency grid.

| Range | Points | Legacy |
|---|---|---|
| `lin(start, stop, step=s)` | from `start` to `stop` in steps of `s` | `start stop s` |
| `lin(start, stop, n=k)` | `k` points in all; not on `.step` | `lin k start stop` |
| `dec(start, stop, n=k)` | `k` points per decade | `dec k start stop` |
| `oct(start, stop, n=k)` | `k` points per octave | `oct k start stop` |
| `[v1, v2, ...]` | the listed values, ascending for a frequency | `poi N v1 v2 ...`, `list v1 v2 ...` |

A frequency grid takes `dec`, `oct` or `lin` with `n=`, and a list where
its analysis says so. As in the
legacy dialect, an `.ac` `dec` grid spanning a decade or more stretches its
step so the last point is `stop`.

## Analyses { #analyses }

Each analysis is one directive. [Analyses](analyses.md) says what each
computes and the plot it writes; this section is how to write it. `out` is
a probe, `src` the name of a V or I source, `freq` a frequency
[range](#ranges). A key in brackets is optional.

### DC { #dc-analyses }

| Analysis | Signature | Legacy |
|---|---|---|
| `.op` | `.op [at=[t1, t2, ...]]` | `.op`, `.op t1 t2` |
| `.dc` | `.dc target=range [target2=range] [sweep ...]` | `.dc src start stop step [src2 ...]` |
| `.tf` | `.tf out= src=` | `.tf v(out) src` |
| `.sens` | `.sens out= [freq=]` | `.sens v(out)`, `.sens v(out) ac dec N f1 f2` |
| `.dcmatch` | `.dcmatch out=` | `.dcmatch v(out)` |
| `.dcsens` | `.dcsens out= [file= perturbation= interval= threshold= groupbydevice=yes\|no]` | `.dcsens v(out) FILE= ...` |
| `.dcxf` | `.dcxf out= [tf]` | `.dcxf v(out) [tf]` |
| `.dcinc` | `.dcinc` | `.dcinc` |
| `.mc` | `.mc trials= [sigma=]` | `.mc N [sigma]` |

A `.dc` target is a V or I source, a resistor, a parameter or `temp`. The
first target varies fastest. `.dc sweep data(name)` and `.dc sweep
monte(n)` sweep no source. The `out` of `.tf` and `.dcxf` may also be
`i(Vx)`; every other `out` here is `v(a)` or `v(a,b)`. `.sens`'s `freq`
takes no list.

```espice
.op
.op at=[1ns, 5ns]
.dc Vin=lin(0, 1.8V, step=10mV) Vdd=[1.6V, 1.8V, 2.0V]
.dc temp=lin(-40C, 125C, step=5C)
.tf out=v(out) src=Vin
.sens out=v(out) freq=dec(1Hz, 1MHz, n=10)
.dcmatch out=v(out)
.dcsens out=v(out) threshold=0.01 groupbydevice=yes
.dcxf out=i(Vm) tf
.dcinc
.mc trials=1000 sigma=1%
```

### Small signal { #ac-analyses }

| Analysis | Signature | Legacy |
|---|---|---|
| `.ac` | `.ac freq=` | `.ac dec N f1 f2` |
| `.noise` | `.noise out= [src=] freq= [contributions]` | `.noise v(out) src dec N f1 f2 [1]` |
| `.pz` | `.pz [in=v(a,b) out=v(c,d) drive=voltage\|current find=poles\|zeros\|both]` | `.pz a b c d vol\|cur pol\|zer\|pz` |
| `.disto` | `.disto freq= [f2overf1=]` | `.disto dec N f1 f2 [ratio]` |
| `.sp` | `.sp freq= [noise]` | `.sp dec N f1 f2 [1]` |
| `.lin` | `.lin [sparcalc] [noisecalc] [gdcalc] [format=touchstone\|touchstone2\|citi\|selem] [filename=] [mixedmode2port=ss\|sd\|...]` | `.lin SPARCALC=1 ...` |
| `.net` | `.net [out=] src= [rin=] [rout=]` | `.net v(out) src RIN= ROUT=` |
| `.stb` | `.stb probe= freq=` | `.stb Vprobe dec N f1 f2` |
| `.lstb` | `.lstb mode=single\|diff\|comm vsource= [localgnd=] [freq=]` | `.lstb mode= vsource=Vp,Vn ...` |
| `.acmatch` | `.acmatch out= [threshold= file= interval= virtual_sensitivity=yes\|no sens_threshold=]` | `.acmatch v(out) ...` |
| `.acxf` | `.acxf out= freq= [tf]` | `.acxf v(out) dec N f1 f2 [tf]` |

`.pz` alone finds the circuit's natural poles; its four keys come
together. `.lstb`'s `vsource` is one probe source, or the list `[Vp, Vn]`
for `diff` and `comm`. `.lin`, `.net` and a `.lstb` without `freq` run over
the deck's `.ac` grid. `.net` takes `rout` only with `out`. The flags of
`.lin` are its `=1` settings. The `out` of `.net` and `.acxf` may also be
`i(Vx)`. `.ac` and `.noise` read a list grid; `.disto`, `.sp`, `.stb`,
`.lstb` and `.acxf` do not.

```espice
.ac freq=dec(1Hz, 1GHz, n=20)
.noise out=v(out) src=Vin freq=dec(10Hz, 10MHz, n=10) contributions
.pz in=v(in, 0) out=v(out, 0) drive=voltage find=both
.disto freq=dec(1kHz, 100kHz, n=10) f2overf1=0.9
.sp freq=dec(1MHz, 1GHz, n=10)
.lin sparcalc noisecalc format=touchstone filename="amp.s2p"
.net out=v(out) src=Vin rin=50Ohm rout=50Ohm
.stb probe=Vprobe freq=dec(1Hz, 1GHz, n=10)
.lstb mode=single vsource=Vprobe
.acmatch out=v(out) threshold=0.01
.acxf out=v(out) freq=dec(1Hz, 1MHz, n=5) tf
```

### Transient { #tran-analyses }

| Analysis | Signature | Legacy |
|---|---|---|
| `.tran` | `.tran stop= step= [start=] [maxstep=] [uic]` | `.tran step stop [start [maxstep]] [uic]` |
| `.four` | `.four out... f0= [nharm=]` | `.four f0 v(out) ... [nharm]` |
| `.fft` | `.fft out [start= stop= np= format=norm\|unorm window= alfa= freq= fmin= fmax=]` | `.fft v(out) START= ...` |
| `.trannoise` | `.trannoise stop= step=`, or `.trannoise out= [method=mc\|sde seed= samples= fmin= fmax= scale= time=]` | `.trannoise tstep tstop`, `.trannoise v(out) METHOD= ...` |
| `.envelope` | `.envelope period= stop=` | `.envelope tcarrier tstop` |
| `.matex` | `.matex stop= step=` | `.matex tstep tstop` |

`.fft`'s `window` is `rect`, `bart`, `hann`, `hamm`, `black`, `harris`,
`gauss` or `kaiser`. The `out=` form of `.trannoise` runs on the deck's
`.tran`; its `time` is a time or the word `all`.

```espice
.tran stop=10us step=1ns
.tran stop=2ns step=2ps maxstep=200ps uic
.four v(out) f0=1kHz nharm=9
.fft v(out) np=1024 window=hann
.trannoise out=v(out) samples=3 seed=1
.trannoise stop=1us step=1ns
.envelope period=1ms stop=5ms
.matex stop=2ms step=1us
```

### Periodic steady state { #pss-analyses }

| Analysis | Signature | Legacy |
|---|---|---|
| `.pss` | `.pss f0= [points=] [osc=] [settle=]` | `.pss f0 [points]`, `.pss v(osc) f0 [points [settle]]` |
| `.pss`, ngspice's oscillator form | `.pss f0= osc= tstab= points= harmonics= sciter= steadycoeff= [uic]` | `.pss gfreq tstab oscnob points harms sciter steadycoeff [uic]` |
| `.pac` | `.pac f0= freq=` | `.pac f0 dec N f1 f2` |
| `.pxf` | `.pxf [out=] f0= freq=` | `.pxf [v(out)] f0 dec N f1 f2` |
| `.pnoise` | `.pnoise out= src= freq= f0= [sidebands=]` | `.pnoise v(out) src dec N f1 f2 f0 [sidebands]` |
| `.ptdnoise` | `.ptdnoise out= time= [tdelta=] freq=` | `.ptdnoise v(out) TIME= [TDELTA=] dec N f1 f2` |
| `.qpss` | `.qpss f1= f2= [nharms=[k1, k2]]` | `.qpss f1 f2 [k1 [k2]]` |

`osc=v(node)` makes `.pss` autonomous: `f0` is then a first guess, and
`settle` (periods) needs it; `points` defaults to 256. Giving `tstab`
selects ngspice's form, which needs every key of its row but `uic` and
refuses `settle`; its `harmonics` is the spectrum's row count. `osc`, and
the `out` of `.pxf`, `.hbxf` and `.phasenoise`, is a single-ended
`v(node)`. `.pac`, `.pxf`, `.pnoise` and `.ptdnoise` read a list grid. `.ptdnoise`'s `time` is a time or a [range](#ranges) of times
(`lin` with `n=`, `dec`, `oct` or a list). `.qpss` keeps `k1` and `k2`
harmonics of the two tones, 5 each by default.

```espice
.pss f0=1kHz points=256
.pss f0=1GHz osc=v(osc) settle=20
.pss f0=1MHz tstab=10us osc=v(osc) points=100 harmonics=10 sciter=50 steadycoeff=1e-3
.pac f0=1kHz freq=dec(10Hz, 10kHz, n=4)
.pxf out=v(out) f0=1kHz freq=[10Hz, 100Hz]
.pnoise out=v(out) src=Vin freq=dec(10Hz, 10kHz, n=3) f0=1kHz sidebands=3
.ptdnoise out=v(out) time=1ns freq=dec(1kHz, 1MHz, n=2)
.qpss f1=1kHz f2=1.4142kHz nharms=[2, 2]
```

### Harmonic balance { #hb-analyses }

| Analysis | Signature | Legacy |
|---|---|---|
| `.hb` | `.hb f0= [harmonics=] [osc=]` | `.hb f0 [harmonics]`, `.hb v(osc) f0 [harmonics]` |
| `.hb`, multitone | `.hb tones=[f1, f2, ...] [nharms=[n1, n2, ...]] [intmodmax= subharms= ss_tone=]` | `.hb TONES= NHARMS= ...` |
| `.hbac` | `.hbac freq= [f0=] [harmonics=]` | `.hbac dec N f1 f2 [f0 [K]]` |
| `.hbxf` | `.hbxf out= freq= [f0=] [harmonics=]` | `.hbxf v(out) dec N f1 f2 [f0 [K]]` |
| `.hbnoise` | `.hbnoise out= [src=] freq= [f0=] [harmonics=] [sidebands=]` | `.hbnoise v(out) [src] dec N f1 f2 [f0 [K [M]]]` |
| `.hblin` | `.hblin freq= [noisecalc] [filename= dataformat=ri\|ma\|db]` | `.hblin dec N f1 f2 NOISECALC=1 ...` |
| `.phasenoise` | `.phasenoise out= freq= [f0=] [harmonics=] [method=nlp\|pac\|bpn] [carrierindex=]` | `.phasenoise v(out) dec N f1 f2 [f0 [K]] [METHOD=0\|1\|2] ...` |

Without `f0` the `.hbac` family takes the deck's `.hb` tone. `harmonics`
is the harmonics kept about the tone and `sidebands` the noise sidebands
folded; each needs the key before it (`harmonics` needs `f0`, `sidebands`
needs `harmonics`). `.phasenoise`'s `method` is `nlp`, the perturbation
projection, `pac`, the periodic noise at the carrier sideband, or `bpn`,
`nlp` close in and `pac` beyond. Their `freq` takes no list; `.hblin`'s
does. `tones` needs `nharms` or `intmodmax`, and refuses `f0`, `harmonics`
and `osc`.

```espice
.hb f0=1kHz harmonics=8
.hb f0=1GHz osc=v(t)
.hb tones=[1kHz, 1.1kHz] nharms=[5, 5]
.hbac freq=dec(1Hz, 1kHz, n=10) f0=1MHz harmonics=4
.hbxf out=v(out) freq=dec(1Hz, 1kHz, n=10)
.hbnoise out=v(out) src=Vin freq=dec(1Hz, 1kHz, n=2) f0=1MHz harmonics=4 sidebands=3
.hblin freq=dec(1MHz, 1GHz, n=10) noisecalc
.phasenoise out=v(t) freq=dec(1kHz, 1MHz, n=2) method=bpn
```

## Sweeps and runs { #sweeps }

| Statement | Meaning | Legacy |
|---|---|---|
| `.step target=range` | reruns every analysis per point; the target is a parameter, `temp`, a source or a resistor | `.step name start stop step`, `.step dec name start stop N`, `.step name list v1 ...` |
| `... sweep target=range` | on an analysis: one run of that analysis per point; the target is a parameter, `temp`, a source or a resistor, as `.step`'s | `SWEEP name start stop step`, `SWEEP name lin\|dec\|oct N start stop`, `SWEEP name poi N v1 ...` |
| `... sweep data(name)` | on an analysis: one run per row of a `.data` table | `SWEEP DATA=name` |
| `... sweep monte(n, first=k)` | `n` Monte Carlo trials, the first numbered `k` | `SWEEP MONTE=n FIRSTRUN=k` |
| `... sweep monte(runs=[10, (20, 30)])` | the listed trials; a pair is a span | `SWEEP MONTE=list(10 20:30)` |
| `... sweep monte(n, sigma_scale=[...], fail=expr)` | scaled-sigma sampling of a rare failure | `SWEEP MONTE=n SIGMA_SCALE= FAIL=` |
| `... sweep optimize(name, results=[m1, m2], model=optmod)` | optimizes the parameters declared with `optimize(name, ...)` | `SWEEP OPTIMIZE=name RESULTS= MODEL=` |
| `.data name (p1, p2) { rows }` | a table of parameter values, one comma-separated row per line | `.data name p1 p2` ... `.enddata` |
| `.wcd spec... [maxiter=] [tol=] [top=]` | each spec's worst-case distance; a spec is `(measure op bound)`, `op` one of `>=` `>` `<=` `<` | `.wcd m1 '>= L1' ...` |

```espice
.step rval=[1k, 2k, 5k]
.step temp=lin(-40C, 125C, step=55C)
.step vdd=dec(1V, 10V, n=5)
.data corners (rval, cval) {
    1k, 1pF
    2k, 2pF
}
.tran stop=10us step=10ns sweep data(corners)
.ac freq=dec(1Hz, 1GHz, n=10) sweep rval=lin(1k, 3k, step=1k)
.op sweep rval=[1k, 2k, 5k]
.ac freq=dec(1Hz, 1GHz, n=10) sweep monte(100, first=11)
.tran stop=10us step=10ns sweep monte(runs=[10, (20, 30)])
.dc Vin=lin(0, 1, step=0.1) sweep monte(1000, sigma_scale=[2.5, 3, 3.5, 4, 4.5], fail=m > 5)
.dc sweep monte(50)
.param wn = optimize(opt1, 1um, lo=0.5um, hi=5um)
.dc Vin=lin(0, 1.8V, step=0.1V) sweep optimize(opt1, results=[m], model=optmod)
.wcd (gain >= 60) (pm >= 45) maxiter=20
```

Every analysis takes the `sweep` clause. `sigma_scale` and `fail` come
together, on a `.tran`, an `.ac` or a `.dc` with a target; `runs` takes
no count, `first`, `sigma_scale` or `fail`, and lists literal trial
numbers. A `.step` grid is `lin` with
`step=`, `dec` or `oct` with `n=`, or a list: `.step` has no `lin` by
count; a `sweep target=` range may be `lin` with `n=` too. One `.step`
names one target. HSPICE's `.data` file forms (`MER`,
`LAM`) are not in the language: write them in a legacy file and include it.

`optimize(name, init, lo=, hi=, [step=], [grid=])` declares an optimized
parameter: `step` is its finite-difference step and `grid` the grid its
values stay on. **Legacy.** `.param wn = opt1(1u, 0.5u, 5u)`; with `grid`
and no `step`, `opt1(1u, 0.5u, 5u, 0, 5n)`, the step the optimizer
picks.

## Statistics { #statistics }

| Function | Draws |
|---|---|
| `agauss(nom, abs, sigma)` | a Gaussian, `abs` being `sigma` standard deviations |
| `gauss(nom, rel, sigma)` | the same with a relative spread |
| `aunif(nom, abs)` | uniform within ±`abs` |
| `unif(nom, rel)` | uniform within ±`rel`·`nom` |
| `limit(nom, abs)` | one of the two ends |

Each returns `nom` unless a Monte Carlo sweep or `.option seed` is active.
The names and meanings are the legacy dialect's.

```espice
.param avt = 5mV
.variation {
    global {
        nmos nch vto=20mV kp=1%
    }
    local {
        nmos nch vto=avt*1um/sqrt(w*l)
    }
    element {
        resistor r=5%
        mosfet w=2%
    }
}
```

A `.variation` block holds `global`, `local` and `element` blocks: a
`global` sigma draws once per model, a `local` or `element` one once per
device. A `global` or `local` row is a model's type (HSPICE's word, read
and not used: the name selects) and name, then its sigmas, one standard
deviation each. An `element` row names a [primitive](#primitives), a kind
of modelled device (`mosfet`, `bjt`, `diode`, `jfet`, `mesfet`,
`vswitch`, `cswitch`, `ltra`, `txl`, `cpl`, `urc`) or `module`, and
reaches every device of that kind. A sigma written as a number with `%`
is relative to the nominal; any other is absolute, and may be an
expression over global parameters and the device's `w`, `l` and `m`.
**Legacy.** `.variation`, each part between `.global_variation`,
`.local_variation` or `.element_variation` and its `.end_` card, an
element row headed by its card letter (`r r=5%`), then `.end_variation`.

## Measurements { #meas }

```text
.meas kind name = expression [goal=] [goal_bound=above|below|equal] [weight=] [minval=]
```

`kind` is the result measured: `tran`, `ac`, `dc`, `op`, `sp`, `fft`,
`trannoise`, `dcmatch`, `acmatch`, `lstb`, `phasenoise` or `ptdnoise`,
and `tran_cont`, `ac_cont` or `dc_cont` for every occurrence instead of
one.

The expression is one measurement function, the difference of two
`cross()` calls, or arithmetic over parameters and the names of earlier
measurements. A measurement function inside arithmetic is refused: give
it its own `.meas` and use its name.

| Function | Result | Legacy |
|---|---|---|
| `cross(sig, level, rise=\|fall=\|cross=, td=, from=, to=)` | when `sig` crosses `level`, a value or a signal: the `n`th rising, falling or any crossing, or `last` | `WHEN sig=level RISE=n TD=` |
| `cross(...) - cross(...)` | the time from the second to the first; either side may be `at(x)`, the point `x`; each `cross` needs a count and a value for its level; the first may take `td=trig`, counting only after the second | `TRIG ... TARG ...`, `TRIG AT=x` |
| `find(sig, at=x)`, `find(sig, when=cross(...))` | `sig` at `x`, or when another signal crosses | `FIND sig AT=x`, `FIND sig WHEN ...` |
| `find(column)` | a column of a one-row result: `dcmatch`, `lstb`, `op` | `FIND column` |
| `deriv(sig, at=x)`, `deriv(sig, when=cross(...))` | the slope | `DERIV sig AT=x` |
| `avg rms integ min max pp min_at max_at` `(sig, from=, to=)` | over the window | `AVG sig FROM= TO=` |
| `err err1 err2 err3` `(a, b, from=, to=, ymin=, ymax=)` | the error of `a` against `b`, over the points whose magnitude is within `ymin` to `ymax`; `minval` floors the denominator | `ERR1 a b IGNOR= YMAX= MINVAL=` |
| `thd snr sndr enob sfdr` `(sig, nbharm=, minfreq=, maxfreq=, binsiz=)` | of an `fft` result | `THD sig NBHARM= ...` |
| `em_avg(sig, from=, to=)` | of a `tran` result: the electromigration average current | `EM_AVG sig` |
| `jitter(sig, level, rise=\|fall=\|cross=, td=)` | of a `tran` or `trannoise` result: time-interval error of a clock's edges | `JITTER TRIG sig VAL=level` |
| `gain_margin()` `phase_margin()` `phase_crossover_freq()` `unity_gain_freq()` `loop_gain_minifreq()` | of an `lstb` result | `.meas lstb name phase_margin` |
| `soa_count()`, in arithmetic | the result's SOA excursion count | `PARAM='soa_count()'` |

A signal is a probe (`v`, `i`, and `vdb vm vp vr vi` of an `ac`, `fft` or
`sp` result), `lstb(db)` (also `m`, `mag`, `p`, `r`, `i`) for the `.lstb`
loop gain, a result's column by name (`total_3sigma`,
`ptdnoise_density`), or an expression of `v()`, `i()`, `time`, parameters
and earlier results: `avg(v(out)*i(Vdd))`. The signals of `err` and of
the FFT functions are probes or columns. A level, `at`, `from`, `to` and
`td` are numbers or expressions over parameters and earlier results; a
count is an integer or `last`.

`goal=` is an optimization target: the result's error is `weight` times
its distance from `goal` over `max(|goal|, minval)`, and with
`goal_bound=above` (`below`) it is 0 while the result stays above (below)
`goal`; `goal_bound` needs `goal`. `goal`, `weight` and `minval` are
refused after `find(column)` and the `lstb` margins. **Legacy.** `GOAL=g`, `GOAL > g`, `GOAL < g`; a level in `when`
holding a parenthesis is the constant signal `par('...')`, arithmetic is
`PARAM='...'` and an expression signal `par('...')`.

```espice
.meas tran tphl  = cross(v(out), 0.9V, fall=1) - cross(v(in), 0.9V, rise=1)
.meas tran tset  = cross(v(out), 1.7V, rise=1, td=trig) - at(1ns)
.meas tran vmax  = max(v(out), from=1ns, to=5ns)
.meas tran vmid  = find(v(out), at=2ns)
.meas tran vx    = find(v(in), when=cross(v(out), v(ref), cross=last))
.meas tran pavg  = avg(v(out)*i(Vdd), from=1ns)
.meas tran e     = err1(v(out), v(ref), ymax=2V) minval=1mV
.meas ac   bw    = cross(vdb(out), -3, fall=1)
.meas fft  dist  = thd(v(out), nbharm=9)
.meas lstb pm    = phase_margin()
.meas dcmatch s  = find(total_3sigma)
.meas tran ratio = vmax/1.8
.meas tran slow  = cross(v(out), 0.9V, rise=last) goal=1ns goal_bound=below weight=2
```

### Checks { #checks }

| Statement | Reports | Legacy |
|---|---|---|
| `.check rise\|fall\|slew min= max= nodes=[...] [hi= lo= hi_th= lo_th=]` | transitions whose duration is outside [`min`, `max`] | `.check rise (min max) nodes [(hi lo hi_th lo_th)]` |
| `.check setup\|hold ref= ref_edge=rise\|fall limit= edge=rise\|fall nodes=[...] [hi= lo= hi_th= lo_th=]` | transitions within `limit` before (setup) or after (hold) an edge of `ref` | `.check setup (ref RISE limit FALL) nodes` |
| `.check edge ref= ref_edge=rise\|fall min= max= edge=rise\|fall nodes=[...] [hi= lo= hi_th= lo_th=]` | edges of `ref` with no transition from `min` to `max` after them | `.check edge (ref RISE min max RISE) nodes` |
| `.check irdrop level= duration= nodes=[...]` | stretches beyond `level` (below it when negative) longer than `duration` | `.check irdrop (level duration) nodes` |
| `.check global_level hi= lo= hi_th= lo_th=` | the thresholds of the checks with none of their own | `.check global_level (hi lo hi_th lo_th)` |
| `.dout nodes=[...] [vth= \| vlo= vhi=] states=[(t, s, ...), ...]` | states the nodes fail to hold; a row is a time and one state per node, `0`, `1` or `x` (any); 1.65 V without a threshold | `.dout n1 n2 VTH (t s1 s2 ...)` |
| `.biaschk expr [max= min= tstart= tstop=]` | stretches of an expression outside its limits | `.biaschk 'expr' max= ...` |
| `.stim pwl\|data signal... [table=] [file=] [from= to= npoints= \| times=[...]] [indepout]` | writes transient signals as PWL sources, or as the `.data` table `table`, which `data` requires and `pwl` refuses | `.stim tran pwl\|data [filename=] [table] ...` |

A node is a name or a `v()` or `i()` probe. A threshold `hi_th` or
`lo_th` written with `%` is that share of the swing above `lo`, else a
voltage. A `.stim` signal is a probe, `name=signal` (an expression signal
needs its name), or `(signal, p, n)`, naming a PWL source's terminals; an
unnamed one is named after its probe (`v(a)` is `v_a`), and a PWL
signal's name starts with `v` or `i`, the source it becomes. `from`, `to`,
`npoints` and `times` are numbers, not expressions.

```espice
.check global_level hi=1.8V lo=0 hi_th=80% lo_th=20%
.check slew min=10ps max=200ps nodes=[out, v(x1.q)]
.check setup ref=clk ref_edge=rise limit=50ps edge=rise nodes=[d]
.check irdrop level=-0.1V duration=1ns nodes=[vdd]
.dout nodes=[q, qb] vth=0.9V states=[(10ns, 1, 0), (20ns, 0, x)]
.biaschk v(d, s) max=1.8V tstart=1ns
.stim pwl vq=v(q) (i(Vdd), vdd, 0) from=0 to=10ns npoints=101
.stim data table=waves v(out) times=[0, 1ns, 2ns]
```

## Reliability { #reliability }

| Statement | Legacy |
|---|---|
| `.mosra reltotaltime= [relstarttime= relstep= simmode=aged\|degradation relmode=both\|hci\|bti agingstart= agingstop= hcithreshold= nbtithreshold= degf=]` | `.mosra RelTotalTime= ... SimMode=2\|0 RelMode=0\|1\|2 ...` |
| `.appendmodel from= to= type=nmos\|pmos` | `.appendmodel src MOSRA dst NMOS` |
| `.sample fs= [tol= numf= maxfld= beta=]` | `.sample FS= ...` |

`.mosra` ages the MOSFETs of each model `.appendmodel` binds to a `mosra`
model, over a stress `.tran`. Its times (`reltotaltime`, `relstarttime`,
`relstep`, the stress window `agingstart` to `agingstop`) are `time`s;
`hcithreshold`, `nbtithreshold` and `degf`, the |ΔVth| that ends a
device's life, are `voltage`s. `simmode=aged`, the default, reruns the
deck at each reliability time; `degradation` only reports it. `relmode`
picks the mechanisms: both, hot-carrier injection or bias temperature
instability. `.sample` folds sampled `.noise` spectra: `fs` is a
`frequency`, `numf` and `maxfld` `integer`s, `tol` and `beta` `real`s.

```espice
.model nra mosra tit0=1e-4 tn=0.25
.appendmodel from=nra to=nch type=nmos
.mosra reltotaltime=10s relstep=3s simmode=aged relmode=hci
.sample fs=1GHz maxfld=5
```

## Moving a deck to the language { #moving }

A legacy deck needs no change to run, and a new deck can `.include` or
`.lib` it as it is. To rewrite one, these are the main spellings:

| Legacy | Here |
|---|---|
| the title line | `.espice 1`, then `.title "text"` |
| `* comment`, `+` continuation, `.end` | `// comment`, brackets or `{ }`, the end of the file |
| `R1 a b 1k` | `R1 (a b) resistor 1k` |
| `C1 a 0 1p IC=0.9` | `C1 (a 0) capacitor 1pF ic=0.9V` |
| `V1 in 0 DC 0 AC 1 PULSE(0 1.8 1n 20p 20p 2n 4n)` | `V1 (in 0) vsource dc=0 ac=1 pulse(0, 1.8V, td=1ns, tr=20ps, tf=20ps, pw=2ns, per=4ns)` |
| `E1 p n cp cn 2`, `F1 p n Vsense 5` | `E1 (p n cp cn) vcvs 2`, `F1 (p n) cccs 5 probe=Vsense` |
| `B1 p n V={v(a)*v(b)}` | `B1 (p n) bsource v=v(a)*v(b)` |
| `M1 d g s b nch W=1u L=180n` | `M1 (d g s b) nch w=1um l=180nm` |
| `X1 in out vdd 0 inv wn=2u` | `X1 (in out vdd 0) inv wn=2um` |
| `.model nch NMOS LEVEL=14 vth0=0.45` | `.model nch bsim4 type=n vth0=0.45` |
| `.subckt inv in out` ... `.ends` | `.subckt inv (in out) {` ... `}` |
| `.param vdd=1.8 r={2*vdd}` | `.param vdd = 1.8V  r = 2*vdd` |
| `10meg`, `x^y`, `a<>b` | `10M` with a unit (`10MHz`), `x**y`, `a != b` |
| `.options reltol=1e-4`, `.temp 85` | `.option reltol=1e-4 temp=85C` |
| `.save v(out)` | `.probe v(out)` |
| `.include models.inc`, `.lib pdk.lib tt` | `.include "models.inc"`, `.lib "pdk.lib" tt` |
| `.dc V1 0 1.8 0.01` | `.dc V1=lin(0, 1.8V, step=0.01V)` |
| `.ac dec 10 1 1g` | `.ac freq=dec(1Hz, 1GHz, n=10)` |
| `.tran 1n 10u` | `.tran stop=10us step=1ns` |
| `.noise v(out) Vin dec 10 1 1meg` | `.noise out=v(out) src=Vin freq=dec(1Hz, 1MHz, n=10)` |
| `.step param r list 1k 2k` | `.step r=[1k, 2k]` |
| `.tran 1n 1u sweep monte=100` | `.tran stop=1us step=1ns sweep monte(100)` |
| `.meas tran t TRIG v(a) VAL=0.5 RISE=1 TARG v(b) VAL=0.5 RISE=1` | `.meas tran t = cross(v(b), 0.5V, rise=1) - cross(v(a), 0.5V, rise=1)` |
| `.meas tran v FIND v(a) AT=1n`, `.meas tran r PARAM='t/2'` | `.meas tran v = find(v(a), at=1ns)`, `.meas tran r = t/2` |

Each construct's **Legacy** entry above gives the rest.

## Not in the language { #retired }

These legacy spellings have no statement here, each for the reason given.
A deck that needs a rare legacy-only form reaches it through a legacy file:
put the form in a file without the header and `.include` or `.lib` it,
since includes mix the two dialects.

| Legacy | Here |
|---|---|
| the title line, `.end` | `.title`; the end of the file |
| `+` continuation, `*`, `;` and `$` comments | brackets and `{ }`; `//` |
| `'expr'`, `{expr}` | the expression itself |
| `.ends` `.endl` `.endif` `.enddata` | the `}` that closes the block |
| `.print` `.plot` `.graph` `.width` `.protect` `.unprotect` `.prot` `.unprot` `.pat` `.csparam` | they had no effect |
| `.control` ... `.endc`, `.store` | skipped with a warning before; no statement |
| `.temp t` | `.option temp=` |
| `.macro` `.eom` `.parameter` `.parameters` `.options` `.opt` `.opts` `.measure` `.inc` | `.subckt` `.param` `.option` `.meas` `.include` |
| a B card, an E or G card's `VALUE=`, `VOL=`, `CUR=` | `bsource` |
| `LEVEL=` | the model's family |
| `.osdi_include` `.pre_osdi` | refused in both: load Verilog-A with `.hdl` |
| `.lin noisecalc=2` | ESPice computes it as `noisecalc=1`, the two-port noise parameters; write the flag `noisecalc` |
| `.data` from a file (`MER`, `LAM`) | write the rows in a `.data` block, or the file form in an included legacy file |

## What is checked, and when { #checks-when }

A file in this language is checked before anything is simulated, and every
problem in it is reported, not only the first: an unknown directive, key or
enum word, a missing or repeated key, a unit that is not its slot's, a
number that does not read. Each message names the file, line and column
and carries a code (`E` an error, `W` a warning) that
[Diagnostics](diagnostics.md) lists.

What needs the whole deck is checked when the circuit is built, as in the
legacy dialect: that a master, a node or a source exists, that an instance
parameter is one its device declares, and a subcircuit's port names.
