#!/bin/sh
# SpiceRack's `spice2rack --dialect D --to espice --kit -o DIR DECK`, faked
# for tests/test_correctness.zig (spicerack/include): writes a kit of two
# files into DIR, the entry and decoy.inc, the entry naming its include by
# its absolute path into DIR, as the contract requires. The run's working
# directory holds a different decoy.inc: a relative include would read it.
set -eu
out= deck= prev=
for arg; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg deck=$arg
done
[ -n "$out" ] || { echo "usage: spice2rack --dialect D --to espice --kit -o DIR DECK" >&2; exit 2; }
out=$(cd "$out" && pwd)
echo "r2 out 0 1k" >"$out/decoy.inc"
printf '* kit translation of %s\nv1 in 0 2\nr1 in out 1k\n.include %s/decoy.inc\n.op\n.end\n' "$deck" "$out" >"$out/deck.sp"
echo "$out/deck.sp"
