-- main.lua – Main loop with persistent board‑size AND difficulty settings

import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

local sound = import "sound"    -- button‑click sounds
local Board = import "board"
local UI    = import "ui"
local Ai    = import "ai"

local gfx <const> = playdate.graphics

playdate.display.setRefreshRate(20) -- sets frame rate to 20 FPS

-- ---------------------------------------------------------------------------
-- One global input handler only for click sounds ---------------------------
-- ---------------------------------------------------------------------------
local click = {
    leftButtonDown  = sound.basic,
    rightButtonDown = sound.basic,
    upButtonDown    = sound.basic,
    downButtonDown  = sound.basic,
    AButtonDown     = sound.select,
    BButtonDown     = sound.select
}
for k, fn in pairs(click) do
    click[k] = function()
        fn()
        return false
    end
end
playdate.inputHandlers.push(click)

-- ---------------------------------------------------------------------------
-- Persistent settings ------------------------------------------------------
-- ---------------------------------------------------------------------------
local DEFAULT_SETTINGS = {
    numDots     = 6,
    difficulty  = "medium",
    firstPlayer = "random"
}
local settings = playdate.datastore.read("settings") or {}
settings.numDots = math.min(8, math.max(3, settings.numDots or DEFAULT_SETTINGS.numDots))

-- validate difficulty string -----------------------------------------------
local difficulties = { "easy", "medium", "hard", "expert" }
local function difficultyIndex()
    for i, v in ipairs(difficulties) do
        if settings.difficulty == v then return i end
    end
    return 1
end
local function isValidDiff(d)
    for _, v in ipairs(difficulties) do
        if d == v then return true end
    end
    return false
end
if not isValidDiff(settings.difficulty) then
    settings.difficulty = DEFAULT_SETTINGS.difficulty
end

-- first‑player selection helpers -------------------------------------------
local firstPlayerOptions = { "player1", "player2", "random" }
local function isValidFirstPlayer(fp)
    for _, v in ipairs(firstPlayerOptions) do
        if fp == v then return true end
    end
    return false
end
if not isValidFirstPlayer(settings.firstPlayer) then
    settings.firstPlayer = DEFAULT_SETTINGS.firstPlayer
end

local function firstPlayerIndex()
    for i, v in ipairs(firstPlayerOptions) do
        if settings.firstPlayer == v then return i end
    end
    return 3
end

local function firstPlayerDisplay()
    local labels = { "Player 1", "Player 2", "Random" }
    return labels[firstPlayerIndex()]
end

-- ---------------------------------------------------------------------------
-- Global runtime state -----------------------------------------------------
-- ---------------------------------------------------------------------------
local appState       = "menu"        -- "menu", "settings", "pvc", "pvp"
local menuOptions    = { "1 Player", "2 Player", "Settings" }
local selectedOption = 1
local settingsCursor = 1             -- 1 = board size, 2 = difficulty, 3 = first player
local ui             = nil

-- ---------------------------------------------------------------------------
-- AI scheduling helper -----------------------------------------------------
-- ---------------------------------------------------------------------------
local function scheduleAIMove()
    playdate.timer.performAfterDelay(1, function()
        local mv = Ai.chooseMove(ui.board)
        if mv then
            ui.board:playEdge(mv)
            -- if AI just completed a box and still has the turn, schedule again
            if ui.mode == "pvc"
            and ui.board.currentPlayer == 2
            and not ui.board:isGameOver()
            then
                scheduleAIMove()
            end
        end
    end)
end

-- seed RNG once at load ----------------------------------------------------
math.randomseed(playdate.getSecondsSinceEpoch())
math.random()

-- helpers ------------------------------------------------------------------
local function returnToMainMenu()
    appState       = "menu"
    ui             = nil
    selectedOption = 1
end
playdate.getSystemMenu():addMenuItem("Main Menu", returnToMainMenu)

