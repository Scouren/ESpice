#!/usr/bin/env python3
"""The oracles of a reader refactor that the corpus golden cannot be: its
decks reach few refusals, so a refactor can change an error path or a
message and leave every corpus dump identical (TESTING.md).

  mutants CORPUS DECKS OUT_LIST [K]
      K seeded one-edit mutants of every deck DECKS lists (paths under
      CORPUS, a scratch copy of the corpus), written beside each deck so
      its includes still resolve, as <stem>.mutN<ext>; OUT_LIST gets their
      names. Run `nldump --list OUT_LIST` built before the refactor and
      after it: the two reports are equal, byte for byte.

  literals BEFORE_ROOT AFTER_ROOT
      Every string literal of src/frontend (non-test files) in
      both trees, as multisets; prints `- Nx text` for one the refactor
      dropped and `+ Nx text` for one it added. A codemod that rewrote
      inside a log line or a key shows here. Imports and embeds are left out.

  --self-test
      The mutants are reproducible and each differs from its deck.

usage: python3 -I tools/reader_refactor.py mutants|literals|--self-test ...
"""
import random
import re
import sys
import tempfile
from collections import Counter
from pathlib import Path

JUNK = ['{', '}', ')', '(', '=', "'", '1e', '@x', '%3', ',', 'params:', '.if', '.endif', '.ends', '+', '0', 'v(', '{a+}', '.param', 'm=x', 'pwl(', 'agauss(1,2,3)']
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def mutant(lines, rng):
    """One edit of `lines` (a deck's lines; line 0 is its title): a field dropped, replaced by junk, added or
    swapped with its neighbour, a line cut short, doubled or removed. None when the deck has no card."""
    body = [i for i in range(1, len(lines)) if lines[i].strip() and not lines[i].lstrip().startswith('*')]
    if not body:
        return None
    out = list(lines)
    i = rng.choice(body)
    toks = out[i].split()
    kind = rng.randrange(7)
    if kind == 0 and len(toks) > 1:
        del toks[rng.randrange(len(toks))]
        out[i] = ' '.join(toks)
    elif kind == 1:
        toks[rng.randrange(len(toks))] = rng.choice(JUNK)
        out[i] = ' '.join(toks)
    elif kind == 2:
        toks.insert(rng.randrange(len(toks) + 1), rng.choice(JUNK))
        out[i] = ' '.join(toks)
    elif kind == 3:
        out[i] = out[i][:rng.randrange(1, max(2, len(out[i])))]
    elif kind == 4 and len(toks) > 2:
        j = rng.randrange(len(toks) - 1)
        toks[j], toks[j + 1] = toks[j + 1], toks[j]
        out[i] = ' '.join(toks)
    elif kind == 5:
        out.insert(i, out[i])
    else:
        del out[i]
    return out


def mutants(corpus, decks, out_list, k_max):
    names = []
    for rel in decks.read_text().split():
        src = corpus / rel
        try:
            lines = src.read_text(errors='surrogateescape').split('\n')
        except OSError:
            continue
        for k in range(k_max):
            # Seeded by the deck's name, so a mutant is the same on every run and machine.
            out = mutant(lines, random.Random('%s#%d' % (rel, k)))
            if out is None:
                break
            name = '%s.mut%d%s' % (rel[:len(rel) - len(src.suffix)], k, src.suffix)
            (corpus / name).write_text('\n'.join(out), errors='surrogateescape')
            names.append(name)
    out_list.write_text('\n'.join(names) + '\n')
    return names


def literals(root):
    found = Counter()
    for sub in ('src/frontend',):
        for p in sorted(Path(root, sub).rglob('*.zig')):
            if 'tests' in p.parts:
                continue
            for line in p.read_text().split('\n'):
                t = line.strip()
                if t.startswith('//'):
                    continue
                if t.startswith('\\\\'):
                    found[t] += 1
                    continue
                for m in LITERAL.finditer(line):
                    if '@import("' + m.group(1) in line or '@embedFile("' + m.group(1) in line:
                        continue
                    found[m.group(1)] += 1
    return found


def self_test():
    with tempfile.TemporaryDirectory() as d:
        corpus = Path(d)
        (corpus / 'a.sp').write_text('title\nr1 a b 1k\n* note\nv1 a 0 dc 1\n.op\n.end\n')
        (corpus / 'decks.txt').write_text('a.sp\nmissing.sp\n')
        first = mutants(corpus, corpus / 'decks.txt', corpus / 'm.txt', 5)
        texts = [(corpus / n).read_text() for n in first]
        assert first == ['a.mut%d.sp' % k for k in range(5)], first
        assert mutants(corpus, corpus / 'decks.txt', corpus / 'm.txt', 5) == first
        assert [(corpus / n).read_text() for n in first] == texts, 'a mutant changed between runs'
        assert all(t != (corpus / 'a.sp').read_text() for t in texts), 'a mutant equals its deck'
        (corpus / 'src/frontend').mkdir(parents=True)
        (corpus / 'src/frontend/x.zig').write_text('const a = @import("y.zig");\n// "no"\nconst s = "kept \\" one";\n')
        assert literals(corpus) == Counter({'kept \\" one': 1}), literals(corpus)
    print('ok')


def main(argv):
    if argv[1:] == ['--self-test']:
        return self_test()
    if len(argv) >= 5 and argv[1] == 'mutants':
        names = mutants(Path(argv[2]), Path(argv[3]), Path(argv[4]), int(argv[5]) if len(argv) > 5 else 3)
        print(len(names), 'mutants')
        return
    if len(argv) == 4 and argv[1] == 'literals':
        before, after = literals(argv[2]), literals(argv[3])
        for text, n in sorted((before - after).items()):
            print('- %dx %s' % (n, text))
        for text, n in sorted((after - before).items()):
            print('+ %dx %s' % (n, text))
        return
    sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
