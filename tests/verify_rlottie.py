#!/usr/bin/env python3
"""Render exported .tgs with rlottie and diff against the source art.

This is the test that matters. rlottie is the renderer Telegram actually ships,
and it diverges from web players in ways that produce a file which previews
perfectly in a browser and renders completely blank in Telegram -- which is
exactly what happened with shape-object key order. Checking against lottie-web
or python-lottie alone is not sufficient evidence that a sticker will work.

Reference frames come from Aseprite's own CLI export at the same upscale factor,
so a match means our vector output is indistinguishable from the source art.

Usage:
    aseprite -b --script tests/export_all.lua      # writes out/*.tgs + manifest
    aseprite -b art.aseprite --scale 16 --save-as ref/name-1.png
    .venv/bin/python tests/verify_rlottie.py <ref_dir>
"""
import sys
import json
import os

from PIL import Image
from rlottie_python import LottieAnimation

TOLERANCE = 0          # exact match expected: integer scale, no resampling


def compare(tgs_path, ref_dir, name, sample_at):
    anim = LottieAnimation.from_tgs(tgs_path)
    total = anim.lottie_animation_get_totalframe()

    results = []
    for idx, lottie_frame in enumerate(sample_at, start=1):
        ref_path = os.path.join(ref_dir, f"{name}-{idx}.png")
        if not os.path.exists(ref_path):
            continue
        ref = Image.open(ref_path).convert("RGBA")
        frame = min(lottie_frame, total - 1)
        got = anim.render_pillow_frame(frame_num=frame).convert("RGBA")

        if got.size != ref.size:
            results.append((idx, -1, f"size {got.size} != ref {ref.size}"))
            continue

        gp = got.load()
        rp = ref.load()
        w, h = ref.size
        bad = 0
        for y in range(h):
            for x in range(w):
                g = gp[x, y]
                r = rp[x, y]
                if r[3] == 0 and g[3] == 0:
                    continue
                if abs(g[0]-r[0]) > TOLERANCE or abs(g[1]-r[1]) > TOLERANCE \
                   or abs(g[2]-r[2]) > TOLERANCE or abs(g[3]-r[3]) > TOLERANCE:
                    bad += 1
        results.append((idx, bad, None))
    return results


def main(argv):
    ref_dir = argv[0] if argv else "ref"
    with open("out/manifest.json") as fh:
        manifest = json.load(fh)

    print(f"{'SPRITE':<20} {'FRAMES':>7} {'PIXELS':>10} {'MISMATCH':>9}  VERDICT")
    print("-" * 62)
    total_bad = 0
    failures = 0
    for name, meta in manifest.items():
        tgs = f"out/{name}.tgs"
        if not os.path.exists(tgs):
            continue
        results = compare(tgs, ref_dir, name, meta["sampleAt"])
        if not results:
            print(f"{name:<20} {'-':>7} {'-':>10} {'-':>9}  no reference frames")
            continue
        bad = sum(r[1] for r in results if r[1] > 0)
        errs = [r[2] for r in results if r[2]]
        px = len(results) * 512 * 512
        total_bad += bad
        ok = bad == 0 and not errs
        if not ok:
            failures += 1
        verdict = "PIXEL-PERFECT" if ok else (errs[0] if errs else f"{bad} px differ")
        print(f"{name:<20} {len(results):>7} {px:>10} {bad:>9}  {verdict}")

    print("-" * 62)
    if failures == 0 and total_bad == 0:
        print("rlottie output matches the source art exactly")
        return 0
    print(f"FAILED: {failures} sprite(s), {total_bad} mismatched pixels")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
