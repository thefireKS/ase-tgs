-- Rasterise our own Lottie output back to pixels and diff against the source.
-- All our edges are axis-aligned with integer coords, so a scanline fill with
-- non-zero winding reproduces exactly what rlottie will fill. A perfect match
-- proves the contours AND the hole winding are correct.
local ROOT = "/Users/kirill/projects/ase-tgs"
package.path = ROOT.."/src/?.lua;"..ROOT.."/vendor/?.lua;"..package.path
local exporter = require("export_tgs")

local function rasterizeGroup(loops, W, H, put, color)
  for y = 0, H - 1 do
    local yc = y + 0.5
    local xs = {}
    for _, pts in ipairs(loops) do
      local n = #pts // 2
      for k = 0, n - 1 do
        local x1, y1 = pts[k*2+1], pts[k*2+2]
        local j = (k + 1) % n
        local x2, y2 = pts[j*2+1], pts[j*2+2]
        if x1 == x2 and y1 ~= y2 then                 -- vertical edge
          local lo, hi = math.min(y1,y2), math.max(y1,y2)
          if yc > lo and yc < hi then
            xs[#xs+1] = { x1, (y2 > y1) and 1 or -1 }
          end
        end
      end
    end
    table.sort(xs, function(a,b) return a[1] < b[1] end)
    local wind = 0
    for i = 1, #xs - 1 do
      wind = wind + xs[i][2]
      if wind ~= 0 then
        for x = math.floor(xs[i][1]), math.ceil(xs[i+1][1]) - 1 do
          if x >= 0 and x < W then put(x, y, color) end
        end
      end
    end
  end
end

local files = {"Lexa-Messi","Mirana-Cat-Bob","Denis-Objection","Yarik-Nerd",
               "Maga-Papakha","Sanya-Techies","Pray-Team-Spirit"}

print(string.format("%-19s %-7s %-11s %-11s %s","SPRITE","FRAMES","PIXELS","MISMATCHES","VERDICT"))
print(string.rep("-",70))
local totalBad = 0
for _, name in ipairs(files) do
  local spr = app.open("/Users/kirill/projects/art/"..name..".aseprite")
  if spr then
    local W,H = spr.width, spr.height
    local spec = ImageSpec{width=W,height=H,colorMode=ColorMode.RGB,transparentColor=0}
    local doc = exporter.buildLottie(spr, {name=name})

    -- layers were reversed for draw order; walk them back to source order
    local layers = {}
    for i = #doc.layers, 1, -1 do layers[#layers+1] = doc.layers[i] end

    local checked, bad, li = 0, 0, 1
    local marks = {}
    local t = 0
    for i=1,#spr.frames do marks[i] = math.floor(t*60+0.5); t = t + spr.frames[i].duration end

    for fi = 1, #spr.frames do
      -- find the layer covering this frame's start time
      local L = nil
      for _, lay in ipairs(layers) do
        if marks[fi] >= lay.ip and marks[fi] < lay.op then L = lay break end
      end
      if L then
        local canvas = {}
        local function put(x,y,c) canvas[y*W+x] = c end
        for _, grp in ipairs(L.shapes) do
          local loops, color = {}, nil
          for _, it in ipairs(grp.it) do
            if it.ty == "sh" then
              local flat = {}
              for _, p in ipairs(it.ks.k.v) do flat[#flat+1]=p[1]; flat[#flat+1]=p[2] end
              loops[#loops+1] = flat
            elseif it.ty == "fl" then
              local k = it.c.k
              color = { math.floor(k[1]*255+0.5), math.floor(k[2]*255+0.5), math.floor(k[3]*255+0.5) }
            end
          end
          rasterizeGroup(loops, W, H, put, color)
        end
        -- compare against the real flattened frame
        local img = Image(spec)
        img:drawSprite(spr, fi)
        local px = {string.unpack(string.rep("I4", W*H), img.bytes)}
        for y=0,H-1 do for x=0,W-1 do
          local v = px[y*W+x+1]
          local a = (v>>24)&0xFF
          local src = (a>0) and {v&0xFF,(v>>8)&0xFF,(v>>16)&0xFF} or nil
          local got = canvas[y*W+x]
          checked = checked + 1
          local match
          if src == nil and got == nil then match = true
          elseif src and got then match = (src[1]==got[1] and src[2]==got[2] and src[3]==got[3])
          else match = false end
          if not match then bad = bad + 1 end
        end end
      end
    end
    totalBad = totalBad + bad
    print(string.format("%-19s %-7d %-11d %-11d %s", name, #spr.frames, checked, bad,
      bad == 0 and "PIXEL-PERFECT" or "*** MISMATCH ***"))
    spr:close()
  end
end
print(string.rep("-",70))
print(totalBad == 0 and "ALL SPRITES REPRODUCE EXACTLY" or ("TOTAL MISMATCHED PIXELS: "..totalBad))
