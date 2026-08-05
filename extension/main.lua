--- Aseprite extension entry point: adds "Export as .tgs" to the File menu.
--
-- All the real work lives in the modules under src/; this file is the editor
-- integration -- menu registration, the dialog, and turning refusals into
-- something a person can act on.

local exporter, reduce

--- Modules are loaded relative to the installed extension, whose location is
-- only known at runtime.
local function loadModules(plugin)
  if exporter then return end
  package.path = table.concat({
    app.fs.joinPath(plugin.path, "src", "?.lua"),
    app.fs.joinPath(plugin.path, "vendor", "?.lua"),
    package.path,
  }, ";")
  exporter = require("export_tgs")
  reduce   = require("reduce")
end

local MODE_ALL, MODE_TAG, MODE_RANGE = "Whole animation", "Tag", "Frame range"

--- Where to put the file if the user has not chosen yet: next to the sprite,
-- same base name.
local function defaultOutput(sprite, plugin)
  local dir, base = plugin.preferences.lastDir, "emoji"
  if sprite.filename and sprite.filename ~= "" then
    base = app.fs.fileTitle(sprite.filename)
    dir = dir or app.fs.filePath(sprite.filename)
  end
  dir = dir or app.fs.userDocsPath
  return app.fs.joinPath(dir, base .. ".tgs")
end

--- Speed is a percentage on the slider: 100 means "as authored".
local SPEED_MIN, SPEED_MAX, SPEED_DEFAULT = 25, 400, 100

local function rangeFrom(data)
  if data.mode == MODE_TAG then
    return { mode = "tag", tag = data.tag }
  elseif data.mode == MODE_RANGE then
    return { mode = "frames", from = data.from, to = data.to }
  end
  return { mode = "all" }
end

--- Translate dialog fields into exporter options. Zero means "off" for the
-- levers so the dialog needs no extra checkboxes.
local function optionsFrom(data, sprite)
  local speed = (data.speedPct or SPEED_DEFAULT) / 100
  return {
    range     = rangeFrom(data),
    speed     = (speed ~= 1) and speed or nil,
    fps       = (data.fps and data.fps > 0) and data.fps or nil,
    maxColors = (data.maxColors and data.maxColors > 0) and data.maxColors or nil,
    name      = sprite.filename and app.fs.fileTitle(sprite.filename) or "emoji",
  }
end

--- Running time of the current selection, for the live readout under the
-- slider. Only touches frame durations, never pixels, so it is cheap enough to
-- recompute on every slider step.
local function selectionSeconds(sprite, data)
  local frames = reduce.selectFrames(sprite, rangeFrom(data))
  if not frames then return nil end
  local total = 0
  for _, f in ipairs(frames) do total = total + f.duration end
  return total / ((data.speedPct or SPEED_DEFAULT) / 100)
end

local showDialog   -- forward declaration: failure re-opens the dialog

