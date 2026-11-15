# 5. Subcircuits

A subcircuit is a named block of elements with ports, defined once and
placed as many times as you like. It is how you build an opamp, a logic
gate or a standard cell once and reuse it.

```text
.subckt name (port1 port2 ...) [param=default ...] {
    instances
}

instance (node1 node2 ...) name [param=value ...]
```

An instance whose master is the subcircuit connects its nodes to the ports
in order, or by name: `X1 (inp=a inn=b out=c) opamp`. Parameters on the
`.subckt` line are defaults; the instance can override any of them, and
the lines inside use them by name.

## An opamp, used as an inverting amplifier

```espice
--8<-- "examples/opamp_subckt.esp"
```

```sh
espice opamp_subckt.esp --rawfile amp.txt --format=print
```

`.tf` (DC transfer function) reports the gain from VIN to
`v(out)` and the input and output resistances:

```text
Transfer Function: Inverting amplifier with an opamp subcircuit
Index	transfer_function	input_resistance	output_resistance
-----	---------------	---------------	---------------
0	-9.999448930366691e0	1.0000500997492506e3	5.499696939200166e-4
```

The gain is −Rf/Rin = −10, short by the opamp's finite open-loop gain; the
input resistance is Rin. The `.ac` sweep shows the closed-loop bandwidth.

## Names inside a subcircuit

Instances and nodes inside a subcircuit get the instance name as a prefix,
the way ngspice names them. In the operating point above the internal
node `int` of `X1` is `v(x1.int)`, and E2's branch current is
`i(e.x1.e2)`:

```text
Index	i(vin)	i(e.x1.e1)	i(e.x1.e2)	v(in)	v(x1.p1)	v(x1.int)	v(inv)	v(x1.drv)	v(out)
```

Node `0` is global: ground inside a subcircuit is the same ground as
outside. To make other nets global, list them with `.global`
(`.global vdd vss`). Subcircuits can contain instances of other
subcircuits, up to 32 levels deep.

## Splitting a design into files

`.include "file"` reads another file in place. `.lib "file" section`
reads only one section of a library file, the block of a
`.lib section { ... }` inside it. PDKs use sections for process corners.

`models.esp.lib`:

```text
--8<-- "examples/models.esp.lib"
```

`divider.esp.inc`:

```text
--8<-- "examples/divider.esp.inc"
```

The deck picks the slow corner and pulls in the divider:

```text
--8<-- "examples/include_lib.esp"
```

```text
Operating Point: Diode forward voltage from a library corner
Index	v(a)	v(mid)
-----	---------------	---------------
0	7.392795709202897e-1	3.6963978546014487e-1
```

Relative paths resolve against the working directory, then the directory
of the file that names them. An included file may be in either language:
a PDK's ngspice library is read with `.lib` as it is.
(The browser playground runs single files only, so this example has no
Run button. Run it from `docs/examples/` in a checkout.)

## Exercises

1. Place a second opamp after the first as a unity-gain buffer
   (`X2 (out out2 out2) opamp`). What is `v(out2)`?
2. Override the opamp's output resistance on `X1` with `rout=1k`. What
   happens to the output resistance `.tf` reports, and why is it still
   so small?
3. Switch `include_lib.esp` to the `typ` section. Does `v(a)` go up or
   down?

??? tip "Answers"

    1. Its non-inverting input is `out` and its output feeds its inverting
       input, so `v(out2)` follows `v(out)` to within 1/a0.
    2. It rises a hundredfold, from 0.55 mΩ to 55 mΩ, but stays far
       below the 1k inside the opamp: the feedback loop divides the
       opamp's own output resistance by its loop gain.
    3. Down: the typical corner's diode has twice the `is` and `n` = 1, so it
       needs less voltage for 1 mA.
