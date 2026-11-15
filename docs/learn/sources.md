# 2. Sources

Every circuit needs something to drive it. SPICE has independent sources,
which set a voltage or current, and controlled sources, whose output
depends on another voltage or current in the circuit.

## Independent sources

A voltage source is a `vsource`, a current source an `isource`:

```text
name (p n) vsource [value | wave] [dc=value] [ac=mag] [acphase=degrees]
name (p n) isource [value | wave] [dc=value] [ac=mag] [acphase=degrees]
```

The three parts serve different analyses:

- `dc=` is the value at the operating point and in `.dc` sweeps. A bare
  value after the master means the same thing: `V1 (in 0) vsource 5V`.
- `ac=` (and `acphase=`) is the small-signal stimulus for `.ac` and the
  noise input reference: `ac=1` is a 1 V phasor at 0 degrees.
- The waveform is the value over time in `.tran`.

A current source pushes current from `p` through the source to `n`, so
`I1 (0 a) isource 1mA` drives 1 mA *into* node `a`.

### Waveforms

A waveform's first two arguments are values; the rest are named.

| Waveform | Arguments |
|---|---|
| `pulse(v1, v2, td=, tr=, tf=, pw=, per=)` | low, high, delay, rise, fall, width, period |
| `sin(vo, va, freq=, td=, theta=, phase=)` | offset, amplitude, frequency, delay, damping (1/s), degrees |
| `exp(v1, v2, td1=, tau1=, td2=, tau2=)` | start, end, rise delay and time constant, fall delay and time constant |
| `pwl((t1, v1), (t2, v2), ...)` | time and value pairs, linear in between; `r=` repeats, `td=` delays |
| `sffm(vo, va, fm=, mdi=, fc=)` | single-frequency FM |
| `am(va, vo, fm=, fc=, td=)` | amplitude modulation |

A named argument you leave out takes its default. A `pulse` with no rise or
fall time uses the transient's step; with no width or period it stays high
until the end. The [language reference](../using/language.md#waves) gives
every default.

This deck drives five 1k loads, one per waveform, plus a DC current source:

```espice
--8<-- "examples/sources.esp"
```

```sh
espice sources.esp --rawfile sources.raw
```

```text
Independent source waveforms: 10 devices
  Transient Analysis: 526 points, 10 variables
```

Open `sources.raw` in a waveform viewer, or write `--format=csv` and plot
the columns with anything you like.

## Controlled sources

Four masters give the four linear dependent sources:

| Master | Output | Controlled by | Syntax |
|---|---|---|---|
| `vcvs` | voltage | a voltage | `E1 (p n cp cn) vcvs gain` |
| `vccs` | current | a voltage | `G1 (p n cp cn) vccs transconductance` |
| `cccs` | current | a current | `F1 (p n) cccs gain probe=Vsense` |
| `ccvs` | voltage | a current | `H1 (p n) ccvs transresistance probe=Vsense` |

`cccs` and `ccvs` sense the current through the voltage source `probe=`
names. When there is no source in the branch you want to sense, add a 0 V
one (`Vsense`) in series: it changes nothing in the circuit and gives you a
current to read.

`bsource` is a behavioural source: its value is any expression of node
voltages, branch currents, `time` and parameters. `v=` makes a voltage,
`i=` a current.

```text
B1 (out 0) bsource v=v(a)*v(b)
B2 (out 0) bsource i=1mA*tanh(v(in))
```

All of them in one deck:

```espice
--8<-- "examples/controlled.esp"
```

```sh
espice controlled.esp --rawfile controlled.txt --format=print
```

```text
Operating Point: The four controlled sources and a B source
Index	i(v1)	i(vsense)	i(b1)	i(e1)	i(h1)	v(in)	v(sense)	v(f)	v(h)	v(b)	v(e)	v(g)
-----	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------
0	-3.0000000000000005e-3	4.999999999999946e-4	-1e-3	-5.999999999999986e-3	-2.500000000000001e-4	2e0	1.9999999999999991e0	9.999999999999848e-1	2.500000000000001e-1	1e0	5.999999999999997e0	1.999999999999999e0
```

Check each against its line: `v(e)` = 3 × 2 V = 6 V. G1 pushes
1 mA/V × 2 V = 2 mA into `g`, so `v(g)` = 2 V across 1k. 0.5 mA flows
through Vsense, so F1 drives 1 mA into `f` (1 V) and H1 makes
500 Ω × 0.5 mA = 0.25 V. And `v(b)` = 2² / 4 = 1 V.

A `bsource` also takes the classic nonlinear forms as its whole value
(`laplace`, `pole`, `table`, `delay`, `poly`); the
[language reference](../using/language.md#behavioural) lists them.

## Exercises

1. In `controlled.esp`, change the gain of `F1` to `-2`. What happens to
   `v(f)`?
2. Make a 1 kHz square wave between −1 V and 1 V with 1 µs edges, using
   `pulse`.
3. Using one `vccs` and one resistor, build a voltage amplifier with a
   gain of −10 from node `in` to node `out`.

??? tip "Answers"

    1. F1 now pushes 1 mA out of `f`, so `v(f)` = −1 V.
    2. `V1 (sq 0) vsource pulse(-1V, 1V, tr=1us, tf=1us, pw=0.499ms, per=1ms)`:
       the width plus one edge is half the period.
    3. `G1 (out 0 in 0) vccs 10mS` and `R1 (out 0) resistor 1k`. G1 drives
       10 mA/V × v(in) from `out` to ground through the source, so the
       current into `out` is −10 mA/V × v(in), and across 1k that is
       −10 × v(in).
