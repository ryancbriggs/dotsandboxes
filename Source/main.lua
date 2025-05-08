-- main.lua – Main loop with persistent board‑size AND difficulty settings

import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

local sound = import "sound"    -- button‑click sounds
local Board = import "board"
local UI    = import "ui"
local Ai    = import "ai"

local gfx = playdate.graphics

-- ---------------------------------------------------------------------------
-- One global input handler only for click sounds -----------------------------
-- ---------------------------------------------------------------------------
local click = { leftButtonDown  = sound.basic,
                rightButtonDown = sound.basic,
                upButtonDown    = sound.basic,
                downButtonDown  = sound.basic,
                AButtonDown     = sound.select,
                BButtonDown     = sound.select }
for k, fn in pairs(click) do click[k] = function() fn(); return false end end
playdate.inputHandlers.push(click)

-- ---------------------------------------------------------------------------
-- Persistent settings --------------------------------------------------------
-- ---------------------------------------------------------------------------
local DEFAULT_SETTINGS = { numDots = 6, difficulty = "medium", firstPlayer = "random" }
local settings = playdate.datastore.read("settings") or {}
settings.numDots = math.min(8, math.max(3, settings.numDots or DEFAULT_SETTINGS.numDots))

-- validate difficulty string -------------------------------------------------
local difficulties = { "easy", "medium", "hard", "expert" }
local function difficultyIndex()
    for i, v in ipairs(difficulties) do
        if settings.difficulty == v then return i end
    end
    return 1
end
local function isValidDiff(d)
    for _,v in ipairs(difficulties) do
        if d == v then return true end
    end
end
if not isValidDiff(settings.difficulty) then
    settings.difficulty = DEFAULT_SETTINGS.difficulty
end

-- first‑player selection helpers -------------------------------------------------
local firstPlayerOptions = { "player1", "player2", "random" }
local function isValidFirstPlayer(fp)
    for _,v in ipairs(firstPlayerOptions) do
        if fp == v then return true end
    end
end
if not isValidFirstPlayer(settings.firstPlayer) then
    settings.firstPlayer = DEFAULT_SETTINGS.firstPlayer
end

local function firstPlayerIndex()
    for i,v in ipairs(firstPlayerOptions) do
        if settings.firstPlayer == v then return i end
    end
    return 3  -- default to random
end

local function firstPlayerDisplay()
    local labels = { "Player 1", "Player 2", "Random" }
    return labels[firstPlayerIndex()]
end

-- ---------------------------------------------------------------------------
-- Global runtime state -------------------------------------------------------
-- ---------------------------------------------------------------------------
local appState       = "menu"             -- "menu", "settings", "pvc", "pvp"
local menuOptions    = { "1 Player", "2 Player", "Settings" }
local selectedOption = 1
local settingsCursor = 1      -- 1 = board size, 2 = difficulty, 3 = first player
local ui = nil

-- seed RNG once at load for general randomness --------------------------------
math.randomseed(playdate.getSecondsSinceEpoch())
math.random()

-- helpers -------------------------------------------------------------------
local function returnToMainMenu()
    appState       = "menu";  ui = nil;  selectedOption = 1
end
playdate.getSystemMenu():addMenuItem("Main Menu", returnToMainMenu)

-- initialize a new game, applying first‑player selection --------------------
local function initGame(mode)
    local board = Board.new(settings.numDots)
    ui       = UI.new(board)
    ui.mode  = mode
    appState = mode
    Ai.setDifficulty(settings.difficulty)

    if settings.firstPlayer == "player1" then
        ui.board.currentPlayer = 1
    elseif settings.firstPlayer == "player2" then
        ui.board.currentPlayer = 2
    else
        ui.board.currentPlayer = math.random(1, 2)
    end
end

-- ---------------------------------------------------------------------------
-- SETTINGS SCREEN -----------------------------------------------------------
-- ---------------------------------------------------------------------------
local function drawSettings()
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText("Settings", 40, 40)

    -- tighter vertical spacing
    local rowY = { 80, 120, 160 }
    local mark

    -- board size row
    mark = (settingsCursor==1) and "> " or "  "
    gfx.drawText(mark .. "Board size (dots):", 40, rowY[1])
    gfx.drawText(string.format("<  %d  >", settings.numDots), 280, rowY[1])

    -- difficulty row
    mark = (settingsCursor==2) and "> " or "  "
    gfx.drawText(mark .. "Difficulty:", 40, rowY[2])
    gfx.drawText(string.format("<  %s  >", settings.difficulty), 280, rowY[2])

    -- first‑player row
    mark = (settingsCursor==3) and "> " or "  "
    gfx.drawText(mark .. "First player:", 40, rowY[3])
    gfx.drawText(string.format("<  %s  >", firstPlayerDisplay()), 280, rowY[3])

    -- save prompt
    gfx.drawText("Press A or B to save", 40, 200)