-- initialize a new game ----------------------------------------------------
local function initGame(mode)
    local board = Board.new(settings.numDots)
    ui       = UI.new(board)
    ui.mode  = mode
    appState = mode
    Ai.setDifficulty(settings.difficulty)

    -- who goes first?
    if settings.firstPlayer == "player1" then
        ui.board.currentPlayer = 1
    elseif settings.firstPlayer == "player2" then
        ui.board.currentPlayer = 2
    else
        ui.board.currentPlayer = math.random(1, 2)
    end

    -- if AI goes first, kick off its move
    if ui.mode == "pvc"
    and ui.board.currentPlayer == 2
    then
        scheduleAIMove()
    end
end

-- ---------------------------------------------------------------------------
-- SETTINGS SCREEN ----------------------------------------------------------
-- ---------------------------------------------------------------------------
local function drawSettings()
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText("Settings", 40, 40)

    local rowY = { 80, 120, 160 }
    local mark

    mark = (settingsCursor == 1) and "> " or "  "
    gfx.drawText(mark .. "Board size (dots):", 40, rowY[1])
    gfx.drawText(string.format("<  %d  >", settings.numDots), 280, rowY[1])

    mark = (settingsCursor == 2) and "> " or "  "
    gfx.drawText(mark .. "Difficulty:", 40, rowY[2])
    gfx.drawText(string.format("<  %s  >", settings.difficulty), 280, rowY[2])

    mark = (settingsCursor == 3) and "> " or "  "
    gfx.drawText(mark .. "First player:", 40, rowY[3])
    gfx.drawText(string.format("<  %s  >", firstPlayerDisplay()), 280, rowY[3])

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
    elseif playdate.buttonJustPressed(playdate.kButtonA)
        or playdate.buttonJustPressed(playdate.kButtonB)
    then
        playdate.datastore.write(settings, "settings")
        returnToMainMenu()
    end
end

-- ---------------------------------------------------------------------------
-- Main update loop ---------------------------------------------------------
-- ---------------------------------------------------------------------------
function playdate.update()
    gfx.clear()

    if appState == "menu" then
        -- your existing SELECT MODE menu code (unchanged)...
        local sw, sh = playdate.display.getSize()
        gfx.clear()
        local header = "SELECT MODE"
        local f, tw, th = gfx.getSystemFont(), gfx.getSystemFont():getTextWidth(header), gfx.getSystemFont():getHeight()
        local hx, hy = (sw - tw) / 2, 20
        gfx.setColor(gfx.kColorBlack)
        gfx.drawText(header, hx, hy)

        local startY, lineH = hy + th + 20, 30
        local font, fh = gfx.getSystemFont(), gfx.getSystemFont():getHeight()
        for i, label in ipairs(menuOptions) do
            local y = startY + (i - 1) * lineH
            gfx.fillCircleAtPoint(40, y + fh/2, UI.DOT_SIZE)
            gfx.drawText(label, 60, y)
        end

        do
            local i = selectedOption
            local y = startY + (i - 1) * lineH
            local label = menuOptions[i]
            local w, h = gfx.getSystemFont():getTextWidth(label), gfx.getSystemFont():getHeight()
            local padX, padY = 8, 4
            local left, top    = 40 - padX, y - padY
            local right, bottom = 60 + w + padX, y + h + padY
            gfx.setDitherPattern(0.5); gfx.setLineWidth(3)
            gfx.drawRect(left, top, right-left, bottom-top)
            gfx.setDitherPattern(0); gfx.setLineWidth(1)
        end

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

    elseif appState == "settings" then
        drawSettings()
        handleSettingsInput()

    else  -- =========== GAMEPLAY =============
        -- remember who had the turn at frame start
        local prev = ui.board.currentPlayer

        -- 1) allow input only on appropriate turns
        if ui.board:isGameOver()
        or ui.mode == "pvp"
        or (ui.mode == "pvc" and prev == 1)
        then
            ui:handleInput()
        end

        -- 2) draw right away so your line shows immediately
        ui:draw()

        -- 3) if turn just passed from you to the AI, defer its move
        if ui.mode == "pvc"
        and prev == 1
        and ui.board.currentPlayer == 2
        and not ui.board:isGameOver()
        then
            scheduleAIMove()
        end
    end

    -- always process timers & sprites
    playdate.timer.updateTimers()
    gfx.sprite.update()
end