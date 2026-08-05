# ase-tgs

Turn Aseprite pixel art into Telegram `.tgs` animated stickers and custom emoji —
entirely inside Aseprite's Lua sandbox. No After Effects, no Illustrator, no
external processes.

Pixels are traced into vector contours, assembled into a Lottie document, and
gzipped. Because the source is pixel art, the output is exact: every sticker in
the test set round-trips through Telegram's own renderer without a single pixel
of difference.

## Status

The conversion pipeline works and is verified end to end. **The Aseprite
extension wrapper is not built yet** — there is no `package.json`, no menu
command, no `.aseprite-extension` bundle. Today this runs headlessly:

```bash
make test
```

Verified on Aseprite 1.3.15.3 (arm64), Lua 5.4.

## Telegram's constraints

| Constraint | Value |
| --- | --- |
| Canvas | exactly 512×512 |
| File size | ≤ 64 KB |
| Duration | ≤ 3 s |
| Frame rate | ≤ 60 fps |
| Container | gzip of a Lottie JSON carrying `"tgs": 1` |
| Playback | rlottie, looping the whole file |

Objects must stay inside the canvas. Source: <https://core.telegram.org/stickers>.

Animated **custom emoji** may want a different canvas than stickers — Telegram's
docs give 100×100 for static emoji and only say animated emoji use "the same
technology" as stickers. 512×512 has been accepted in practice.

## How it works

**Contours, not rectangles.** For each frame, pixels are grouped by exact RGBA
value. Each colour's mask emits a directed unit edge wherever a filled cell
borders an empty one, wound so outer contours run clockwise and holes run
counter-clockwise. Stitching those edges yields every contour of every component
in one pass — hole nesting falls out of the winding, so Lottie's non-zero fill
rule punches holes with no parent/child bookkeeping. Collinear runs collapse as
the loop is walked, so a 32-pixel straight edge costs two vertices, not 32.

**Flipbook, not tweening.** Each Aseprite frame becomes its own shape layer,
visible only across its own `ip`/`op` range. No path morphing between frames —
that is both far simpler and the correct aesthetic for pixel art. Frames
identical to their predecessor extend the previous layer instead of emitting a
duplicate.

**Native coordinates, upscaled by transform.** Path coordinates stay in the
sprite's own pixel space (small integers) and the 512 canvas is reached with a
scale in the layer transform. Fewer digits per number than pre-multiplying
coordinates, and it keeps the upscale exact.

**Integer scale wherever possible.** An integer factor lands every pixel
boundary on a whole canvas coordinate, so rlottie renders razor-sharp edges; a
fractional factor puts boundaries between coordinates and antialiasing visibly
softens the art. `computeFit` floors `512 / max(w, h)` and absorbs the remainder
as a margin — which is free, being just a translation. A 28×28 sprite scales
18× to 504 with a 4px border. The offset is floored too: a half-pixel translate
would reintroduce exactly the blurring the integer scale avoids. Only when
flooring would waste more than 10% of the canvas does it fall back to a
fractional scale.

Reading pixels goes through `Image.bytes` + `string.unpack` rather than
`getPixel`, which measured ~25× faster.

## Modules

| File | Role |
| --- | --- |
| `src/pixel_trace.lua` | connected contours + collinear collapse |
| `src/lottie_build.lua` | contours + timings → Lottie document, canvas fitting |
| `src/json_encode.lua` | compact JSON (see the `ty` rule below) |
| `src/gzip.lua` | gzip container + CRC32 over LibDeflate's raw DEFLATE |
| `src/export_tgs.lua` | orchestration, frame dedup, limit checks |
| `vendor/LibDeflate.lua` | pure-Lua DEFLATE (third party, zlib licence) |

## rlottie will bite you

Telegram renders with **rlottie**, which is stricter than every web player. Both
of the following produced files that played perfectly in lottie-web and
python-lottie and were rejected outright by Telegram:

**`"ty"` must be the first key of every shape object.** rlottie parses shapes as
a stream: it dispatches on `"ty"` and interprets the *remainder* of the object
according to that type, so any key emitted before `"ty"` is silently discarded.
Get this wrong and the sticker renders completely blank — no error, no warning.
Web players read the whole object into memory first and never notice.

**Colour channels need biasing.** rlottie converts colour floats back to bytes
by *truncating* `255 * f`, so the obvious `c / 255` lands a hair low and comes
out as `c - 1`. Emitting `(c + 0.25) / 255` yields exactly `c` under both
truncating and rounding renderers.

The lesson: **a web player is not evidence that a sticker works.** `make rlottie`
is the gate — it renders through real rlottie and demands an exact pixel match.

## Testing

Four independent levels, cheapest first. They are independent on purpose:
geometry is checked by our own rasteriser, format by a parser that did not write
the file, and the final render by Telegram's own engine, so a bug in the writer
cannot mask itself.

```bash
make unit       # tracer invariants: shoelace area == filled pixel count
make export     # sprite -> .tgs, then contours diffed against source pixels
make validate   # format + Telegram limits, via python-lottie
make rlottie    # real rlottie render, diffed against Aseprite's PNG export
```

One-time setup for the Python-side checks:

```bash
make venv
```

Test sprites are read from `$(ART)`, default `~/projects/art`. Override with
`make test ART=/path/to/art SPRITES="Foo Bar"`.

## Licence

MIT — see `LICENSE`.

Bundles [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) by Haoqian He,
used under the zlib licence; its notice is retained in the vendored file.
