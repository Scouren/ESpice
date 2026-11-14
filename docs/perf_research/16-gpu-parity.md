# GPU parity: what is CPU-only today

The owner's rule of 2026-11-11: "lets not make anything cpu only,
everything should be gpu as well." A feature, a deck option or a lever
lands with its GPU form and a host-instantiation test against the host
loop, or with a written blocker; a host fallback is allowed only so that
nothing is silently ignored, and it is tracked here until it goes. GPU
code is verified only in a GPU session, so "written" and "checked on the
card" are reported apart.

This page is the inventory the rule is worked down from, read from the
code by the placement work's author and not yet traced by a run. Sizes
are estimates. The deck counts come from a search of the 958 corpus decks
for the card: they count decks that contain it, not decks that reach the
refusal. Two paths reach the card:

- **E (device evaluation):** the host runs Newton, the card evaluates the
  devices and, when admitted, factors. Every query that evaluates through
  `Circuit` can take it.
- **L (lanes):** the whole Newton and step loop runs on the card, many
  points at once.

Every built-in model already evaluates on the card
(`device/tests/eval.zig:1439` pins the list). What is CPU-only is the lane
loop's refusals, the operating point under `gpu_lanes`, and the
small-signal analyses that have no lane form.

## State

| Row | State |
|---|---|
| 4, `.options dv` | Clamp written in the lane kernels (`Bodies.clampUpdate`, the limit word's veto bit), host-instantiation tests bitwise against `converger.newton`; the three refusals go when the GPU session has run it on the card |
| 1, the operating point under `gpu_lanes` | Written behind `p1` (`price.opOnHost`): nothing is barred, `price.place` decides the device evaluation from the model rows and `lu_price` the device LU from the `lu` rows. The LU half is inert until `machine.lu_host_key` exists, and concurrent operating-point workers are each priced as if alone on the card. Unbuilt |
| 8, the census | Written: a comptime test compares, by name, the models the lanes refuse (23) and the models the HB samples refuse (63 of 86). Expected lists come from a scan of the generated sources, not yet from a run |
| 2, 3 | Written (wave 9). `uic` was already a host start before the lanes take over; the one gap was device step control's next breakpoint, which missed `Sim.uic_bp` (now in `LaneStep`). Hold rows (nodeset, `.ic`) and gmin stamps run in the lane Newton (`Bodies.loadExtras`, kernel `arp_lane_extras`), bitwise `converger.newton` per lane on the host instantiation; the operating-point lanes run the `.nodeset` step and the plain rung with holds on the card. Unbuilt |
| 2, 3, second half | Written (wave 10). The operating-point ladder runs on lanes: `dc/op_ladder_steps.zig` restates gmin stepping, source stepping, the sources-off rung and the final Newton as a state machine per lane, kept on the host, and each step's Newton runs on the card for every lane on it, with a per-lane `[gmin, hold scale]` plane. The source scale needs no contract change: it is the Model field `source_scale__` that the `set_homotopy` hook writes, so re-uploading each lane's Model rows carries it. A batch whose setup caches the homotopy knobs rewrites live Instance rows; a byte compare sends that lane to the host (a static flag in the contract would replace the compare, an owner's request). OPtran evaluates at t = 0 on lanes; a floating start with no holds still needs OPtran run as transient lanes. Oracle: `op_ladder` on a twin circuit, bitwise. Unbuilt |
| 7, snapshot | Written (wave 10). Gear 3 to 6 runs on the lanes under host step control: `Sim.end` keeps the order control and solves the coefficients per lane, the card forms the companion rows, the step bound at the order and both neighbours, and the accepted charge, each bitwise `integrator`'s on the host instantiation. A snapshot was one missing data move: the last accepted row's probes now reach the lane's `cur`. Refusals stay until the card run. Unbuilt |
| 12, HB samples | Written (wave 10), with the premise corrected: the host oracle (`mhb_newton.sample`) only evaluates, so running limit or state kernels per sample lane would move latches the evaluation reads and break parity. The lift is the refusal: `lanes_samples.refusal` applies the lanes' census rule, so the 23 census models stay out and `mos1`, `bsim4va` and every other model with device kernels sample on the card. It also fixes a gap the old refusal hid: a batch that ran a state pass evaluates with `analog_initial` false on the host, and the sample lanes now get their own per-lane `SimState` for it. Unbuilt |
| 9, coupled inductors | Written (wave 10), with the premise corrected: the cross terms were already ordinary charge stamps; the gap was the truncation error, where a K card makes the host's states the charge tape with the inductor spans zeroed plus q at the branch rows. A new kernel `arp_lane_lte_fix` sets each lane's ring slot that way after every charge pass. Without a K card nothing new launches. Unbuilt |
| `g3` | Its deletion is a held patch, applied after the card measurement above |
| 5, 8 | Need a state kernel from VerA for `.history` and delay history (20 models), so the contract change is the owner's to request |
| small-signal (`tf`, `sens`, `pz`, `disto`) | Not started. `tf` and `sens` are solves of the linearized system, which the device LU can take once the price model admits it; `pz` needs an eigenvalue or rooting kernel. Whether a lone small solve pays on the card is the price model's verdict, but the path must exist |
| the rest | Not started; each needs a census of what it is worth first |

## 1. Refusals, most valuable first

| # | Site | Reason string | Lift | Size [est] | Worth |
|---|---|---|---|---|---|
| 1 | `executor.zig:551`, `:572` | (none) Under `gpu_lanes`, the OP gets no device eval and no device LU | Let the OP, or OP lanes, keep E and the device LU. G3 does the reverse (OP pivot epochs stay on host) | 10 lines, 1 file | Every OP of a lane deck: 121 `.dc`, 130 `.ac` |
| 2 | `dc/op_lanes.zig:111`, `dc/dc.zig:193` | "nodesets, holds or a floating start" | Lane kernels take `force` rows and gmin stamps (`lanes_newton.zig:39` asserts both empty; `lanes_step.zig:114` also asserts `!init_fix`). Needs a force-row and diagonal-stamp kernel, plus the source-stepping ladder on lanes | 300 lines, 3 files | 6 `.nodeset`, 17 `.ic`; floating start (`needs_tran_op`) not counted |
| 3 | `tran/gpu_drive.zig:229` | "uic, snapshot, OPtran or tangents" | uic: start from `x0` with `init_fix` on lanes, kernel bit already wired (`lanes_newton.zig:47`). Snapshot: a data move. Tangents: Gear-2 charge-history lanes | uic 50 lines; tangents 400 lines | 23 `uic`, 2 optran; tangents also host-only in `optimizer.zig:51` (`backend == .cpu`) |
| 4 | `gpu_drive.zig:232`, `op_lanes.zig:115`, `dc.zig:193` | "a Newton voltage bound (dv)" | `NewtonOpts.dv` already reaches the kernels (`lanes_newton.zig:76`). Only the update kernel's clamp is missing; check it, then delete the three refusals | 30 lines, 4 files | 0 decks set `dv`. Cheap, and it fixes a refusal added today |
| 5 | `gpu_drive.zig:234` | "a delay line" (`minDelay`) | Device delay-line history: a ring buffer per instance on the card. `commit_state` covers `absdelay` (`traits.hasAbsdelayState`) | 400 lines, VerA contract field | 14 decks with T lines (ideal tline) |
| 6 | `gpu_drive.zig:233`, `lanes.zig:464`, `lanes_samples.zig:81` | "VPI, display tasks or a load check" | Display: per-lane device printf buffer → host. VPI: host by nature (calls user code), so lanes must stop at each VPI call. Load check: hfet1 only (`traits.zig:80`) | display 200; VPI won't lift; hfet1 100 | 46 HDL decks (some VPI); hfet1 decks unknown |
| 7 | `gpu_drive.zig:230` | "gear-3..6" | Lane integrator coefficients and history planes for orders 3 to 6 | 200 lines, 2 kernels | 1 deck (`maxord` 3+); 49 use gear, defaulting to order 2, which lanes |
| 8 | `gpu_drive.zig:239-252`, `lanes.zig:467-472`, `lanes_samples.zig:86` | Hook list: no device payload, commit_state, predict_first_iterate (hfet1, `traits.zig:110`), check_convergence or advance_iteration (no built-in, per the inventory test `device/tests/eval.zig:1439`), host-stepped (`.history` state, no lim kernel) | Host-stepped needs a state kernel per model. VerA contract: emit `updateState` for `.history`. The predictor is a small kernel | VerA plus 100 lines | Host-stepped models unknown: no census of `gpuHostStepped` per model. Ask VerA for that list |
| 9 | `gpu_drive.zig:248`, `lanes.zig:471` | "coupled inductors" (`kinduc`) | Treat kinduc's cross terms as an ordinary stamp; it is linear | 100 lines | 3 decks |
| 10 | `gpu_drive.zig:235` | "no charge tape" | Data: build the q tape. `knobs.no_qtape` is a debug knob | small | Only under the knob |
| 11 | `gpu/periodic.zig:220` | `UnsupportedPeriodicPreconditioner` (a factor without a held tape) | Device preconditioner from the plain factor (upload L/U) | 150 lines | PSS and MHB decks whose factor has no held tape: unknown |
| 12 | `lanes_samples.zig:81-88` | `UnsupportedSampleState` (HB samples: `has_state_q`, delay, any state hook) | Same lifts as rows 5 and 8 | shared | 33 `.hb` decks: share unknown |
| 13 | `gpu/context.zig:410`, `:464`; `context_batch.zig:160-167` | `CircuitNotEligible` (no eligible batch); `ImageNotCompiled` (cold image of 1 MiB+ under `auto`) | Not eligible: nothing to lift, every built-in is eligible (inventory test). Cold image: under `p1` a model row is the marker; or a background JIT | done under p1 | Tiny R/V decks: correct by price, not a gap |
| 14 | `context_batch.zig:157` | "no kernel image in this build" | A runtime `.hdl` image does load (`hdl.runtimeImage`). Only a model built without images hits this | build | Unknown |
| 15 | `espice/config.zig:131` | `EmirNeedsCpu` (`--emir`) | Current and EM density per instance from device planes: a reduce kernel | 200 lines | EMIR users only |
| 16 | `session_sched.zig:240` | The `gpu_share` split sends a share of lanes to the CPU on purpose | Policy, not a gap | — | — |
| 17 | `gpu/lu.zig:571` `admits` and `executor.zig:589` `gpu_lu_min_n` | Device LU refused under 10k unknowns or the flop bars | Lever-step 4: rent-or-buy from the `lu` rows | 08-placement step 4 | Every deck under 10k unknowns |
| 18 | `price.zig` (`p1`) and `context_cost.admit` | A batch with no model row, and history lines, stay on the host by design (q. 6) | Calibrate the history lines; `price.zig` does the rest | calibrate | txl_wide_batch_1000: GPU measured 1.9x faster |

### What the census sizes (rows 8 and 12)

The lanes refuse 23 built-in models, in four groups:

| Group | Models | Lift |
|---|---|---|
| Delay lines (9) | `coupled_tlines`, `lossy_tline`, `tline`, `vccs_delay`, `vcvs_delay`, `wline_1` to `wline_4` | VerA marks the delay history and emits its state kernel; a ring per instance on the card (row 5) |
| `.history` operators (11) | `ltra`, `sparam_1` to `sparam_4`, `vccs_laplace`, `vcvs_laplace`, `vccs_pole`, `vcvs_pole`, `cswitch`, `vswitch` | A state kernel VerA emits for `.history` (`updateState`, `stateCtl` on the device); lane step control reads their breakpoints |
| `bound_step` only (2) | `mosvar`, `r3_cmc` | The same kernel, trivial here, and a per-lane `$bound_step` in lane step control |
| `hfet1` | | A small predictor kernel and a load-check row kernel; no VerA change |

`kinduc` is refused by type name and is row 9. The HB samples refuse 63
of the 86 models, among them models that already have state kernels
(`mos1` to `mos9`, `bsim4va`, `hisim2_va`, `psp104`): row 12 is one
structural change in `lanes_samples` (run the limit and state kernels per
sample lane) and not a set of per-model lifts.

Lever `g3` holds every operating-point pivot epoch on the host for 16
refactors, a number that was never measured. Under `p1` the rent rule
replaces it: an epoch moves once `age * (h - d)` covers the margin times
the table build (plus the driver start when it is down), with `h`, `d`
and the build read from the two `lu` rows nearest the epoch's fill. On
the fixture numbers for `logic_bsim4_10k` (29 ms on the host at 8 lanes,
15.1 ms on the device, 0.48 s to build) the break-even is 114 refactors
with the driver up. The card measurement that decides is refactors per
operating-point epoch against the calibrated build time on the three
thick 10k decks: if every epoch dies first, the rent rule keeps them on
the host anyway and `g3` is deleted; if one outlives it, `g3`'s 16 moved
it at the wrong age.

## 2. Analyses on the card today

| Analysis | Device eval (E) | Lanes (L) | CPU only |
|---|---|---|---|
| op | yes, unless `gpu_lanes` (row 1) | `gpu_static` OP lanes (`op_lanes.zig`) | gmin and source stepping; nodeset or ic holds |
| dc | yes | static lanes (`dc.zig:193`) | as op |
| tran, four, fft | yes, plus device LU | `gpu_drive.zig` | rows 3-10 |
| ac, noise, sp, stb, lstb, acxf | OP only | frequency lanes (`exec_config.zig:210`, `gpu/freq.zig`) | — |
| pss | yes | `pss.runGpuLanes`, `gpu/periodic.zig` | row 11 |
| hb, mhb | yes | `hb.runGpuLanes` (samples), `mhb_gpu.zig` | row 12 |
| envelope, qpss, pnoise, pac, pxf, tran_noise, matex | E inside their transient or OP | none found | lane forms |
| tf, pz, sens, dcmatch, acmatch, disto, sens sweeps, mc and temp sweeps | OP only | none (mc and temp run point by point) | small-signal solves (`pz` 26 decks, `tf` 18, `sens` 10) |

## 3. Levers of this branch

Read from the lever names and the 04/05 briefs; not traced into each implementation. C2, C5 and N6 are rejected and deleted ([13](13-implementation.md)); their rows stay for the twin they name. N2, N4, N9, G8 and G9 were never built and lost their bits on 2026-11-11 ([18](18-lever-verdicts.md)); their rows keep the brief's name in capitals.

| Bit | On the GPU path? | GPU twin |
|---|---|---|
| c1 refactor supernode panels | Host LU only | g2 |
| c3 linear circuits: one confirm per factor | Host Newton, which also drives E queries, so E gains. Not in the lane kernels | Lane-kernel confirm: none yet |
| c4 bypass (`c4h` is its measurement bit) | E evaluates every instance | Per-instance bypass mask in the eval kernel: none |
| c5 solve and update at lane scale (deleted) | CPU lanes | G8 (lane kernels) |
| c6 lanes past 8 | Host-only by construction (threads) | — |
| c7 reduce pass forms A | ParEval host reduce | Device reduce that forms A: none |
| c8 reorder on pivot drift (its rung budget and cycle watch are deleted) | Host LU, also used under E | Lanes: none traced |
| n1 dense tail tiled | Host LU | g7 |
| N2 FMA in LU kernels (no bit) | Host | Device FMA would break host-bitwise device LU: by construction, no twin |
| n3 one charge eval per step | Host step loop, so E gains | Lane loop: none |
| N4 transcendentals (no bit; Gompute's) | Host SIMD math | Device uses its own: no twin needed |
| n6 charge and limit latency (deleted) | Host | Lane tick fusion (G8) |
| n7 step bookkeeping | Host step loop (E) | Lane step control (`lanes_step.zig`): none |
| n8 lane-affine staging | ParEval | — |
| N9 OP full factors per lane (no bit) | CPU lanes | g1 batched dense LU |
| g1, g2, g7; G8 and G9 (no bit) | GPU | — |
| g3 OP epochs stay on host | Host-only by design | Conflicts with the new rule: replace with p1 step 4's rent-or-buy |
| p1 | Placement | Explicit `cuda` ignores it |

## 4. Options the host honours and the card ignores or refuses

- `.options dv`: refused on L (row 4) until the written kernel clamp has run on the card.
- gmin stepping stamps, `force` (nodeset, ic), `init_fix` on the step path: asserted absent on L (row 2). Source stepping: host ladder only.
- `itl*`: L uses `max_iter` (`lanes_newton.zig:87`). Whether `itl4` vs `itl1` reach the same field: not traced.
- Tolerances: reltol, abstol, vntol, gmin and residual_tol reach L (`lanes_newton.zig:76`). chgtol and trtol in lane step control: not traced.
- Limiting hooks: covered by device lim kernels; host-stepped models refuse (row 8). Bypass (c4): host only.
- Tangents for the optimizer: `backend == .cpu` only (`espice/optimizer.zig:51`).

## First five, and why

1. **Row 4 (`dv`)**: smallest lift, deletes a refusal added today, and the kernel already receives the value.
2. **Row 1 (OP under `gpu_lanes`)**: one condition. Every lane deck's OP gets device eval and LU back.
3. **Row 3 (uic)**: 23 decks, and the `init_fix` bit is already wired in the lane Newton.
4. **Row 2 (force rows and gmin stamps on lanes)**: unlocks nodesets, ic holds and OP gmin stepping on L in one kernel, and is the base for row 3's OPtran.
5. **Row 8 census, then the VerA state kernel**: no one knows which models are host-stepped. One comptime census test (as in `device/tests/eval.zig:1439`) sizes rows 8 and 12 before any kernel work.
