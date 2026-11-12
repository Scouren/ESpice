#!/bin/sh
# Refuses every deck as SpiceRack refuses a construct: a coded note on
# stderr, exit 1 (tests/test_correctness.zig, spicerack/refused).
for deck; do :; done
echo "W0001: fake spice2rack refuses $(basename "$deck")" >&2
exit 1
