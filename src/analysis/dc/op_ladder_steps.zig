//! `op_ladder.afterPlain`'s rungs 2 and 3 and its final Newton as a state
//! machine, so a driver that runs many lanes' Newtons at once (GPU lanes)
//! keeps each lane on its own rung. The machine owns no circuit and no x:
//! `next` says which Newton to run and how to set it up, `feed` takes its
//! outcome. A driver that applies every request with `converger.run` on one
//! circuit is `op_ladder`'s `gminStepping`, `sourceStepping` and final
//! Newton, solve for solve (the oracle in `tests/ladder_steps.zig`).
//! JFNK and OPtran (rungs 4 and 5) stay with the host's `op_ladder`.
//! In: the plain rung's outcome, then each solve's. Out: the requests and
//! the ladder's verdict.
//! Cites ngspice cktop.c dynamic_gmin and gillespie_src, as `op_ladder`.
//!
//! Contents:
//! - `pub const Rung = enum { gmin, clean, source, source_off, final, done }`
//! - `pub const XStart = enum { keep, cold, good }`
//! - `pub const Request = struct { ... }`
//! - `pub const Ladder = struct { init, next, feed }`

const std = @import("std");
const assert = std.debug.assert;
const converger = @import("solver").converger;
const op_ladder = @import("op_ladder.zig");
const GminStep = op_ladder.GminStep;

/// Where the machine stands. `done` holds the verdict in `Ladder.converged`.
pub const Rung = enum(u8) { gmin, clean, source, source_off, final, done };

/// What x a solve starts from: as the last solve left it, `op.coldStart`,
/// or the last good x the driver saved when `feed` said so.
pub const XStart = enum(u8) { keep, cold, good };

/// One Newton the driver runs. Before it: `x` from `x_start` (after
/// building the gmin stamps from the planes when `build_stamps`), then
/// `Circuit.setHomotopy(homotopy[0], homotopy[1])` with a rebuilt baseline
/// when `rebuild`, else a computed one; `source_off` keeps the homotopy
/// its `source` solve set and sets nothing (`homotopy` still names it, for
/// a driver that keeps it per lane). The Newton: `gmin`, the last built
/// stamps when `stamped`, every hold at `value * hold_scale`, `max_iter`
/// (null: itl1, as `converger.optionsFromTolerances`), `init_fix`. A
/// singular Jacobian feeds null; under `lenient` so does any numerical
/// failure.
pub const Request = struct {
    rung: Rung,
    x_start: XStart,
    build_stamps: bool,
    homotopy: [2]f64,
    rebuild: bool,
    gmin: f64,
    stamped: bool,
    hold_scale: f64,
    max_iter: ?u16,
    init_fix: bool,
    lenient: bool,
};

