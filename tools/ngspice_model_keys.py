"""Write src/frontend/Circuit/ngspice_model_keys.tsv: per ESPice model, every key an
ngspice `.model` card of that device sets, with the value at which ngspice
computes what it computes with the key absent, whether only noise reads it,
and ngspice's description of it.

ngspice takes a model-card key from the device's model IFparm table, and
from its instance table as an instance default (inpgmod.c:131-160). Only
entries that set (IOP*, IP*, and jfet2's PARAM* X-macros) count; OP* are
read-only. The keys are lowercased, as ngspice matches them and as the
card reader hands them over.

Inert value: the literal `if (!X->fGiven) X->f = <literal>;` sets, when no
other code reads the Given flag. Then a card giving that literal leaves the
model struct exactly as an absent key does. A flag read anywhere else
(bjttemp.c reads ibe's) means a given key changes the answer even at the
default, so the key has no inert value here.

Inert at any value (`*`, REVIEWED only): ngspice's numbers do not depend
on the key (nothing reads it, only a SOA warning does, or only self-heating
behind a thermal node or flag the builder refuses), or the builder applies
it itself.

Noise only: every read of the field, past its setter, getter and default,
is in a *noi*.c file. A field read anywhere else (temp, load) is not.

A model several ngspice directories implement (BSIM3, BSIM4 and HiSIM_HV by
VERSION) takes the union of keys; an inert value or noise-only verdict holds
only when every directory with the key agrees.

usage: python3 -I tools/ngspice_model_keys.py <ngspice-src-root> <out.tsv>
  e.g. the ngspice-45 release tarball unpacked: <root>/src/spicelib/devices
"""
import hashlib
import os
import re
import sys

# ESPice catalog model -> the ngspice device directories behind its
# LEVELs (spice.zig's tables, inpdomod.c).
MAP = {
    "gummel_poon": ["bjt"],
    "vbic13_4t": ["vbic"],
    "hicumL2_va": ["hicum2"],
    "diode": ["dio"], "diode_t": ["dio"],
    "mos1": ["mos1"], "mos2": ["mos2"], "mos3": ["mos3"], "mos6": ["mos6"], "mos9": ["mos9"],
    "bsim1": ["bsim1"], "bsim2": ["bsim2"],
    "bsim3": ["bsim3", "bsim3v0", "bsim3v1", "bsim3v32"],
    "bsim4va": ["bsim4", "bsim4v5", "bsim4v6", "bsim4v7"],
    "bsimsoi_va": ["bsimsoi"],
    "b3soifd": ["bsim3soi_fd"], "b3soidd": ["bsim3soi_dd"],
    "hisim2_va": ["hisim2"],
    "hisimhv_va": ["hisimhv1", "hisimhv2"],
    "jfet": ["jfet"], "jfet2": ["jfet2"],
    "mes": ["mes"], "mesa": ["mesa"], "hfet1": ["hfet1"], "hfet2": ["hfet2"],
    "vdmos": ["vdmos"],
    "resistor": ["res"], "capacitor": ["cap"], "inductor": ["ind"],
}

