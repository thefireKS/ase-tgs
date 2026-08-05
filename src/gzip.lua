--- gzip container (RFC 1952) on top of LibDeflate's raw DEFLATE stream.
--
-- LibDeflate ships DEFLATE (RFC 1951) and zlib (RFC 1950) but not gzip, and
-- only exposes Adler32 -- which is zlib's checksum. gzip needs CRC32, so we
-- provide it here.
--
-- A .tgs file is exactly gzip(lottie_json), so this is the final stage of the
-- export pipeline.

local M = {}

-- CRC32 (IEEE 802.3 polynomial, reflected: 0xEDB88320) -----------------------

local crc_table = nil

local function build_crc_table()
  local t = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if c & 1 == 1 then
        c = 0xEDB88320 ~ (c >> 1)
      else
        c = c >> 1
      end
    end
    t[i] = c
  end
  return t
end

--- CRC32 of a string, optionally continuing from a previous value.
-- @param s string
-- @param crc previous crc to continue from (omit to start fresh)
-- @return number in [0, 2^32)
function M.crc32(s, crc)
  crc_table = crc_table or build_crc_table()
  local c = (crc or 0) ~ 0xFFFFFFFF
  local byte = string.byte
  local t = crc_table
  for i = 1, #s do
    c = t[(c ~ byte(s, i)) & 0xFF] ~ (c >> 8)
  end
  return (c ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

-- gzip container -------------------------------------------------------------

local function u32le(n)
  return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
end

--- Wrap raw DEFLATE output in a gzip container.
-- @param deflated raw DEFLATE stream (LibDeflate:CompressDeflate)
-- @param original the uncompressed input, needed for CRC32 and ISIZE
-- @return gzip byte string
function M.wrap(deflated, original)
  local header = string.char(
    0x1F, 0x8B, -- magic
    0x08,       -- CM = deflate
    0x00,       -- FLG = no extra fields, no name, no comment
    0x00, 0x00, 0x00, 0x00, -- MTIME = 0, so output is byte-identical between runs
    0x00,       -- XFL
    0x03        -- OS = Unix
  )
  return header
    .. deflated
    .. u32le(M.crc32(original))
    .. u32le(#original & 0xFFFFFFFF)
end

--- Compress a string straight to a gzip byte string.
-- @param libdeflate the LibDeflate module
-- @param s input
-- @param level DEFLATE level 1..9 (default 9)
function M.compress(libdeflate, s, level)
  local deflated = libdeflate:CompressDeflate(s, { level = level or 9 })
  return M.wrap(deflated, s)
end

return M