--- Run the export and report. Returns true when a file was written.
local function doExport(plugin, sprite, data)
  local opts = optionsFrom(data, sprite)
  local path = data.output

  if not path or path == "" then
    app.alert{ title = "Export .tgs", text = "Choose where to save the file." }
    return false
  end
  if app.fs.fileExtension(path):lower() ~= "tgs" then
    path = path .. ".tgs"
  end

  local stats, err = exporter.export(sprite, path, opts)

  if not stats then
    -- A refusal names the lever that fixes it; keep the user's settings so they
    -- can adjust rather than re-entering everything.
    local choice = app.alert{
      title = "Cannot export",
      text = { "This sprite does not fit Telegram's limits:", err or "unknown error" },
      buttons = { "Adjust", "Export anyway", "Cancel" },
    }
    if choice == 1 then
      return false, data
    elseif choice == 2 then
      opts.force = true
      local forced, ferr = exporter.export(sprite, path, opts)
      if not forced then
        app.alert{ title = "Export failed", text = ferr or "unknown error" }
        return false
      end
      stats = forced
    else
      return true   -- cancelled outright; do not reopen
    end
  end

  plugin.preferences.lastDir    = app.fs.filePath(path)
  plugin.preferences.mode       = data.mode
  plugin.preferences.speedPct   = data.speedPct
  plugin.preferences.fps        = data.fps
  plugin.preferences.maxColors  = data.maxColors

  local pct = stats.tgsBytes / exporter.MAX_BYTES * 100
  local lines = {
    string.format("Saved %s", app.fs.fileName(path)),
    string.format("%.1f KB of the 64 KB budget (%.0f%%)", stats.tgsBytes / 1024, pct),
    string.format("%d frames, %.2f s, upscaled %gx", stats.layers, stats.seconds, stats.scale),
  }
  if stats.droppedFrames and stats.droppedFrames > 0 then
    lines[#lines + 1] = string.format("%d frames dropped by the fps setting", stats.droppedFrames)
  end
  if stats.mergedColors and stats.mergedColors > 0 then
    lines[#lines + 1] = string.format("%d colours merged into %d", stats.mergedColors, stats.paletteKept)
  end
  if #stats.problems > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Warning: " .. table.concat(stats.problems, "; ")
  end
  app.alert{ title = "Export .tgs", text = lines }
  return true
end

showDialog = function(plugin, prefill)
  local sprite = app.sprite
  if not sprite then
    app.alert{ title = "Export .tgs", text = "Open a sprite first." }
    return
  end

  local prefs = plugin.preferences
  local p = prefill or {}

  local tagNames = {}
  for _, t in ipairs(sprite.tags) do tagNames[#tagNames + 1] = t.name end
  local hasTags = #tagNames > 0

  local modes = { MODE_ALL, MODE_RANGE }
  if hasTags then table.insert(modes, 2, MODE_TAG) end
  local mode = p.mode or prefs.mode or MODE_ALL
  -- a remembered "Tag" is meaningless on a sprite without tags
  if mode == MODE_TAG and not hasTags then mode = MODE_ALL end

  local dlg = Dialog{ title = "Export as .tgs" }
  local outPath = p.output or defaultOutput(sprite, plugin)

  local function refresh()
    local m = dlg.data.mode
    dlg:modify{ id = "tag",  visible = (m == MODE_TAG) }
    dlg:modify{ id = "from", visible = (m == MODE_RANGE) }
    dlg:modify{ id = "to",   visible = (m == MODE_RANGE) }

    -- Show what the current settings actually produce. The 3 s ceiling is the
    -- limit people hit first, so say plainly when it is breached instead of
    -- letting them find out only on export.
    local secs = selectionSeconds(sprite, dlg.data)
    local speed = (dlg.data.speedPct or SPEED_DEFAULT) / 100
    local note
    if not secs then
      note = "-"
    elseif secs > 3.0 + 1e-9 then
      note = string.format("%.2fx  %.2f s  -- over the 3 s limit", speed, secs)
    else
      note = string.format("%.2fx  %.2f s", speed, secs)
    end
    dlg:modify{ id = "timing", text = note }
  end

  -- Output first, mirroring Aseprite's own export dialog. The path is an
  -- editable entry rather than only a button; the picker below writes into it.
  -- (The scripting Dialog API puts every labelled widget on its own row, so the
  -- native "entry + ... button" single row cannot be reproduced here.)
  dlg:entry{ id = "output", label = "Output File:", text = outPath }
  dlg:file{ id = "browse", save = true, filetypes = { "tgs" }, filename = outPath,
            onchange = function()
              if dlg.data.browse and dlg.data.browse ~= "" then
                dlg:modify{ id = "output", text = dlg.data.browse }
              end
            end }

  dlg:separator()
  dlg:combobox{ id = "mode", label = "Frames:", option = mode, options = modes,
                onchange = refresh }
  if hasTags then
    dlg:combobox{ id = "tag", label = "Tag:", option = p.tag or tagNames[1],
                  options = tagNames, onchange = refresh }
  else
    -- keep the field present so dlg.data.tag is always defined
    dlg:combobox{ id = "tag", label = "Tag:", option = "", options = { "" } }
  end
  dlg:number{ id = "from", label = "From frame:", text = tostring(p.from or 1),
              decimals = 0, onchange = refresh }
  dlg:number{ id = "to", label = "To frame:", text = tostring(p.to or #sprite.frames),
              decimals = 0, onchange = refresh }

  dlg:separator{ text = "Fitting Telegram's limits" }
  dlg:slider{ id = "speedPct", label = "Speed %:",
              min = SPEED_MIN, max = SPEED_MAX,
              value = p.speedPct or prefs.speedPct or SPEED_DEFAULT,
              onchange = refresh }
  dlg:label{ id = "timing", label = "", text = "" }
  dlg:number{ id = "fps", label = "Target FPS:",
              text = tostring(p.fps or prefs.fps or 0), decimals = 0 }
  dlg:number{ id = "maxColors", label = "Max colours:",
              text = tostring(p.maxColors or prefs.maxColors or 0), decimals = 0 }
  dlg:label{ label = "", text = "0 = leave as is" }

  dlg:separator()
  dlg:button{ id = "ok", text = "Export", focus = true }
  dlg:button{ id = "cancel", text = "Cancel" }

  refresh()
  dlg:show()

  local data = dlg.data
  if not data.ok then return end

  local done, keep = doExport(plugin, sprite, data)
  if not done and keep then
    showDialog(plugin, keep)   -- reopen with the user's settings intact
  end
end

function init(plugin)
  plugin:newCommand{
    id = "ExportTgs",
    title = "Export as .tgs (Telegram)...",
    group = "file_export",
    onclick = function()
      loadModules(plugin)
      showDialog(plugin)
    end,
  }
end

function exit(plugin) end
