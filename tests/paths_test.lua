-- Path resolution for the export dialog.
-- Run: aseprite -b --script tests/paths_test.lua
--
-- Guards the "../ accumulation" bug: Aseprite's file widget resolves relative
-- values against the working directory and ignores its own `path` property, so
-- a picked location can come back relative, and re-picking re-relativises it.
-- Left alone the segments pile up until the directory does not exist.

local ROOT = "/Users/kirill/projects/ase-tgs"
package.path = ROOT .. "/src/?.lua;" .. package.path
local paths = require("paths")

local pass, fail = 0, 0
local function check(label, got, want)
  local ok = (got == want)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(string.format("  %-44s %s", label, ok and "PASS"
    or string.format("*** FAIL ***  got %s  want %s", tostring(got), tostring(want))))
end

local BASE = "/Users/kirill/projects/art"

print("=== isAbsolute ===")
check("unix absolute", paths.isAbsolute("/a/b"), true)
check("relative", paths.isAbsolute("a/b"), false)
check("dot-relative", paths.isAbsolute("../a"), false)
check("windows drive", paths.isAbsolute("C:\\a\\b"), true)
check("windows drive fwd", paths.isAbsolute("C:/a/b"), true)
check("empty", paths.isAbsolute(""), false)
check("nil", paths.isAbsolute(nil), false)

print("")
print("=== absolute: already-absolute paths are just collapsed ===")
check("plain", paths.absolute(BASE .. "/x.tgs"), BASE .. "/x.tgs")
check("one dotdot", paths.absolute(BASE .. "/../art/x.tgs"), BASE .. "/x.tgs")
check("dotdot through a file name",
  paths.absolute(BASE .. "/x.tgs/../x.tgs"), BASE .. "/x.tgs")
check("many dotdots",
  paths.absolute("/Users/kirill/projects/art/../../projects/art/x.tgs"), BASE .. "/x.tgs")

print("")
print("=== absolute: relative values resolve against the base ===")
check("bare name", paths.absolute("x.tgs", BASE), BASE .. "/x.tgs")
check("one dotdot", paths.absolute("../x.tgs", BASE), "/Users/kirill/projects/x.tgs")
check("two dotdots", paths.absolute("../../x.tgs", BASE), "/Users/kirill/x.tgs")
check("subdir", paths.absolute("sub/x.tgs", BASE), BASE .. "/sub/x.tgs")

print("")
print("=== the accumulation itself cannot build up ===")
-- Feeding the result back in is what the dialog does on every change; the
-- value has to reach a fixed point rather than growing each round.
local v = BASE .. "/x.tgs"
for _ = 1, 5 do v = paths.absolute(v, BASE) end
check("repeated resolution is a fixed point", v, BASE .. "/x.tgs")

-- and a value that did come back relative settles after one pass
local rel = "../art/x.tgs"
local once = paths.absolute(rel, BASE)
check("relative settles in one pass", paths.absolute(once, BASE), once)

print("")
print("=== values the widget actually produces ===")
-- Observed by driving the widget in a live editor session: it keeps its own
-- directory and re-expresses anything handed to it relative to that, so after
-- picking Downloads and then an art file the reported value looked like this.
-- Collapsing it has to land on the file the user really chose.
check("widget's relative-to-its-own-dir form",
  paths.absolute("/Users/kirill/Downloads/../projects/art/x.tgs"),
  "/Users/kirill/projects/art/x.tgs")
check("after several picks",
  paths.absolute("/Users/kirill/Downloads/../../kirill/projects/art/x.tgs"),
  "/Users/kirill/projects/art/x.tgs")

print("")
print("=== ensureFile: picking a folder instead of typing a name ===")
check("trailing slash gets the base appended",
  paths.ensureFile("/Users/kirill/Downloads/", "Sprite.tgs"),
  "/Users/kirill/Downloads/Sprite.tgs")
check("a real filename is left alone",
  paths.ensureFile("/Users/kirill/Downloads/x.tgs", "Sprite.tgs"),
  "/Users/kirill/Downloads/x.tgs")
check("extension-less name is treated as a filename, not a folder",
  paths.ensureFile("/Users/kirill/Downloads/x", "Sprite.tgs"),
  "/Users/kirill/Downloads/x")
check("backslash separator too",
  paths.ensureFile("C:\\Users\\kirill\\", "Sprite.tgs"),
  app.fs.joinPath("C:\\Users\\kirill\\", "Sprite.tgs"))
check("empty passes through", paths.ensureFile("", "Sprite.tgs"), "")
check("idempotent", paths.ensureFile(
  paths.ensureFile("/Users/kirill/Downloads/", "Sprite.tgs"), "Sprite.tgs"),
  "/Users/kirill/Downloads/Sprite.tgs")

print("")
print("=== the folder case end to end, as doExport chains them ===")
do
  local picked = "/Users/kirill/Downloads/"
  local p = paths.withExtension(
    paths.ensureFile(paths.absolute(picked), "Sprite.tgs"), "tgs")
  check("picking a folder yields a writable file path",
    p, "/Users/kirill/Downloads/Sprite.tgs")
end

print("")
print("=== withExtension ===")
check("adds when missing", paths.withExtension("/a/b", "tgs"), "/a/b.tgs")
check("keeps when present", paths.withExtension("/a/b.tgs", "tgs"), "/a/b.tgs")
check("case-insensitive", paths.withExtension("/a/b.TGS", "tgs"), "/a/b.TGS")
check("does not clobber another ext", paths.withExtension("/a/b.png", "tgs"), "/a/b.png.tgs")
check("empty passes through", paths.withExtension("", "tgs"), "")

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