end

local function handleSettingsInput()
    if playdate.buttonJustPressed(playdate.kButtonUp) then
        settingsCursor = settingsCursor == 1 and 3 or (settingsCursor - 1)
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonDown) then
        settingsCursor = settingsCursor == 3 and 1 or (settingsCursor + 1)
        return
    end

    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        if settingsCursor == 1 then
            settings.numDots = math.max(3, settings.numDots - 1)
        elseif settingsCursor == 2 then
            local idx = difficultyIndex() - 1
            if idx < 1 then idx = #difficulties end
            settings.difficulty = difficulties[idx]
        else
            local idx = firstPlayerIndex() - 1
            if idx < 1 then idx = #firstPlayerOptions end
            settings.firstPlayer = firstPlayerOptions[idx]
        end
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        if settingsCursor == 1 then
            settings.numDots = math.min(8, settings.numDots + 1)
        elseif settingsCursor == 2 then
            local idx = difficultyIndex() + 1
            if idx > #difficulties then idx = 1 end
            settings.difficulty = difficulties[idx]
        else
            local idx = firstPlayerIndex() + 1
            if idx > #firstPlayerOptions then idx = 1 end
            settings.firstPlayer = firstPlayerOptions[idx]
        end
    elseif playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
        playdate.datastore.write(settings, "settings")
        returnToMainMenu()
    end
end

