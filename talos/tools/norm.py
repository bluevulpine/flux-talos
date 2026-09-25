#!/usr/bin/env python3
"""Flatten a multi-document Talos machine config into sorted `Kind/name | path = value` lines.

Migration verification tool (talhelper -> topf); delete with talconfig.yaml in Phase 7.

Two modes, chosen by the environment:

  default        Secrets are MASKED (`<secret>`). Use to compare a render made with SYNTHETIC
                 secrets against the real baseline: masked values are not compared.
  NORM_KEY=...   Secrets are replaced by HMAC-SHA256(NORM_KEY, value). Use for real-vs-real
                 comparisons: a wrong secret differs, and nothing reversible is printed. The
                 key must be random per run and shared by both sides (compare.sh does this),
                 because a bare hash of a low-entropy value such as the registry domain can
                 be dictionary-attacked.

In both modes an EMPTY value is shown as `<empty>`, so "field absent/blank" never compares
equal to "field holds a secret".

Masking is by exact PATH, never by field name: `key` also names taint keys and volume keys.
"""
import hashlib, hmac, json, os, re, subprocess, sys

if os.environ.get("NORM_HASH"):
    # Removed: it was an unsalted hash. Silently ignoring it would fall back to weaker masking.
    sys.exit("NORM_HASH no longer exists; run compare.sh --hash (it sets a random per-run NORM_KEY)")
KEY = os.environ.get("NORM_KEY")
SECRET_PREFIXES = ("machine.ca", "machine.token", "cluster.ca", "cluster.id", "cluster.secret",
                   "cluster.token", "cluster.aggregatorCA", "cluster.serviceAccount",
                   "cluster.etcd.ca", "cluster.secretboxEncryptionSecret",
                   "cluster.aescbcEncryptionSecret")
LONG = re.compile(r'^[A-Za-z0-9+/=_-]{40,}$')  # catch-all for secret-shaped strings elsewhere


def tok(val, label="<secret>"):
    if val == "":
        return "<empty>"
    if KEY:
        return "<hmac:" + hmac.new(KEY.encode(), val.encode(), hashlib.sha256).hexdigest()[:12] + ">"
    return label


def esc(seg):
    return str(seg).replace("\\", "\\\\").replace(".", "\\.")


def mask(path, val, main):
    if not isinstance(val, str):
        return val
    dotted = ".".join(esc(x) for x in path)
    if main and any(dotted == p or dotted.startswith(p + ".") for p in SECRET_PREFIXES):
        return tok(val)
    if path and path[-1] == "passphrase":
        return tok(val)
    if val.startswith("TS_AUTHKEY="):
        return "TS_AUTHKEY=" + tok(val[len("TS_AUTHKEY="):])
    if LONG.match(val):
        return tok(val, f"<long-string:{len(val)}>")
    # Nexus mirror URLs embed SECRET_DOMAIN: hide it in synthetic mode, HMAC it in real mode.
    return re.sub(r'(nexus\.)([A-Za-z0-9.-]+)',
                  lambda m: m.group(1) + (tok(m.group(2)) if KEY else "<DOMAIN>"), val)


def leaves(node, path, out):
    if isinstance(node, dict):
        if not node:
            out.append((path, "<empty-map>"))
        for k in sorted(node, key=str):
            leaves(node[k], path + [k], out)
    elif isinstance(node, list):
        if not node:
            out.append((path, "<empty-list>"))
        for i, v in enumerate(node):
            leaves(v, path + [i], out)
    else:
        out.append((path, node))


def load(fn):
    raw = subprocess.run(["yq", "eval-all", "-o=json", "-I=0", ".", fn],
                         capture_output=True, text=True, check=True).stdout
    docs = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        if not isinstance(d, dict):
            sys.exit(f"{fn}: non-map document ({type(d).__name__}); refusing to skip it silently")
        docs.append(d)
    if not docs:
        sys.exit(f"{fn}: no documents")
    return docs


def docid(d):
    kind = d.get("kind") or ("MachineConfig" if d.get("version") == "v1alpha1" else "?")
    return f"{kind}/{d['name']}" if d.get("name") else kind


def main(argv):
    if argv[0] == "--order":  # document sequence, which the leaf comparison discards
        print("\n".join(docid(d) for d in load(argv[1])))
        return
    lines = []
    for d in load(argv[0]):
        key = docid(d)
        out = []
        leaves(d, [], out)
        for p, v in out:
            lines.append(f"{key} | {'.'.join(esc(x) for x in p)} = {json.dumps(mask(p, v, key == 'MachineConfig'))}")
    print("\n".join(sorted(lines)))


main(sys.argv[1:])
