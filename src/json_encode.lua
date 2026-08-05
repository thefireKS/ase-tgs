--- Compact JSON serialisation.
--
-- Deliberately minimal: no whitespace, no key sorting, shortest possible number
-- formatting. Every byte here is a byte against the 64 KB .tgs budget.

local M = {}

local fmt = string.format
local concat = table.concat

--- Format a number as compactly as possible without losing precision we care
-- about. Integers must never render as "12.0", and we must never emit
-- scientific notation -- Lottie parsers reject it.
local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then
    error("cannot encode non-finite number: " .. tostring(v))
  end
  if math.type(v) == "integer" then
    return tostring(v)
  end
  -- float that happens to be integral -> emit as integer
  if v == math.floor(v) and math.abs(v) < 1e15 then
    return fmt("%d", v)
  end
  -- 6 decimals: coordinates are integers, so the only floats here are colour
  -- channels, and those need this much precision to survive rlottie's
  -- truncating conversion back to 8 bits (see channel() in lottie_build).
  -- Trailing zeros are stripped, so values that need less stay short.
  local s = fmt("%.6f", v)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end
M.num = num

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
  ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function str(s)
  local out = s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or fmt("\\u%04x", c:byte())
  end)
  return '"' .. out .. '"'
end

--- Marker so callers can force an empty table to encode as [] rather than {}.
M.EMPTY_ARRAY = setmetatable({}, { __tostring = function() return "[]" end })

local encode

local function is_array(t)
  return #t > 0 or t == M.EMPTY_ARRAY
end

encode = function(v, buf)
  local tv = type(v)
  if v == nil then
    buf[#buf + 1] = "null"
  elseif tv == "number" then
    buf[#buf + 1] = num(v)
  elseif tv == "string" then
    buf[#buf + 1] = str(v)
  elseif tv == "boolean" then
    buf[#buf + 1] = v and "true" or "false"
  elseif tv == "table" then
    if is_array(v) then
      buf[#buf + 1] = "["
      for i = 1, #v do
        if i > 1 then buf[#buf + 1] = "," end
        encode(v[i], buf)
      end
      buf[#buf + 1] = "]"
    else
      -- "ty" MUST be serialised first. rlottie -- the renderer Telegram
      -- actually uses -- parses shape objects as a stream: it dispatches on
      -- "ty" and then interprets the *remainder* of the object according to
      -- that type, so any key appearing before "ty" is lost. lottie-web reads
      -- the whole object into memory first and so is insensitive to order,
      -- which is exactly how a file can render perfectly in a web player and
      -- come out completely blank in Telegram.
      buf[#buf + 1] = "{"
      local first = true
      local function emit(k, val)
        if not first then buf[#buf + 1] = "," end
        first = false
        buf[#buf + 1] = str(tostring(k))
        buf[#buf + 1] = ":"
        encode(val, buf)
      end
      if v.ty ~= nil then emit("ty", v.ty) end
      for k, val in pairs(v) do
        if k ~= "ty" then emit(k, val) end
      end
      buf[#buf + 1] = "}"
    end
  else
    error("cannot encode value of type " .. tv)
  end
end

--- Encode a Lua value as a compact JSON string.
function M.encode(v)
  local buf = {}
  encode(v, buf)
  return concat(buf)
end

return M
