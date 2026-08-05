--- Orchestration: Aseprite sprite -> .tgs on disk.

local LibDeflate = require("LibDeflate")
local gzip       = require("gzip")
local json       = require("json_encode")
local trace      = require("pixel_trace")
local lottie     = require("lottie_build")
local reduce     = require("reduce")

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

-- Lowest gzip ratio observed on real art (measured 13x-24x). Used only to rule
-- work out: if even this optimistic ratio leaves us over budget, no compression
-- setting can rescue the file, and compressing it anyway costs seconds on
-- exactly the oversized art that triggers the case.
M.GZIP_RATIO_FLOOR = 12

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

--- Map selected frame durations onto Lottie frame indices.
local function timeline(frames, fr)
  local marks = { 0 }
  local t = 0
  for i = 1, #frames do
    t = t + frames[i].duration
    marks[i + 1] = math.floor(t * fr + 0.5)
  end
  -- guarantee every frame occupies at least one Lottie frame
  for i = 2, #marks do
    if marks[i] <= marks[i - 1] then marks[i] = marks[i - 1] + 1 end
  end
  return marks, t
end

--- Count how many pixels each colour covers across the selected frames.
local function countColors(sprite, frameList, spec)
  local counts = {}
  local W, H = spec.width, spec.height
  for _, f in ipairs(frameList) do
    local px = readFrame(sprite, f.number, spec)
    for i = 1, W * H do
      local v = px[i]
      if (v >> 24) & 0xFF > 0 then counts[v] = (counts[v] or 0) + 1 end
    end
  end
  return counts
end

--- Convert a sprite to a Lottie table plus stats. Does not touch the disk.
-- @param opts {
--   range     = { mode = "all"|"tag"|"frames", tag =, from =, to = },
--   fps       = target rate to resample down to (never up),
--   maxColors = palette ceiling,
--   fr, canvas, minCoverage, name }
-- @return doc, stats  (or nil, nil, error)
function M.buildLottie(sprite, opts)
  opts = opts or {}
  local fr = opts.fr or lottie.DEFAULT_FR
  local W, H = sprite.width, sprite.height
  local spec = ImageSpec{ width = W, height = H, colorMode = ColorMode.RGB, transparentColor = 0 }

  local frameList, err = reduce.selectFrames(sprite, opts.range)
  if not frameList then return nil, nil, err end
  if #frameList == 0 then return nil, nil, "no frames selected" end

  local sourceCount = #frameList
  frameList = reduce.rescale(frameList, opts.speed)
  frameList = reduce.decimate(frameList, opts.fps)

  local marks, totalSeconds = timeline(frameList, fr)

  local stats = {
    loops = 0, verts = 0, colors = 0, dedup = 0,
    frames = #frameList,
    droppedFrames = sourceCount - #frameList,
    mergedColors = 0,
  }

  -- Palette reduction needs to see every selected frame before it can decide
  -- which colours are the real ones, so it costs one extra read pass. Reading
  -- is cheap next to compression, and caching whole frames would not scale.
  local colorMap
  if opts.maxColors then
    local kept
    colorMap, kept, stats.mergedColors =
      reduce.quantize(countColors(sprite, frameList, spec), opts.maxColors)
    stats.paletteKept = kept
  end

  local frames = {}
  local prevRaw = nil

  for i, f in ipairs(frameList) do
    local px, raw = readFrame(sprite, f.number, spec)

    if raw == prevRaw and #frames > 0 then
      -- identical to the previous frame: stretch that layer instead of
      -- emitting a duplicate one
      frames[#frames].op = marks[i + 1]
      stats.dedup = stats.dedup + 1
    else
      if colorMap then
        for k = 1, W * H do
          local repl = colorMap[px[k]]
          if repl then px[k] = repl end
        end
      end

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
  -- Lottie frame at the midpoint of each selected frame's on-screen time. The
  -- rlottie regression test samples exactly here to line renders up with the
  -- original Aseprite frames.
  stats.sampleAt = {}
  for i = 1, #frameList do
    stats.sampleAt[i] = (marks[i] + marks[i + 1]) // 2
  end
  stats.scale = meta.scale
  stats.offX, stats.offY = meta.offX, meta.offY
  stats.durationFrames = meta.durationFrames
  return doc, stats
end

--- Everything except compression, so callers can see what they are in for
-- before paying for it. Compression is ~98% of export time, so this is the
-- cheap half.
-- @return jsonText, stats  (or nil, nil, error)
function M.prepare(sprite, opts)
  local doc, stats, err = M.buildLottie(sprite, opts)
  if not doc then return nil, nil, err end
  local text = json.encode(doc)
  stats.jsonBytes = #text
  -- Best case even a perfect compressor could manage.
  stats.floorBytes = math.floor(#text / M.GZIP_RATIO_FLOOR)
  stats.overBudget = stats.floorBytes > M.MAX_BYTES
  stats.overDuration = stats.seconds > lottie.MAX_DURATION + 1e-9
  return text, stats
end

--- Full pipeline: sprite -> .tgs bytes.
-- Refuses rather than writing a file Telegram will reject; pass opts.force to
-- get the bytes anyway.
-- @return bytes, stats, jsonText  (or nil, stats, error)
function M.toTgsBytes(sprite, opts)
  opts = opts or {}
  local text, stats, err = M.prepare(sprite, opts)
  if not text then return nil, nil, err end

  if not opts.force then
    if stats.overDuration then
      return nil, stats, string.format(
        "animation is %.2f s, over Telegram's 3 s limit -- export a tag or a "
        .. "shorter frame range, or pass speed=%.2f to fit",
        stats.seconds, stats.seconds / lottie.MAX_DURATION)
    end
    if stats.overBudget then
      return nil, stats, string.format(
        "projected size is at least %.0f KB, far over the 64 KB limit -- try "
        .. "fewer frames (fps=), a smaller palette (maxColors=), or fewer "
        .. "frames in range", stats.floorBytes / 1024)
    end
  end

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
-- @return stats  (or nil, error)
function M.export(sprite, path, opts)
  local bytes, stats, err = M.toTgsBytes(sprite, opts)
  if not bytes then return nil, err end
  local f, ioErr = io.open(path, "wb")
  if not f then
    return nil, "cannot open " .. tostring(path) .. ": " .. tostring(ioErr)
  end
  f:write(bytes)
  f:close()
  stats.path = path
  return stats
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
