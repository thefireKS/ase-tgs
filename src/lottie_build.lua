--- Assemble traced contours + frame timings into a Lottie document.
--
-- Pixel art is a flipbook, not a tween: each Aseprite frame becomes its own
-- shape layer, visible only across its own ip/op range. No path morphing.

local json = require("json_encode")

local M = {}

M.CANVAS = 512          -- Telegram requires exactly 512x512
M.MAX_DURATION = 3.0    -- seconds
M.DEFAULT_FR = 60

--- Pick the upscale factor from native sprite size to the 512 canvas.
--
-- An integer factor is strongly preferred: it lands every pixel boundary on a
-- whole canvas coordinate, so rlottie renders razor-sharp edges. A fractional
-- factor (512/28 = 18.2857...) puts boundaries on fractional coordinates and
-- rlottie antialiases them, which visibly softens pixel art.
--
-- The leftover is absorbed as an empty margin, which costs nothing -- it is
-- just a translation in the layer transform, not padded pixel data.
--
-- We fall back to a fractional factor only when flooring would waste too much
-- of the canvas (e.g. a 300px sprite would floor to 1x and fill 59% of the
-- frame), where filling the canvas matters more than pixel crispness.
-- @return scale, offsetX, offsetY, mode
function M.computeFit(W, H, canvas, minCoverage)
  canvas = canvas or M.CANVAS
  minCoverage = minCoverage or 0.90
  local n = math.max(W, H)
  local scale = canvas // n
  local mode = "integer"
  if scale < 1 or (n * scale) / canvas < minCoverage then
    scale = canvas / n
    mode = "fractional"
  end
  local offX = (canvas - W * scale) / 2
  local offY = (canvas - H * scale) / 2
  if mode == "integer" then
    -- Keep the offset whole too, otherwise a half-pixel translate reintroduces
    -- exactly the blurring the integer scale was chosen to avoid. An odd
    -- remainder costs at most 1px of asymmetry, which is invisible; a 0.5px
    -- offset is not.
    offX, offY = math.floor(offX), math.floor(offY)
  end
  return scale, offX, offY, mode
end

--- Map an 8-bit channel to the Lottie 0..1 float that survives the round trip.
--
-- The naive c/255 is not safe. rlottie converts colour floats back to bytes by
-- truncating (255 * f), so any representation that lands even a hair below c
-- comes out as c-1 -- which is how an exact palette silently shifts by one.
-- Other renderers round instead of truncating.
--
-- Biasing to (c + 0.25)/255 satisfies both: truncation yields c because the
-- product sits at c + 0.25, and round-half-up yields c for the same reason. The
-- introduced error is a quarter of one 8-bit step, far below anything visible,
-- and it makes the exported palette byte-exact in Telegram.
local function channel(c)
  return math.floor((c + 0.25) / 255 * 1e6 + 0.5) / 1e6
end

--- Convert a packed RGBA uint32 to a Lottie fill colour + opacity percentage.
local function unpackColor(v)
  local r = v & 0xFF
  local g = (v >> 8) & 0xFF
  local b = (v >> 16) & 0xFF
  local a = (v >> 24) & 0xFF
  -- opacity is a percentage, so it needs the same bias expressed in 0..100
  local opacity = (a >= 255) and 100 or (math.floor((a + 0.25) / 255 * 1e6 + 0.5) / 1e4)
  return { channel(r), channel(g), channel(b) }, opacity
end

--- Build one shape group: all contours of a single colour under one fill.
local function colorGroup(loops, color)
  local items = {}
  for _, pts in ipairs(loops) do
    local n = #pts // 2
    local v, i, o = {}, {}, {}
    for k = 0, n - 1 do
      v[k + 1] = { pts[k * 2 + 1], pts[k * 2 + 2] }
      i[k + 1] = { 0, 0 }
      o[k + 1] = { 0, 0 }
    end
    items[#items + 1] = {
      ty = "sh",
      ks = { a = 0, k = { c = true, v = v, i = i, o = o } },
    }
  end
  local rgb, opacity = unpackColor(color)
  items[#items + 1] = {
    ty = "fl",
    c = { a = 0, k = { rgb[1], rgb[2], rgb[3], 1 } },
    o = { a = 0, k = opacity },
    r = 1,   -- non-zero winding: our holes are wound opposite to their outer
             -- contour, so this punches them out with no extra bookkeeping
  }
  items[#items + 1] = {
    ty = "tr",
    p = { a = 0, k = { 0, 0 } },
    a = { a = 0, k = { 0, 0 } },
    s = { a = 0, k = { 100, 100 } },
    r = { a = 0, k = 0 },
    o = { a = 0, k = 100 },
  }
  return { ty = "gr", it = items }
end

--- Build the full Lottie document.
-- @param frames list of { shapes = <list of {loops=..., color=...}>, ip = , op = }
-- @param opts { width, height, fr, name }
function M.build(frames, opts)
  local W, H = opts.width, opts.height
  local fr = opts.fr or M.DEFAULT_FR
  local scale, offX, offY = M.computeFit(W, H, opts.canvas, opts.minCoverage)

  local layers = {}
  local lastOp = 0
  for idx, f in ipairs(frames) do
    local shapes = {}
    for _, s in ipairs(f.shapes) do
      shapes[#shapes + 1] = colorGroup(s.loops, s.color)
    end
    layers[#layers + 1] = {
      ddd = 0,
      ind = idx,
      ty = 4,
      nm = "f" .. idx,
      sr = 1,
      ks = {
        o = { a = 0, k = 100 },
        r = { a = 0, k = 0 },
        p = { a = 0, k = { offX, offY } },
        a = { a = 0, k = { 0, 0 } },
        s = { a = 0, k = { scale * 100, scale * 100 } },
      },
      ao = 0,
      shapes = #shapes > 0 and shapes or json.EMPTY_ARRAY,
      ip = f.ip,
      op = f.op,
      st = 0,
      bm = 0,
    }
    if f.op > lastOp then lastOp = f.op end
  end

  -- Lottie draws layers in array order with the first on top; frames must play
  -- in order, so later frames need to be earlier in the array.
  local rev = {}
  for i = #layers, 1, -1 do rev[#rev + 1] = layers[i] end

  return {
    v = "5.5.2",
    fr = fr,
    ip = 0,
    op = lastOp,
    w = opts.canvas or M.CANVAS,
    h = opts.canvas or M.CANVAS,
    nm = opts.name or "emoji",
    ddd = 0,
    assets = json.EMPTY_ARRAY,
    layers = rev,
    tgs = 1,
  }, { scale = scale, offX = offX, offY = offY, fr = fr, durationFrames = lastOp }
end

return M
