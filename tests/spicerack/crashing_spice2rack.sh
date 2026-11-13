#!/bin/sh
# refusing_spice2rack.sh's refusal text, then a panic's exit 101, as
# spice2rack e2ad5d7 panics on an output directory it cannot make: a crash,
# not a refusal, whatever it printed first (tests/test_correctness.zig,
# spicerack/crashed).
"$(dirname "$0")/refusing_spice2rack.sh" "$@"
echo "thread 'main' panicked at src/bin/spice2rack.rs:279:35:" >&2
exit 101
