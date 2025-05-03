-- ui.lua (complete, consolidated)
import "CoreLibs/graphics"
import "CoreLibs/sprites"

local gfx <const> = playdate.graphics

local UI = {}
UI.__index = UI

-- Visual constants ----------------------------------------------------------
local SCORE_MARGIN <const> = 60   -- left margin for HUD (px)
local V_PADDING    <const> = 20   -- top & bottom padding (px)
local LINE_WIDTH   <const> = 6    -- thickness of lines (px)
local DOT_SIZE     <const> = 4    -- radius of dots (px)

-------------------------------------------------------------------------------
-- Build reverse lookups for edges and boxes
-------------------------------------------------------------------------------
function UI:buildCoordToEdge()
    self.coordToEdge = {}
    for e, coords in ipairs(self.board.edgeToCoord) do
        local r, c, d = table.unpack(coords)
        self.coordToEdge[r] = self.coordToEdge[r] or {}
        self.coordToEdge[r][c] = self.coordToEdge[r][c] or {}
        self.coordToEdge[r][c][d] = e
    end
end

function UI:buildBoxToCoord()
    self.boxToCoord = {}
    local idx = 1
    for r = 1, self.board.DOTS - 1 do
        for c = 1, self.board.DOTS - 1 do
            self.boxToCoord[idx] = {r, c}
            idx = idx + 1
        end
    end
end

-------------------------------------------------------------------------------
-- Convert grid coords to pixel coords
-------------------------------------------------------------------------------
local function dotXY(self, r, c)
    local x = self.left + (c - 1) * self.spacing
    local y = self.top  + (r - 1) * self.spacing
    return x, y
end

-------------------------------------------------------------------------------
-- Draw a thick line between two points
-------------------------------------------------------------------------------
local function drawThickLine(x1, y1, x2, y2)
    if not (x1 and y1 and x2 and y2) then return end
    if x1 == x2 then
        local x = x1 - math.floor(LINE_WIDTH / 2)
        gfx.fillRect(x, math.min(y1, y2), LINE_WIDTH, math.abs(y2 - y1))
    else
        local y = y1 - math.floor(LINE_WIDTH / 2)
        gfx.fillRect(math.min(x1, x2), y, math.abs(x2 - x1), LINE_WIDTH)
    end
end

-------------------------------------------------------------------------------
-- Constructor
-------------------------------------------------------------------------------
function UI.new(board)
    local self = setmetatable({}, UI)
    self.board = board

    -- Build lookups
    self:buildCoordToEdge()
    self:buildBoxToCoord()

    -- Compute spacing & offsets
    local screenW, screenH = playdate.display.getSize()
    local dots = board.DOTS
    local maxW = math.floor((screenW - SCORE_MARGIN) / (dots - 1))
    local maxH = math.floor((screenH - 2 * V_PADDING) / (dots - 1))
    self.spacing = math.min(maxW, maxH)

    self.left = SCORE_MARGIN + math.floor((screenW - SCORE_MARGIN - (dots - 1) * self.spacing) / 2)
    local availH = screenH - 2 * V_PADDING
    self.top = V_PADDING + math.floor((availH - (dots - 1) * self.spacing) / 2)

    -- Initial state
    self.cursorEdge = 1
    self.turnCount = 0

    playdate.display.setRefreshRate(20)
    return self
end

-------------------------------------------------------------------------------
-- Find next free edge
-------------------------------------------------------------------------------
local function seekFreeEdge(board, startEdge, delta)
    local total = #board.edgeToCoord
    local e = startEdge
    for _ = 1, total do
        e = ((e - 1 + delta) % total) + 1
        if not board:edgeIsFilled(e) then
            return e
        end
    end
    return startEdge
end

