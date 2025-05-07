-- ui.lua  – centred board, 3‑column layout with pulsing side‑column scores
import "CoreLibs/graphics"
import "CoreLibs/sprites"

local gfx <const> = playdate.graphics

local UI = {}
UI.__index = UI

-- Visual constants ----------------------------------------------------------
local SIDE_COL_W   <const> = 60   -- width of each side column (px)
local V_PADDING    <const> = 20   -- top & bottom padding (px)
local LINE_WIDTH   <const> = 6    -- line thickness (px)
local DOT_SIZE     <const> = 4    -- radius of dots (px)
local DIGIT_SCALE  <const> = 6    -- chunky‑digit scale factor

-------------------------------------------------------------------------------
-- CHUNKY 3×5 DIGIT BITMAP ---------------------------------------------------
local DIGIT_BITS <const> = {
    [0] = 31599, -- 0b111101101101111
    11415,       -- 1
    29671,       -- 2
    29647,       -- 3
    23497,       -- 4
    31183,       -- 5
    31215,       -- 6
    29257,       -- 7
    31727,       -- 8
    31695        -- 9
}
local function drawChunkyDigit(n, x, y, scale)
    local bits = DIGIT_BITS[n]
    if not bits then return end
    for row = 0, 4 do
        for col = 0, 2 do
            local bitPos = 14 - (row*3 + col)
            if ((bits >> bitPos) & 1) == 1 then
                gfx.fillRect(x + col*scale, y + row*scale, scale, scale)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Build reverse look‑ups for edges and boxes
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
            self.boxToCoord[idx] = { r, c }
            idx = idx + 1
        end
    end
end

-------------------------------------------------------------------------------
-- Convert dot grid coords to pixel coords
-------------------------------------------------------------------------------
local function dotXY(self, r, c)
    return self.left + (c - 1) * self.spacing,
           self.top  + (r - 1) * self.spacing
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
-- Cursor highlight box (transparent center, tinted by player)
-------------------------------------------------------------------------------
function UI:drawCursor()
    local coords = self.board.edgeToCoord[self.cursorEdge]
    if not coords then return end
    local rr, cc, dir = table.unpack(coords)
    local x1, y1 = dotXY(self, rr, cc)
    local x2, y2
    if dir == self.board.H then
        x2, y2 = dotXY(self, rr, cc + 1)
    else
        x2, y2 = dotXY(self, rr + 1, cc)
    end

    local pad = 8
    local left   = math.min(x1, x2) - pad
    local top    = math.min(y1, y2) - pad
    local width  = math.abs(x2 - x1) + pad * 2
    local height = math.abs(y2 - y1) + pad * 2

    if self.board.currentPlayer == 1 then
        gfx.setColor(gfx.kColorBlack)
    else
        gfx.setDitherPattern(0.5)
    end
    gfx.setLineWidth(3)
    gfx.drawRect(left, top, width, height)
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0)
end

-------------------------------------------------------------------------------
-- Constructor
-------------------------------------------------------------------------------
function UI.new(board)
    local self = setmetatable({}, UI)
    self.board = board

    -- Build look‑ups
    self:buildCoordToEdge()
    self:buildBoxToCoord()

    -- Spacing & offsets
    local screenW, screenH = playdate.display.getSize()
    local dots = board.DOTS
    local maxW = math.floor((screenW - 2*SIDE_COL_W) / (dots - 1))
    local maxH = math.floor((screenH - 2*V_PADDING) / (dots - 1))
    self.spacing = math.min(maxW, maxH)

    local boardSide = (dots - 1) * self.spacing
    self.left = SIDE_COL_W + math.floor((screenW - 2*SIDE_COL_W - boardSide) / 2)
    local availH = screenH - 2*V_PADDING
    self.top = V_PADDING + math.floor((availH - boardSide) / 2)

    -- Cursor
    self.cursorEdge = 1
    return self
end

-------------------------------------------------------------------------------
-- Handle input
-------------------------------------------------------------------------------
function UI:handleInput()
    if playdate.buttonJustPressed(playdate.kButtonA) and self.board:isGameOver() then
        local BoardClass = getmetatable(self.board).__index
        self.board = BoardClass.new(self.board.DOTS)
        self:buildCoordToEdge()
        self:buildBoxToCoord()
        self.cursorEdge = 1
        return
    end

    local coords = self.board.edgeToCoord[self.cursorEdge]
    if not coords then return end
    local r, c, dir = table.unpack(coords)

    local maxR = (dir == self.board.H) and self.board.DOTS or self.board.DOTS-1
    local maxC = (dir == self.board.H) and self.board.DOTS-1 or self.board.DOTS
    local newR, newC = r, c
    if playdate.buttonJustPressed(playdate.kButtonLeft)  then newC = (c-2)%maxC+1 end
    if playdate.buttonJustPressed(playdate.kButtonRight) then newC = c%maxC+1 end
    if playdate.buttonJustPressed(playdate.kButtonUp)    then newR = (r-2)%maxR+1 end
    if playdate.buttonJustPressed(playdate.kButtonDown)  then newR = r%maxR+1 end

    if newR~=r or newC~=c then
        local e = self.coordToEdge[newR] and self.coordToEdge[newR][newC] and
                  self.coordToEdge[newR][newC][dir]
        if e then self.cursorEdge = e end
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        self.board:playEdge(self.cursorEdge)
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        local altDir = (dir==self.board.H) and self.board.V or self.board.H
        local e2 = self.coordToEdge[r] and self.coordToEdge[r][c] and
                   self.coordToEdge[r][c][altDir]
        if not e2 then
            local ar, ac = r, c
            if altDir==self.board.H then ac = math.min(c, self.board.DOTS-1)
            else                  ar = math.min(r, self.board.DOTS-1) end
            e2 = self.coordToEdge[ar] and self.coordToEdge[ar][ac] and
                 self.coordToEdge[ar][ac][altDir]
        end
        if e2 then self.cursorEdge = e2 end
    end
