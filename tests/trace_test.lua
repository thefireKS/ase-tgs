-- Unit tests for the contour tracer.
-- Run: aseprite -b --script tests/trace_test.lua
--
-- The strong invariant here is the shoelace area: summing the signed area of
-- every traced contour must equal the number of filled pixels exactly. That
-- catches both wrong geometry and wrong hole winding -- a hole traced in the
-- same direction as its outer contour would add area instead of subtracting it.

local ROOT = "/Users/kirill/projects/ase-tgs"
package.path = ROOT .. "/src/?.lua;" .. package.path
local PT = require("pixel_trace")

local function shoelace(pts)
  local a, n = 0, #pts // 2
  for i = 0, n - 1 do
    local x1, y1 = pts[i * 2 + 1], pts[i * 2 + 2]
    local j = (i + 1) % n
    local x2, y2 = pts[j * 2 + 1], pts[j * 2 + 2]
    a = a + (x1 * y2 - x2 * y1)
  end
  return a / 2
end

local pass, fail = 0, 0

--- @param rows ASCII art of the mask; '#' is filled
local function case(name, W, H, rows, wantLoops, wantVerts)
  local cells = {}
  for y = 1, #rows do
    local r = rows[y]
    for x = 1, #r do
      if r:sub(x, x) == "#" then cells[#cells + 1] = (y - 1) * W + (x - 1) end
    end
  end
  local loops = PT.traceColor(cells, W, H)
  local totalArea, totalVerts, desc = 0, 0, {}
  for _, lp in ipairs(loops) do
    local a = shoelace(lp)
    totalArea = totalArea + a
    totalVerts = totalVerts + #lp // 2
    desc[#desc + 1] = string.format("%dv/%+.0f", #lp // 2, a)
  end
  local areaOK = math.abs(math.abs(totalArea) - #cells) < 1e-9
  local ok = (#loops == wantLoops) and areaOK and (wantVerts == nil or totalVerts == wantVerts)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(string.format("%-22s loops=%d(want %d) verts=%-3d area=%+.0f(px %d) [%s] %s",
    name, #loops, wantLoops, totalVerts, totalArea, #cells,
    table.concat(desc, " "), ok and "PASS" or "*** FAIL ***"))
end

print("=== CONTOUR TRACER UNIT TESTS ===")
case("single pixel",   3, 3, { "...", ".#.", "..." }, 1, 4)
case("2x2 block",      4, 4, { "....", ".##.", ".##.", "...." }, 1, 4)
case("horizontal 3x1", 5, 3, { ".....", ".###.", "....." }, 1, 4)
case("vertical 1x3",   3, 5, { "...", ".#.", ".#.", ".#.", "..." }, 1, 4)
case("L-shape",        4, 4, { "....", ".#..", ".#..", ".##." }, 1, 6)
case("plus sign",      5, 5, { ".....", "..#..", ".###..", "..#..", "....." }, 1, 12)
-- a hole must come out wound opposite to its outer contour
case("donut (hole)",   5, 5, { ".....", ".###.", ".#.#.", ".###.", "....." }, 2, 8)
case("two separate",   5, 3, { ".....", ".#.#.", "....." }, 2, 8)
-- corner-touching components must not stitch into one figure-eight loop
case("diagonal touch", 4, 4, { "....", ".#..", "..#.", "...." }, 2, 8)
case("full canvas",    3, 3, { "###", "###", "###" }, 1, 4)
-- worst case for path count: every pixel its own contour
case("checkerboard",   4, 4, { "#.#.", ".#.#", "#.#.", ".#.#" }, 8, 32)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
