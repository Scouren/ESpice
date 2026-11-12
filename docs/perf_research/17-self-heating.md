# Self-heating for the diode (and what to do about VDMOS and the BJT)

Research of 2026-11-11 on `dev/performance`. No code was written and no
ESPice build was run; every number below is an ngspice measurement or a line
read from source. Scratch decks and outputs:
`/tmp/claude-1000/-home-omare-Documents-Projects-EDA-Tools-Simulator-ESPice/a4b9a03a-c468-4624-9c3e-13218d819563/scratchpad/selfheat/`
(called `$S` below).

Sources, and how they are cited:

- **ngspice master**: `VerA/tests/conformance/external/ngspice` at `a9da7bca`
  (2026-10-14). Cited as `dioload.c:796`. This tree is *newer* than both
  oracle binaries.
- **ngspice 44.2 source**: the same repository at `e1bd97d8` (2025-01-10),
  extracted to `$S/dioload_44.c`, `$S/diodefs_44.h`, `$S/vdmosload_44.c`,
  `$S/vdmosset_44.c`. Cited as `dioload_44.c:530`.
- **ngspice binaries**: 44.2
  (`/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice`)
  and 45 (`/nix/store/bvcwn52yfwwb8q3q2c939a64907k92zg-ngspice-45/bin/ngspice`).
- **VerA 0.23.0**: `zig-pkg/vera-0.23.0-fzAu7BznSAHTovhsbqKB1WQBFu66b65RDnBfVhQi4EF9/`,
  cited as `vera:docs/using/limit.md`.
- ESPice line numbers are of the working tree on 2026-11-11. Other agents
  were editing `src/frontend/net_devices.zig`, `src/tests/card_keys.zig` and
  `src/frontend/ngspice_model_keys.tsv` during this research, so find by
  function name when a line has moved.

## Summary: what to build, in order

