--- Path handling for the export dialog.
--
-- Aseprite's file widget resolves relative values against the working
-- directory, ignoring the `path` property it was handed. A location picked
-- through it can therefore come back expressed relatively, and picking again
-- re-relativises what is already relative -- so "../" segments accumulate until
-- the directory no longer exists. Everything here exists to stop that.

local M = {}

--- True for "/foo" and for "C:\foo" / "C:/foo".
function M.isAbsolute(p)
  if not p or p == "" then return false end
  return p:sub(1, 1) == "/" or p:match("^%a:[\\/]") ~= nil
end

--- Resolve to an absolute, collapsed path.
-- @param p the path to resolve
-- @param base directory for relative paths; defaults to the working directory
function M.absolute(p, base)
  if not p or p == "" then return p end
  if not M.isAbsolute(p) then
    p = app.fs.joinPath(base or app.fs.currentPath, p)
  end
  return app.fs.normalizePath(p)
end

--- If the value names a directory rather than a file, put `base` inside it.
--
-- Picking a folder in the save dialog rather than typing a name yields a
-- directory, which is not somewhere a file can be written. The widget reports
-- directories with a trailing separator, which is what distinguishes them from
-- an extension-less filename the user typed on purpose.
function M.ensureFile(p, base)
  if not p or p == "" then return p end
  local last = p:sub(-1)
  if last == "/" or last == "\\" then
    return app.fs.joinPath(p, base)
  end
  return p
end

--- Ensure the path ends in the given extension.
function M.withExtension(p, ext)
  if not p or p == "" then return p end
  if app.fs.fileExtension(p):lower() == ext:lower() then return p end
  return p .. "." .. ext
end

return M
