#!/usr/bin/env python3
"""Write StudioExport JSON chunks into the repo.

Usage:
    python3 tools/export/write_export.py --clean chunk1.json chunk2.json ...

--clean empties src/ and studio-only/ first, so scripts deleted in Studio
disappear from the repo too. Every path must stay under src/ or studio-only/.
"""

import argparse
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ALLOWED = ("src/", "studio-only/")


def safe_target(rel):
    norm = os.path.normpath(rel).replace(os.sep, "/")
    if not norm.startswith(ALLOWED) or ".." in norm.split("/"):
        raise ValueError(f"refusing path outside src/ or studio-only/: {rel}")
    return os.path.join(ROOT, norm)


def clean():
    for top in ALLOWED:
        base = os.path.join(ROOT, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base, topdown=False):
            for f in filenames:
                if f != ".gitkeep":
                    os.remove(os.path.join(dirpath, f))
            for d in dirnames:
                full = os.path.join(dirpath, d)
                if not os.listdir(full):
                    os.rmdir(full)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("chunks", nargs="+")
    args = parser.parse_args()

    if args.clean:
        clean()

    written = 0
    lines = 0
    seen = set()
    for chunk_path in args.chunks:
        with open(chunk_path, encoding="utf-8") as fh:
            chunk = json.load(fh)
        for warning in chunk.get("warnings") or []:
            print(f"warning: {warning}", file=sys.stderr)
        for entry in chunk["files"]:
            target = safe_target(entry["path"])
            if target in seen:
                print(f"warning: {entry['path']} appears twice, keeping the last", file=sys.stderr)
            seen.add(target)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8", newline="\n") as out:
                out.write(entry["content"])
            written += 1
            lines += entry["content"].count("\n") + 1

    print(f"wrote {written} files, about {lines} lines")


if __name__ == "__main__":
    main()
