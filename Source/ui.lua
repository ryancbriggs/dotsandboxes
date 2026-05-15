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
UI.DOT_SIZE = DOT_SIZE            -- for external use

-- Box-claim animation (expand-and-settle) ----------------------------------
local CLAIM_ANIM_MS    <const> = 260    -- total duration in milliseconds
local CLAIM_OVERSHOOT  <const> = 1.25   -- scale at the peak of the pop

-------------------------------------------------------------------------------
-- Build reverse look‑up for boxes (edge lookup lives on the board)
-------------------------------------------------------------------------------
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
    local tx = math.min(x1, x2) - pad
    local ty = math.min(y1, y2) - pad
    local tw = math.abs(x2 - x1) + pad * 2
    local th = math.abs(y2 - y1) + pad * 2

    -- Glide toward the target edge, then snap — identical feel to the main
    -- menu's selection rect (same k and sub-pixel snap).
    if not self.cursorAnim then
        self.cursorAnim = { x = tx, y = ty, w = tw, h = th }
    else
        local s, k = self.cursorAnim, 0.65
        s.x = s.x + (tx - s.x) * k
        s.y = s.y + (ty - s.y) * k
        s.w = s.w + (tw - s.w) * k
        s.h = s.h + (th - s.h) * k
        if math.abs(s.x - tx) < 1 then s.x = tx end
        if math.abs(s.y - ty) < 1 then s.y = ty end
        if math.abs(s.w - tw) < 1 then s.w = tw end
        if math.abs(s.h - th) < 1 then s.h = th end
    end
    local s = self.cursorAnim

    if self.board.currentPlayer == 1 then
        gfx.setColor(gfx.kColorBlack)
    else
        gfx.setDitherPattern(0.5)
    end
    gfx.setLineWidth(3)
    gfx.drawRect(math.floor(s.x), math.floor(s.y),
                 math.floor(s.w), math.floor(s.h))
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0)
end

-------------------------------------------------------------------------------
-- Constructor
-------------------------------------------------------------------------------
function UI.new(board, opts)
    local self = setmetatable({}, UI)
    self.board = board
    opts = opts or {}
    self.onRestart  = opts.onRestart
    self.onMainMenu = opts.onMainMenu
    self.sound      = opts.sound
    self.fonts      = opts.fonts   -- central type hierarchy (see fonts.lua)
    -- Pretty difficulty label ("Expert") shown under the CPU score in PvC.
    local d = opts.difficulty
    self.difficultyLabel = d and (d:sub(1, 1):upper() .. d:sub(2)) or nil

    -- Build box lookup (edge lookup is on the board)
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
    self.cursorAnim = nil   -- eased highlight rect; snaps fresh each game
    -- Per-box claim-animation start times (boxId -> ms timestamp)
    self.boxAnimStart = {}
    playdate.display.setRefreshRate(20)
    return self
end

-------------------------------------------------------------------------------
-- Handle input
-------------------------------------------------------------------------------
function UI:handleInput()
    if self.board:isGameOver() then
        if playdate.buttonJustPressed(playdate.kButtonA) then
            self.onRestart()
        elseif playdate.buttonJustPressed(playdate.kButtonB) and self.onMainMenu then
            self.onMainMenu()
        end
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
        local c2e = self.board.coordToEdge
        local e = c2e[newR] and c2e[newR][newC] and c2e[newR][newC][dir]
        if e then self.cursorEdge = e end
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        if self.mode ~= "pvc" or self.board.currentPlayer == 1 then
            local claimed = self.board:playEdge(self.cursorEdge)
            if claimed and claimed > 0 and self.sound then
                self.sound.done(self.board.chainLen - 1)
            end
        end
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        local c2e = self.board.coordToEdge
        local altDir = (dir==self.board.H) and self.board.V or self.board.H
        local e2 = c2e[r] and c2e[r][c] and c2e[r][c][altDir]
        if not e2 then
            local ar, ac = r, c
            if altDir==self.board.H then ac = math.min(c, self.board.DOTS-1)
            else                  ar = math.min(r, self.board.DOTS-1) end
            e2 = c2e[ar] and c2e[ar][ac] and c2e[ar][ac][altDir]
        end
        if e2 then self.cursorEdge = e2 end
    end
end

