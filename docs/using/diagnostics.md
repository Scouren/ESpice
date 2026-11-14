# Diagnostics and errors

When a deck fails, ESPice prints what went wrong on stderr and exits with
status 1. The last line is always `Error: <file>: <ErrorName>`; the lines
before it usually say which card and why. Warnings (`warning: ...`) and
notes (`note: ...`) do not stop the run.

```text
error: analysis: .ac dec 10 100: InvalidAnalysisArguments
Error: bad_args.sp: InvalidAnalysisArguments
```

## Reading the deck

| Error | Cause | Fix |
|---|---|---|
| `FileNotFound` | the deck, an `.include`, a `.lib` file or a data file does not exist | a relative path is looked for in the working directory, then beside the file that names it, then beside the top deck |
| `ParseError` | a card ESPice cannot read: a missing node or value, an unbalanced parenthesis, a keyword where a node belongs, a block close (`.ends`, `.endif`, `.enddata`, `.end_variation`) with no block open; the card is printed | check the card's syntax in the [reference](reference.md) |
| `UnsupportedCard` | a dot card or element form ESPice does not simulate, or an analysis card inside a `.subckt`; the line is printed | see [what is not supported](dialects.md#what-is-not-supported-or-differs) |
| `UnresolvedParameter` | a device value, a source value or an `E`, `F`, `G` or `H` gain does not evaluate to a number: it names a parameter no `.param` defines, a source value reads the circuit, or a `V`, `I` or linear `E` or `G` value reads `temper` (ngspice stops on each) | define it, or check its spelling and scope; read the circuit or `temper` in a `B` source |
| `OsdiUnsupported` | `pre_osdi` or `.osdi_include` | load the Verilog-A source with `.hdl`; see [Verilog-A](devices.md#osdi-is-not-loaded) |
| `UnsupportedDevice` | a `.model` LEVEL with no built-in model; a warning names it | see the [LEVEL tables](devices.md#model-type-and-level) |
| `UnsupportedSelfHeating` | a card ngspice would self-heat on a model ESPice runs isothermal: a VDMOS with a thermal node, or with `thermal` and `rthjc`; a B3SOI-FD or -DD with `shmod=1` and a non-zero `rth0`. A diode self-heats ([diode self-heating](devices.md#diode-self-heating)) | drop the thermal node, the flag or `rth0` to run it isothermal |
| `LibrarySectionNotFound`, `InvalidLibrarySection` | `.lib file section` names a section the file does not have | check the section names inside the library |
| `IncludeDepthExceeded` | includes nested more than 32 deep, usually a file including itself | |
| `SpiceRackNotFound` | a deck in another dialect than ngspice, and no `spice2rack` to translate it: not at `--spicerack`, `$ESPICE_SPICERACK` or on `PATH` | install SpiceRack, or name it with `--spicerack=PATH`; `--tokenizer=ngspice` reads the deck as written. See [Dialects](dialects.md#other-dialects-spicerack) |
| `SpiceRackRefused` | `spice2rack` refused a construct of the deck: the line before names its file, line, column and code (`error: spicerack: deck.sp: deck:6:1: W0001 a statement kept as another dialect's text`) | rewrite what SpiceRack names, or report the construct to SpiceRack |
| `SpiceRackFailed` | `spice2rack` failed some other way: an unreadable deck, a crash (exit 101) or a signal, a usage error, or past 64 KiB of stdout or 1 MiB of stderr; the line before has its exit | report it to SpiceRack with that line |
| `SpiceRackNoEntry` | `spice2rack` succeeded but printed no single path of a translated deck that exists | a SpiceRack without `--to espice --kit`: update it |
| `SpiceRackNeedsFile` | a deck in another dialect came through a pipe or FIFO (`/dev/stdin`, `<(...)`): spice2rack opens the deck by path, with no stdin, and would read nothing | save it to a file first |

```text
error: netlist: cannot read the card: .subckt
Error: bad_subckt.sp: ParseError
```

```text
error: netlist: unsupported card: .foo 1 2
Error: bad_card.sp: UnsupportedCard
```

```text
warning: devices: MOSFET LEVEL 57 needs model 'b3soipd', which is not in the device catalog
Error: bad_level.sp: UnsupportedDevice
```

A common `ParseError`: in an E, F, G or H card the word right after the
output nodes names a behavioural form when one is a keyword (`poly`,
`table`, `laplace`, `pole`, `delay`, `vcr`, `vol`, ...) and the card is no
linear one; on a linear card (`E1 o 0 pole 0 2`) it is a node, as in
ngspice. `value` and `table` are forms wherever they stand: a control node
named `table` makes the rest of the line no longer parse. Rename the node.

## Building the circuit

| Error | Cause |
|---|---|
| `FloatingNode` | a node, or a group of nodes, has no DC path to ground: only capacitors, or nothing, connect it; also a node that only an expression reads (`B1 o 0 V={v(a)}` with nothing at `a`) |
| `VoltageSourceLoop` | voltage sources (and inductors) form a loop that breaks Kirchhoff's voltage law, such as two different sources in parallel |
| `NonuniqueOperatingPoint` | voltage sources alone form a loop that agrees with KVL, such as two equal sources in parallel: no equation fixes the current around it |
| `CurrentSourceCutset` | current sources drive a group of nodes with no DC path to ground and their currents do not cancel. A `.ic` on one of the nodes is a DC path for a `.tran`'s operating point, which holds it there as ngspice does; an operating point without that hold (`.op`, `.dc`, `.ac`) then fails with `FloatingNode` |
| `InvalidParameterValue` | a value out of its allowed range, such as a URC model's `K` |
| `UnknownParameter`, `WrongNodeCount` | an instance card sets a parameter its device (built-in or Verilog-A) does not declare, such as `ww=10u` for `w=10u`; an `S` or `W` card has a word other than `ON` or `OFF` after its model; an `O` card sets a key other than `v1`, `v2`, `i1`, `i2` or `ic`, such as `len=` (the line's length is its model's `len=`); or a Verilog-A instance has more nodes than its module has ports |

```text
error: topology: a node has no DC path to ground (capacitor-only island) — the operating point is not unique
Error: divider.sp: FloatingNode
```

```text
error: topology: 'v2' closes an inconsistent voltage-source/inductor loop (-1 V of KVL violation)
Error: bad_short.sp: VoltageSourceLoop
```

## Analysis cards

| Error | Cause |
|---|---|
| `InvalidAnalysisArguments` | wrong number of arguments, a negative or zero step, an unknown keyword, or a value the analysis cannot represent: a frequency whose 2πf or 1/f overflows, a step too small to resolve, a sweep past 2^32 points |
| `UnsupportedFrequencySweep` | a sweep type other than `dec`, `oct`, `lin` (or `poi`) |
| `AnalysisNodeNotFound` | the card's output node does not exist, or is ground |
| `AnalysisSourceNotFound` | the card names a source (or probe) the deck does not have |
| `MissingAnalysisCard` | a card that borrows another card's settings, and that card is missing: `.fft` needs a `.tran`, `.acmatch` an `.ac`, `.ptdnoise` a driven `.pss` |
| `UnsupportedAnalysisOutput` | an output form the analysis cannot give, such as `i(...)` in `.fft` or a balanced port in `.hblin` |
| `MissingPortNumber` | the deck's `portnum` numbers skip one: ports run 1 to N |
| `DuplicatePortNumber` | a third V card on one `portnum`; two make a [balanced port](analyses.md#sp) |
| `UnbalancedPort` | a balanced port's two V cards differ in z0 or n− |

```text
error: analysis: .tf v(b) V9: AnalysisSourceNotFound
Error: bad_source.sp: AnalysisSourceNotFound
```

## Simulation

| Error | Cause |
|---|---|
| `SingularMatrix` | the circuit matrix cannot be factored: usually a floating sub-circuit the topology check missed, or a device with zero conductance everywhere |
| `TimestepTooSmall` | the transient step fell below its minimum without converging: a discontinuity too sharp for the tolerances, or a model misbehaving |
| `OpDidNotConverge` | the operating point failed even after gmin and source stepping |
| `HbDidNotConverge`, `QpssDidNotConverge`, `PzDidNotConverge`, `EnvelopeDidNotConverge`, `PacDidNotConverge` | the named analysis did not converge |
| `MatexDidNotConverge` | a `.matex` step needed a Krylov space larger than its limit, or came out non-finite (stiffness beyond the exponential integrator); run `.tran` instead |
| `OscillatorDidNotStart` | an autonomous `.pss` or `.hb` found no oscillation |
| `NoPeriodicSteadyState` | an autonomous `.pss` or `.hb` started oscillating but its shooting found no periodic orbit. The line before it gives the residual and the swing's factor per period over the start-up: below 1, the oscillation decays to its operating point and has no steady state to publish |

For convergence trouble:

- Give the solver a starting point with `.nodeset`, or start a transient
  from `.ic` values with `uic`.
- Raise the iteration limits: `.options itl1=500 itl4=50`.
- Loosen `reltol` (`.options reltol=1e-2`) to see whether the circuit
  converges at all, then tighten it back.
- For transients, cap the step (`tmax` on `.tran`, or `.options delmax=`)
  so sharp edges are not jumped over, or switch the integrator with
  `.options method=gear`.
- Run with `--timing-in-depth` to see the Newton iteration counts of each
  query.

## Output

| Error | Cause |
|---|---|
| `NotSParameterData` | `--format=touchstone` or `citi` on a result that is not S-parameters |
| `NoPorts` | an S-parameter format on an `.sp` with no ports |
| `FormatLimitExceeded` | a result too large for the format, such as more than 64 variables in `sst2` |
| `DeliveryFailed` | writing the output file failed; the line after it says why (`Output error: AccessDenied`) |

## Measurements

A `.meas` card whose event never happens prints an error and the run
carries on. The exit status is unaffected:

```text
Error: measure  t50 : out of interval
```

## Verilog-A loading

| Message | Cause |
|---|---|
| `CompilerGone` | the Zig compiler could not be started for `.hdl`: put Zig 0.17.0 on `PATH` or set `ZIG` |
| `HdlShareNotFound` | an embedder's toolchain share path (`Options.hdl_toolchain`, C `share_path`) holds no `device/eval.zig`; point it at the installed `share/espice` |
| VerA diagnostics (file, line, error code) | the Verilog-A source does not compile |
| `UnregisteredSystf` | an instance's module calls a system function or task no standard defines (`$my_fn(...)`, VerA warning W0852) and no loaded VPI application registers it; load one with `--vpi` |
| `VpiApplicationUnloadable`, `VpiNoStartupRoutines` | a `--vpi` or `.options vpi=` library does not open, or exports no `vlog_startup_routines` |
| `VpiSecondSystfModule` | a second module calls a `$systf`; one per run is supported |
| `VpiDesignFailed` | VerA could not build the VPI design of the module |
| `VpiUnavailable` | a VPI application in a build without a VPI host (the C API, an embedding) |

See [Verilog-A](devices.md#your-own-verilog-a) for the requirements.

## Why does my deck fail?

**It works in ngspice.** Check, in this order:

1. Does it load OSDI, or rely on a `.control` script? ESPice runs the
   analysis cards only; replace the OSDI line with `.hdl` and move the
   script's analyses into the deck as cards.
2. Does it use a model LEVEL ESPice does not have? The warning names it.
3. Look up the card in [what is not supported, or differs](dialects.md#what-is-not-supported-or-differs).

**The numbers differ from ngspice.** Small differences in the last digits
are normal for any two simulators: time steps, iteration counts and
rounding differ. Large ones are worth a look. The
[dialects page](dialects.md#what-is-not-supported-or-differs) lists every
place ESPice deliberately does something else. Two to check first: an
HSPICE deck runs at 25 °C by default, not 27 °C, which SpiceRack's
translation must carry, and ESPice uses `.ic` only with `uic`.

**A model name is misspelled.** Check that every element names a model
that exists: in testing, a `D` card naming an undefined model ran with
default diode parameters and no warning.

**Nothing is written.** Without `--rawfile`, ESPice writes no result file;
the summary and the `.meas` results are the whole output.
