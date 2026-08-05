-- Verify the packaged extension actually works from its installed layout.
-- Run: make extension && aseprite -b --script tests/extension_test.lua
--
-- The failure this guards against is packaging, not logic: main.lua resolves
-- its modules relative to plugin.path at runtime, so a missing file or a wrong
-- relative path only shows up once the tree is assembled the way Aseprite
-- installs it.

local BUILD = "/Users/kirill/projects/ase-tgs/build/ase-tgs"

local pass, fail = 0, 0
local function check(label, ok, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(string.format("  %-44s %s%s", label, ok and "PASS" or "*** FAIL ***",
    detail and ("  " .. detail) or ""))
end

print("=== PACKAGED LAYOUT ===")
for _, rel in ipairs({ "package.json", "main.lua",
                       "src/export_tgs.lua", "src/reduce.lua", "src/pixel_trace.lua",
                       "src/lottie_build.lua", "src/json_encode.lua", "src/gzip.lua",
                       "vendor/LibDeflate.lua" }) do
  local f = io.open(app.fs.joinPath(BUILD, rel), "r")
  check("bundled: " .. rel, f ~= nil)
  if f then f:close() end
end

print("")
print("=== MODULE RESOLUTION FROM plugin.path ===")
-- exactly what main.lua's loadModules does
package.path = table.concat({
  app.fs.joinPath(BUILD, "src", "?.lua"),
  app.fs.joinPath(BUILD, "vendor", "?.lua"),
  package.path,
}, ";")

local okReq, exporter = pcall(require, "export_tgs")
check("require('export_tgs') resolves", okReq, okReq and "" or tostring(exporter))
local okRed, reduce = pcall(require, "reduce")
check("require('reduce') resolves", okRed, okRed and "" or tostring(reduce))

if okReq then
  print("")
  print("=== END-TO-END THROUGH THE PACKAGED MODULES ===")
  local s = Sprite(16, 16, ColorMode.RGB)
  for _ = 2, 4 do s:newEmptyFrame() end
  for i = 1, #s.frames do
    s.frames[i].duration = 0.1
    local img = s.cels[i] and s.cels[i].image
    if img then
      for y = 0, 15 do for x = 0, 15 do
        img:drawPixel(x, y, ((x + y + i) % 3 == 0)
          and app.pixelColor.rgba(220, 60, 60, 255)
          or app.pixelColor.rgba(30, 30, 40, 255))
      end end
    end
  end
  local t = s:newTag(2, 3); t.name = "mid"

  local out = app.fs.joinPath(app.fs.tempPath, "ext_selftest.tgs")
  local stats, err = exporter.export(s, out, { range = { mode = "all" }, name = "selftest" })
  check("export writes a file", stats ~= nil, err or "")
  if stats then
    local f = io.open(out, "rb")
    local head = f and f:read(2)
    if f then f:close() end
    check("file is a gzip stream", head == "\x1f\x8b")
    check("within budget", stats.tgsBytes <= exporter.MAX_BYTES,
      string.format("%.1f KB", stats.tgsBytes / 1024))
  end

  local tagStats = exporter.export(s, out, { range = { mode = "tag", tag = "mid" }, name = "t" })
  check("tag range exports through the bundle", tagStats ~= nil and tagStats.frames == 2,
    tagStats and ("#" .. tagStats.frames) or "")

  s:close()
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
