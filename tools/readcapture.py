"""Read CutMaster's SavedVariables and summarise the capture buffer.

Usage: python tools/readcapture.py <path to CutMaster.lua> [--all] [--reason X]

WoW writes SavedVariables as a Lua literal. This walks it line by line rather
than trying to regex nested tables, which is fragile with escaped quotes in
captured chat text.
"""
import sys
from collections import Counter

SCALAR = ("true", "false", "nil")


def parse_value(raw):
    raw = raw.strip().rstrip(",")
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        return raw[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if raw in SCALAR:
        return {"true": True, "false": False, "nil": None}[raw]
    try:
        return float(raw) if "." in raw else int(raw)
    except ValueError:
        return raw


def extract_section(text, key):
    """Return the lines belonging to CutMasterDB[key], by brace depth."""
    marker = '["%s"] = {' % key
    start = text.find(marker)
    if start == -1:
        return []
    i = start + len(marker)
    depth = 1
    out = []
    for line in text[i:].splitlines():
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break
        out.append(line)
    return out


def parse_entries(lines):
    """Each capture entry is a table at depth 1 of the section."""
    entries, cur, depth = [], None, 0
    for line in lines:
        s = line.strip()
        opens, closes = s.count("{"), s.count("}")
        if depth == 0 and s.startswith("{"):
            cur = {}
            depth += opens - closes
            continue
        if cur is not None:
            if "] = " in s and depth == 1:
                k, _, v = s.partition("] = ")
                k = k.strip().lstrip("[").strip('"')
                if not v.strip().startswith("{"):
                    cur[k] = parse_value(v)
            depth += opens - closes
            if depth <= 0:
                entries.append(cur)
                cur, depth = None, 0
    return entries


def main():
    path = sys.argv[1]
    show_all = "--all" in sys.argv
    want = None
    if "--reason" in sys.argv:
        want = sys.argv[sys.argv.index("--reason") + 1]

    section = "capture"
    if "--section" in sys.argv:
        section = sys.argv[sys.argv.index("--section") + 1]

    text = open(path, encoding="utf-8", errors="replace").read()
    entries = parse_entries(extract_section(text, section))

    print(f"{section} messages: {len(entries)}\n")

    print("verdict:")
    for v, c in Counter(e.get("verdict") for e in entries).most_common():
        print(f"  {c:4}  {v}")

    print("\nreason:")
    for v, c in Counter(e.get("reason") for e in entries).most_common():
        print(f"  {c:4}  {v}")

    print("\ntop talkers:")
    for p, c in Counter(e.get("player") for e in entries).most_common(10):
        print(f"  {c:4}  {p}")

    rows = entries if want is None else [e for e in entries if e.get("reason") == want]
    limit = len(rows) if show_all else 40
    print(f"\nmessages ({min(limit, len(rows))} of {len(rows)}):")
    for e in rows[:limit]:
        print(f"  [{e.get('reason')}] {e.get('player')}: {(e.get('msg') or '')[:130]}")


if __name__ == "__main__":
    main()
