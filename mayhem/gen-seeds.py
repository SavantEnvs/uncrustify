#!/usr/bin/env python3
"""Regenerate the starter seeds from upstream's tests/ (run from the repo root; seeds are committed).

uncrustify_format seed = 3 header bytes (language index, 16-bit index into the sorted tests/config/**/*.cfg
list that build.sh bakes into the binary) + a source file. uncrustify_config seed = a config file.
"""
import os, re, shutil, sys

PER_LANG = 12
MAX_SRC = 4096
MAX_CFG = 3000
N_CFG_SEEDS = 60
LANG_IDX = {"C": 0, "CPP": 1, "D": 4, "CS": 5, "JAVA": 6, "OC": 7, "OC+": 8, "VALA": 9, "PAWN": 10, "ECMA": 11}
BY_NAME = {"c": "C", "cpp": "CPP", "d": "D", "c-sharp": "CS", "ecma": "ECMA", "java": "JAVA",
           "objective-c": "OC", "pawn": "PAWN", "vala": "VALA"}
BY_EXT = {".c": "C", ".h": "C", ".cpp": "CPP", ".hpp": "CPP", ".cc": "CPP", ".d": "D", ".cs": "CS",
          ".java": "JAVA", ".m": "OC", ".mm": "OC+", ".vala": "VALA", ".p": "PAWN", ".pwn": "PAWN",
          ".inc": "PAWN", ".js": "ECMA", ".es": "ECMA"}

cfgs = sorted(os.path.join(d, f)[len("tests/config/"):] for d, _, fs in os.walk("tests/config")
              for f in fs if f.endswith(".cfg"))
cfg_idx = {c: i for i, c in enumerate(cfgs)}

for sub in ("uncrustify_format", "uncrustify_config"):
    p = os.path.join("mayhem", sub, "testsuite")
    shutil.rmtree(p, ignore_errors=True)
    os.makedirs(p)

picked = {}
for tf in sorted(f for f in os.listdir("tests") if f.endswith(".test")):
    base = tf[:-5]
    for line in open(os.path.join("tests", tf), errors="replace"):
        line = line.split("#")[0].strip()
        m = re.match(r"^\d+[!~]?\s+(\S+)\s+(\S+)(?:\s+(\S+))?$", line)
        if not m or m.group(1) not in cfg_idx:
            continue
        cfg, src, lang = m.group(1), m.group(2), m.group(3)
        path = os.path.join("tests", "input", src)
        if not os.path.isfile(path) or os.path.getsize(path) > MAX_SRC:
            continue
        lang = lang or BY_NAME.get(base) or BY_EXT.get(os.path.splitext(src)[1])
        if lang not in LANG_IDX:
            continue
        picked.setdefault(lang, []).append((os.path.getsize(path), cfg, src, path))

n = 0
for lang, items in sorted(picked.items()):
    items.sort()
    step = max(1, len(items) // PER_LANG)
    for size, cfg, src, path in items[::step][:PER_LANG]:
        i = cfg_idx[cfg]
        hdr = bytes([LANG_IDX[lang], i & 255, i >> 8])
        name = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{lang}-{src}")
        with open(os.path.join("mayhem/uncrustify_format/testsuite", name), "wb") as o:
            o.write(hdr + open(path, "rb").read())
        n += 1

small = [c for c in cfgs if os.path.getsize("tests/config/" + c) <= MAX_CFG]
step = max(1, len(small) // N_CFG_SEEDS)
m = 0
for c in small[::step][:N_CFG_SEEDS]:
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", c)
    shutil.copy("tests/config/" + c, os.path.join("mayhem/uncrustify_config/testsuite", name))
    m += 1
print(f"{n} format seeds, {m} config seeds", file=sys.stderr)