1. **Diode only.** Add a second device `diode_t` (three ports `a, c, tj`)
   compiled from the same `models/diode.va` under `` `ifdef SELFHEATING ``,
   through `build.zig`'s existing `model_variants` table. The plain `diode`
   stays byte-identical, so no plain-diode deck pays anything.
2. **The frontend picks `diode_t` on ngspice's own condition**: the card has
   a third node, the `thermal` flag is set (word on the card, or `thermal=1`
   on the model card), and the model card gives a non-zero `rth0`. Otherwise
   the card runs as the plain diode, isothermal, as ngspice runs it
   (measured). The pick goes in `resolveDeviceId`, beside the existing
   `psp103` to `psp103_nqs` swap.
3. **Tests, cheapest oracle first**: fixed-temperature twin (metamorphic),
   analytic steady state, energy-balance certificate in transient, then the
   ngspice 44.2 golden that already exists
   (`regression/diode_self_heating.sp`, its `KNOWN GAP` line deleted).
4. **VDMOS: do not implement now.** ngspice self-heats it, but its thermal
   network differs between 44.2, 45 and master, and 44.2's has stamp bugs
   (measured: the source resistor's heat is missing and the case-to-ambient
   resistor lands on the wrong rows). There is no trustworthy oracle. Keep
   `UnsupportedSelfHeating`. Section 1 records what would be built and what
   blocks it.
5. **Gummel-Poon BJT: nothing to build.** ngspice's BJT never self-heats;
   `rth0` is read only by the SOA check.

Three VerA facts could not be checked without a build and are named in
"VerA gaps and unknowns"; the design avoids depending on any of them.

## 1. What ngspice computes

### Diode

**Syntax** (`inp2d.c:46-63`, `dio.c:27`, `dio.c:130-131`):

```
Dname anode cathode [tj] model [area] [off] [ic=..] [temp=..] [dtemp=..] [thermal] [m=..]
.model name D (... rth0=<K/W> cth0=<J/K>)
```

Up to three nodes are read until a model name is found; the third is the
thermal node. `thermal` is an `IF_FLAG` instance parameter: a bare word.
Measured on 44.2: `thermal=1` on the instance card is a parse error;
`thermal=1` on the **model** card works and heats the instance (ngspice
applies instance parameters found on a model card as instance defaults).

**Condition** (`diodefs.h:24-33`, same test inline at `dioload_44.c:77`):

```c
#define DIOselfheat(inst) ((inst)->DIOtempNode > 0 && (inst)->DIOthermal && (mod)->DIOrth0Given)
```

All three are needed. Measured on 44.2 (`$S/sh_op.sp` and its variants;
`V = 0.75 V`, `is=1e-14 rs=0.5 rth0=200`):

| Card | `@d[id]` | `v(tj)` |
|---|---|---|
| node + `thermal` + `rth0=200` | 2.868543356224e-02 | 4.302815034336 |
| node, no flag | 2.443493713593e-02 (isothermal) | 0 |
| flag, no node | 2.443493713593e-02 | no node |
| node + flag, `rth0` not given | 2.443493713593e-02 | 0 |
| node + flag, `rth0=0` | 2.443493713593e-02 | 0 |
| no node, no flag, `rth0=200` | 2.443493713593e-02 | no node |

**The thermal node carries the temperature rise in kelvin, not an absolute
temperature.** `Temp = here->DIOtemp + delTemp` (`dioload.c:331`,
`dioload_44.c:242`), with `delTemp = CKTrhsOld[DIOtempNode]`
(`dioload.c:214`). `DIOtemp` is the instance's ambient: `temp=` when given,
else `CKTtemp + dtemp` (`diotemp.c:308-311`).

**Thermal network**, all inside the device, between `tj` and ground:

- conductance `1/rth0` and the companion of `cth0`: `tempTemp += -dIth_dT +
  1/rth0 + gcTt` (`dioload.c:874`); charge `qth = cth0 * delTemp`
  (`dioload.c:217`), integrated by `NIintegrate` (`dioload.c:740`).
  Defaults: `rth0 = 0`, `cth0 = 1e-5` (`diosetup.c:281-285`).
- power into the node: `Ith = vd*cd + vrs*vrs*gspr` (`dioload.c:796`,
  `dioload_44.c:530`). `cd` already includes `gmin*vd` (`dioload.c:552`)
  and, in transient, the junction capacitor's current (`dioload.c:708`), so
  at convergence `Ith = V(a,c) * I_terminal`.
- neither `rth0` nor `cth0` is scaled by `m` or `area` (`dioload.c:874`);
  the currents are (`diotemp.c:121`). Measured: `m=2 area=3` gives
  `v(tj) = 570.4706801586 = 200 * @d[p]` with `@d[p] = 2.852353400793`.

So the steady state is `v(tj) = rth0 * P` when nothing else touches `tj`,
and an external network on `tj` adds to the KCL. In
`examples/soa/diode-soa-simple.sp` the deck ties `tj` to a 27 V source
through 100 ohm with `rth0=1e6`: `v(tj)/1e6 + (v(tj)-27)/100 = P`.

**What takes the junction temperature**: everything `DIOtempUpdate`
recomputes (`dioload.c:332`, body at `diotemp.c:19-294`): `IS`, `JSW`,
`ISR`, tunnel currents, `VJ`, `CJO`, `PHP`, `CJP`, `M`, `F1..F3`, `Vcrit`,
`BV` knee, `TT`, `RS`, `RSW`; plus `vt`, `vte`, `vtebrk`
(`dioload.c:333-335`). In 44.2 `vtesw` and `vterec` are also taken at the
junction temperature (`dioload_44.c:261`, `:312`); on master they are
computed once at the ambient (`dioload.c:110-112`) and not refreshed. Follow
44.2: everything at the junction temperature.

**What stays at the ambient**:

- pnjlim's `vte` (`dioload.c:108-109`, used at `:303` before the update at
  `:332`) and the cold-start seed `DIOtVcrit` with `delTemp = 0`
  (`dioload.c:164-168`). Path only, not the answer.
- RS thermal noise: `NevalSrcInstanceTemp(..., DIOtConductance, dtemp)` with
  `dtemp = DIOtemp - CKTtemp` (`dionoise.c:88-95`): the conductance is the
  heated one, the temperature is the instance ambient. Shot noise uses the
  heated current (`dionoise.c:97-99`).

**The `_dT` terms** are Jacobian entries only; VerA derives all of them.
For the record (`dioload.c`): `dIdio_dT` (`:554`, built from `cdb_dT`
`:403/446/470`, `cdsw_dT` `:365/376/385/408/451/478`, recombination `:424`,
tunnel `:490/502`), `dIrs_dT = vrs * tConductance_dT` (`:795`,
`diotemp.c:264`), `dIth_dVrs` (`:797-799`), `dIth_dT` (`:800`),
`dIth_dVdio = cd + vd*gd` (`:801`); stamped at `:839-843` (RHS) and
`:870-877` (matrix). ngspice's `dIdio_dT` omits the knee roll-off and the
capacitor current, so its Jacobian is inexact; an exact one changes
iteration counts, not results.

**Limiting**: `delTemp = DEVlimitlog(delTemp, old, 100, &Check_th)`
(`dioload.c:320-322`; `devsup.c:153-185`): a step over 100 K per iteration
is compressed to `old +/- (100 + log10(step/100))`. No absolute clamp.

**Truncation error**: only `DIOcapCharge` is checked (`diotrunc.c:23`); the
thermal charge does not steer the time step.

**Small signal, measured and read**: 44.2 and 45 stamp the thermal
capacitance in AC as `DIOcqth * omega` (`dioacld` at `e1bd97d8`, lines
61-62), where `DIOcqth` is the capacitor's *current*, zero after an
operating point. Measured (`$S/sh_ac.sp`, `rth0=200 cth0=1e-3`, thermal
corner at 0.8 Hz): `vm(tj) = 131.79097513` at every frequency from 1 mHz to
1 kHz on both binaries. Master fixes it to `cth0 * omega`
(`dioacld.c:72-75`, commit `8533ad9fb`, 2026-08-24). **44.2 and 45 have no
thermal pole in AC or noise.**

### VDMOS

ngspice self-heats it; condition `VDMOSthermal && VDMOSrthjcGiven`
(`vdmosload_44.c:81`; master adds `VDMOStempNode > 0`,
`vdmosdefs.h:28-37`). Syntax `M d g s tj tc model thermal`; measured on 44.2
and 45: `thermal` with fewer than five nodes is a parse error ("We need
exactly 5 nodes"). Parameters `rthjc` (default 1), `rthca` (default 23 on
master `vdmosset.c:143-150`), `cthj` (1e-5).

The three versions compute different things:

| | 44.2 (`vdmosload_44.c`) | master (`vdmosload.c`) |
|---|---|---|
| Node value | rise, `Temp = VDMOStemp + delTemp` (`:289-291`) | absolute degC, `TjK = Tj + 273.15` (`:286-288`) |
| Heat sources | channel `cdrain*Vds` + drain resistor (`:449-457`) + body diode (`:890`) | the same plus the source resistor (`:478-493`) |
| Case to ambient | `rthca` stamped between `tNodePrime` and **`tempNode`** (`vdmosset_44.c:482-483`), not `tcase` | between `tNodePrime` and `tcase` (`vdmosset.c:527-529`) |
| `m` scaling of the network | none (`:650-668`) | `gthjc = m/rthjc`, `cthj*m` (`:531`, `:713-714`) |
| Limiter | `DEVlimitlog(.., 10)` (`:280-281`) | the same plus a clamp to [-100, 1000] degC (`:274-278`) |

Measured (`$S/vd1.sp`, the IRFP240 card of `examples/vdmos/self-heating.sp`
at `VD = 2`, `VG = 10`, `rthk = 0.05` from `tc` to ground): 44.2 gives
`v(tj) = 1.912715060794`, `v(tc) = 1.366205526202`, `id = 15.93437797905`;
45 gives `1.943293195471`, `1.388046738954`, `16.24183676707`. On 44.2 the
heat through `rthjc` is `(Tj-Tc)/0.02 = 27.33 W` against `V*I = 31.87 W`;
the missing 4.57 W is `Id^2 * Rs`. The case balance closes only with the
ambient end of `rthca` at 0, not at 27. A deck with `thermal` and a default
(not given) network on 44.2 with tight tolerances fails its operating point
with NaN on `tj` (`$S/vd_op.sp`); `vdmosload_44.c:87-95` carries a FIXME
hack for exactly that.

**Verdict: no usable oracle today.** An implementation matching 44.2 would
encode two bugs; one matching master has no binary to check against. Keep
the refusal (`refuseSelfHeating` in `src/frontend/net_devices.zig`, added
this week, already refuses on ngspice's condition). Revisit when an ngspice
release contains commit `b3594401c` ("VDMOS: fix device polarity,
self-heating and soft recovery", 2026-08-24); then the design is the
diode's with two thermal ports, an internal ambient source and absolute
degC, and its own research pass.

### Gummel-Poon BJT

No self-heating. `rth0` exists (`bjt.c:233`) and is read only in
`bjtsoachk.c:114-119` to derate `pd_max`. `bjtload.c` has no thermal node.
`ngspice_model_keys.tsv` already marks `gummel_poon rth0` inert. Nothing to
do.

### Also self-heating in ngspice, out of scope

B3SOI-FD/DD with `shmod=1` and `rth0 != 0` (already refused by
`refuseSelfHeating`), BSIM-SOI, HiSIM-HV (`coselfheat`), VBIC (`selft`),
HICUM (`flsh`). The last three are Verilog-A models in ESPice that carry
their own thermal network.

## 2. How ESPice's existing self-heating models are wired

| Model | File | Thermal node | How the card reaches it |
|---|---|---|---|
| Mextram 505.6 SH | `models/bjt505t.va` | **port** `dt`, `thermal dt;` (`:139-145`) | 5th node of an `N`/`Q` card whose model kind is `bjt505t` (`src/frontend/spice.zig:163-164`) |
| PSP 103/104 SH | `models/psp103t.va`, `psp104t.va` | port `dt` (`psp104t.va:2812`, `:2855`) | 5th node, model kind `psp103tva` / `psp104tva` (`spice.zig:151-154`) |
| VBIC | `models/vbic13_4t.va` | **internal** `dt` (`:790-792`) | none; `sw_et` is forced 0 for a 4-node card (`addSingleDevice`, `net_devices.zig:155-161`) |
| HICUM/L2, BSIM-BULK, HiSIM-SOTB | `hicumL2_v320.va:1533-1542` etc. | port or internal | model kind |

The pattern, read from those files:

- **Declaration**: `thermal dt;` from `disciplines.vams`; potential
  `Temp(dt)` in kelvin, flow `Pwr(dt)` in watts (`vera:docs/learn/resistor.md:42`,
  `vera:docs/examples/resistor/thermal.va`).
- **Local temperature**: `Tk = Tamb + Vdt` with `Tamb = $temperature + dta`
  (`bjt505t.va:775`, `:864-877`); VBIC `tdevK = tambK + Temp(b_rth)`
  (`vbic13_4t.va:1267-1270`). `$temperature` stays the ambient; the node
  holds the rise. That is the diode's convention in ngspice too.
- **Temperature-dependent parameters at a node voltage**: nothing special.
  The temperature map is ordinary analog-block code that reads `Tk`; VerA
  differentiates it with respect to `Temp(dt)` like any other unknown. VBIC
  says so in a comment (`vbic13_4t.va:1263-1265`: "as they depend on
  self-heating they need to be in the evaluateStatic and not the
  initializeInstance block").
- **Network**: `Pwr(br_ith) <+ -MULT_inst * Pdiss; Pwr(br_rth) <+ ddt(MULT *
  CTH * Temp); Pwr(br_rth) <+ MULT * Temp / RTH_T;` (`psp104t.va:6565-6567`).
  VBIC leaves the thermal charge out of the truncation error with
  `(* vera_lte = 0 *) Pwr(b_rth) <+ ddt(Qcth);` (`vbic13_4t.va:1779`).
- **Binding**: no thermal-specific code. `deviceNodes`
  (`net_devices.zig:249-255`) maps `dev.pins[i]` to port `i` and grounds a
  port the card does not name. A thermal node is an ordinary MNA row; the
  core has no node kind for it (no hit for a thermal node kind anywhere in
  `src/` outside the frontend and noise names).
- **Two files for with/without**: `bjt505t.va` is `bjt505.va` plus
  `` `define SELFHEATING `` and the port (`diff` shows 4 changed lines).
  ESPice's own models do the same thing without a second file through
  `build.zig`'s `model_variants` (`build.zig:747-766`): the variant is
  `defines` followed by `` `include "base" ``, and the module is named after
  the variant (`build.zig:848-858`). `bsource.va:62-74` shows the
  `` `ifdef `` module header.

