-- board.lua  (ASCII‑only, fixed loops)
-- Complete game logic for a dots‑and‑boxes board.

local Board = {}
Board.__index = Board

-- ── Constants ───────────────────────────────────────────────────────────────
local DOTS  = 6                          -- 6×6 dots
local BOXES = (DOTS-1)*(DOTS-1)          -- 25 boxes
local EDGES = DOTS*(DOTS-1)*2            -- 60 edges total

-- Direction enum
local H, V = 1, 2                        -- 1 = horizontal, 2 = vertical

-- ── Static lookup tables ────────────────────────────────────────────────────
local edgeToCoord = {}   -- edgeId -> {row,col,dir}
local coordToEdge = {}   -- [row][col][dir] = edgeId
local boxEdges    = {}   -- boxId  -> {e1,e2,e3,e4}
local edgeBoxes   = {}   -- edgeId -> {b1, b2?}

do
    local id = 1

    -- Horizontal edges: rows 1..DOTS  (6), cols 1..DOTS‑1 (5)
    for r = 1, DOTS do
        for c = 1, DOTS-1 do
            edgeToCoord[id] = {r, c, H}
            coordToEdge[r]            = coordToEdge[r] or {}
            coordToEdge[r][c]         = coordToEdge[r][c] or {}
            coordToEdge[r][c][H]      = id
            id = id + 1
        end
    end

    -- Vertical edges: rows 1..DOTS‑1 (5), cols 1..DOTS (6)
    for r = 1, DOTS-1 do
        for c = 1, DOTS do
            edgeToCoord[id] = {r, c, V}
            coordToEdge[r]            = coordToEdge[r] or {}
            coordToEdge[r][c]         = coordToEdge[r][c] or {}
            coordToEdge[r][c][V]      = id
            id = id + 1
        end
    end

    -- Build box ↔ edge relationships
    local boxId = 1
    for r = 1, DOTS-1 do
        for c = 1, DOTS-1 do
            local top    = coordToEdge[r    ][c    ][H]
            local right  = coordToEdge[r    ][c+1  ][V]
            local bottom = coordToEdge[r+1  ][c    ][H]
            local left   = coordToEdge[r    ][c    ][V]

            boxEdges[boxId] = {top, right, bottom, left}
            for _, e in ipairs(boxEdges[boxId]) do
                edgeBoxes[e] = edgeBoxes[e] or {}
                table.insert(edgeBoxes[e], boxId)
            end
            boxId = boxId + 1
        end
    end
end

-- ── Constructor ─────────────────────────────────────────────────────────────
function Board.new()
    local self = setmetatable({}, Board)
    self.edgesFilled   = {}       -- [edgeId] = true/nil
    self.edgeOwner     = {}       -- [edgeId] = 1|2 (who played it)
    self.boxOwner      = {}       -- [boxId]  = 0|1|2
    self.currentPlayer = 1
    self.score         = {0, 0}
    return self
end

-- ── Public API ──────────────────────────────────────────────────────────────
function Board:playEdge(e)
    if self.edgesFilled[e] then return false end
    self.edgesFilled[e] = true
    self.edgeOwner[e]   = self.currentPlayer

    local claimed = 0
    if edgeBoxes[e] then
        for _, b in ipairs(edgeBoxes[e]) do
            local done = true
            for _, ee in ipairs(boxEdges[b]) do
                if not self.edgesFilled[ee] then done = false break end
            end
            if done and not self.boxOwner[b] then
                self.boxOwner[b] = self.currentPlayer
                self.score[self.currentPlayer] = self.score[self.currentPlayer] + 1
                claimed = claimed + 1
            end
        end
    end
    if claimed == 0 then
        self.currentPlayer = 3 - self.currentPlayer
    end
    return true
end

function Board:edgeIsFilled(e) return self.edgesFilled[e] or false end
function Board:ownerOfBox(b)   return self.boxOwner[b]    or 0    end
function Board:isGameOver()    return (self.score[1]+self.score[2]) == BOXES end

function Board:listFreeEdges()
    local list = {}
    for e = 1, EDGES do
        if not self.edgesFilled[e] then list[#list+1] = e end
    end
    return list
end

-- expose read‑only tables for UI
Board.DOTS        = DOTS
Board.H, Board.V  = H, V
Board.edgeToCoord = edgeToCoord

return Board