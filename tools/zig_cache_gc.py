#!/usr/bin/env python3
"""Collects the shared Zig local cache (`.zig-cache`) down to a byte budget.

    python3 -I tools/zig_cache_gc.py --budget SIZE [--dry-run] [CACHE]

CACHE defaults to the main checkout's `.zig-cache`, the one every worktree
symlinks (AGENTS.md, Worktrees). Collection is stop-the-world: it refuses
while a `zig`, `maker` or `configurer` process has its cwd in any worktree of
this repository (`git worktree list`) or in the cache (Linux: it reads
/proc), and it stops at the first manifest a build holds locked. A dry run
deletes nothing, so it only warns about such a process.

It deletes, every manifest before any output, in this order:
1. garbage: all of `tmp/`, every manifest never finalized or not in the
   pinned format, and every `o/` or `c/` entry no manifest produces;
2. while over budget, least recently used first: a manifest together with
   the output it produces, or one `z/` (ZIR cache) file;
3. the final pass, on disk again: every manifest whose output is gone.
It never touches `h/timestamp`, the corpus runner's scratch (`correctness/`,
`metamorphic/`), `vera-check/`, `args/`, or anything outside the cache.

Invariant: no surviving manifest hits on a deleted output. It rests on these
facts of Zig 0.18.0-dev.349 (`~/.cache/zig-src-d924f83bf/`):
- A hit reports `o/<digest>` without checking that it exists: the build
  runner's Run step (lib/compiler/Maker/Step/Run.zig:571-577, :2024-2036)
  and the compiler (src/Compilation.zig:2818-2833). The consumer then fails
  with "checking cache failed: file_open FileNotFound".
- `<digest>` is SipHash128(1, 3) under `hasher_init`'s key over the
  manifest's own name (its input digest) and then each file digest the
  manifest records, in order (lib/std/Build/Cache.zig:130-141, :986-987,
  :2011-2027; record layout `File`, :439-457). So a manifest names its
  output exactly; `output_digest` recomputes it.
- A manifest is written only on a miss (`finalize`, Cache.zig:2029-2041). A
  hit, even one that re-hashed an input whose stat changed (a fresh
  checkout), leaves it untouched: `deinit` only closes it (:2126-2142). So
  its mtime is its last build. Its last use is its atime: every `check`
  reads it (:1076). Under relatime (Linux fs/inode.c,
  `relatime_need_update`) atime moves on the first read after a write and
  then at most once per 24 h, so among entries used within the last 24 h
  the order is first use, not last use. Those rank after every older entry;
  the summary warns when the budget reaches them.

Not covered: a build started during a collection, after the process check,
that rebuilds an output this run then deletes and finalizes its manifest
after the final pass. The final pass catches it when that build finished
first. Otherwise the repair is to rerun the collector once no build runs:
its final pass deletes every manifest whose output is gone.
"""
import argparse
import fcntl
import os
import shutil
import stat
import struct
import subprocess
import sys
import time
from collections import defaultdict
from typing import NamedTuple

# Processes that read or write a Zig local cache (the build runner is `maker`,
# src/main.zig:353; its configure step is `configurer`, Maker.zig:1200).
BUILD_COMMS = {"zig", "maker", "configurer"}
# `hasher_init`'s key (lib/std/Build/Cache.zig:135-140).
KEY = bytes.fromhex("02e9fafee0958155f55a15cb4af40009")
# A manifest record: size u64, inode u64, mtime i64, digest [16]u8, flags u8,
# then the path and one NUL (Cache.zig:439-457; `File` aligns to 1 byte).
DIGEST_AT, FILE_HEAD = 24, 41
# Reading a manifest must not refresh the atime that marks its last use.
NOATIME = getattr(os, "O_NOATIME", 0)
COLLECTED = {"h", "o", "c", "z", "tmp"}
# relatime moves an atime at most once per this many seconds.
DAY = 24 * 3600
# Last-use bands the summary sizes, to pick a budget from: (hours, label).
BANDS = ((1, "< 1 h"), (3, "1-3 h"), (12, "3-12 h"), (48, "12-48 h"), (float("inf"), "older"))


