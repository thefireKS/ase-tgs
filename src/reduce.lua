--- Frame selection and the two levers for getting under the 64 KB budget.
--
-- Both levers trade fidelity for bytes, so neither is applied unless asked for.
-- Cost is driven by the number of contours, which is why dropping frames and
-- shrinking the palette are the effective moves: fewer frames means fewer shape
-- layers, and fewer colours means adjacent pixels merge into larger regions
-- with shorter outlines.

local M = {}

--- Resolve which source frames an export covers.
--
-- Mirrors the choices Aseprite's own export dialog offers.
-- @param range { mode = "all" | "tag" | "frames", tag = <name>, from = , to = }
-- @return list of { number = <frame index>, duration = <seconds> }, or nil+error
function M.selectFrames(sprite, range)
  range = range or { mode = "all" }
  local mode = range.mode or "all"
  local first, last

  if mode == "all" then
    first, last = 1, #sprite.frames

  elseif mode == "tag" then
    local found
    for _, t in ipairs(sprite.tags) do
      if t.name == range.tag then found = t break end
    end
    if not found then
      local names = {}
      for _, t in ipairs(sprite.tags) do names[#names + 1] = t.name end
      return nil, string.format("no tag named %q (sprite has: %s)",
        tostring(range.tag),
        #names > 0 and table.concat(names, ", ") or "none")
    end
    first = found.fromFrame.frameNumber
    last  = found.toFrame.frameNumber

  elseif mode == "frames" then
    first = math.max(1, math.floor(range.from or 1))
    last  = math.min(#sprite.frames, math.floor(range.to or #sprite.frames))
    if last < first then
      return nil, string.format("empty frame range %d..%d", first, last)
    end

  else
    return nil, "unknown range mode: " .. tostring(mode)
  end

  local out = {}
  for i = first, last do
    out[#out + 1] = { number = i, duration = sprite.frames[i].duration }
  end
  return out
end

--- Resample a frame list down to roughly a target rate.
--
-- Note this drops frames rather than changing Lottie's `fr`. In a flipbook the
-- layer count follows the number of distinct source frames, so lowering `fr`
-- alone renumbers ip/op and saves nothing -- only removing frames does.
--
-- Never upsamples: asking for a rate above the source's own gains nothing and
-- would multiply the layer count.
function M.decimate(frames, targetFps)
  if not targetFps or targetFps <= 0 or #frames == 0 then return frames end

  local total = 0
  for _, f in ipairs(frames) do total = total + f.duration end
  if total <= 0 then return frames end

  local want = math.max(1, math.floor(total * targetFps + 0.5))
  if want >= #frames then return frames end

  local slot = total / want
  local out = {}
  for i = 0, want - 1 do
    local t = (i + 0.5) * slot          -- sample the middle of each new slot
    local acc, pick = 0, frames[#frames]
    for _, f in ipairs(frames) do
      acc = acc + f.duration
      if t < acc then pick = f break end
    end
    out[#out + 1] = { number = pick.number, duration = slot }
  end
  return out
end

--- Scale every frame's duration, making the animation play faster or slower.
--
-- Distinct from decimate(): that one keeps the running time and removes frames,
-- this one keeps every frame and changes the running time. Fitting a long
-- animation into Telegram's 3 s ceiling needs this one -- dropping frames alone
-- never shortens anything.
-- @param speed multiplier; 2 plays twice as fast, halving the duration
function M.rescale(frames, speed)
  if not speed or speed == 1 or speed <= 0 then return frames end
  local out = {}
  for i, f in ipairs(frames) do
    out[i] = { number = f.number, duration = f.duration / speed }
  end
  return out
end

--- Speed needed to bring a frame list under a duration ceiling, or nil if it
-- already fits.
function M.speedToFit(frames, maxSeconds)
  local total = 0
  for _, f in ipairs(frames) do total = total + f.duration end
  if total <= maxSeconds then return nil end
  return total / maxSeconds
end

--- Perceptual-ish distance between two packed RGBA colours.
-- Alpha is weighted heavily so semi-transparent pixels never collapse into
-- opaque ones, which would show up as hard edges where soft ones were intended.
local function distance(a, b)
  local ar, ag, ab, aa = a & 0xFF, (a >> 8) & 0xFF, (a >> 16) & 0xFF, (a >> 24) & 0xFF
  local br, bg, bb, ba = b & 0xFF, (b >> 8) & 0xFF, (b >> 16) & 0xFF, (b >> 24) & 0xFF
  local dr, dg, db, da = ar - br, ag - bg, ab - bb, aa - ba
  return 2 * dr * dr + 4 * dg * dg + 3 * db * db + 8 * da * da
end

--- Build a colour remap that keeps the most-used colours.
--
-- Pixel art's real palette is its frequent colours; the long tail is usually
-- anti-aliasing and stray blends, and those are exactly the pixels that
-- fragment regions into many tiny contours. Keeping the top N by pixel count
-- and snapping the rest to their nearest survivor removes that tail while
-- leaving the artwork's actual colours untouched.
--
-- @param counts map of packed RGBA -> pixel count
-- @param maxColors how many to keep
-- @return map of colour -> replacement colour, number kept, number merged
function M.quantize(counts, maxColors)
  local palette = {}
  for color, n in pairs(counts) do
    palette[#palette + 1] = { color = color, n = n }
  end
  if not maxColors or #palette <= maxColors then
    return nil, #palette, 0
  end

  table.sort(palette, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.color < b.color            -- stable ordering for equal counts
  end)

  local keep = {}
  for i = 1, maxColors do keep[i] = palette[i].color end

  local map = {}
  for i = maxColors + 1, #palette do
    local c = palette[i].color
    local best, bestD = keep[1], math.huge
    for j = 1, #keep do
      local d = distance(c, keep[j])
      if d < bestD then best, bestD = keep[j], d end
    end
    map[c] = best
  end
  return map, maxColors, #palette - maxColors
end

return M
