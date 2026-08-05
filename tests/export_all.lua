-- Headless end-to-end run over the in-scope art.
-- Usage: aseprite -b --script tests/export_all.lua
local ROOT = "/Users/kirill/projects/ase-tgs"
package.path = ROOT.."/src/?.lua;"..ROOT.."/vendor/?.lua;"..package.path
local exporter = require("export_tgs")

local files = {
  "Lexa-Messi","Mirana-Cat-Bob","Denis-Objection","Yarik-Nerd",
  "Maga-Papakha","Sanya-Techies","Pray-Team-Spirit",
}

print(string.format("%-19s %-7s %-6s %-7s %-6s %-9s %-9s %-7s %s",
  "SPRITE","SCALE","LAYRS","LOOPS","DEDUP","JSON","TGS","BUDGET","STATUS"))
print(string.rep("-",100))

local worst, worstName = 0, ""
local manifest = {}
for _, name in ipairs(files) do
  local path = "/Users/kirill/projects/art/"..name..".aseprite"
  local spr = app.open(path)
  if not spr then print(name.."  <open failed>") goto continue end
  do
    local t0 = os.clock()
    local stats, err = exporter.export(spr, ROOT.."/out/"..name..".tgs", {name=name})
    local dt = os.clock() - t0
    if err then print(name.."  ERROR: "..err) goto continue end

    local problems = exporter.validate(stats)
    local pct = stats.tgsBytes / exporter.MAX_BYTES * 100
    if pct > worst then worst, worstName = pct, name end
    manifest[#manifest+1] = string.format('"%s":{"scale":%d,"sampleAt":[%s]}',
      name, stats.scale, table.concat(stats.sampleAt, ","))
    print(string.format("%-19s %-7s %-6d %-7d %-6d %-9s %-9s %-7s %s",
      name,
      string.format("%gx", stats.scale),
      stats.layers, stats.loops, stats.dedup,
      string.format("%.0f KB", stats.jsonBytes/1024),
      string.format("%.1f KB", stats.tgsBytes/1024),
      string.format("%.0f%%", pct),
      #problems == 0 and string.format("OK (%.1fs)", dt) or table.concat(problems, "; ")))
    spr:close()
  end
  ::continue::
end
print(string.rep("-",100))
print(string.format("worst case: %s at %.0f%% of the 64 KB budget", worstName, worst))

-- sidecar so the rlottie regression test knows which Lottie frame corresponds
-- to which source frame
local mf = io.open(ROOT.."/out/manifest.json", "w")
mf:write("{"..table.concat(manifest, ",").."}")
mf:close()
