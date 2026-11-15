# 1. A first circuit

A SPICE netlist is a text file that lists the parts of a circuit and how
they connect, then says which analyses to run. These chapters write
netlists in [ESPice's own language](../using/language.md); ESPice also
reads ngspice decks as they are ([dialects](../using/dialects.md)). Here is
the smallest useful netlist: a 10 V source across two resistors.

```espice
--8<-- "examples/divider.esp"
```

Run it:

```sh
espice divider.esp --rawfile divider.txt --format=print
```

ESPice prints a summary on stderr:

```text
Voltage divider: 3 devices
  Operating Point: 1 points, 3 variables
```

and `divider.txt` holds the result:

```text
Operating Point: Voltage divider
Index	i(v1)	v(in)	v(out)
-----	---------------	---------------	---------------
0	-2.5e-3	1e1	7.5e0
```

`v(out)` is 7.5 V, as 10 V × 3k / (1k + 3k) says it should be. `i(v1)` is
the current through the source, −2.5 mA. SPICE measures a source's current
flowing into its positive terminal, so a source that delivers power shows a
negative current.

## The parts of a netlist

**The header.** The first line is `.espice 1`: it says the file is in
version 1 of the language. A file without it is read as an ngspice deck.

**The title.** `.title "text"` names the deck. ESPice prints it in the
summary and stores it in the output file.

**Comments.** `//` starts a comment that runs to the end of the line.

**Instances.** A line that does not start with a dot places a part. It
gives the part's name, the nodes it connects in parentheses, its master
(what kind of part it is) and its value:

```text
R1  (in out)  resistor  1k
│    │         │         └─ value: 1 kilo-ohm
│    │         └─────────── master: a resistor
│    └───────────────────── the nodes it connects
└────────────────────────── name
```

The name only has to be unique: `R1`, `load` and `r_bias` are all fine
names for a resistor. The master says what the part is: `resistor`,
`capacitor`, `vsource` (a voltage source), or a model or subcircuit you
define (chapters 4 and 5).

**Nodes.** A node is any name or number. Two terminals that name the
same node are connected. Node `0` is ground, the reference every voltage is
measured against; `gnd` and `ground` are the same node. Every circuit needs
a path to ground from every node, or it has no DC solution.

**Directives.** A line starting with `.` is a directive. `.op` asks for the
DC operating point. The deck ends where the file ends.

**Case.** Names ignore case: `R1` and `r1` name the same part, and result
columns come out lowercase (`v(out)`). Masters, directives and keys are
written in lower case; the prefixes and units of numbers are
case-sensitive.

## Values and units

A value is a number with an optional prefix and an optional unit, so
`1kOhm`, `1k` and `1000` are the same value:

| Prefix | Scale | Example |
|---|---|---|
| `T` | 10^12 | `1T` |
| `G` | 10^9 | `2.4GHz` |
| `M` | 10^6 | `10MHz` |
| `k` | 10^3 | `4.7kOhm` |
| `m` | 10^-3 | `5mA` |
| `u` | 10^-6 | `100uF` |
| `n` | 10^-9 | `22nH` |
| `p` | 10^-12 | `10pF` |
| `f` | 10^-15 | `5fF` |
| `a` | 10^-18 | `1aF` |

`M` is mega and `m` is milli: `1mA` is 0.001 A, `1MHz` a million hertz. A
bare `M` with no unit is refused, as are SPICE's `meg` and `mil`, so the
two cannot be confused. A unit must suit the slot it fills: ESPice
refuses `capacitor 10pH`. The [language reference](../using/language.md#numbers)
lists every unit.

## Splitting long lines

A statement ends at the end of its line, except inside parentheses or
square brackets, where it may run over lines:

```text
V1 (in 0) vsource pulse(0, 10V, td=1ms,
                        tr=1us, tf=1us)
```

(`pulse` is a waveform; [chapter 2](sources.md) covers it.)

## Exercises

1. Change R2 to 1k. What is `v(out)` now, and what is `i(v1)`?
2. Add a third resistor, `R3 (out 0) resistor 3k`, in parallel with R2.
   Predict `v(out)` before you run it.
3. Delete the `R2` line. What is `v(out)`? Then add
   `C1 (out x) capacitor 1nF`, where nothing else touches `x`, and run it
   again.

??? tip "Answers"

    1. `v(out)` = 5 V and `i(v1)` = −5 mA.
    2. Two 3k in parallel make 1.5k, so `v(out)` = 10 × 1.5 / 2.5 = 6 V.
    3. Without R2 no current flows through R1, so there is no drop across
       it: `v(out)` = 10 V and `i(v1)` = 0. With `C1` added, node `x` has
       no DC path to ground (a capacitor is open at DC), so the operating
       point is not unique. ESPice refuses the deck:

        ```text
        error: topology: a node has no DC path to ground (capacitor-only island) — the operating point is not unique
        Error: divider.esp: FloatingNode
        ```
