# The hot path as it is

Where one transient spends its time, which file owns each cost, and which
invariant binds any change to it. Line numbers are `dev/performance` at
`9bbd4d7f`. The measured shares are in [02-baseline.md](02-baseline.md).

## One step, one iteration

```text
Sim.begin            predict x (xfact), limit, publish SimState        tran/Sim.zig:253, tran/host_ops.zig:35
└ converger.newton   per iteration:                                   solver/converger.zig:282
   ├ hook.assemble   device pass -> planes g, c, rhs, q               tran/integrator.zig:304, analysis/Circuit.zig:599
   │   ├ serial      host_walks.stampRange -> batch.eval -> stamp.evalRange
   │   ├ ParEval     staged stamps + tape-order reduce (bitwise serial) analysis/par_eval.zig:431
   │   └ GPU         x up, one block of planes down                    analysis/gpu/context_eval.zig
   ├ companionAt     rhs += ag0*(q - q1) - history   (SIMD, O(n))      tran/integrator.zig:248
   ├ hook.vals       A = G + ag0*C               (SIMD, O(nnz))        analysis/Circuit.zig:788
   ├ slv.factor      skip if A bitwise unchanged, else replay          solver/direct.zig:265
   ├ slv.solveNeg    dx = -A^-1 F                                      solver/direct.zig:294
   └ finalizeStep    x += dx, gates; on accept x := x_old              solver/converger.zig:591, :354
Sim.end              q re-read at the solution, LTE bound, accept      tran/Sim.zig:309, tran/host_ops.zig:78
```

## Facts a change must respect

| Fact | Where | Consequence |
|---|---|---|
| Every iteration assembles every device, factors and solves. A factor is skipped only when all `nnz` values are bitwise equal to the last factor's. | `direct.zig:278` | A step that converges in k iterations pays k factors unless the circuit is linear and `dt` held. |
| Iteration 1 is never accepted (ngspice `niiter.c`). | `converger.zig:626` | Every step costs at least two assemblies and two solves, a linear circuit included. |
| On acceptance the engine publishes `x_k`, the last linearization point, and discards `x_k+1`. | `converger.zig:354`, `:650` (`updateStates(x_old)`) | The last factor and solve of every converged step produce a verdict and nothing else. Nine oracle decks fail when `x_k+1` is published instead ([the rule](07-prior-work.md#the-published-iterate-rule)). |
| The transient accepts on the per-row delta test and the device tests. The residual gate is off (`residual_tol = inf`). | `tran/Sim.zig:629` | An approximate Jacobian changes the accepted point, not only the path to it: nothing downstream checks `F(x)`. |
| The limiter's "old" value is the previous limited value, kept across steps. After an accept it was written at the discarded `x_k+1`. | `device/stamp.zig:267`, `batch_state.zig:146` | Anything that perturbs the discarded iterate can move the next step, but only where a limiter clamps. |
| Step control is ngspice `dctran.c` statement for statement: grow by at most 2x, LTE per charge state, cut by 8 on a Newton failure. | `tran/Sim.zig:309` | ESPice lands on ngspice's time grid. A lever that moves the grid is class *mode*. |
| `dt` changes on nearly every step, so `ag0` and every entry of `A` with a `C` part change with it. | `tran/integrator.zig:248` | The bitwise factor skip fires on linear decks at the step ceiling and almost nowhere else. |
| The device SIMD axis is the derivative: one instance per loop turn, its Jacobian row in `@Vector(W, f64)` dual lanes. | `device/stamp.zig:68`, `device/dual.zig` | AVX2's four f64 lanes are spent. A second axis over instances measured about 1.05x end to end ([closed](07-prior-work.md#closed-in-this-codebase)). |
| Instances are AoS rows (`D.Instance`), models a separate deduplicated table. | `device/batch.zig` | The bypass compares and copies the whole instance row. |
| The latency bypass never replays the first iterate of a step, compares every instance's unknowns and instance bytes on each later one, replays every recorded stamp and re-reads the charge exactly. It turns itself off for a batch that replays under one evaluation in five. | `device/batch_bypass.zig:165`, `:117` | A fully latent circuit still pays every instance on every iteration, and a two-iteration step can skip at most half its evaluations. |
| ParEval gives every stamp its own staging position, then sums every plane cell in tape order. Limiting and state updates run on the same lanes. | `analysis/par_eval.zig:65`, `:468`, `:565` | Bitwise the serial stamp at any lane count. Per pass it writes, reads and resets one f64 per stamp per plane: 2 to 4 times the planes themselves. |
| A query borrows at most 8 lanes, and only when its device weight is 4M or more (about 800 BSIM4 instances) or `nnz >= 50k`. | `analysis/exec_config.zig:114`, `executor.zig:578` | A lone transient uses at most 8 of this machine's 32 threads. |
| The refactor replay is a scalar scatter-axpy per source column (`dst[idx[p]] -= src[p] * f`), or a flat slot tape below 2,048 flops. The full factor has bitwise SIMD supernode panels; the replay does not. | `solver/lu_replay.zig:56`, `:174`, `:256`; `solver/lu_panel.zig:149` | A thick factor replays one multiply-subtract per load-load-store, whatever its structure. |
| Multicore refactor: subtree lanes with a pipelined tail, admitted per pivot epoch. | `solver/subtree.zig`, `direct.zig:511` | 1.7 to 2.6x per refactor at 8 lanes on the chains; thick factors take the ticketed kernel. |
| The GPU eval's floor is a round trip per iteration: `x` up, planes down, update and gates on the host. | `analysis/gpu/context.zig:6` | The GPU pays on device work per iteration, never on circuit size. |
| `auto` admits GPU lanes only when the card's FP64 rate is at least a quarter of FP32. | `docs/using/gpu.md` | Every consumer NVIDIA card (FP64 = FP32/64) is excluded. |
