--- Turn a binary pixel mask into closed orthogonal contours.
--
-- Approach: instead of flood-filling components and then walking their borders,
-- we emit the boundary directly. Every filled cell contributes a directed unit
-- edge on each side where its neighbour is empty, wound so that outer contours
-- come out clockwise and holes counter-clockwise. Stitching those edges into
-- loops then yields every contour of every component in one pass, with hole
-- nesting already handled by the winding -- no explicit parent/child hierarchy
-- and no even-odd bookkeeping, because Lottie's non-zero fill rule reads the
-- winding directly.
--
-- Cell (x,y) covers the unit square from lattice point (x,y) to (x+1,y+1), so a
-- WxH sprite has (W+1)x(H+1) lattice points.

local M = {}

-- Direction indices, in visual clockwise order (screen coords: x right, y down)
local DX = { [0] = 1, 0, -1, 0 }
local DY = { [0] = 0, 1, 0, -1 }

--- Trace every closed contour of a mask.
-- @param isSet function(x,y) -> truthy if the cell is part of the mask
-- @param cells flat list of cell indices in the mask (y*W+x), so we only ever
--        touch filled cells rather than scanning the whole canvas per colour
-- @param W sprite width
-- @return list of loops; each loop is a flat array {x1,y1,x2,y2,...} of lattice
--         points with collinear runs already collapsed
function M.trace(isSet, cells, W)
  -- Directed edges keyed by their start vertex. A vertex can host up to two
  -- outgoing edges, which happens exactly where two components touch corner to
  -- corner.
  local edges = {}   -- vertexKey -> { dir, dir }  (up to 2)
  local stride = W + 1

  local function addEdge(x, y, dir)
    local k = y * stride + x
    local t = edges[k]
    if t then
      t[#t + 1] = dir
    else
      edges[k] = { dir }
    end
  end

  for i = 1, #cells do
    local idx = cells[i]
    local x = idx % W
    local y = idx // W
    -- Wind clockwise around the cell: top→ right↓ bottom← left↑
    if not isSet(x, y - 1) then addEdge(x,     y,     0) end
    if not isSet(x + 1, y) then addEdge(x + 1, y,     1) end
    if not isSet(x, y + 1) then addEdge(x + 1, y + 1, 2) end
    if not isSet(x - 1, y) then addEdge(x,     y + 1, 3) end
  end

  --- Take an outgoing edge from vertex k, preferring the sharpest clockwise
  -- turn relative to how we arrived. This is what keeps two components that
  -- merely touch at a corner from being stitched into a single figure-eight
  -- loop: at the shared vertex the right-hand turn always stays on the
  -- component we came in on.
  local function takeEdge(k, incoming)
    local t = edges[k]
    if not t or #t == 0 then return nil end
    if #t == 1 or incoming == nil then
      local d = t[#t]
      t[#t] = nil
      return d
    end
    -- preference order: right turn, straight, left turn, reverse
    for _, rot in ipairs({ 1, 0, 3, 2 }) do
      local want = (incoming + rot) % 4
      for j = 1, #t do
        if t[j] == want then
          table.remove(t, j)
          return want
        end
      end
    end
    local d = t[#t]
    t[#t] = nil
    return d
  end

  local loops = {}

  for i = 1, #cells do
    local idx = cells[i]
    local cx, cy = idx % W, idx // W
    -- Every contour touches at least one cell's own lattice corners, so
    -- seeding from cell corners is enough to find them all.
    for _, seed in ipairs({ { cx, cy }, { cx + 1, cy }, { cx + 1, cy + 1 }, { cx, cy + 1 } }) do
      local sx, sy = seed[1], seed[2]
      local sk = sy * stride + sx
      while edges[sk] and #edges[sk] > 0 do
        local pts = {}
        local x, y, k = sx, sy, sk
        local dir = takeEdge(k, nil)
        local lastDir = nil
        while dir do
          -- collapse collinear: only record a point where the direction changes
          if lastDir ~= dir then
            pts[#pts + 1] = x
            pts[#pts + 1] = y
          end
          lastDir = dir
          x = x + DX[dir]
          y = y + DY[dir]
          k = y * stride + x
          if x == sx and y == sy then break end
          dir = takeEdge(k, dir)
        end
        -- The first recorded point may sit mid-run; if the closing direction
        -- matches the opening one it is redundant.
        if #pts >= 6 then
          local n = #pts
          local firstDir = (pts[3] ~= pts[1]) and ((pts[3] > pts[1]) and 0 or 2)
                                              or ((pts[4] > pts[2]) and 1 or 3)
          if lastDir == firstDir then
            table.remove(pts, 1)
            table.remove(pts, 1)
          end
          loops[#loops + 1] = pts
        end
      end
    end
  end

  return loops
end

--- Group a frame's pixels by exact RGBA value.
-- @param px flat array of packed RGBA uint32, 1-based, row-major
-- @param W,H dimensions
-- @return map colour -> list of cell indices, and the count of distinct colours
function M.groupByColor(px, W, H)
  local byColor = {}
  local n = 0
  for i = 1, W * H do
    local v = px[i]
    if (v >> 24) & 0xFF > 0 then      -- fully transparent pixels contribute nothing
      local t = byColor[v]
      if not t then
        t = {}
        byColor[v] = t
        n = n + 1
      end
      t[#t + 1] = i - 1               -- store as 0-based cell index
    end
  end
  return byColor, n
end

--- Trace one colour's mask into contours.
-- @param cells list of 0-based cell indices for this colour
-- @param W,H dimensions
function M.traceColor(cells, W, H)
  local inMask = {}
  for i = 1, #cells do inMask[cells[i]] = true end
  local function isSet(x, y)
    if x < 0 or y < 0 or x >= W or y >= H then return false end
    return inMask[y * W + x] == true
  end
  return M.trace(isSet, cells, W)
end

return M