**No test exercises self-heating numerically today.** No deck or Zig test
under `tests/` or `src/` instantiates `bjt505t`, `psp103t`, `psp104t`, or a
VBIC with `selft`/5 nodes (searched by name). The existing thermal models
are proven to compile and to be in the catalog, nothing more. The diode will
be the first self-heating result with an oracle, which is why the test plan
below starts from analytic checks.

### VerA gaps and unknowns

VerA 0.23 has what the diode needs: the thermal discipline, `ddt` on a
thermal flow, `(* vera_lte = 0 *)`, `$mfactor` readable in `eval`
(`vera:docs/host/batching.md:33-34`, `vera:docs/host/tables.md:110-112`),
`$param_given`, `white_noise` with a solution-dependent density (Mextram and
VBIC use it at `tdevK`, `vbic13_4t.va:1798-1807`).

Not available or not verified (no build was allowed):

1. **No `DEVlimitlog`.** `vera:docs/using/limit.md` lists `pnjlim`,
   `pnjlimds`, `fetlim`, `fetlimds`, `steplim`, `limvds` and user functions.
   `vbic13_4t.va:1362-1363` already records the gap ("VerA's $limit has no
   such limiter yet"). A user analog function could spell it, but see 2.
2. **A clamp on a port is not published.** "A clamp moves only the device's
   own internal nodes" (`vera:docs/using/limit.md`, "Who does the
   limiting"; `vera:docs/host/state.md:160`). `tj` is a port, so
   `$limit(Temp(tj), ...)` would be declined or dropped. Unverified which.
   **The design does not limit the thermal node** (VBIC's precedent) and
   guards finiteness in the model instead.
3. **Solution-dependent `$limit` arguments.** With `vte` and `vcrit`
   functions of `Temp(tj)`, the limiter's arguments and its default seed
   ("a pnjlim leg with no seed starts at its vcrit") would read the
   solution; a seed that does is error E0527. Unverified for the non-seed
   arguments. **The design passes ambient values**, which is also what
   ngspice does.

## 3. GPU

- GPU eligibility is structural: `gpuRefusal` (`src/device/traits.zig:284-289`)
  refuses only `mutable_eval`, Newton-history hooks and `systf_calls`. A
  thermal port adds none of them.
- `test "GPU inventory: every built-in model evaluates on the GPU"`
  (`src/device/tests/eval.zig:1439-1455`) walks every model in the `models`
  module by name, so it already covers `mextram_t`, `psp103t`, `psp104t`
  and will cover `diode_t` the moment it is in the catalog. That is the
  confirmation that the mechanism reaches the Gompute kernels: the same
  generated `eval` is the kernel body, and the thermal port is one more
  column.
- `test "GPU census: ..."` (`eval.zig:1457-1527`) compares, by name, the
  models the lanes and the HB samples refuse. `diode` is in neither list;
  `mextram_t` and `psp104t` are in the HB-sample list only (they have state
  hooks). `diode_t` has the same hooks as `diode` (a `$limit`, one more
  `ddt` site), so the expectation is that **neither list changes**. If
  `diode_t` shows up in one, that is a GPU regression to explain, not a
  name to append.
- Nothing in the design is CPU-only. The one host-side list to leave alone
  is `bypass_models` (`traits.zig:34-42`): an unlisted model always
  evaluates, which is correct; adding `diode_t` is a later, measured step.

## 4. Change list

### `models/diode.va`

Everything new sits under `` `ifdef SELFHEATING ``; with the macro undefined
the file must compile to the same module as today (check: the generated
`diode` source is unchanged, or the corpus raws are byte-identical).

1. **Header** (replaces `diode.va:37-39`):

   ```verilog
   `ifdef SELFHEATING
   module diode_t(a, c, tj);
       inout a, c, tj;
       electrical a, c, ai;
       thermal tj;
   `else
   module diode(a, c);
       inout a, c;
       electrical a, c, ai;
   `endif
   ```

2. **Parameters** (SELFHEATING only), after `trs2`:
   `parameter real rth0 = 1.0 from (0:inf);` (K/W; the frontend only builds
   `diode_t` with a given, non-zero `rth0`) and
   `parameter real cth0 = 1e-5 from [0:inf);` (J/K, `diosetup.c:285`).
   New reals: `tamb`, `vte_a`, `is_a`, `pwr`.

3. **Device temperature** (replaces `diode.va:140-141` in the variant):

   ```verilog
   if ($param_given(temp)) tamb = temp + 273.15;
   else tamb = $temperature + dtemp;
   tk = tamb + Temp(tj);                 // dioload.c:331
   if (tk < 0.5 * tamb) tk = 0.5 * tamb; // finiteness guard, never binds for a rise >= 0
   ```

   No upper clamp: `examples/soa/diode-soa-simple.sp` reaches
   `v(tj) = 2026.583 K` at 2 V on 44.2 and the golden follows it. Everything
   after this line already reads `tk`, so the whole temperature map follows
   the junction with no further edit.

4. **Limiter at the ambient** (replaces the `vcrit`/`$limit` lines at
   `diode.va:279-280` in the variant):

   ```verilog
   vte_a = n * 1.38064852e-23 / 1.6021766208e-19 * tamb;       // dioload.c:108-109
   is_a  = is * ae * exp((tamb / tnomk - 1.0) * egp / vte_a + (xti / n) * ln(tamb / tnomk));
   // ponytail: TLEV 0/1 form and no sidewall; vcrit only steers Newton.
   vcrit = vte_a * ln(vte_a / (1.4142135623730951 * is_a));     // dioload.c:164-168
   vd    = $limit(V(ai, c), "pnjlim", vte_a, vcrit);
   ```

   Do not use the untempered `is` here as VBIC does: at `.temp 100` it puts
   the cold start near 0.9 V, tens of amperes and thousands of kelvin on
   the first iterate.

5. **RS noise at the ambient** (`diode.va:393` in the variant):
   `white_noise(4.0 * 1.38064852e-23 * tamb / rs_t, "rs")`
   (`dionoise.c:88-95`). Shot noise is unchanged.

6. **Thermal network**, after the `rsb` block:

   ```verilog
   `ifdef SELFHEATING
       // dioload.c:796: Ith = vd*cd + vrs^2*gspr, cd with its gmin shunt.
       pwr = vd * (ihi + gmin * vd);
       if (rs > 0.0) pwr = pwr + V(rsb) * V(rsb) / rs_t;
       // dioload.c:874: 1/rth0 is not scaled by m; the host scales every
       // row by $mfactor, so divide it back out (measured: m=2 area=3).
       Pwr(tj) <+ Temp(tj) / (rth0 * $mfactor) - pwr;
       // dioload.c:740 cth0; diotrunc.c:23 leaves it out of the LTE.
       (* vera_lte = 0 *) Pwr(tj) <+ ddt(cth0 / $mfactor * Temp(tj));
   `endif
   ```

   Sign: a `Pwr(tj) <+ x` is a flow leaving `tj`, so KCL reads
   `T/rth0 + cth0*dT/dt - P = 0`, the form of `psp104t.va:6565-6567`.

   `ponytail:` deviation to record in the file: ngspice's `cd` also holds
   the junction capacitor's current in transient (`dioload.c:708`), so it
   counts `vd * dq/dt` as heat. Left out here. Its integral is the change in
   stored energy, at most about `tt * I * V` (7e-9 J for 10 ns, 1 A, 0.7 V)
   against `cth0 >= 1e-5 J/K`: under 1e-3 K. If a transient golden ever
   disagrees, the exact form with `rs > 0` is `pwr = V(a, c) * V(rsb) /
   rs_t` (equal to ngspice's `Ith` at convergence, no `ddt` in a product).

7. Header comment: one paragraph on the variant, citing `dioload.c:331`,
   `:796`, `:874` and `diodefs.h:31`.

### `build.zig`

One row in `model_variants` (`build.zig:750`):
`.{ .name = "diode_t", .base = "diode.va", .defines = "`define SELFHEATING\n" }`.

### Frontend

| File, function | Change |
|---|---|
| `src/frontend/spice.zig`, `DeviceId` | Add `diode_t` with a doc comment like `psp103_nqs`'s (`spice.zig:68-70`): the builder swaps it in. No letter, level or kind entry. |
| `src/frontend/net_devices.zig`, `resolveDeviceId` (`:68-79`) | After the `psp103` block: `if (id == .diode and heatsDiode(dev)) return .diode_t;`. `heatsDiode`: `dev.pins.len == 3`, and the `thermal` word is in `dev.positional[1..]` or `kvNumber(m.kv, "thermal")` is non-zero, and `kvNumber(m.kv, "rth0")` is given and non-zero (`diodefs.h:31-33`; table in section 1). The positional scan already exists in `refuseDroppedTerminals`; factor it out. |
| `net_devices.zig`, `refuseDroppedTerminals` (`:348-360`) | Stop refusing the diode: a plain `diode` with a third pin, or with the flag, runs isothermal as ngspice does (measured). Keep `WrongNodeCount` past three pins and keep the VDMOS arm. `diode_t` has three ports, so it passes on its own. |
| `net_devices.zig`, `addSingleDevice`, `shape_m` (`:182-183`) | Add `DeviceId.Type(.diode_t)`. Without it a card's `m=2` sets the grading coefficient instead of `$mfactor`. |
| `src/frontend/opvar_ngspice.zig:193` | `dio` list: add `"diode_t"`, so `@d1[id]` and friends resolve (the SOA decks save `@dth1[id]`). |
| `tools/ngspice_model_keys.py`, `MAP` and `REVIEWED` | Add `"diode_t": ["dio"]` and copy the two `jtun`/`jtunsw` verdicts; regenerate `src/frontend/ngspice_model_keys.tsv`. Without rows for `diode_t`, a key ESPice does not model (`jtun=1e-5`) would only warn on a self-heated card where it is refused on a plain one. `rth0`/`cth0` need no row for `diode_t` (they are Model fields); `thermal` keeps `*`. |
| `src/frontend/reader_devices.zig:160-162` | None. `splitTerminals` already puts `tj` in `pins` and `thermal` in `positional`. |
| `src/frontend/net_lines.zig:242`, `src/espice/calibrate.zig:112`, `src/frontend/spectre_state.zig:58` | None; they build plain diodes. |
| `src/device/traits.zig`, `bypass_models` | None for now (section 3). |

Edge left as is: a third node that nothing else names, on a card that does
not heat, is not created (ngspice makes it and reports 0 V). Printing it
fails by name, which is loud enough.

### Tests that change meaning

- `src/tests/card_keys.zig`, `test "a diode's or VDMOS's thermal node, or
  the thermal flag, is refused"`: the three diode bodies stop being
  refusals. Move them to the "runs" loop (they have no `rth0`, so they are
  isothermal), keep the VDMOS body.
- `tests/conformance/tests/netlist/regression/diode_self_heating.sp`:
  delete the `* KNOWN GAP:` line and the last sentence of the header
  comment; `tests/VERDICTS.tsv` gains the deck as PASS from a measured run
  (`zig build test -- --update-verdicts`).

### Docs

- `docs/using/devices.md:24`: Diode row, "junction diode (with
  self-heating)"; a short paragraph under the Diodes section (`:84`): the
  three-part condition, `v(tj)` is the rise in kelvin above the instance
  ambient, `rth0`/`cth0` are not scaled by `m` or `area`.
- `docs/using/reference.md:77`: `D1 anode cathode [tj] model [area] [thermal] [m=]`.
- `docs/using/diagnostics.md`: `UnsupportedSelfHeating` now means VDMOS and
  B3SOI only.
- `models/LICENSES.md`: no new file, nothing to add.
- `CHANGELOGS.md`: one line, citing the issue; no number unless measured.
- State in the docs that AC and noise include the thermal pole
  `1/(2*pi*rth0*cth0)`, which ngspice 44.2 and 45 leave out (section 1).

## 5. Test plan

Tolerances: ngspice at its default `reltol = 1e-3` is a 1e-3 oracle; the
decks below tighten it (`.options reltol=1e-6` or lower), so the comparison
can sit at `rtol = 1e-3` with margin, as the existing golden does. Analytic
and metamorphic checks can sit at 1e-6 relative, limited by ESPice's own
`reltol`; set `.options reltol=1e-9 abstol=1e-16 vntol=1e-12` in those
decks.

Each test must go red first. The red state for all of them today is the
refusal (`UnsupportedSelfHeating`); the sharper red check per test is listed.

| # | Test | Oracle | Red first by |
|---|---|---|---|
| T1 | **Fixed-temperature twin.** Solve `dsh 1 0 tj dmod thermal` at 0.75 V; read `v(tj)`; solve a plain diode with `temp = 27 + v(tj)`; currents equal. | Metamorphic. ngspice shows the relation holds to 12 digits: both `2.868543356224e-02` (`$S/sh_op.sp`, `$S/sh_twin_run.sp`). | Dropping `Temp(tj)` from `tk`: currents differ by 17 % (2.4435e-2 against 2.8685e-2). |
| T2 | **Steady state.** Same deck: `v(tj) = rth0 * V * I`. | Analytic: 200 * 0.75 * `i` ; ngspice reference `v(tj) = 4.302815034336`, `P = 2.151407517168e-02`. | Halving the `rs` term in `pwr`: `v(tj)` falls by `I^2*rs*rth0/2 = 0.041 K` (1 %). |
| T3 | **`m` and `area`.** `m=2 area=3` on the card: `v(tj) = rth0 * V * I_total`. | Analytic; ngspice `570.4706801586`, `id = 3.803137867724`. | Removing `$mfactor` from the network: `v(tj)` halves. |
| T4 | **Ambient.** `.temp 50`, one card with `dtemp=10`, one with `temp=80`; twins at `60 + v(tj)` and `80 + v(tj3)`. | Metamorphic; ngspice `v(tj) = 3.936421421763`, `v(tj3) = 8.021213335491`, twins equal to 12 digits (`$S/sh_temp.sp`, `$S/sh_temp_twin.sp`). | Using `$temperature` alone for `tamb`. |
| T5 | **Off conditions.** The five non-heating rows of the table in section 1 give the plain diode's current and build `diode`, not `diode_t`. | Metamorphic (equals the plain card); ngspice `2.443493713593e-02` for each. | The old refusal, and separately a `heatsDiode` that ignores `rth0`. |
| T6 | **Energy balance in transient.** 20 mA step into the diode, `rth0=200 cth0=1e-3`, `tran 1m 1.5`: `cth0 * v(tj)(t_end) = integral of (v(1)*i - v(tj)/rth0) dt`. | Certificate, computed from the output waveforms by trapezoid quadrature. ngspice closes it to 4.4e-6 relative: `2.950924e-3` against `2.950911e-3` (`$S/sh_tran.sp`). Tolerance 1e-4. | `cth0` off by 2x. |
| T7 | **Time constant.** Same run: `v(tj)` one `rth0*cth0 = 0.2 s` after the step lies between `(1-1/e) * rth0 * P_end` and `(1-1/e) * rth0 * P_0`. | Analytic bracket: [1.8663, 1.8776] K from `v_end = 0.7381253`, `v_0 = 0.7426000`; ngspice `1.872908`. End value `2.950924` against `rth0*P_end*(1-e^-7.5) = 2.9509`. | `ddt` term missing: `v(tj)` jumps to 2.97 K at once. |
| T8 | **External thermal network** (the existing golden). `regression/diode_self_heating.sp`, sha256 `77710cd509f4d8a12658d95a22cb643190c8f914b23e310b40901acdfd36abdc`, 45 rows. | ngspice 44.2, `ngspice -n -b -r reference.raw diode_self_heating.sp` (recorded in the `.expected.json`; rerun here, 135 iterations). Spot values: at 0.7 V `v(tj) = 51.00973874558`, `i(vtamb) = 0.2400973874558`; at 0.9 V `209.8822627373`, `1.828822627373`. `rtol = 1e-3`. | XFAIL to PASS when the `KNOWN GAP` line goes; XPASS if the line stays. |
| T9 | **Real decks.** `examples/soa/diode-soa-simple.sp` (sha256 `72cfcaa6...9237`) and `diode-soa-sh.sp` (`bca2793b...eb02`), 100 points each. | ngspice 44.2 goldens, generated with the same command as T8; reference `max v(tj) = 2026.583` and `2026.579` at 2 V, 247 and 251 Newton iterations. | These also need the SOA keys and `.save @d[id]`; they are the acceptance decks, not the first test. |
| T10 | **AC thermal pole.** `rth0=200 cth0=1e-3`, AC from 1 mHz to 1 kHz: `v(tj)/v1` is one pole, flat value `131.79097513`, corner where the thermal row's diagonal `1/rth0 - dP/dT` equals `omega*cth0`. | Analytic (flat value from ngspice, which is right at DC; the pole from the stamp). **Not** an ngspice 44.2/45 golden above the corner: they have no pole. | `ddt` term missing: flat at all frequencies, which is exactly ngspice's bug. |
| T11 | **Noise below the corner.** `cth0=1e-9` (corner near 0.8 MHz), noise at 1 Hz to 1 kHz. | ngspice 44.2 golden (valid there because `(f/f_th)^2 < 2e-6`); covers RS noise at the ambient and shot noise at the heated current. | RS noise at `tk` instead of `tamb`. |
| T12 | **Jacobian.** The existing finite-difference Jacobian check (`src/analysis/tests/jacobian.zig`) over `diode_t` including the `tj` column. | Certificate. | Any hand-written partial; there should be none. |
| T13 | **GPU.** `eval.zig`'s inventory and census tests pass with `diode_t` present and both name lists unchanged; T1, T2 and T8 repeated with `-- --backend cuda --jobs 1` give the host's bytes. | The host path (the standing rule). | A refusal for `diode_t` by name. |
| T14 | **Plain diode untouched.** Corpus raws for every deck without a thermal card are byte-identical before and after. | Round trip against the previous build. | Any edit outside `` `ifdef SELFHEATING ``. |

T1 to T7 are small decks with analytic or metamorphic oracles: put them in
`tests/conformance/tests/netlist/` with `"kind": "analytic"` expectations
(pattern: `ac/dec_lane_tail_17.expected.json`), or as unit tests beside
`src/tests/card_keys.zig` if a two-solve comparison does not fit the corpus
runner.

## 6. Risks

- **Newton on the thermal node without a limiter.** ngspice damps steps over
  100 K (`dioload.c:320-322`); this design does not (VerA gaps 1 and 2).
  What keeps it tame: the cold start is at the ambient `vcrit`, where the
  current is `vte/sqrt(2)` (about 20 mA, milliwatts); `pnjlim` bounds each
  voltage step; the thermal row is linear in `T`. ngspice needs 135
  iterations for the 45-point golden and about 2.5 per point on the SOA
  decks, so the problem is easy. If ESPice needs many more, or fails, on T8
  or T9, the fallback is in-model compression of the rise as Mextram does
  (`bjt505t.va:864-870`, `linLog` with `dtmax`). It needs no VerA feature
  and changes results only above `dtmax`; with the SOA decks at 2000 K that
  bound must be above 3000 K. A limiter on an internal thermal node is not
  an option: a 0 K short between it and `tj` collapses the node.
- **Thermal runaway.** `v(tj)` grows with `rth0 * dP/dT`; when the thermal
  row's diagonal `1/rth0 - dP/dT` reaches zero the operating point is a fold
  and no solver has an answer. ngspice fails there too. Do not add a clamp
  to hide it.
- **Convergence tolerance on `tj`.** The node is an ordinary voltage row,
  checked against `vntol` (1 microkelvin by default). ngspice does the same
  (the node is an external voltage node). No special handling.
- **Time step.** The thermal charge is out of the LTE (`vera_lte = 0`), as
  in ngspice; a thermal time constant far longer than the electrical ones
  does not shrink the step. The reverse holds too: a fast thermal network
  is integrated but not error-controlled. Parity, not a defect to fix here.
- **`.temp`, `dtemp`, `temp`.** The node is a rise above the *instance*
  ambient (T4). A deck that ties `tj` to a source at 27 "degrees"
  (`diode-soa-simple.sp`) is adding 27 K plus the heating to `.temp 100`;
  that is what ngspice computes and what the golden holds. Document it;
  do not reinterpret it.
- **Temperature sweeps and `.step temp`.** `tamb` comes from `$temperature`
  inside `eval`, so it follows any sweep. The plain diode's temperature map
  is hoisted out of the bias loop by VerA where it can be; in `diode_t` it
  cannot be (it depends on an unknown). That is the cost of the variant and
  the reason it is a variant.
- **Unphysical temperatures.** The SOA decks run the junction to 2400 K.
  `vj(T)` goes negative there; with `cjo > 0` the charge block
  (`diode.va:351-362`) then takes its continuation branch and stays finite
  unless `vj_t` is exactly 0. ngspice evaluates the same expressions in
  transient. No guard added; note it if a NaN gate trips.
- **Noise.** RS noise at the ambient and shot noise at the heated current
  match ngspice; the thermal feedback path in the AC matrix differs from
  44.2/45 above the thermal corner (T10, T11).
- **AC goldens.** Any future ngspice 44.2/45 AC or noise golden on a
  self-heated diode with `f` near or above `1/(2*pi*rth0*cth0)` will
  disagree, by ngspice's bug. Such a deck needs an analytic oracle.
- **Moving target.** ngspice master has changed the diode since 44.2
  (separate sidewall diode, soft recovery, `vtesw` at the ambient). The
  oracle is the 44.2 binary; where master and 44.2 differ, this document
  says which was followed.

## Open questions

1. Does VerA 0.23 accept `$limit` on a branch whose only node is a port,
   and does it accept solution-dependent limiter arguments? Neither is
   needed by the design; both would allow a `DEVlimitlog` twin later. Ask
   VerA for a `limitlog` built-in if T8/T9 show slow convergence.
2. Does `diode_t` land in the HB-sample refusal list
   (`eval.zig` census)? Expected no; known only after the first build.
3. Should a model-card `rth0` given through a parameter expression
   (`rth0={rth}`) count as "given, non-zero" in `heatsDiode`? `kvNumber`
   reads numbers; check what it returns for an expression that folds, and
   refuse (not ignore) one that does not.
4. VDMOS: which ngspice release first contains `b3594401c`, and is its
   binary available in the flake? That unblocks a VDMOS design.
5. Is `@d[p]` (ngspice's dissipated power, measured above) wanted as an
   operating-point variable? Not needed by any deck found.