class Entry(NamedTuple):
    path: str
    bytes: int
    used: float = 0.0
    # A manifest's output digest; None for one never finalized or unreadable.
    out: str | None = None


class Busy(Exception):
    """A build holds a manifest lock. Raised before that manifest's output
    goes: every manifest is deleted before any output."""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cache", nargs="?", help="the cache directory (default: the main checkout's .zig-cache)")
    # ponytail: no default until the working set is measured on the relative-path build.zig.
    ap.add_argument("--budget", required=True, type=parse_bytes, help="bytes, or a number with K, M, G or T")
    ap.add_argument("--dry-run", action="store_true", help="print what would go; delete nothing")
    args = ap.parse_args(argv)
    cache = os.path.realpath(args.cache or default_cache())
    if not os.path.isdir(os.path.join(cache, "h")):
        sys.exit(f"zig-cache-gc: {cache} has no h/: not a Zig cache")
    busy = busy_builds(worktrees(os.path.dirname(cache)) + [cache])
    if busy:
        print("zig-cache-gc: a build is running; collect when none is:", *busy, sep="\n  ", file=sys.stderr)
        if not args.dry_run:
            return 2
    try:
        lines = collect(cache, args.budget, args.dry_run)
    except Busy as e:
        print(f"zig-cache-gc: a build holds {e}; stopped. Rerun once no build runs.", file=sys.stderr)
        return 2
    print("\n".join(lines))
    return 0


def collect(cache, budget, dry_run):
    """Collects `cache` as the header says; returns the summary lines."""
    manifests = scan_manifests(cache)
    outputs = {}
    for sub in ("o", "c"):
        for e in scan_dir(cache, sub):
            if is_digest(os.path.basename(e.path)):
                outputs[os.path.basename(e.path)] = e
    zir, tmp = scan_dir(cache, "z"), scan_dir(cache, "tmp")
    other = sum(du(os.path.join(cache, n)) for n in os.listdir(cache) if n not in COLLECTED)
    other += sum(du(os.path.join(cache, "h", n)) for n in os.listdir(os.path.join(cache, "h")) if not is_digest(n))
    finalized = [m for m in manifests if m.out is not None]
    if finalized and not any(m.out in outputs for m in finalized):
        sys.exit("zig-cache-gc: no manifest names an existing output; the manifest format differs from "
                 "Zig 0.18.0-dev.349's (Cache.zig:135, :439): update KEY and output_digest first")
    total = sum(e.bytes for e in manifests + list(outputs.values()) + zir + tmp) + other

    # 1. Garbage: nothing can hit these.
    producers = defaultdict(list)
    for m in finalized:
        if m.out in outputs:
            producers[m.out].append(m)
    unreadable = [m for m in manifests if m.out is None]
    orphans = [e for d, e in outputs.items() if d not in producers]
    left = total - sum(e.bytes for e in tmp + unreadable + orphans)

    # 2. Least recently used, a manifest always with its output.
    now = time.time()
    lru_manifests, lru_rest, lru_zir, lru_today = [], [], 0, 0
    candidates = [(max(m.used for m in ms), [outputs[d]], ms) for d, ms in producers.items()]
    candidates += [(z.used, [z], []) for z in zir]
    by_band = [0] * len(BANDS)
    for used, rest, ms in candidates:
        by_band[sum(now - used >= h * 3600 for h, _ in BANDS)] += sum(e.bytes for e in ms + rest)
    for used, rest, ms in sorted(candidates, key=lambda c: c[0]):
        if left <= budget:
            break
        lru_manifests += ms
        lru_rest += rest
        lru_zir += not ms
        size = sum(e.bytes for e in ms + rest)
        lru_today += size if now - used < DAY else 0
        left -= size

    gone = {e.path for e in unreadable + lru_manifests + orphans + lru_rest}
    if not dry_run:
        for m in unreadable + lru_manifests:
            remove_manifest(cache, m.path)
        for e in tmp + orphans + lru_rest:
            remove(cache, e.path)

    # 3. Final pass: a manifest whose output is gone would hit on nothing.
    if dry_run:
        kept = {d for d, e in outputs.items() if e.path not in gone}
        stale = [m for m in manifests if m.path not in gone and m.out not in kept]
    else:
        stale = [m for m in scan_manifests(cache) if not output_exists(cache, m.out)]
        for m in stale:
            remove_manifest(cache, m.path)

    verb = "would remove" if dry_run else "removed"
    lines = [
        f"zig-cache-gc: {cache}: {gb(total)} before, budget {gb(budget)}" + (" (dry run)" if dry_run else ""),
        "  pairs and z/ files by last use: " + ", ".join(f"{label} {gb(n)}" for (_, label), n in zip(BANDS, by_band)),
        f"  {verb} tmp/: {len(tmp)} entries, {gb(sum(e.bytes for e in tmp))}",
        f"  {verb} manifests never finalized or unreadable: {len(unreadable)}",
        f"  {verb} outputs no manifest produces: {len(orphans)}, {gb(sum(e.bytes for e in orphans))}",
        f"  {verb} least recently used: {len(lru_manifests)} manifests with {len(lru_rest) - lru_zir} outputs, "
        f"{lru_zir} z/ files, {gb(sum(e.bytes for e in lru_manifests + lru_rest))}",
    ]
    if lru_today:
        lines.append(f"  warning: budget below the last-24 h working set: {gb(lru_today)} of entries used within 24 h "
                     "evicted; relatime orders those by first use, not last use. Raise --budget.")
    return lines + [
        f"  {verb} manifests whose output is gone: {len(stale)}",
        f"  after: {gb(left - sum(m.bytes for m in stale))}, of which {gb(other)} is not collected",
    ]


def output_digest(name, data):
    """The `o/` (or `c/`) entry a hit on manifest `name`, whose bytes are
    `data`, reports. None for a manifest never finalized (empty) or not in
    the pinned format."""
    if not data:
        return None
    digests, off = [], 0
    while off + 1 < len(data):
        end = data.find(b"\0", off + FILE_HEAD)
        if end <= off + FILE_HEAD:
            return None
        digests.append(data[off + DIGEST_AT:off + DIGEST_AT + 16])
        off = end + 1
    if off + 1 != len(data) or data[off] != 0:
        return None
    return siphash128(KEY, bytes.fromhex(name) + b"".join(digests)).hex()


def siphash128(key, msg, c_rounds=1, d_rounds=3):
    """SipHash with 128-bit output, as lib/std/crypto/siphash.zig computes it
    (`SipHash128(c, d)`, little-endian `b1 | b2 << 64`)."""
    mask = (1 << 64) - 1

    def rounds(v, n):
        for _ in range(n):
            v[0] = (v[0] + v[1]) & mask; v[1] = rotl(v[1], 13) ^ v[0]; v[0] = rotl(v[0], 32)
            v[2] = (v[2] + v[3]) & mask; v[3] = rotl(v[3], 16) ^ v[2]
            v[0] = (v[0] + v[3]) & mask; v[3] = rotl(v[3], 21) ^ v[0]
            v[2] = (v[2] + v[1]) & mask; v[1] = rotl(v[1], 17) ^ v[2]; v[2] = rotl(v[2], 32)

    def rotl(x, b):
        return ((x << b) | (x >> (64 - b))) & mask

    k0, k1 = struct.unpack("<QQ", key)
    v = [k0 ^ 0x736F6D6570736575, k1 ^ 0x646F72616E646F6D ^ 0xEE, k0 ^ 0x6C7967656E657261, k1 ^ 0x7465646279746573]
    whole = len(msg) - len(msg) % 8
    last = msg[whole:] + bytes(7 - len(msg) % 8) + bytes([len(msg) & 0xFF])
    for block in [msg[i:i + 8] for i in range(0, whole, 8)] + [last]:
        (m,) = struct.unpack("<Q", block)
        v[3] ^= m
        rounds(v, c_rounds)
        v[0] ^= m
    v[2] ^= 0xEE
    rounds(v, d_rounds)
    b1 = v[0] ^ v[1] ^ v[2] ^ v[3]
    v[1] ^= 0xDD
    rounds(v, d_rounds)
    return struct.pack("<QQ", b1, v[0] ^ v[1] ^ v[2] ^ v[3])


def busy_builds(dirs):
    """`pid comm cwd` of every build process whose cwd is in one of `dirs`
    (real paths). Another user's processes are unreadable and cannot write
    this cache."""
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
            if comm not in BUILD_COMMS:
                continue
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if any(cwd == d or cwd.startswith(d + os.sep) for d in dirs):
            found.append(f"{pid} {comm} {cwd}")
    return found


def worktrees(repo):
    """Real paths of every worktree of the repository at `repo`, the main
    checkout first; `[repo]` when git cannot list them."""
    try:
        text = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"],
                              capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return [os.path.realpath(repo)]
    return [os.path.realpath(line[len("worktree "):]) for line in text.splitlines() if line.startswith("worktree ")]


def default_cache():
    checkout = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    return os.path.join(worktrees(checkout)[0], ".zig-cache")


def scan_manifests(cache):
    out = []
    h = os.path.join(cache, "h")
    for name in os.listdir(h):
        if not is_digest(name):
            continue
        path = os.path.join(h, name)
        st = os.lstat(path)  # before the read, which may touch atime where O_NOATIME is refused
        try:
            fd = os.open(path, os.O_RDONLY | NOATIME)
        except PermissionError:
            fd = os.open(path, os.O_RDONLY)
        with os.fdopen(fd, "rb") as f:
            data = f.read()
        out.append(Entry(path, st.st_blocks * 512, max(st.st_atime, st.st_mtime), output_digest(name, data)))
    return out


def scan_dir(cache, sub):
    d = os.path.join(cache, sub)
    if not os.path.isdir(d):
        return []
    out = []
    for name in os.listdir(d):
        path = os.path.join(d, name)
        st = os.lstat(path)
        out.append(Entry(path, du(path), max(st.st_atime, st.st_mtime)))
    return out


def du(path):
    """Bytes `path` holds on disk, directories walked, symlinks not followed."""
    total = os.lstat(path).st_blocks * 512
    if stat.S_ISDIR(os.lstat(path).st_mode):
        for root, dirs, files in os.walk(path):
            total += sum(os.lstat(os.path.join(root, n)).st_blocks * 512 for n in dirs + files)
    return total


def output_exists(cache, digest):
    return digest is not None and (os.path.isdir(os.path.join(cache, "o", digest)) or
                                   os.path.isfile(os.path.join(cache, "c", digest)))


def remove_manifest(cache, path):
    """Deletes the manifest at `path` under its own exclusive lock; raises
    `Busy` when a build holds it."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except FileNotFoundError:
        return
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Busy(path) from None
        remove(cache, path)
    finally:
        os.close(fd)


def remove(cache, path):
    """Deletes `path`, a file or a directory tree, after checking that it
    lies strictly inside `cache` (a real path)."""
    real = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
    if real == cache or os.path.commonpath([cache, real]) != cache:
        raise SystemExit(f"zig-cache-gc: refusing to delete {path}: not inside {cache}")
    if os.path.isdir(real) and not os.path.islink(real):
        shutil.rmtree(real)
    else:
        os.unlink(real)


def is_digest(name):
    return len(name) == 32 and all(c in "0123456789abcdef" for c in name)


def parse_bytes(text):
    units = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
    scale = units.get(text[-1:].upper())
    return int(float(text[:-1]) * scale) if scale else int(text)


def gb(n):
    return f"{n / (1 << 30):.1f} GB"


if __name__ == "__main__":
    sys.exit(main())
