"""zig_cache_gc on a fake cache: after a collection no manifest names a
deleted output, the least recently used pairs go first, and a running build
stops it. The digest it finds outputs by is checked against SipHash's
reference vectors and a manifest from a real cache.

    python3 -I -m unittest discover -s tools -p 'test_zig_cache_gc*.py'
"""
import fcntl
import os
import shutil
import subprocess
import tempfile
import time
import unittest

import zig_cache_gc as gc

HOUR = 3600.0


class Digest(unittest.TestCase):
    def test_siphash128_reference_vectors(self):
        # veorq/SipHash vectors.h `vectors_sip128`, as Zig copies them
        # (lib/std/crypto/siphash.zig:328-405): key 00..0f, message 00..len-1.
        key = bytes(range(16))
        for length, want in [(0, "a3817f04ba25a8e66df67214c7550293"), (7, "a1f1ebbed8dbc153c0b84aa61ff08239"),
                             (8, "3b62a9ba6258f5610f83e264f31497b4"), (16, "6ee2a4ca67b054bbfd3315bf85230577")]:
            self.assertEqual(gc.siphash128(key, bytes(range(length)), 2, 4).hex(), want)

    def test_output_digest_of_a_real_manifest(self):
        # h/00196575bee629ffd1d3768116b80c3a (1 byte: no files) and
        # o/02293408cb008267ceeacf971dd7b8c8 sat side by side in ESPice's
        # .zig-cache on 2026-11-11 (Zig 0.18.0-dev.349); 764 of its 780
        # non-empty manifests named an existing o/ entry this way.
        self.assertEqual(gc.output_digest("00196575bee629ffd1d3768116b80c3a", b"\0"), "02293408cb008267ceeacf971dd7b8c8")
        self.assertIsNone(gc.output_digest("00196575bee629ffd1d3768116b80c3a", b""))
        self.assertIsNone(gc.output_digest("00196575bee629ffd1d3768116b80c3a", b"\1\0"))


class Collect(unittest.TestCase):
    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.cache = os.path.join(self.root, ".zig-cache")
        for sub in ("h", "o", "z", "tmp", "metamorphic"):
            os.makedirs(os.path.join(self.cache, sub))
        self.now = time.time()
        self.serial = 0

    def write(self, sub, data, age_h, used_h=None):
        path = os.path.join(self.cache, sub)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        used = age_h if used_h is None else used_h
        os.utime(path, (self.now - used * HOUR, self.now - age_h * HOUR))
        return path

    def manifest(self, inputs, age_h, used_h=None):
        """A finalized manifest recording `inputs` (cache-relative paths);
        returns (its path, the output digest a hit on it reports)."""
        self.serial += 1
        name = f"{self.serial:032x}"
        data = b"".join(bytes(24) + bytes([self.serial]) * 16 + bytes([2 << 2]) + p.encode() + b"\0" for p in inputs) + b"\0"
        return self.write(f"h/{name}", data, age_h, used_h), gc.output_digest(name, data)

    def output(self, digest, age_h, kib=256):
        # Random bytes: a compressing file system would shrink zeros.
        path = self.write(f"o/{digest}/out", os.urandom(kib << 10), age_h)
        os.utime(os.path.dirname(path), (self.now - age_h * HOUR,) * 2)
        return os.path.dirname(path)

    def pair(self, age_h, used_h=None):
        m, d = self.manifest(["src/main.zig"], age_h, used_h)
        return m, self.output(d, age_h)

    def tree(self):
        return sorted(os.path.relpath(os.path.join(r, n), self.cache) for r, ds, fs in os.walk(self.cache) for n in ds + fs)

    def assert_invariant(self):
        """No surviving manifest hits on a missing output."""
        for name in os.listdir(os.path.join(self.cache, "h")):
            if gc.is_digest(name):
                with open(os.path.join(self.cache, "h", name), "rb") as f:
                    out = gc.output_digest(name, f.read())
                self.assertTrue(gc.output_exists(self.cache, out), f"h/{name} names missing o/{out}")

    def test_collects_to_budget_and_keeps_the_invariant(self):
        old = self.pair(30)
        unused = self.pair(10)
        # A hit after a fresh checkout re-hashes its inputs and leaves the
        # manifest as it was (Cache.zig:2126): an old mtime, a recent atime.
        hot = self.pair(30, used_h=1)
        # A miss in another worktree rewrote this manifest to a new output;
        # the old output stays behind with no manifest.
        rewritten = self.pair(2)
        replaced = self.output("e" * 32, 20)
        # Its output deleted by hand, before this collector existed.
        dangling, _ = self.manifest(["src/core/root.zig"], 3)
        # A test run: no output of its own, its input the hot pair's binary.
        test_run, _ = self.manifest([f"o/{os.path.basename(hot[1])}/out"], 1)
        unfinalized = self.write("h/" + "f" * 32, b"", 1)
        zir = self.write("z/" + "a" * 32, os.urandom(256 << 10), 5)
        junk = self.write("tmp/0123456789abcdef", os.urandom(64 << 10), 40)
        kept = [self.write("h/timestamp", b"", 1), self.write("metamorphic/scratch", b"x", 50)]
        survivors = [*hot, *rewritten, zir, *kept]
        budget = sum(gc.du(p) for p in survivors) + (64 << 10)

        before = self.tree()
        gc.collect(self.cache, budget, dry_run=True)
        self.assertEqual(self.tree(), before)

        # A build holding a manifest stops the collection before any output goes.
        with open(old[0], "rb") as held:
            fcntl.flock(held, fcntl.LOCK_SH)
            with self.assertRaises(gc.Busy):
                gc.collect(self.cache, budget, dry_run=False)
        for d in (old[1], unused[1], replaced):
            self.assertTrue(os.path.isdir(d))

        gc.collect(self.cache, budget, dry_run=False)
        self.assert_invariant()
        for p in survivors:
            self.assertTrue(os.path.exists(p), p)
        for p in (*old, *unused, replaced, dangling, test_run, unfinalized, junk):
            self.assertFalse(os.path.exists(p), p)

    def test_warns_when_the_budget_reaches_entries_used_today(self):
        # relatime moves atime at most once a day: a pair first used 20 h ago
        # may have been hit a minute ago, so evicting it is worth a warning.
        self.pair(30)
        today = self.pair(30, used_h=20)
        fits = sum(gc.du(p) for p in today) + (64 << 10)

        def warnings(budget):
            return [line for line in gc.collect(self.cache, budget, dry_run=True) if "within 24 h" in line]

        self.assertEqual(warnings(fits), [])
        self.assertEqual(len(warnings(0)), 1)

    def test_refuses_while_a_zig_process_runs_in_a_worktree(self):
        # The kernel names a script's process after the script file (`zig`).
        # A copy of `sleep` is no fake: NixOS's multi-call coreutils comes up
        # as `sleep` whatever the file is called. `read` blocks without a child.
        zig = os.path.join(self.root, "zig")
        with open(zig, "w") as f:
            f.write("#!/bin/sh\nread -r line\n")
        os.chmod(zig, 0o755)
        proc = subprocess.Popen([zig], cwd=self.cache, stdin=subprocess.PIPE)
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        for _ in range(100):  # until the exec has renamed the process
            with open(f"/proc/{proc.pid}/comm") as f:
                if f.read().strip() == "zig":
                    break
            time.sleep(0.01)
        self.assertTrue(any(line.startswith(f"{proc.pid} zig ") for line in gc.busy_builds([self.root])))
        self.assertFalse(gc.busy_builds([os.path.join(self.root, "elsewhere")]))


if __name__ == "__main__":
    unittest.main()
