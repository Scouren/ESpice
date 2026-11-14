#!/bin/sh
# Refuses every deck as spice2rack e2ad5d7 refuses a construct, its stderr
# in the measured form (invalid/hspice_brace_behavioural.sp): the refused
# file, its coded line, nothing written, exit 1 (tests/test_correctness.zig,
# spicerack/refused).
for deck; do :; done
name=$(basename "$deck")
echo "$deck: Espice refused:" >&2
echo "${name%.*}:2:1: W0001 a statement kept as another dialect's text" >&2
echo "$deck: nothing written: Espice refuses a file of the kit" >&2
echo "1 deck(s) failed" >&2
exit 1
