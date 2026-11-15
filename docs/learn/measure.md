# 7. Measurements

A waveform answers questions only after you read numbers off it. `.meas`
reads them for you after the run and prints the results on stdout, so a
deck can report its own rise time, delay or peak.

```text
.meas <analysis> <name> = <function>(...)
```

`<analysis>` is `tran`, `ac` or `dc`: which result to measure. `<name>`
labels the printed line and can be used by later measurements.

## A worked example

```espice
--8<-- "examples/measure.esp"
```

```sh
espice measure.esp
```

```text
  Measurements for Transient Analysis

trise               =  2.197201e-06 targ=  3.303064e-06 trig=  1.105863e-06
tdelay              =  6.931367e-07 targ=  1.693637e-06 trig=  1.000500e-06
vat3u               =  8.645984e-01
tcross              =   6.68790e-06
vmax                =  9.932657e-01 at=  6.001000e-06
vavg                =  4.982781e-01 from=  0.000000e+00 to=  1.000000e-05
vrms                =   6.33054e-01 from=  0.00000e+00 to=  1.00000e-05
slope               =  3.685512e+05
charge              =   -9.93246e-10 from=  1.00000e-06 to=  6.00000e-06
ratio               =  3.169938e+00
Measurements on an RC step response: 3 devices
  Transient Analysis: 1029 points, 4 variables
```

Every number checks against the RC math (τ = 1 µs): the 10 % to 90 % rise is
τ ln 9 = 2.197 µs, the 50 % delay τ ln 2 = 0.693 µs, and 2 µs after the
edge the output is 1 − e⁻² = 0.865 V. The charge V1 delivers while it is
high is C × ΔV ≈ 1 nC (negative, since a source's current is measured into
its positive terminal).

## The functions

| Form | Measures |
|---|---|
| `cross(sig2, v2, rise=n) - cross(sig1, v1, rise=n)` | time from the first event to the second |
| `find(sig, at=x)` | the value of `sig` at `x` |
| `find(sig, when=cross(sig2, v))` | the value of `sig` when `sig2` crosses `v` |
| `cross(sig, v, rise=n \| fall=n \| cross=n)` | when `sig` crosses `v` |
| `max`, `min`, `pp` `(sig, from=, to=)` | peak, valley, peak-to-peak; `max_at`, `min_at` give where |
| `avg`, `rms`, `integ` `(sig, from=, to=)` | average, RMS and integral over the window |
| `deriv(sig, at=x)` | slope at `x` |
| an expression | arithmetic over earlier results and parameters: `trise/tdelay` |

`rise=n`, `fall=n` and `cross=n` pick the nth rising, falling or any
crossing; `last` picks the last one. `td=t` ignores events before `t`.
`from` and `to` bound the window, and a signal can be `v(node)`,
`v(a,b)`, `i(source)`, or in AC `vdb(node)`, `vm`, `vp`, `vr` and `vi`.

ESPice evaluates `.meas` like ngspice's `meas` command, with the same
interpolation and print format, and has more functions (`err1` to
`err3`, `thd`, `jitter`, continuous `tran_cont` measures and more). The
[language reference](../using/language.md#meas) lists them all.

A measurement that cannot be taken, because its event never happens in
the run, prints an error and the run carries on:

```text
Error: measure  t50 : out of interval
```

## Exercises

1. Add a measurement of the fall time (90 % down to 10 %) after the
   input steps back to 0 at 6 µs.
2. Measure the average of `v(out)` over the last full period only: is it
   still about 0.5 V?
3. In `cmos_inverter.esp` (chapter 4), add `tplh` for the rising output
   edge and a measurement of the mean delay.

??? tip "Answers"

    1. `.meas tran tfall = cross(v(out), 0.1V, fall=1) - cross(v(out), 0.9V, fall=1)`,
       2.197 µs again: the circuit is linear.
    2. The run is only 10 µs and the period 20 µs, so there is no full
       period. Lengthen the `.tran` to `stop=40us` and average with
       `from=20us, to=40us`.
    3. `.meas tran tplh = cross(v(out), 0.9V, rise=1) - cross(v(in), 0.9V, fall=1)`
       and `.meas tran tpd = (tphl + tplh)/2`. `tplh` is 32 ps (the
       PMOS is weaker) and `tpd` 30 ps.
