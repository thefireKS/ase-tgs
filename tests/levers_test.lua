-- Frame selection, the size/duration levers, and limit enforcement.
-- Run: aseprite -b --script tests/levers_test.lua

local ROOT = "/Users/kirill/projects/ase-tgs"
package.path = ROOT .. "/src/?.lua;" .. ROOT .. "/vendor/?.lua;" .. package.path
local exporter = require("export_tgs")
local reduce   = require("reduce")

local pass, fail = 0, 0
local function check(label, ok, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(string.format("  %-46s %s%s", label, ok and "PASS" or "*** FAIL ***",
    detail and ("  " .. detail) or ""))
end

--- A sprite with tags, so range selection has something to select.
local function makeSprite(n, frames)
  local s = Sprite(n, n, ColorMode.RGB)
  for _ = 2, frames do s:newEmptyFrame() end
  for i = 1, #s.frames do
    s.frames[i].duration = 0.1
    local img = s.cels[i] and s.cels[i].image
    if img then
      for y = 0, n - 1 do for x = 0, n - 1 do
        local c = ((x + y + i) % 4 < 2)
          and app.pixelColor.rgba(200, 40, 40, 255)
          or app.pixelColor.rgba(40, 40, 200, 255)
        img:drawPixel(x, y, c)
      end end
    end
  end
  return s
end

print("=== FRAME RANGE SELECTION ===")
do
  local s = makeSprite(16, 10)
  local t = s:newTag(3, 6); t.name = "walk"

  local all = reduce.selectFrames(s, { mode = "all" })
  check("all -> every frame", #all == 10, "#" .. #all)

  local tag = reduce.selectFrames(s, { mode = "tag", tag = "walk" })
  check("tag -> that tag's span", #tag == 4 and tag[1].number == 3, "#" .. #tag)

  local rng = reduce.selectFrames(s, { mode = "frames", from = 2, to = 5 })
  check("frames A..B", #rng == 4 and rng[1].number == 2 and rng[4].number == 5, "#" .. #rng)

  local clamped = reduce.selectFrames(s, { mode = "frames", from = 8, to = 999 })
  check("frames clamps past the end", #clamped == 3, "#" .. #clamped)

  local _, err = reduce.selectFrames(s, { mode = "tag", tag = "nope" })
  check("missing tag reports available names", err ~= nil and err:find("walk") ~= nil)

  local _, err2 = reduce.selectFrames(s, { mode = "frames", from = 9, to = 2 })
  check("inverted range refused", err2 ~= nil)
  s:close()
end

print("")
print("=== DECIMATE (fps) keeps duration, drops frames ===")
do
  local s = makeSprite(16, 10)          -- 10 frames x 100ms = 1.0s = 10fps
  local frames = reduce.selectFrames(s, { mode = "all" })

  local half = reduce.decimate(frames, 5)
  local function total(fs)
    local t = 0 ; for _, f in ipairs(fs) do t = t + f.duration end ; return t
  end
  check("5fps halves the frame count", #half == 5, "#" .. #half)
  check("running time preserved", math.abs(total(half) - 1.0) < 1e-9,
    string.format("%.2fs", total(half)))

  local up = reduce.decimate(frames, 60)
  check("never upsamples", #up == 10, "#" .. #up)
  s:close()
end

print("")
print("=== RESCALE (speed) keeps frames, changes duration ===")
do
  local s = makeSprite(16, 10)
  local frames = reduce.selectFrames(s, { mode = "all" })
  local fast = reduce.rescale(frames, 2)
  local t = 0 ; for _, f in ipairs(fast) do t = t + f.duration end
  check("2x speed halves the duration", math.abs(t - 0.5) < 1e-9, string.format("%.2fs", t))
  check("2x speed keeps every frame", #fast == 10, "#" .. #fast)
  check("speedToFit computes the ratio",
    math.abs(reduce.speedToFit(frames, 0.5) - 2.0) < 1e-9)
  check("speedToFit nil when already fitting", reduce.speedToFit(frames, 5) == nil)
  s:close()
end

print("")
print("=== PALETTE REDUCTION ===")
do
  local counts = {}
  -- three dominant colours plus a tail of near-duplicates
  counts[0xFF0000FF] = 1000
  counts[0xFF00FF00] = 900
  counts[0xFFFF0000] = 800
  for i = 1, 20 do counts[0xFF0000FF - i] = 5 end
  local map, kept, merged = reduce.quantize(counts, 3)
  check("keeps the requested count", kept == 3, "kept " .. kept)
  check("merges the tail", merged == 20, "merged " .. merged)
  check("dominant colours survive untouched",
    map[0xFF0000FF] == nil and map[0xFF00FF00] == nil)
  check("tail snaps to a survivor", map[0xFF0000FF - 1] ~= nil)

  local none = reduce.quantize(counts, 100)
  check("no-op when under the ceiling", none == nil)
end

print("")
print("=== LIMIT ENFORCEMENT ===")
do
  local s = makeSprite(16, 8)
  for i = 1, #s.frames do s.frames[i].duration = 0.6 end   -- 4.8s
  local bytes, stats, err = exporter.toTgsBytes(s, { name = "long" })
  check("over 3s refuses to produce a file", bytes == nil and err ~= nil)
  check("refusal suggests a concrete speed", err and err:find("speed=1.60") ~= nil, err and "" or "")

  local forced = exporter.toTgsBytes(s, { name = "long", force = true })
  check("force overrides the refusal", forced ~= nil)

  local fitted, st2 = exporter.toTgsBytes(s, { name = "long", speed = 1.6 })
  check("suggested speed actually fits", fitted ~= nil and st2.seconds <= 3.0 + 1e-9,
    st2 and string.format("%.2fs", st2.seconds) or "")
  s:close()
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
