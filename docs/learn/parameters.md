# 6. Parameters and sweeps

Hard-coded values make a deck hard to change. `.param` names a value once;
expressions compute the rest from it.

```text
.param name = value [name = value ...]
```

A parameter is used by its name wherever a value goes, and its value may be
an expression of numbers, other parameters and functions:

```espice
--8<-- "examples/expressions.esp"
```

```text
  Measurements for AC Analysis

f3db                =   9.97623e+02
Parameters and expressions: 3 devices
  AC Analysis: 41 points, 4 variables
```

R is computed from the corner frequency you asked for, and the measured
corner lands within 0.3 % of 1 kHz (the gap is the sweep's interpolation
between points).

A parameter keeps the unit it was written with: after `.param f0 = 1kHz`,
`.tran stop=f0` is refused, since a frequency is no time. Anything
computed (`1/f0`) is not checked.

## Expressions

| Kind | What is available |
|---|---|
| Arithmetic | `+ - * /`, `%` (remainder), `**` for powers, parentheses |
| Comparison and logic | `< > <= >= == !=`, `&&`, `\|\|`, `!`, and `cond ? a : b` |
| Functions | `sqrt abs min max pow pwr exp ln log log10 sin cos tan atan tanh floor ceil` and [more](../using/language.md#expressions) |
| Statistics | `agauss gauss unif aunif limit` (nominal value unless Monte Carlo is on; see [chapter 9](monte-carlo.md)) |

`log` is the natural logarithm, like `ln`; use `log10` for base 10.
`x ** y` and `pow(x, y)` are the real power, so `(-2)**3` is −8, and a
negative base with a fractional exponent has no value: a parameter that
computes one fails the deck. `pwr(x, y)` is sign(x)·|x|^y.

In a behavioural source (`bsource`), expressions can also read `v(node)`,
`v(a,b)`, `i(source)`, `time` and `temper`.

A top-level `.param` must evaluate where it stands: one that reads a name
no `.param` defines (`hertz`, `time`, `pi`, a probe) is refused even when
nothing reads it. One that reads `temper` is left to the value that reads
it.

## Scope

A `.param` at the top level is global. Parameters on a `.subckt` line, or
set by `.param` inside a subcircuit, are local to each instance, and an
instance's `name=value` settings override them for that instance.

## `.step`: run everything again with a new value

`.step` reruns every analysis in the deck once per value:

```text
.step name=[v1, v2, ...]
.step name=lin(start, stop, step=s)
.step name=dec(start, stop, n=points)       also oct
.step temp=[t1, t2, ...]
.step Vsource=[v1, v2, ...]
```

```espice
--8<-- "examples/step_param.esp"
```

```text
  Measurements for AC Analysis

f3db                =   1.58788e+03

  Measurements for AC Analysis

f3db                =   7.93938e+02

  Measurements for AC Analysis

f3db                =   3.96908e+02
RC corner against R, with .step: 3 devices
  AC Analysis (rval=1000): 21 points, 4 variables
  AC Analysis (rval=2000): 21 points, 4 variables
  AC Analysis (rval=4000): 21 points, 4 variables
```

Each run gets its own plot, named for the point, and each `.meas` is
evaluated per run. Doubling R halves the corner, as 1/(2πRC) says. Several
`.step` lines make a grid; the last one varies fastest.

## Exercises

1. In `expressions.esp`, change `f0` to 20kHz. What does the `.meas` line
   report, and what do you change to fix it?
2. Write a `.param` that sets `rpar` to R1 and R2 in parallel, for
   `.param r1 = 3k  r2 = 6k`.
3. Use `.step` to run `diode_iv.esp` (chapter 3) at −40, 27 and 125 °C.

??? tip "Answers"

    1. The `.ac` stops at 10 kHz, below the new corner, so the
       response never falls 3 dB inside the sweep and ESPice prints
       `Error: measure  f3db : out of interval`. Extend the sweep to 100kHz.
    2. `.param rpar = r1*r2/(r1 + r2)`, which is 2k.
    3. `.step temp=[-40C, 27C, 125C]`. You get three DC plots, named
       `(temp=-40)`, `(temp=27)` and `(temp=125)`.
