#!/usr/bin/env bash
# Documentation that executes: every deck under docs/examples/ and every inline
# ```spice block in the docs (the bench reports excepted) must run to exit 0,
# with -r and in the CLI's default mode; so must every deck in ESPice's own
# language (docs/examples/*.esp, and each ```espice block that is a whole
# deck, its first line `.espice 1`; language.md's fragments are the lang
# tests' to check). An X.esp beside an X.sp is its twin: the same stdout and
# raw file, byte for byte (the deck's name and the raw file's Date aside).
# A page whose deck no longer runs fails here, before a reader finds it.
#   tools/doc_decks.sh zig-out/bin/espice
set -uo pipefail
exe=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export ESPICE_CACHE="$work/cache"
fail=0 total=0

# A Debug build reports a leak on stderr and still exits as it would:
# any such report fails the deck, whatever its exit code.
leaked() { grep -q 'leaked' "$work/log"; }

run() { # run LABEL DIR DECK [espice args...]
  local label=$1 dir=$2 deck=$3
  shift 3
  total=$((total + 1))
  if ! (cd "$dir" && timeout 300 "$exe" --backend cpu -b -r "$work/out.raw" "$@" "$deck" >"$work/log" 2>&1) || leaked; then
    fail=$((fail + 1))
    echo "FAIL $label"
    tail -5 "$work/log"
  fi
}

plain() { # plain LABEL DIR DECK: the CLI's default mode, no -r
  local label=$1 dir=$2 deck=$3
  total=$((total + 1))
  if ! (cd "$dir" && timeout 300 "$exe" --backend cpu "$deck" >"$work/log" 2>&1) || leaked; then
    fail=$((fail + 1))
    echo "FAIL $label (no -r)"
    tail -5 "$work/log"
  fi
}

twin() { # twin STEM: docs/examples/STEM.esp prints and writes what STEM.sp does
  local stem=$1 ext
  total=$((total + 1))
  for ext in sp esp; do
    (cd docs/examples && timeout 300 "$exe" --backend cpu -b -r "$work/$ext.raw" "$stem.$ext" 2>&1 | sed "s|$stem\.$ext|DECK|g") >"$work/$ext.out"
    grep -v '^Date:' "$work/$ext.raw" >"$work/$ext.rawd" 2>/dev/null
  done
  if ! cmp -s "$work/sp.out" "$work/esp.out" || ! cmp -s "$work/sp.rawd" "$work/esp.rawd"; then
    fail=$((fail + 1))
    echo "FAIL $stem.esp differs from $stem.sp"
    diff "$work/sp.out" "$work/esp.out" | head -5
    diff "$work/sp.rawd" "$work/esp.rawd" | head -5
  fi
}

# A deck in another dialect runs as `sprack translate`'s ngspice of it, as
# dialects.md says to run it; no sprack on PATH fails it, never skips it.
translated() { # translated FROM DECK
  total=$((total + 1))
  if ! (cd docs/examples && sprack translate --from "$1" --to ngspice "$2" >"$work/translated.sp" 2>"$work/log"); then
    fail=$((fail + 1))
    echo "FAIL $2: sprack translate --from $1"
    tail -5 "$work/log"
    return
  fi
  total=$((total - 1))
  run "docs/examples/$2 ($1)" docs/examples "$work/translated.sp"
}
for deck in docs/examples/*.sp docs/examples/*.esp; do
  [ "$deck" = docs/examples/hspice_alter.sp ] && continue
  run "$deck" docs/examples "$(basename "$deck")"
  plain "$deck" docs/examples "$(basename "$deck")"
done
for deck in docs/examples/*.esp; do
  stem=$(basename "$deck" .esp)
  [ -e "docs/examples/$stem.sp" ] && twin "$stem"
done
translated hspice hspice_alter.sp
translated spectre spectre_rc.scs

# Inline blocks; a block that is one `--8<--` include is an example run above.
while IFS= read -r page; do
  rm -f "$work"/block.*
  awk -v out="$work/block" '
    /^```spice/ { n++; f = out "." n; inb = 1; next }
    inb && /^```/ { inb = 0; next }
    inb { print > f }' "$page"
  for block in "$work"/block.*; do
    [ -e "$block" ] || continue
    grep -q -- '--8<--' "$block" && continue
    cp "$block" "$work/inline.sp"
    run "$page block ${block##*.}" "$work" inline.sp
  done
  # A whole deck in the language; language.md's fences are fragments.
  [ "$page" = docs/using/language.md ] && continue
  rm -f "$work"/eblock.*
  awk -v out="$work/eblock" '
    /^```espice/ { n++; f = out "." n; inb = 1; next }
    inb && /^```/ { inb = 0; next }
    inb { print > f }' "$page"
  for block in "$work"/eblock.*; do
    [ -e "$block" ] || continue
    head -1 "$block" | grep -qx '.espice 1' || continue
    cp "$block" "$work/inline.esp"
    run "$page espice block ${block##*.}" "$work" inline.esp
  done
done < <(find docs README.md -name '*.md' | sort)

# A deck read through a pipe or FIFO prints what the file prints (#234): the
# dialect check once drained the pipe and the run saw an empty deck.
# stdout and stderr both count; each run's deck path is replaced by DECK.
for deck in measure.sp; do
  total=$((total + 1))
  each() { (cd docs/examples && timeout 60 "$exe" --backend cpu "$1" <"$deck" 2>&1 | sed "s|$1|DECK|g"); }
  each "$deck" >"$work/file.out"
  each /dev/stdin >"$work/pipe.out"
  rm -f "$work/fifo" && mkfifo "$work/fifo"
  cat "docs/examples/$deck" >"$work/fifo" &
  each "$work/fifo" >"$work/fifo.out"
  wait
  if ! grep -q devices "$work/file.out" || ! cmp -s "$work/file.out" "$work/pipe.out" || ! cmp -s "$work/file.out" "$work/fifo.out"; then
    fail=$((fail + 1))
    echo "FAIL $deck through a pipe or FIFO"
    diff "$work/file.out" "$work/pipe.out" | head -5
  fi
done

# A refused deck says why once (docs/learn/first-circuit.md, exercise 3):
# one "no DC path" line and the Error line, with -r and without (the
# default mode once solved a warm operating point first and said it twice).
printf '.espice 1\n.title "Voltage divider"\nV1 (in 0)  vsource  10V\nR1 (in out) resistor 1k\nC1 (out x) capacitor 1nF\n.op\n' >"$work/float.esp"
for mode in plain raw; do
  total=$((total + 1))
  if [ "$mode" = raw ]; then set -- -r "$work/out.raw"; else set --; fi
  (cd "$work" && timeout 60 "$exe" --backend cpu "$@" float.esp >"$work/float.out" 2>&1)
  # Exactly the two lines: nothing else (a leak report, a second solve's line).
  if [ "$(wc -l <"$work/float.out")" != 2 ] || [ "$(grep -c 'no DC path' "$work/float.out")" != 1 ] || ! grep -qx 'Error: float.esp: FloatingNode' "$work/float.out"; then
    fail=$((fail + 1))
    echo "FAIL a floating node ($mode) is not refused with one line"
    cat "$work/float.out"
  fi
done

echo "doc decks: $((total - fail)) of $total run"
[ "$fail" -eq 0 ]
