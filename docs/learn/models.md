# 4. Semiconductor models

Resistors and sources take a value. Diodes and transistors take a *model*:
a named set of parameters declared once with `.model` and shared by every
device that names it.

```text
.model name family [type=polarity] param=value param=value ...
```

The family says which device equations the model uses, and so what kind
of device it is for. A device names the model as its master, and its
ports follow the kind:

| Family | Device | Ports |
|---|---|---|
| `diode` | diode | `a k` |
| `gummel_poon`, `type=npn` or `pnp` | bipolar transistor | `c b e` |
| `mos1`, `bsim4`, ..., `type=n` or `p` | MOSFET | `d g s b` |
| `jfet`, `type=n` or `p` | JFET | `d g s` |
| `mesfet`, `type=n` or `p` | MESFET | `d g s` |
| `vswitch`, `cswitch` | voltage- and current-controlled switch | `p n cp cn`; `p n` |

Parameters you leave out take the model's defaults.

## Diodes

`D1 (anode cathode) model`. This half-wave rectifier charges a 100 µF
reservoir through a diode:

```espice
--8<-- "examples/diode_rectifier.esp"
```

```sh
espice diode_rectifier.esp
```

```text
  Measurements for Transient Analysis

vpeak               =  9.228482e+00 at=  5.173860e-03
vmin                =  7.719858e+00 at=  4.317386e-02
Half-wave rectifier: 4 devices
  Transient Analysis: 610 points, 4 variables
```

The output peaks one diode drop below the 10 V input, then sags between
peaks as the load drains the capacitor: about 1.5 V of ripple.

`is` (saturation current), `n` (emission coefficient), `rs` (series
resistance) and `cjo` (zero-bias junction capacitance) are the parameters
you will set most often.

## Bipolar transistors

`Q1 (collector base emitter [substrate]) model`. Nested `.dc` sweeps give
the classic output curves: the first target sweeps fastest, once per value
of the second.

```espice
--8<-- "examples/bjt_bias.esp"
```

```sh
espice bjt_bias.esp --rawfile bjt.txt --format=print
```

```text
Operating Point: BJT bias point and output curves
Index	i(vcc)	i(vb)	v(vcc)	v(b)	v(c)
-----	---------------	---------------	---------------	---------------	---------------
0	-5.933074752456546e-4	-3.7802281732556653e-6	5e0	7.000000000000001e-1	4.406692524754345e0
```

At 0.7 V of base drive the collector draws 0.59 mA and the base 3.8 µA,
a current gain of about 157 (`bf` = 150, raised a little by the Early
effect, `vaf` = 80 V). The DC sweep has 101 × 3 = 303 points.

## MOSFETs

`M1 (drain gate source bulk) model w=... l=...`. A MOSFET model's family
picks the equations: `mos1` is the simple square-law Shichman-Hodges
model, good for learning and hand checks; real processes use `bsim4` or
another compact model. Here is a CMOS inverter in `mos1`:

```espice
--8<-- "examples/cmos_inverter.esp"
```

```sh
espice cmos_inverter.esp --rawfile inv.raw
```

```text
  Measurements for Transient Analysis

tphl                =  2.818778e-11 targ=  1.078188e-09 trig=  1.050000e-09
CMOS inverter: 5 devices
  DC transfer characteristic: 181 points, 6 variables
  Transient Analysis: 2032 points, 6 variables
```

The `.dc` gives the voltage transfer curve; `tphl`, the
high-to-low propagation delay into 10 fF, is 28 ps.

## Model families

The family names the equations, so one device kind has several. The
common ones:

| Device | Families |
|---|---|
| MOSFET | `mos1` `mos2` `mos3` `mos6` `mos9`, `bsim1` ... `bsim4`, `bsimsoi`, `hisim2`, `bsimcmg`, `psp103`, `psp104` |
| BJT | `gummel_poon`, `vbic`, `hicuml2`, `mextram` |
| JFET, MESFET, HFET | `jfet` `jfet2`, `mesfet` `mesa` `hfet1` `hfet2` |

A deck in the ngspice dialect writes the same choice as a type and a
`LEVEL` (`NMOS LEVEL=14` is `bsim4 type=n`). The
[language reference](../using/language.md#models) has the full table, and
the [devices page](../using/devices.md) what each model is.

## Exercises

1. In `diode_rectifier.esp`, double C1. What happens to the ripple?
2. Add `.option temp=100C` to `diode_iv.esp` (chapter 3). Does the diode turn on
   at a lower or higher voltage?
3. In `cmos_inverter.esp`, make the PMOS as wide as the NMOS (`wp = wn`).
   Where does the switching threshold of the DC curve move?

??? tip "Answers"

    1. The capacitor discharges half as fast, so the ripple roughly halves
       and `vmin` rises.
    2. Lower: `is` grows quickly with temperature, so the same current needs
       less forward voltage (about −2 mV per °C).
    3. Down, toward 0 V: the NMOS is now stronger than the PMOS (`kp` 200µ
       against 80µ), so it pulls the output low at a lower input voltage.