-------------------------------------------------------------------------------
-- Draw everything
-------------------------------------------------------------------------------
function UI:draw()
    gfx.setColor(gfx.kColorBlack)

    local p1Score, p2Score = self.board.score[1], self.board.score[2]

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

    -- Claimed boxes: animated expand-and-settle square
    local nowMs = playdate.getCurrentTimeMilliseconds()
    local baseSize = math.floor(self.spacing * 0.5)
    for id, bc in ipairs(self.boxToCoord) do
        local owner = self.board.boxOwner[id]
        if owner then
            local startMs = self.boxAnimStart[id]
            if not startMs then
                startMs = nowMs
                self.boxAnimStart[id] = startMs
            end

            local progress = (nowMs - startMs) / CLAIM_ANIM_MS
            if progress < 0 then progress = 0
            elseif progress > 1 then progress = 1 end

            -- Piecewise scale: 0 → overshoot in first half, overshoot → 1.0 in second.
            local scale
            if progress < 0.5 then
                scale = progress * 2 * CLAIM_OVERSHOOT
            else
                scale = CLAIM_OVERSHOOT - (progress - 0.5) * 2 * (CLAIM_OVERSHOOT - 1)
            end

            local size = math.floor(baseSize * scale)
            if size < 1 then size = 1 end
            local boxX = self.left + (bc[2] - 1) * self.spacing
            local boxY = self.top  + (bc[1] - 1) * self.spacing
            local cx = boxX + self.spacing * 0.5
            local cy = boxY + self.spacing * 0.5
            local x = math.floor(cx - size * 0.5)
            local y = math.floor(cy - size * 0.5)

            gfx.setDitherPattern(owner == 2 and 0.5 or 0)
            gfx.fillRect(x, y, size, size)
            gfx.setDitherPattern(0)
        end
    end

    -- Cursor
    self:drawCursor()

    -- Side‑column scores
    do
        local sw, sh = playdate.display.getSize()
        local F    = self.fonts or {}
        local sys  = gfx.getSystemFont()
        local fNum = F.h1 or sys       -- big score numeral
        local fLbl = F.caption or sys  -- player label / sublabel
        local lblH = fLbl:getHeight()
        local nh   = fNum:getHeight()

        -- Total boxes on the board: the score is a slice of this fixed pie,
        -- so each column "stacks up" a bottom-anchored fill as boxes accrue.
        local total = (self.board.DOTS - 1) * (self.board.DOTS - 1)

        local TUBE_W <const> = 26

        -- Fixed vertical anchors shared by BOTH columns so every element is
        -- rock-solid; only the fill height varies. Room is reserved for two
        -- label lines (label + sublabel) even when a side has only one, and
        -- for the active-turn bar whether or not it is showing.
        local LBL_Y      = V_PADDING
        local SUB_Y      = LBL_Y + lblH + 2
        local NUM_Y      = SUB_Y + lblH + 6
        local TUBE_TOP   = NUM_Y + nh + 10
        local TUBE_BOT   = sh - V_PADDING
        local TUBE_H     = TUBE_BOT - TUBE_TOP

        local function drawColumn(score, label, sub, px, dither)
            local colCx = px + SIDE_COL_W / 2

            -- Header: text always solid black; player identity is carried by
            -- the tube (gray for P2/CPU), matching the dithered P2 boxes.
            gfx.setFont(fLbl)
            local lw = fLbl:getTextWidth(label)
            gfx.drawText(label, colCx - lw / 2, LBL_Y)
            if sub then
                local swid = fLbl:getTextWidth(sub)
                gfx.drawText(sub, colCx - swid / 2, SUB_Y)
            end

            -- Numeral (same y on both sides).
            gfx.setFont(fNum)
            local s  = tostring(score)
            local nw = fNum:getTextWidth(s)
            gfx.drawText(s, colCx - nw / 2, NUM_Y)

            -- Stacking tube: fixed frame, bottom-anchored fill ∝ score/total.
            -- The whole tube (outline + fill) is 50% gray on the P2/CPU side.
            local tubeX = colCx - TUBE_W / 2
            gfx.setDitherPattern(dither and 0.5 or 0)
            gfx.drawRect(tubeX, TUBE_TOP, TUBE_W, TUBE_H)
            local frac  = total > 0 and (score / total) or 0
            local fillH = math.floor((TUBE_H - 2) * frac)
            if fillH > 0 then
                gfx.fillRect(tubeX + 1, TUBE_BOT - 1 - fillH,
                             TUBE_W - 2, fillH)
            end
            gfx.setDitherPattern(0)
        end

        local p1L, p1Sub, p2L, p2Sub
        if self.mode == "pvc" then
            p1L            = "You"
            p2L, p2Sub     = "CPU", self.difficultyLabel
        else
            p1L, p2L       = "P1", "P2"
        end
        drawColumn(p1Score, p1L, p1Sub,               0, false)
        drawColumn(p2Score, p2L, p2Sub, sw - SIDE_COL_W, true)
    end

    -- Game‑over
    if self.board:isGameOver() then
        local F   = self.fonts or {}
        local sys = gfx.getSystemFont()
        local fH1, fH2  = F.h1 or sys, F.h2 or sys
        local fBody, fC = F.body or sys, F.caption or sys

        local pvc = self.mode == "pvc"
        local n1  = pvc and "You" or "P1"
        local n2  = pvc and "CPU" or "P2"

        local winnerLine
        if p1Score > p2Score then winnerLine = (pvc and "You win!" or "P1 wins!")
        elseif p2Score > p1Score then winnerLine = (pvc and "CPU wins!" or "P2 wins!")
        else winnerLine = "It's a draw" end

        local lc1, lc2 = self.board.longestChain[1], self.board.longestChain[2]
        local chainLine
        if lc1 == lc2 then
            chainLine = "Longest chain: tied at " .. lc1
        else
            local who = (lc1 > lc2) and n1 or n2
            chainLine = "Longest chain: " .. who .. " - " .. math.max(lc1, lc2)
        end

        local endMs = self.board.endMs or playdate.getCurrentTimeMilliseconds()
        local secs = math.floor((endMs - self.board.startMs) / 1000)
        local timeLine = string.format("Time: %d:%02d",
            math.floor(secs / 60), secs % 60)

        -- Each line: { text, font, chip? }. `chip` rows render as an inverted
        -- pill (the unlocked-goal toast).
        local lines = {}

        if self.newBadges and #self.newBadges > 0 then
            local cap = math.min(3, #self.newBadges)
            for i = 1, cap do
                lines[#lines + 1] = { self.newBadges[i].goal, fC, chip = true }
            end
            if #self.newBadges > cap then
                lines[#lines + 1] = { "+" .. (#self.newBadges - cap) .. " more", fC, chip = true }
            end
        end

        lines[#lines + 1] = { "Game Over",                  fH1 }
        lines[#lines + 1] = { winnerLine,                   fH2 }
        lines[#lines + 1] = { chainLine,                    fBody }
        lines[#lines + 1] = { timeLine,                     fBody }
        lines[#lines + 1] = { "(A: play again   B: menu)",  fC }

        local maxW, totalH = 0, 0
        local rowH = {}
        for i, l in ipairs(lines) do
            local font = l[2]
            local w = font:getTextWidth(l[1]) + (l.chip and 20 or 0)
            if w > maxW then maxW = w end
            rowH[i] = font:getHeight() + (l.chip and 8 or 4)
            totalH = totalH + rowH[i]
        end

        local panelW = maxW + 28
        local panelH = totalH + 16
        local sw, sh = playdate.display.getSize()
        local cx, cy = sw / 2, sh / 2

        -- Animate-in: a quick eased pop anchored on the game-over instant.
        -- Saturates at t=1 so the panel is static for the rest of the screen.
        local now = playdate.getCurrentTimeMilliseconds()
        local t = (now - (self.board.endMs or now)) / 220
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        -- easeOutBack for a touch of overshoot.
        local b1, b3 = 1.70158, 2.70158
        local tm = t - 1
        local e = 1 + b3 * tm * tm * tm + b1 * tm * tm
        local scale = 0.6 + 0.4 * e

        local pw, ph = panelW * scale, panelH * scale
        local px = math.floor(cx - pw / 2)
        local py = math.floor(cy - ph / 2)

        -- Soft drop shadow, then the panel, at the animated size.
        gfx.setColor(gfx.kColorBlack); gfx.setDitherPattern(0.5)
        gfx.fillRect(px + 4, py + 5, pw, ph)
        gfx.setDitherPattern(0)
        gfx.setColor(gfx.kColorWhite); gfx.fillRect(px, py, pw, ph)
        gfx.setColor(gfx.kColorBlack); gfx.drawRect(px, py, pw, ph)

        -- Content is drawn at full size but clipped to the growing panel, so
        -- it's revealed from the centre outward as the box pops open.
        gfx.setClipRect(px, py, pw, ph)
        local y = math.floor(cy - panelH / 2) + 8
        for i, l in ipairs(lines) do
            gfx.setFont(l[2])
            local tw = l[2]:getTextWidth(l[1])
            local tx = math.floor(cx - tw / 2)
            if l.chip then
                local cw, ch = tw + 18, rowH[i] - 2
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(math.floor(cx - cw / 2), y - 1, cw, ch, 4)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                gfx.drawText(l[1], tx, y + 2)
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            else
                gfx.drawText(l[1], tx, y)
            end
            y = y + rowH[i]
        end
        gfx.clearClipRect()
        gfx.setFont(fBody)
    end
end

-------------------------------------------------------------------------------
function UI:update()
    self:handleInput()
    self:draw()
end

return UI