# Verdicts read off the source where the rules above are too coarse, each
# with the lines that justify it: (model, key) -> {"inert": v} / {"noise": b}.
REVIEWED = {
    # Self-heating needs the thermal node, the `thermal` flag and rth0
    # (dioload.c:77); net_devices builds diode_t exactly then, and on the
    # plain diode only diosoachk.c's warnings read rth0. diode_t declares
    # rth0 and cth0, and `thermal` is what selected it.
    ("diode", "rth0"): {"inert": "*"},
    ("diode", "cth0"): {"inert": "*"},
    ("diode", "thermal"): {"inert": "*"},
    ("diode_t", "thermal"): {"inert": "*"},
    # ngspice-45's BJT does not self-heat: bjtsoachk.c:114 (warnings) is
    # rth0's one read.
    ("gummel_poon", "rth0"): {"inert": "*"},
    # hsmhvset.c:418 and hsmhv2set.c:519 overwrite it with 0 ("not used").
    ("hisimhv_va", "rth0r"): {"inert": "*"},
    # Self-heats with rthjc given (vdmosload.c:81, vdmosset.c:401 makes the
    # nodes); net_devices.refuseSelfHeating refuses exactly that.
    ("vdmos", "thermal"): {"inert": "*"},
    # B3SOI-FD/DD heat only at shmod=1 with an rth0 that is not 0
    # (b3soifdld.c:283, b3soiddld.c:313; cth0 stamps the thermal rows that
    # exist only then, b3soifdbindCSC.c:28); b3soifd.va and b3soidd.va
    # declare none of them, and net_devices.refuseSelfHeating refuses
    # exactly that condition.
    ("b3soifd", "shmod"): {"inert": "*"},
    ("b3soifd", "rth0"): {"inert": "*"},
    ("b3soifd", "cth0"): {"inert": "*"},
    ("b3soidd", "shmod"): {"inert": "*"},
    ("b3soidd", "rth0"): {"inert": "*"},
    ("b3soidd", "cth0"): {"inert": "*"},
    # selft only gates heating through the fifth (thermal) node
    # (vbicsetup.c:471-480); inp2q.c:85-87 grounds a missing one, and
    # vbic13_4t has four ports, so net_devices refuses a fifth.
    ("vbic13_4t", "selft"): {"inert": "*"},
    # b4check.c:144 (and its v5-v7 twins) only fails an absurd value;
    # b4noi.c:53 is the one read that computes anything.
    ("bsim4va", "lintnoi"): {"noise": True},
    # ressetup.c:61 folds them into RESeffNoiseArea, which only
    # resnoise.c:111 reads.
    ("resistor", "lf"): {"noise": True},
    ("resistor", "wf"): {"noise": True},
}

TABLE = re.compile(r"IFparm\s+(\w+?)(mP|p)Table\s*\[\s*\]\s*=\s*\{(.*?)\n\s*\}\s*;", re.S)
INCLUDE = re.compile(r"#include\s+\"([^\"]+)\"")
# IOP("key", ID, IF_TYPE, "description")
ENTRY = re.compile(r"\b(?:IOP\w*|IP\w*)\s*\(\s*\"([^\"]+)\"\s*,\s*(\w+)\s*,[^,]*,\s*\"([^\"]*)\"")
# jfet2parm.h: PARAM("key", id, GivenFlag, field, default, "description")
XPARAM = re.compile(r"\bPARAM\w*\s*\(\s*\"([^\"]+)\"\s*,\s*\w+\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*([^,]+?)\s*,\s*\"([^\"]*)\"")
CASE = re.compile(r"\bcase\s+(\w+)\s*:")
LIT = r"([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)"


def device(src, d):
    """{key: (inert or None, noise_only, description)} of directory `d`, and
    the source bytes the verdicts came from."""
    folder = os.path.join(src, "src", "spicelib", "devices", d)
    names = sorted(n for n in os.listdir(folder) if n.endswith((".c", ".h")))
    texts = {n: open(os.path.join(folder, n), encoding="latin-1").read() for n in names}
    # key -> (field, given flag or None, description, default literal or None)
    entries = {}
    for name in names:
        if not name.endswith(".c"):
            continue
        for prefix, _, body in TABLE.findall(texts[name]):
            # ind.c also holds the mutual inductor's MUT tables.
            if d == "ind" and prefix != "IND":
                continue
            parts = [body] + [texts.get(inc) or open(os.path.join(folder, inc), encoding="latin-1").read() for inc in INCLUDE.findall(body)]
            for part in parts:
                for key, ident, desc in ENTRY.findall(part):
                    entries.setdefault(key.lower(), (ident, None, desc, None))
                for key, given, field, default, desc in XPARAM.findall(part):
                    entries.setdefault(key.lower(), (field, given, desc, default))
    assert entries, d
    setters = setter_fields(names, texts)
    out = {}
    for key, (ident, given, desc, default) in entries.items():
        field = ident if given else setters.get(ident, (None, None))[0]
        given = given or setters.get(ident, (None, None))[1]
        out[key] = (inert(texts, field, given, default), noise_only(texts, field), desc)
    return out, [texts[n] for n in names]


