#!/bin/sh
# SpiceRack's `spice2rack --dialect D --to espice --kit -o DIR DECK`, faked
# for tests/test_correctness.zig (spicerack/translated): sleeps 0.2 s, then
# writes twin.sp beside this script into DIR as DECK's translation, prints
# that path as the only stdout line, and one note on stderr.
set -eu
out= deck= prev=
for arg; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg deck=$arg
done
[ -n "$out" ] || { echo "usage: spice2rack --dialect D --to espice --kit -o DIR DECK" >&2; exit 2; }
sleep 0.2
name=$(basename "$deck")
cp "$(dirname "$0")/twin.sp" "$out/${name%.*}.sp"
echo "note: fake spice2rack translated $name" >&2
echo "$out/${name%.*}.sp"