end

-------------------------------------------------------------------------------
-- Draw everything
-------------------------------------------------------------------------------
function UI:draw()
    gfx.clear()
    gfx.setColor(gfx.kColorBlack)

    -- Tally scores -----------------------------------------
    local p1Score, p2Score = 0, 0
    for _, owner in pairs(self.board.boxOwner) do
        if owner == 1 then p1Score = p1Score + 1
        elseif owner == 2 then p2Score = p2Score + 1 end
    end

    -- Dots
    for rr=1,self.board.DOTS do
        for cc=1,self.board.DOTS do
            local x,y = dotXY(self, rr, cc)
            gfx.fillCircleAtPoint(x, y, DOT_SIZE)
        end
    end

    -- Edges
    for e = 1, #self.board.edgeToCoord do
        if self.board:edgeIsFilled(e) then
            local rr, cc, d = table.unpack(self.board.edgeToCoord[e])
            local x1, y1 = dotXY(self, rr, cc)
            local x2, y2
            if d == self.board.H then x2,y2 = dotXY(self, rr, cc+1)
            else x2,y2 = dotXY(self, rr+1, cc) end
            local owner = self.board.edgeOwner[e] or 1
            gfx.setDitherPattern(owner==2 and 0.5 or 0)
            drawThickLine(x1,y1,x2,y2)
            gfx.setDitherPattern(0)
        end
    end

    -- Claimed boxes
    for id, bc in ipairs(self.boxToCoord) do
        local o = self.board.boxOwner[id]
        if o then
            local br, bc2 = table.unpack(bc)
            local cx = self.left + (bc2-1)*self.spacing + self.spacing/2
            local cy = self.top  + (br-1)*self.spacing + self.spacing/2
            gfx.drawText(tostring(o), cx-4, cy-6)
        end
    end

    -- Cursor
    self:drawCursor()

    -- Side‑column scores
    do
        local sw, sh = playdate.display.getSize()
        local dw, dh = 3*DIGIT_SCALE, 5*DIGIT_SCALE
        local sy    = sh/2 - dh/2

        local function drawScore(val, px, active, useDither)
            -- set digit dithering for P2
            gfx.setDitherPattern(useDither and 0.5 or 0)
            local s = tostring(val)
            local totalW = #s * (dw + DIGIT_SCALE) - DIGIT_SCALE
            local sx     = px + (SIDE_COL_W - totalW) / 2

            for i = 1, #s do
                drawChunkyDigit(tonumber(s:sub(i,i)), sx + (i-1)*(dw + DIGIT_SCALE), sy, DIGIT_SCALE)
            end
            gfx.setDitherPattern(0)

            if active then
                local ux, uy = px + 5, sy + dh + 2
                local uw, uh = SIDE_COL_W - 10, 2
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRect(ux, uy, uw, uh)
                gfx.setColor(gfx.kColorBlack)
            end
        end

        drawScore(p1Score,               0,               self.board.currentPlayer==1, false)
        drawScore(p2Score, sw - SIDE_COL_W, self.board.currentPlayer==2, true)
    end

    -- Game‑over
    if self.board:isGameOver() then
        local msg = "Game Over (A to restart)"
        local f = gfx.getSystemFont()
        local tw,th = f:getTextWidth(msg), f:getHeight()
        local px,py = self.left + ((self.board.DOTS-1)*self.spacing - tw -20)/2,
                       self.top  + ((self.board.DOTS-1)*self.spacing - th -10)/2
        gfx.setColor(gfx.kColorWhite); gfx.fillRect(px,py,tw+20,th+10)
        gfx.setDitherPattern(0.5); gfx.setColor(gfx.kColorBlack)
        gfx.drawRect(px,py,tw+20,th+10); gfx.setDitherPattern(0)
        gfx.drawText(msg, px+10, py+5)
    end
end

-------------------------------------------------------------------------------
function UI:update()
    self:handleInput()
    self:draw()
end

return UI
