#!/bin/sh
# SpiceRack's `spice2rack --dialect D --to espice --kit -o DIR DECK`, faked
# for tests/test_correctness.zig's file-kind checks (spicerack/touchstone,
# data, vec, load, soalimits, vpi, lin, hdl): DECK is <kind>.hsp, and the kit is the
# entry <kind>.sp plus the one file it reads, copied into DIR and named by
# its absolute path into DIR, as the contract requires of every file a deck
# reads. The run's working directory (tests/spicerack/) holds a decoy of
# the same name for each kind (net.s2p, rows.dat, stim.vec, state.ic0,
# limits.json, app.vpi, res.va): a reference that reached it would read it. `lin`
# reads nothing (1 file): its `.lin format=touchstone` writes a file that
# must land beside the -r output, not in the kit the CLI deletes.
set -eu
out= deck= prev=
for arg; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg deck=$arg
done
[ -n "$out" ] || { echo "usage: spice2rack --dialect D --to espice --kit -o DIR DECK" >&2; exit 2; }
out=$(cd "$out" && pwd)
kind=$(basename "$deck" .hsp)
entry="$out/$kind.sp"
case $kind in
touchstone)
  cp "$(dirname "$0")/../conformance/tests/netlist/hspice/s_element.assets/net.s2p" "$out/net.s2p"
  cat >"$entry" <<EOF
* kit translation of $deck: hspice/s_element.sp's network, DC only
v1 in 0 1
rs in p1 50
s1 p1 p2 mname=smod
rl p2 0 50
.model smod s tstonefile=$out/net.s2p
.op
.end
EOF
  ;;
data)
  echo 1k >"$out/rows.dat"
  cat >"$entry" <<EOF
* kit translation of $deck
.param rl=1
v1 in 0 2
r1 in out 1k
r2 out 0 rl
.data rows MER FILE='$out/rows.dat' rl=1
.enddata
.dc data=rows
.end
EOF
  ;;
vec)
  printf 'radix 1\nvname a\nio i\nvih 1\n0 1\n' >"$out/stim.vec"
  cat >"$entry" <<EOF
* kit translation of $deck
.vec '$out/stim.vec'
r1 a 0 1k
.tran 1n 10n
.end
EOF
  ;;
load)
  echo '.ic v(b)=0.25' >"$out/state.ic0"
  cat >"$entry" <<EOF
* kit translation of $deck
v1 a 0 1
r1 a b 1k
c1 b 0 1n
.load file='$out/state.ic0'
.tran 10n 100n uic
.end
EOF
  ;;
soalimits)
  echo '{"nch": {"vgs_max": 1.5}}' >"$out/limits.json"
  cat >"$entry" <<EOF
* kit translation of $deck
v1 d 0 1
v2 g 0 2
m1 d g 0 0 nch
.model nch nmos level=1
.option soa=1 soalimits="$out/limits.json"
.op
.end
EOF
  ;;
lin)
  # Reads no file: its .lin writes lin.s2p, which must outlive the kit.
  cat >"$entry" <<EOF
* kit translation of $deck
v1 a 0 dc 0 portnum 1 z0 50
r1 a b 50
r2 b 0 50
v2 b 0 dc 0 portnum 2 z0 50
.ac dec 1 1k 10k
.lin format=touchstone
.end
EOF
  ;;
vpi)
  echo 'the kit copy: no shared object' >"$out/app.vpi"
  cat >"$entry" <<EOF
* kit translation of $deck
.options vpi="$out/app.vpi"
i1 0 a 1m
r1 a 0 1k
.op
.end
EOF
  ;;
hdl)
  # A 1k Verilog-A resistor, compiled at run time; the decoy res.va is 3k.
  cat >"$out/res.va" <<'VA'
`include "disciplines.vams"
module kitres(p, n);
    inout p, n;
    electrical p, n;
    parameter real R = 1000.0 from (0:inf);
    analog I(p, n) <+ V(p, n) / R;
endmodule
VA
  cat >"$entry" <<EOF
* kit translation of $deck
.hdl "$out/res.va"
v1 in 0 2
r1 in out 1k
n1 out 0 kitres
.op
.end
EOF
  ;;
*) echo "files_spice2rack.sh: no kit for $kind" >&2; exit 2 ;;
esac
echo "$entry"
