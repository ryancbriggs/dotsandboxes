-- board.lua – dynamic board size, 4 – 8 dots per side

local Board  = {}
Board.__index = Board

-------------------------------------------------------------------------------
function Board.new(dots)
    dots = dots or 6
    assert(dots >= 4 and dots <= 8, "dots must be between 4 and 8")
    local self = setmetatable({}, Board)

    -- Public constants ------------------------------------------------------
    self.DOTS = dots
    self.H, self.V = 1, 2                 -- 1 = horizontal, 2 = vertical

    -- Derived counts --------------------------------------------------------
    local EDGES = dots * (dots - 1) * 2

    -- Lookup tables ---------------------------------------------------------
    self.edgeToCoord = {}   -- edgeId -> {row,col,dir}
    self.coordToEdge = {}   -- [row][col][dir] -> edgeId
    self.boxEdges    = {}   -- boxId  -> {e1,e2,e3,e4}
    self.edgeBoxes   = {}   -- edgeId -> {boxId,…}

    -- Build edges -----------------------------------------------------------
    local id = 1
    -- Horizontal
    for r = 1, dots do
        for c = 1, dots - 1 do
            self.edgeToCoord[id] = { r, c, self.H }
            self.coordToEdge[r]  = self.coordToEdge[r] or {}
            self.coordToEdge[r][c] = self.coordToEdge[r][c] or {}
            self.coordToEdge[r][c][self.H] = id
            id = id + 1
        end
    end
    -- Vertical
    for r = 1, dots - 1 do
        for c = 1, dots do
            self.edgeToCoord[id] = { r, c, self.V }
            self.coordToEdge[r]  = self.coordToEdge[r] or {}
            self.coordToEdge[r][c] = self.coordToEdge[r][c] or {}
            self.coordToEdge[r][c][self.V] = id
            id = id + 1
        end
    end

    -- Build boxes <-> edges -------------------------------------------------
    local boxId = 1
    for r = 1, dots - 1 do
        for c = 1, dots - 1 do
            local top    = self.coordToEdge[r    ][c    ][self.H]
            local right  = self.coordToEdge[r    ][c + 1][self.V]
            local bottom = self.coordToEdge[r + 1][c    ][self.H]
            local left   = self.coordToEdge[r    ][c    ][self.V]

            self.boxEdges[boxId] = { top, right, bottom, left }
            for _, e in ipairs(self.boxEdges[boxId]) do
                self.edgeBoxes[e] = self.edgeBoxes[e] or {}
                table.insert(self.edgeBoxes[e], boxId)
            end
            boxId = boxId + 1
        end
    end

    -- Gameplay state --------------------------------------------------------
    self.edgesFilled   = {}               -- edgeId -> bool
    self.edgeOwner     = {}               -- edgeId -> 1|2
    self.boxOwner      = {}               -- boxId  -> 1|2
    self.score         = { 0, 0 }
    self.currentPlayer = 1

    return self
end

-------------------------------------------------------------------------------
-- Helpers --------------------------------------------------------------------
-------------------------------------------------------------------------------
function Board:edgeIsFilled(e) return self.edgesFilled[e] end

function Board:isGameOver()
    return (self.score[1] + self.score[2]) == #self.boxEdges
end

-------------------------------------------------------------------------------
-- Play an edge ---------------------------------------------------------------
-------------------------------------------------------------------------------
function Board:playEdge(e)
    if self.edgesFilled[e] then return false end
    self.edgesFilled[e] = true
    self.edgeOwner[e]   = self.currentPlayer

    local claimed = 0
    if self.edgeBoxes[e] then
        for _, b in ipairs(self.edgeBoxes[e]) do
            local complete = true
            for _, ee in ipairs(self.boxEdges[b]) do
                if not self.edgesFilled[ee] then
                    complete = false
                    break
                end
            end
            if complete and not self.boxOwner[b] then
                self.boxOwner[b] = self.currentPlayer
                self.score[self.currentPlayer] =
                    self.score[self.currentPlayer] + 1
                claimed = claimed + 1
            end
        end
    end
    if claimed == 0 then self.currentPlayer = 3 - self.currentPlayer end
    return true
end

-------------------------------------------------------------------------------
function Board:listFreeEdges()
    local list = {}
    for e = 1, #self.edgeToCoord do
        if not self.edgesFilled[e] then list[#list + 1] = e end
    end
    return list
end

return Board