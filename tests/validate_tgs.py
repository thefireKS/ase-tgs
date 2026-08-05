#!/usr/bin/env python3
"""Validate exported .tgs files against Telegram's published constraints.

Uses python-lottie as an independent parser -- the point is to check the file
with code that did not produce it, so a bug in our own writer cannot mask
itself. Geometry correctness is covered separately by tests/verify_geometry.lua,
which rasterises the contours and diffs them against the source sprite.

Usage:  .venv/bin/python tests/validate_tgs.py out/*.tgs
"""
import sys
import gzip
import json
import glob

MAX_BYTES = 64 * 1024
MAX_SECONDS = 3.0
CANVAS = 512

try:
    from lottie.parsers.tgs import parse_tgs
except ImportError:
    parse_tgs = None


def check(path):
    problems = []
    with open(path, "rb") as fh:
        raw = fh.read()

    size = len(raw)
    if size > MAX_BYTES:
        problems.append(f"{size/1024:.1f} KB exceeds the 64 KB limit")

    if raw[:2] != b"\x1f\x8b":
        problems.append("not a gzip stream (bad magic)")
        return size, None, problems

    try:
        doc = json.loads(gzip.decompress(raw))
    except Exception as exc:                     # noqa: BLE001
        problems.append(f"gzip/JSON decode failed: {exc}")
        return size, None, problems

    if doc.get("w") != CANVAS or doc.get("h") != CANVAS:
        problems.append(f"canvas is {doc.get('w')}x{doc.get('h')}, must be 512x512")
    if doc.get("tgs") != 1:
        problems.append('missing the "tgs": 1 marker')

    fr = doc.get("fr", 0)
    op = doc.get("op", 0)
    seconds = op / fr if fr else 0
    if seconds > MAX_SECONDS + 1e-6:
        problems.append(f"{seconds:.2f}s exceeds the 3s limit")
    if fr > 60:
        problems.append(f"{fr} fps exceeds 60")

    # Objects must stay inside the canvas. Layer transforms upscale native
    # sprite coords, so check the transformed extent rather than raw vertices.
    for layer in doc.get("layers", []):
        ks = layer.get("ks", {})
        scale = ks.get("s", {}).get("k", [100, 100])[0] / 100.0
        pos = ks.get("p", {}).get("k", [0, 0])
        for grp in layer.get("shapes", []):
            for item in grp.get("it", []):
                if item.get("ty") != "sh":
                    continue
                for vx, vy in item["ks"]["k"]["v"]:
                    x = pos[0] + vx * scale
                    y = pos[1] + vy * scale
                    if x < -0.001 or y < -0.001 or x > CANVAS + 0.001 or y > CANVAS + 0.001:
                        problems.append(f"vertex escapes the canvas at ({x:.1f},{y:.1f})")
                        break
                else:
                    continue
                break

    # Independent parse: a second implementation must also accept the file.
    if parse_tgs is not None:
        try:
            parse_tgs(path)
        except Exception as exc:                 # noqa: BLE001
            problems.append(f"python-lottie rejected the file: {exc}")

    return size, (seconds, len(doc.get("layers", []))), problems


def main(argv):
    paths = []
    for arg in argv or ["out/*.tgs"]:
        paths.extend(sorted(glob.glob(arg)))
    if not paths:
        print("no .tgs files found")
        return 1

    print(f"{'FILE':<26} {'SIZE':>9} {'BUDGET':>7} {'TIME':>7} {'LAYERS':>6}  STATUS")
    print("-" * 78)
    failed = 0
    for path in paths:
        size, info, problems = check(path)
        name = path.split("/")[-1]
        if info:
            seconds, layers = info
            meta = f"{seconds:>6.2f}s {layers:>6}"
        else:
            meta = " " * 14
        status = "OK" if not problems else "FAIL: " + "; ".join(problems)
        if problems:
            failed += 1
        print(f"{name:<26} {size/1024:>8.1f}K {size/MAX_BYTES*100:>6.0f}% {meta}  {status}")
    print("-" * 78)
    print(f"{len(paths) - failed}/{len(paths)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
