# ase-tgs

Turn Aseprite pixel art into Telegram `.tgs` animated stickers and custom emoji —
entirely inside Aseprite's Lua sandbox. No After Effects, no Illustrator, no
external processes.

Pixels are traced into vector contours, assembled into a Lottie document, and
gzipped. Because the source is pixel art, the output is exact: every sticker in
the test set round-trips through Telegram's own renderer without a single pixel
of difference.

## Install

```bash
make extension
```

Then in Aseprite: **Edit → Preferences → Extensions → Add Extension**, pick
`dist/ase-tgs.aseprite-extension`, and restart. For development, `make install`
drops the tree straight into Aseprite's extensions folder instead.

The command lands in **File → Export → Export as .tgs (Telegram)…**.

Verified on Aseprite 1.3.15.3 (arm64), Lua 5.4. Everything runs inside
Aseprite's Lua sandbox — writing the file included, with no external process.

**On the Security prompt:** Aseprite gates file access from scripts behind a
"Security" dialog. The first export may ask *"wants to write to this file"* —
choose **Allow Write Access**, or tick **Give full trust to this script** to
stop being asked. Nothing is written if you decline.

## Use

The dialog follows Aseprite's own export dialog: output first, then what to
export, then how to fit it.

- **Output File** — an editable path, with a picker below it that fills it in.
  Defaults next to the sprite, and the folder is remembered.
- **Frames** — the whole animation, a tag, or an explicit frame range
- **Speed %** — a slider from 25% to 400%, with the resulting running time shown
  live underneath and flagged when it breaks the 3 s ceiling
- **Target FPS / Max colours** — the other two levers; `0` leaves each alone

The path sits above the picker rather than beside it because the scripting
Dialog API gives every labelled widget its own row — the single-row
"entry + browse" of the native dialog is not reachable from Lua.

An export that would break Telegram's limits is refused with a message naming
the lever that fixes it, offering **Adjust** (reopens with your settings kept),
**Export anyway**, or **Cancel**. A successful export reports the size against
the 64 KB budget and anything the levers changed.

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

## Performance

Export time is dominated by gzip — measured at **98%**, with contour tracing
barely registering. So the compression level, not the algorithm, is the thing
worth tuning. Level 6 sits at the knee: about 4× faster than level 9 for ~3%
more bytes, and level 9 gains essentially nothing over level 8. Export starts at
level 6 and escalates to 9 only when the result misses the 64 KB budget by
little enough that the extra few percent could rescue it; art that is far over
fails fast instead of grinding through a second pass that cannot help.

Cost scales with the number of contours, not the pixel count, so dithered or
noisy art is the expensive case. A typical 32×32 emoji exports in under 0.4 s.
Worst-case synthetic noise at 128×128 takes ~2 s and at 256×256 ~12 s — and
blows the size budget several times over regardless, so large or heavily
dithered sources are not a good fit for this pipeline.

Because compression is the expensive half, `prepare()` runs everything up to it
and projects the final size from the JSON length. An export whose best possible
compressed size still misses the budget is refused before a single byte is
compressed, which is what keeps hopeless art from freezing the editor.

## Selecting frames, and fitting the limits

Range selection mirrors Aseprite's own export dialog:

```lua
exporter.export(sprite, path, { range = { mode = "all" } })
exporter.export(sprite, path, { range = { mode = "tag", tag = "walk" } })
exporter.export(sprite, path, { range = { mode = "frames", from = 2, to = 20 } })
```

Exports that would break Telegram's limits are **refused**, with a message
naming the lever that fixes them — passing `force = true` overrides. Three
levers, which do genuinely different things:

| Option | Effect | Use for |
| --- | --- | --- |
| `speed = 2` | keeps every frame, halves the running time | the 3 s limit |
| `fps = 10` | keeps the running time, drops frames | the 64 KB limit |
| `maxColors = 8` | merges the rare colours into the palette | the 64 KB limit |

`fps` never upsamples. Note it drops frames rather than lowering Lottie's `fr`:
in a flipbook the layer count follows the number of distinct source frames, so
changing `fr` alone renumbers `ip`/`op` and saves nothing.

`maxColors` keeps the most-used colours and snaps the rest to their nearest
survivor. How well it pays depends on whether the art has a real palette of flat
regions — merging two shades of a large area removes whole contours, whereas on
fine anti-aliased detail the shapes stay just as complex:

| `maxColors` | 32×32 emoji (40 colours) | 160×160 detailed art (76 colours) |
| --- | --- | --- |
| 16 | −15% | −6% |
| 8 | −31% | −10% |
| 4 | −40% | −14% |

The practical ceiling for this pipeline is roughly a 64×64 sprite. The 160×160
art tested here stays 2.6–26× over budget even at 6 fps and 16 colours, because
its cost is shape complexity rather than palette size, and no lever addresses
that.

## Modules

| File | Role |
| --- | --- |
| `extension/main.lua` | menu command + export dialog |
| `extension/package.json` | extension manifest |
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
make unit       # tracer invariants, frame selection, levers, limit enforcement
make bundle     # the packaged extension works from its installed layout
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
