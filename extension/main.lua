--- Aseprite extension entry point: adds "Export as .tgs" to the File menu.
--
-- All the real work lives in the modules under src/; this file is the editor
-- integration -- menu registration, the dialog, and turning refusals into
-- something a person can act on.

local exporter, reduce, paths

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
  paths    = require("paths")
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
  return paths.absolute(app.fs.joinPath(dir, base .. ".tgs"))
end

--- Speed is a percentage on the slider: 100 means "as authored".
local SPEED_MIN, SPEED_MAX, SPEED_DEFAULT = 25, 400, 100

--- Telegram's duration ceiling, mirrored here so the dialog can warn without
-- loading the exporter just to read a constant.
local lottieMaxSeconds = 3.0

--- Fixed footprint for the warning line. Reserved whether or not the warning
-- is showing, so the dialog never changes size.
local WARN_W, WARN_H = 210, 11

--- Theme text colour, so the warning stays legible in light and dark themes.
local function warningTextColor()
  local ok, c = pcall(function() return app.theme.color.text end)
  if ok and c then return c end
  return Color{ r = 0, g = 0, b = 0 }
end

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
  -- Never trust the widget's value to be absolute, or even to name a file; see
  -- src/paths.lua.
  local path = paths.absolute(data.output)

  if not path or path == "" then
    app.alert{ title = "Export .tgs", text = "Choose where to save the file." }
    return false
  end
  local base = sprite.filename and sprite.filename ~= ""
    and app.fs.fileTitle(sprite.filename) or "emoji"
  path = paths.ensureFile(path, base .. ".tgs")
  path = paths.withExtension(path, "tgs")

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
  local outPath = paths.absolute(p.output) or defaultOutput(sprite, plugin)

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
    dlg:modify{ id = "timing",
                text = secs and string.format("%.2fx  %.2f s", speed, secs) or "-" }
    dlg:repaint()   -- the warning canvas re-evaluates itself when it paints
  end

  -- Output first, mirroring Aseprite's own export dialog. `entry = true` is what
  -- makes file{} render as an editable path with a small "..." button beside it
  -- on one row, instead of a single wide button captioned with the filename.
  -- No onchange normalisation here, deliberately. The widget keeps its own
  -- directory and re-expresses whatever it is handed relative to that, so
  -- writing an absolute path back does not stick -- it comes out as
  -- ".../Downloads/../projects/art/x.tgs" and the next write compounds it.
  -- Worse, modify() re-fires onchange, which is what overflowed the stack.
  -- The value is normalised where it is actually used instead: on export, and
  -- when the dialog reopens.
  dlg:file{ id = "output", label = "Output File:", save = true,
            entry = true, filename = outPath, filetypes = { "tgs" } }

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
  -- The over-limit warning lives on its own line, on a canvas of fixed size.
  -- Putting it in the label above meant the text appearing and disappearing
  -- resized the whole dialog; a canvas reserves its space whether or not
  -- anything is painted into it, so nothing moves. "warning_box" is Aseprite's
  -- own warning icon -- the one on "Recover Files" and the update banner.
  dlg:canvas{ id = "warn", width = WARN_W, height = WARN_H,
              onpaint = function(ev)
                -- Worked out here rather than cached by refresh(): the first
                -- paint can happen before refresh() has ever run, and a stale
                -- flag then leaves the warning missing. Summing frame
                -- durations is cheap enough to redo on every paint.
                local secs = selectionSeconds(sprite, dlg.data)
                if not secs or secs <= lottieMaxSeconds + 1e-9 then return end
                local g = ev.context
                g:drawThemeImage("warning_box", 0, 0)
                g.color = warningTextColor()
                g:fillText("over Telegram's 3 s limit", 13, 1)
              end }
  -- Hitting an exact percentage by dragging is fiddly, so give the neutral
  -- value a target. A button carrying an onclick does not close the dialog.
  dlg:button{ id = "resetSpeed", text = "Reset to 100%",
              onclick = function()
                dlg:modify{ id = "speedPct", value = SPEED_DEFAULT }
                refresh()
              end }
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
