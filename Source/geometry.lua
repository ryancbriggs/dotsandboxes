-- geometry.lua – Spatial helpers for geometric badges.
--
-- Box indexing mirrors board.lua exactly: boxIds run 1..(dots-1)^2 in
-- row-major order, with (dots-1) boxes per row. Anything that needs to
-- reason about *where* a box is (corners, edges, diagonals, blocks) lives
-- here so badge predicates stay tiny and declarative.

local Geometry = {}

function Geometry.boxesPerRow(dots) return dots - 1 end

-- 1-based (row, col) of a boxId on a `dots`-dot board.
function Geometry.rowCol(dots, boxId)
    local per = dots - 1
    local idx = boxId - 1
    return math.floor(idx / per) + 1, (idx % per) + 1
end

-- The four corner boxIds: {top-left, top-right, bottom-left, bottom-right}.
function Geometry.cornerBoxes(dots)
    local per = dots - 1
    return {
        1,                    -- (1, 1)
        per,                  -- (1, per)
        per * (per - 1) + 1,  -- (per, 1)
        per * per,            -- (per, per)
    }
end

-- True iff `set` (a {[boxId]=true} map) contains every id in `list`.
function Geometry.ownsAll(set, list)
    for _, id in ipairs(list) do
        if not set[id] then return false end
    end
    return true
end

-- True iff `set` owns every box in any single full row OR full column.
function Geometry.hasFullStripe(set, dots)
    local per = dots - 1
    -- Rows: contiguous blocks of `per` boxIds.
    for r = 1, per do
        local full = true
        local base = (r - 1) * per
        for c = 1, per do
            if not set[base + c] then full = false; break end
        end
        if full then return true end
    end
    -- Columns: every `per`-th boxId starting at column c.
    for c = 1, per do
        local full = true
        for r = 1, per do
            if not set[(r - 1) * per + c] then full = false; break end
        end
        if full then return true end
    end
    return false
end

return Geometry