/// One lane's ladder. `steps` is the caller's, `op_ladder.ladder_solves_max`
/// long.
pub const Ladder = struct {
    tol: converger.Tolerances,
    steps: []GminStep,
    rung: Rung = .gmin,
    converged: bool = false,
    total: u16 = 0,
    solves: u32 = 0,
    x_start: XStart = .cold,
    build_stamps: bool = true,
    // Rung 2.
    factor: f64 = 10.0,
    good_gmin: f64 = 0,
    gmin_val: f64 = 0,
    have_good: bool = false,
    budget: u16 = 0,
    // Rung 3.
    lambda: f64 = 0,
    lambda_good: f64 = -1,
    delta: f64 = 0.25,
    off_i: u8 = 0,
    off_g: f64 = 0,

    /// The ladder after the plain rung (`plain` null: singular). Done at
    /// once when it converged.
    pub fn init(tol: converger.Tolerances, steps: []GminStep, plain: ?converger.Result) Ladder {
        assert(steps.len == op_ladder.ladder_solves_max);
        var self: Ladder = .{ .tol = tol, .steps = steps };
        if (plain) |p| {
            self.total = p.iterations;
            if (p.converged) {
                self.rung = .done;
                self.converged = true;
                return self;
            }
        }
        self.good_gmin = tol.gmin_start;
        self.gmin_val = self.good_gmin / self.factor;
        self.budget = converger.optionsFromTolerances(tol, tol.itl2).max_iter;
        return self;
    }

    /// The next Newton to run, null once `done`.
    pub fn next(self: *const Ladder) ?Request {
        const tol = self.tol;
        var r: Request = .{
            .rung = self.rung,
            .x_start = self.x_start,
            .build_stamps = false,
            .homotopy = .{ tol.gmin, 1.0 },
            .rebuild = false,
            .gmin = 0,
            .stamped = false,
            .hold_scale = 1.0,
            .max_iter = tol.itl2,
            .init_fix = false,
            .lenient = false,
        };
        switch (self.rung) {
            .done => return null,
            .gmin => {
                r.build_stamps = self.build_stamps;
                r.homotopy = .{ self.gmin_val, 1.0 };
                r.gmin = self.gmin_val;
                r.stamped = true;
                r.init_fix = !self.have_good;
            },
            .clean => {
                r.max_iter = null;
                r.lenient = true;
            },
            .source => {
                r.homotopy = .{ tol.gmin, self.lambda };
                r.rebuild = true;
                r.hold_scale = self.lambda;
                r.init_fix = self.lambda_good < 0;
            },
            .source_off => {
                // `sourceStepping` set the homotopy for lambda = 0; nothing
                // is rebuilt between its solves.
                r.build_stamps = self.build_stamps;
                r.homotopy = .{ tol.gmin, self.lambda };
                r.gmin = self.off_g;
                r.stamped = true;
                r.hold_scale = self.lambda;
                r.init_fix = self.off_i == 0;
            },
            .final => {
                r.rebuild = true;
                r.max_iter = null;
            },
        }
        return r;
    }

    /// The outcome of `next()`'s Newton (null: singular, or under `lenient`
    /// any numerical failure). True when the driver must save x, as it now
    /// stands, as the last good x.
    pub fn feed(self: *Ladder, result: ?converger.Result) bool {
        assert(self.rung != .done);
        const r = result orelse op_ladder.failed;
        self.total +|= r.iterations;
        self.x_start = .keep;
        self.build_stamps = false;
        return switch (self.rung) {
            .done => unreachable,
            .gmin => self.feedGmin(r, result == null),
            .clean => {
                if (r.converged) self.finish(true) else self.toSource();
                return false;
            },
            .source => {
                if (!r.converged and self.lambda_good < 0) {
                    self.rung = .source_off;
                    self.off_i = 0;
                    self.off_g = self.tol.gmin * 1e10;
                    self.x_start = .cold;
                    self.build_stamps = true;
                    // `sourcesOffGmin` with no gmin to step down to.
                    if (!(self.tol.gmin > 0)) return self.sourceAfter(false);
                    return false;
                }
                return self.sourceAfter(r.converged);
            },
            .source_off => {
                if (!r.converged) return self.sourceAfter(false);
                self.off_g /= 10;
                self.off_i += 1;
                if (self.off_i == 11) {
                    self.rung = .source;
                    return self.sourceAfter(true);
                }
                return false;
            },
            .final => {
                self.finish(r.converged);
                return false;
            },
        };
    }

    // ---- private ----

    fn feedGmin(self: *Ladder, r: converger.Result, refused: bool) bool {
        const tried = self.gmin_val;
        const gtarget = self.tol.gmin;
        var save = false;
        if (!r.converged) {
            if (self.factor < 1.00005) {
                self.toSource();
                return false;
            }
            self.factor = if (refused) @sqrt(self.factor) else @sqrt(@sqrt(self.factor));
            self.gmin_val = self.good_gmin / self.factor;
            self.x_start = if (self.have_good) .good else .cold;
        } else {
            if (self.gmin_val <= gtarget) {
                self.rung = .clean;
                return false;
            }
            save = true;
            self.have_good = true;
            self.good_gmin = self.gmin_val;
            self.factor = op_ladder.gminFactor(self.factor, r.iterations, self.budget);
            if (self.gmin_val < self.factor * gtarget) {
                self.factor = self.gmin_val / gtarget;
                self.gmin_val = gtarget;
            } else self.gmin_val /= self.factor;
        }
        self.steps[self.solves] = .{ .gmin = tried, .converged = r.converged };
        if (op_ladder.gminStalled(self.steps[0 .. self.solves + 1], self.tol.gmin_start, self.gmin_val)) {
            self.toSource();
            return save;
        }
        self.solves += 1;
        if (self.solves >= op_ladder.ladder_solves_max) self.toSource();
        return save;
    }

    /// `sourceStepping`'s step after a solve at `lambda` (or its
    /// sources-off retry) that `converged` or not.
    fn sourceAfter(self: *Ladder, converged: bool) bool {
        self.rung = .source;
        var save = false;
        if (converged) {
            if (self.lambda >= 1.0) return self.toFinal();
            self.lambda_good = self.lambda;
            save = true;
            self.delta *= 1.5;
            self.lambda = @min(self.lambda + self.delta, 1.0);
            self.x_start = .keep;
        } else {
            self.delta *= 0.5;
            if (self.delta < 1e-4 or self.lambda_good < 0.0) return self.toFinal();
            self.x_start = .good;
            self.lambda = @min(self.lambda_good + self.delta, 1.0);
        }
        self.solves += 1;
        if (self.solves >= op_ladder.ladder_solves_max) _ = self.toFinal();
        return save;
    }

    fn toSource(self: *Ladder) void {
        self.rung = .source;
        self.solves = 0;
        self.lambda = 0;
        self.lambda_good = -1;
        self.delta = 0.25;
        self.x_start = .cold;
    }

    fn toFinal(self: *Ladder) bool {
        self.rung = .final;
        self.x_start = .keep;
        return false;
    }

    fn finish(self: *Ladder, converged: bool) void {
        self.rung = .done;
        self.converged = converged;
    }
};