-- ---------------------------------------------------------------------------
-- Main update loop ----------------------------------------------------------
-- ---------------------------------------------------------------------------
function playdate.update()
    gfx.clear()

    if appState == "menu" then
    local sw, sh = playdate.display.getSize()
    gfx.clear()

    -- 1) CHUNKY BANNER (dithered background + big text)
    local header = "SELECT MODE"
    local f = gfx.getSystemFont()
    local tw, th = f:getTextWidth(header), f:getHeight()
    local hx = (sw - tw) / 2
    local hy = 20

    -- draw the header text on top
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText(header, hx, hy)

    -- 2) BULLETED OPTIONS (with proper vertical centering)
    local startY  = hy + th + 20    -- same as before
    local lineH   = 30
    local font    = gfx.getSystemFont()
    local fh      = font:getHeight()
    for i, label in ipairs(menuOptions) do
        -- the top‐left corner where you drawText(label, textX, y)
        local y = startY + (i - 1) * lineH

        -- center the dot vertically in that font line
        local bulletY = y + fh/2

        -- bullet dot (same radius as game)
        gfx.fillCircleAtPoint(40, bulletY, UI.DOT_SIZE)

        -- the label itself, top‐aligned at y
        gfx.drawText(label, 60, y)
    end

    -- 3) IN‑GAME STYLE CURSOR (fit tightly around dot + text)
    do
        -- coords for our selected line:
        local startY  = hy + th + 20      -- same Y origin you used for the bullets
        local lineH   = 30                -- your spacing
        local i       = selectedOption
        local y       = startY + (i - 1) * lineH

        -- text metrics
        local font      = gfx.getSystemFont()
        local label     = menuOptions[i]
        local textW     = font:getTextWidth(label)
        local textH     = font:getHeight()

        -- positions
        local bulletX   = 40               -- same X you used for gfx.fillCircleAtPoint
        local textX     = 60               -- same X you used for gfx.drawText
        local padX, padY = 8, 4            -- tweak these for more/less breathing room

        -- compute box bounds
        local left   = bulletX - padX
        local right  = textX + textW + padX
        local top    = y       - padY
        local bottom = y + textH + padY
        local w      = right - left
        local h      = bottom - top

        -- draw it
        gfx.setDitherPattern(0.5)          -- grey outline style
        gfx.setLineWidth(3)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawRect(left, top, w, h)
        gfx.setDitherPattern(0)            -- reset
        gfx.setLineWidth(1)
    end

    -- 4) INPUT
    if playdate.buttonJustPressed(playdate.kButtonDown) then
        selectedOption = selectedOption % #menuOptions + 1
    elseif playdate.buttonJustPressed(playdate.kButtonUp) then
        selectedOption = (selectedOption - 2) % #menuOptions + 1
    elseif playdate.buttonJustPressed(playdate.kButtonA) then
        if     selectedOption == 1 then initGame("pvc")
        elseif selectedOption == 2 then initGame("pvp")
        else   appState = "settings"; settingsCursor = 1
        end
    end

    -- Settings
    elseif appState == "settings" then
        local sw, sh = playdate.display.getSize()
        gfx.clear()

        -- 1) HEADER ----------------------------------------------------------
        local header = "SETTINGS"
        local f, tw, th = gfx.getSystemFont(),
                        gfx.getSystemFont():getTextWidth(header),
                        gfx.getSystemFont():getHeight()
        local hx = (sw - tw)/2
        local hy = 20
        gfx.drawText(header, hx, hy)

        -- 2) PREP LABELS + VALUE TEXTS --------------------------------------
        local labels = { "Board size:", "Difficulty:", "First player:" }
        local rawValues = {
            tostring(settings.numDots),
            settings.difficulty,
            firstPlayerDisplay()
        }

        -- build "<  val  >" strings
        local valueTexts = {}
        for i, v in ipairs(rawValues) do
            valueTexts[i] = string.format("<  %s  >", v)
        end

        -- figure out the widest "<...>" so the box is constant
        local maxOptionWidth = 0
        for _, txt in ipairs(valueTexts) do
            local w = f:getTextWidth(txt)
            if w > maxOptionWidth then maxOptionWidth = w end
        end

        -- vertical layout
        local startY = hy + th + 20
        local lineH  = 30
        local bulletX, labelX, valueX = 40, 60, 280

        -- draw rows
        for i = 1, #labels do
            local y = startY + (i-1)*lineH
            -- bullet
            gfx.fillCircleAtPoint(bulletX, y + th/2, UI.DOT_SIZE)
            -- label
            gfx.drawText(labels[i], labelX, y)
            -- value (<  ...  >)
            gfx.drawText(valueTexts[i], valueX, y)
        end

        -- 3) STATIC CURSOR BOX -----------------------------------------------
        do
            local i = settingsCursor
            local y = startY + (i-1)*lineH

            local padX, padY = 8, 4
            local left   = bulletX - padX
            local right  = valueX + maxOptionWidth + padX
            local top    = y - padY
            local bottom = y + th + padY

            --gfx.setDitherPattern(0.5)
            gfx.setLineWidth(3)
            gfx.drawRect(left, top, right - left, bottom - top)
            gfx.setDitherPattern(0)
            gfx.setLineWidth(1)
        end

        -- 4) NAVIGATION ------------------------------------------------------
        if     playdate.buttonJustPressed(playdate.kButtonUp)   then
            settingsCursor = (settingsCursor - 2) % #labels + 1

        elseif playdate.buttonJustPressed(playdate.kButtonDown) then
            settingsCursor =  settingsCursor      % #labels + 1

        elseif playdate.buttonJustPressed(playdate.kButtonLeft) then
            if     settingsCursor == 1 then
                settings.numDots = math.max(3, settings.numDots - 1)
            elseif settingsCursor == 2 then
                local idx = difficultyIndex() - 1
                if idx < 1 then idx = #difficulties end
                settings.difficulty = difficulties[idx]
            else
                local idx = firstPlayerIndex() - 1
                if idx < 1 then idx = #firstPlayerOptions end
                settings.firstPlayer = firstPlayerOptions[idx]
            end

        elseif playdate.buttonJustPressed(playdate.kButtonRight) then
            if     settingsCursor == 1 then
                settings.numDots = math.min(8, settings.numDots + 1)
            elseif settingsCursor == 2 then
                local idx = difficultyIndex() + 1
                if idx > #difficulties then idx = 1 end
                settings.difficulty = difficulties[idx]
            else
                local idx = firstPlayerIndex() + 1
                if idx > #firstPlayerOptions then idx = 1 end
                settings.firstPlayer = firstPlayerOptions[idx]
            end

        elseif playdate.buttonJustPressed(playdate.kButtonA)
        or playdate.buttonJustPressed(playdate.kButtonB) then
            playdate.datastore.write(settings, "settings")
            returnToMainMenu()
        end

    else  -- =========== GAMEPLAY =============
        -- let the UI handle d‑pad/A/B as before
        if ui.board:isGameOver()
            or ui.mode=="pvp"
            or (ui.mode=="pvc" and ui.board.currentPlayer==1)
        then
            ui:handleInput()
        end
        -- AI move
        if ui.mode=="pvc"
        and ui.board.currentPlayer==2
        and not ui.board:isGameOver()
        then
            local mv = Ai.chooseMove(ui.board)
            if mv then ui.board:playEdge(mv) end
        end
        ui:draw()
    end

playdate.timer.updateTimers()
gfx.sprite.update()
end