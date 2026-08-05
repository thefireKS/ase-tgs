--- Orchestration: Aseprite sprite -> .tgs on disk.

local LibDeflate = require("LibDeflate")
local gzip       = require("gzip")
local json       = require("json_encode")
local trace      = require("pixel_trace")
local lottie     = require("lottie_build")

local M = {}

M.MAX_BYTES = 64 * 1024

-- Compression dominates export time -- measured at 98% of it, with contour
-- tracing barely registering. Level 6 is the knee of the curve: roughly 4x
-- faster than level 9 for about 3% more bytes, and level 9 buys essentially
-- nothing over level 8 while costing another half second. Start fast and only
-- pay for maximum compression if the budget is actually missed.
M.DEFAULT_LEVEL = 6
M.MAX_LEVEL = 9
-- How far over budget is still worth a second, slower compression pass.
M.RETRY_MARGIN = 1.15

--- Read one flattened frame as packed RGBA uint32s.
-- Uses Image.bytes + string.unpack rather than per-pixel getPixel, which
-- measured ~25x faster on this runtime.
local function readFrame(sprite, frameNumber, spec)
  local img = Image(spec)
  img:drawSprite(sprite, frameNumber)
  local raw = img.bytes
  local W, H = spec.width, spec.height
  return { string.unpack(string.rep("I4", W * H), raw) }, raw
end

--- Convert Aseprite's per-frame durations (seconds) into Lottie frame indices.
local function timeline(sprite, fr)
  local marks = { 0 }
  local t = 0
  for i = 1, #sprite.frames do
    t = t + sprite.frames[i].duration
    marks[i + 1] = math.floor(t * fr + 0.5)
  end
  -- guarantee every frame occupies at least one Lottie frame
  for i = 2, #marks do
    if marks[i] <= marks[i - 1] then marks[i] = marks[i - 1] + 1 end
  end
  return marks, t
end

--- Convert a sprite to a Lottie table plus stats. Does not touch the disk.
function M.buildLottie(sprite, opts)
  opts = opts or {}
  local fr = opts.fr or lottie.DEFAULT_FR
  local W, H = sprite.width, sprite.height
  local spec = ImageSpec{ width = W, height = H, colorMode = ColorMode.RGB, transparentColor = 0 }

  local marks, totalSeconds = timeline(sprite, fr)

  local frames = {}
  local prevRaw = nil
  local stats = { loops = 0, verts = 0, colors = 0, dedup = 0, frames = #sprite.frames }

  for i = 1, #sprite.frames do
    local px, raw = readFrame(sprite, i, spec)

    if raw == prevRaw and #frames > 0 then
      -- identical to the previous frame: stretch that layer instead of
      -- emitting a duplicate one
      frames[#frames].op = marks[i + 1]
      stats.dedup = stats.dedup + 1
    else
      local byColor, ncol = trace.groupByColor(px, W, H)
      if ncol > stats.colors then stats.colors = ncol end

      local shapes = {}
      for color, cells in pairs(byColor) do
        local loops = trace.traceColor(cells, W, H)
        if #loops > 0 then
          shapes[#shapes + 1] = { loops = loops, color = color }
          stats.loops = stats.loops + #loops
          for _, lp in ipairs(loops) do stats.verts = stats.verts + #lp // 2 end
        end
      end

      frames[#frames + 1] = { shapes = shapes, ip = marks[i], op = marks[i + 1] }
    end
    prevRaw = raw
  end

  local doc, meta = lottie.build(frames, {
    width = W, height = H, fr = fr,
    name = opts.name or (sprite.filename and sprite.filename:match("([^/\\]+)%.%w+$")) or "emoji",
    canvas = opts.canvas, minCoverage = opts.minCoverage,
  })

  stats.layers = #frames
  stats.seconds = totalSeconds
  -- Lottie frame at the midpoint of each source frame's on-screen time. The
  -- rlottie regression test samples exactly here to line renders up with the
  -- original Aseprite frames.
  stats.sampleAt = {}
  for i = 1, #sprite.frames do
    stats.sampleAt[i] = (marks[i] + marks[i + 1]) // 2
  end
  stats.scale = meta.scale
  stats.offX, stats.offY = meta.offX, meta.offY
  stats.durationFrames = meta.durationFrames
  return doc, stats
end

--- Full pipeline: sprite -> .tgs bytes.
function M.toTgsBytes(sprite, opts)
  opts = opts or {}
  local doc, stats = M.buildLottie(sprite, opts)
  local text = json.encode(doc)
  stats.jsonBytes = #text

  local level = opts.level or M.DEFAULT_LEVEL
  local bytes = gzip.compress(LibDeflate, text, level)
  -- Retry at maximum compression only when it could plausibly help. Going from
  -- level 6 to 9 recovers a few percent, so a file that is far past the budget
  -- is unsalvageable and a second pass just burns seconds -- and the second
  -- pass is expensive precisely for the oversized art that triggers it.
  if not opts.level and level < M.MAX_LEVEL
     and #bytes > M.MAX_BYTES and #bytes <= M.MAX_BYTES * M.RETRY_MARGIN then
    local tighter = gzip.compress(LibDeflate, text, M.MAX_LEVEL)
    if #tighter < #bytes then
      bytes, level = tighter, M.MAX_LEVEL
    end
  end

  stats.level = level
  stats.tgsBytes = #bytes
  stats.problems = M.validate(stats)
  return bytes, stats, text
end

--- Full pipeline including the write.
function M.export(sprite, path, opts)
  local bytes, stats, text = M.toTgsBytes(sprite, opts)
  local f, err = io.open(path, "wb")
  if not f then
    return nil, "cannot open " .. tostring(path) .. ": " .. tostring(err)
  end
  f:write(bytes)
  f:close()
  stats.path = path
  return stats, nil, text
end

--- Check the result against Telegram's published limits.
-- @return list of problem strings (empty when the file is acceptable)
function M.validate(stats)
  local problems = {}
  if stats.tgsBytes and stats.tgsBytes > M.MAX_BYTES then
    problems[#problems + 1] = string.format(
      "file is %.1f KB, over the 64 KB limit", stats.tgsBytes / 1024)
  end
  if stats.seconds and stats.seconds > lottie.MAX_DURATION + 1e-9 then
    problems[#problems + 1] = string.format(
      "animation is %.2f s, over the 3 s limit", stats.seconds)
  end
  return problems
end

return M
