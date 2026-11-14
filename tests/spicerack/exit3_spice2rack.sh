#!/bin/sh
# Refuses every deck under SpiceRack's P8-324 contract: exit 3 for a
# refused input, a coded line on stderr and no `refused:` header, so only
# the exit says refusal (tests/test_correctness.zig, spicerack/refused_exit3).
for deck; do :; done
name=$(basename "$deck")
echo "${name%.*}:2:1: W0336 a construct no ngspice form expresses" >&2
echo "1 deck(s) failed" >&2
exit 3