def setter_fields(names, texts):
    """{case constant: (field, its Given flag)} from the *par.c setters."""
    found = {}
    for name in sorted(names, key=lambda n: not n.endswith("par.c")):
        text = texts[name]
        cases = list(CASE.finditer(text))
        for i, m in enumerate(cases):
            body = text[m.end():cases[i + 1].start() if i + 1 < len(cases) else m.end() + 600]
            field = re.search(r"->\s*(\w+)\s*=\s*value\s*->", body)
            given = re.search(r"->\s*(\w+Given)\s*=\s*TRUE", body)
            if field and given and m.group(1) not in found:
                found[m.group(1)] = (field.group(1), given.group(1))
    return found


def default_spans(texts, field, given):
    """(file, start, end, literal) of each `if (!X->given) X->field = lit;`."""
    pat = re.compile(r"if\s*\(\s*!\s*\(?\s*\w+\s*->\s*%s\s*\)?\s*\)\s*\{?\s*\w+\s*->\s*%s\s*=\s*%s\s*;" % (given, field, LIT))
    return [(n, m.start(), m.end(), m.group(1)) for n, t in texts.items() for m in pat.finditer(t)]


def inert(texts, field, given, default):
    if not field or not given:
        return None
    spans = default_spans(texts, field, given)
    literals = {float(s[3]) for s in spans}
    if default is not None and re.fullmatch(LIT, default.strip()):
        literals.add(float(default))  # jfet2parm.h's default column
    if len(literals) != 1:
        return None
    # Any read of the Given flag outside the default lines, its setter and
    # its getters (*ask.c, *mask.c).
    for n, t in texts.items():
        if n.endswith("ask.c"):
            continue
        for m in re.finditer(r"->\s*%s\b(?!\s*=[^=])" % given, t):
            if not any(s[0] == n and s[1] <= m.start() < s[2] for s in spans):
                return None
    return literals.pop()


def noise_only(texts, field):
    if not field:
        return False
    reads = []
    for n, t in texts.items():
        if n.endswith(("par.c", "ask.c")):
            continue  # the setter and the getters
        for m in re.finditer(r"->\s*%s\b(?!\s*=[^=])" % field, t):
            reads.append(n)
    return bool(reads) and all("noi" in n for n in reads)


def merge(verdicts):
    """One verdict from the directories that hold a key."""
    inerts = {v[0] for v in verdicts}
    return (inerts.pop() if len(inerts) == 1 else None, all(v[1] for v in verdicts), next((v[2] for v in verdicts if v[2]), ""))


def main():
    src, out = sys.argv[1], sys.argv[2]
    rows, digest = [], hashlib.sha256()
    for model, dirs in MAP.items():
        per = {}
        for d in dirs:
            keys, seen = device(src, d)
            for s in seen:
                digest.update(s.encode("latin-1"))
            for k, v in keys.items():
                per.setdefault(k, []).append(v)
        for key in sorted(per):
            inert_v, noise, desc = merge(per[key])
            fix = REVIEWED.get((model, key), {})
            inert_v, noise = fix.get("inert", inert_v), fix.get("noise", noise)
            inert_s = "-" if inert_v is None else inert_v if inert_v == "*" else repr(inert_v)
            rows.append("\t".join([model, key, inert_s, "noise" if noise else "-", desc.replace("\t", " ")]))
    with open(out, "w") as f:
        f.write("# Generated by tools/ngspice_model_keys.py from %s's device sources\n" % os.path.basename(os.path.normpath(src)))
        f.write("# (sha256 of the .c and .h files read: %s). Do not edit; rerun the script.\n" % digest.hexdigest())
        f.write("# model<TAB>key<TAB>inert value, - (none) or * (any)<TAB>noise or -<TAB>ngspice's description\n")
        f.write("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