-------------------------------------------------------------------------------
-- Handle input
-------------------------------------------------------------------------------
function UI:handleInput()
    -- Restart if game over and A pressed
    if playdate.buttonJustPressed(playdate.kButtonA) and self.board:isGameOver() then
        local boardClass = getmetatable(self.board).__index
        self.board = boardClass.new(self.board.DOTS)
        self:buildCoordToEdge()
        self:buildBoxToCoord()
        self.cursorEdge = 1
        self.turnCount = 0
        return
    end

    -- Current edge coords
    local coords = self.board.edgeToCoord[self.cursorEdge]
    if not coords then return end
    local r, c, dir = table.unpack(coords)

    -- Move cursor with wrapping
    local maxR = (dir == self.board.H) and self.board.DOTS or (self.board.DOTS - 1)
    local maxC = (dir == self.board.H) and (self.board.DOTS - 1) or self.board.DOTS
    local newR, newC = r, c
    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        newC = (c - 2) % maxC + 1
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        newC = c % maxC + 1
    elseif playdate.buttonJustPressed(playdate.kButtonUp) then
        newR = (r - 2) % maxR + 1
    elseif playdate.buttonJustPressed(playdate.kButtonDown) then
        newR = r % maxR + 1
    end
    if newR ~= r or newC ~= c then
        local edge = self.coordToEdge[newR][newC][dir]
        if edge then self.cursorEdge = edge end
    end

    -- Play edge with A
    if playdate.buttonJustPressed(playdate.kButtonA) then
        if self.board:playEdge(self.cursorEdge) then
            self.turnCount = self.turnCount + 1
            -- cursor stays where it is:
            -- self.cursorEdge = seekFreeEdge(self.board, self.cursorEdge, 1)
        end
    end

    -- Toggle orientation with B
    if playdate.buttonJustPressed(playdate.kButtonB) then
        local altDir = (dir == self.board.H) and self.board.V or self.board.H
        local altEdge = self.coordToEdge[r][c][altDir]
        if altEdge then self.cursorEdge = altEdge end
    end
end

-------------------------------------------------------------------------------
-- Draw everything
-------------------------------------------------------------------------------
function UI:draw()
    gfx.clear()
    gfx.setColor(gfx.kColorBlack)

    -- Draw dots
    for rr = 1, self.board.DOTS do
        for cc = 1, self.board.DOTS do
            local x, y = dotXY(self, rr, cc)
            gfx.fillCircleAtPoint(x, y, DOT_SIZE)
        end
    end

    -- Draw edges
    for e = 1, #self.board.edgeToCoord do
        if self.board:edgeIsFilled(e) then
            local rr, cc, d = table.unpack(self.board.edgeToCoord[e])
            local x1, y1 = dotXY(self, rr, cc)
            local x2, y2
            if d == self.board.H then
                x2, y2 = dotXY(self, rr, cc + 1)
            else
                x2, y2 = dotXY(self, rr + 1, cc)
            end
            local owner = self.board.edgeOwner[e] or 1
            gfx.setDitherPattern(owner == 2 and 0.5 or 0)
            drawThickLine(x1, y1, x2, y2)
            gfx.setDitherPattern(0)
        end
    end

    -- Draw claimed boxes
    for boxId, bc in ipairs(self.boxToCoord) do
        local owner = self.board.boxOwner[boxId] or 0
        if owner > 0 then
            local br, bc = table.unpack(bc)
            local cx = self.left + (bc - 1) * self.spacing + self.spacing/2
            local cy = self.top  + (br - 1) * self.spacing + self.spacing/2
            gfx.drawText(tostring(owner), cx - 4, cy - 6)
        end
    end

    -- Draw cursor on top
    do
        local coords = self.board.edgeToCoord[self.cursorEdge]
        if coords then
            local rr, cc, d = table.unpack(coords)
            local cx1, cy1 = dotXY(self, rr, cc)
            local cx2, cy2
            if d == self.board.H then
                cx2, cy2 = dotXY(self, rr, cc + 1)
            else
                cx2, cy2 = dotXY(self, rr + 1, cc)
            end
            if cx1 and cy1 and cx2 and cy2 then
                -- draw the cursor by XOR’ing pixels under it
                gfx.setLineWidth(2)
                gfx.setStrokeLocation(gfx.kStrokeCentered)

                gfx.setColor(gfx.kColorXOR)        -- kColorXOR inverts existing pixels
                gfx.drawLine(cx1, cy1, cx2, cy2)

                -- restore your normal color for subsequent drawing
                gfx.setColor(gfx.kColorBlack)
            end
        end
    end

    -- HUD
    gfx.drawText("Turn: P" .. self.board.currentPlayer, 5, 20)
    gfx.drawText("P1: " .. self.board.score[1], 5, 40)
    gfx.drawText("P2: " .. self.board.score[2], 5, 60)
    gfx.drawText("Turn Num: " .. self.turnCount, 5, 80)
    if self.board:isGameOver() then
        gfx.drawText("Game Over (A to restart)", 5, 100)
    end
end

-------------------------------------------------------------------------------
function UI:update()
    self:handleInput()
    self:draw()
end

return UI