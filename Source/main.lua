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

for k,fn in pairs(click) do click[k] = function() fn() return false end end
playdate.inputHandlers.push(click)

-- ---------------------------------------------------------------------------
-- Persistent settings --------------------------------------------------------
-- ---------------------------------------------------------------------------
local DEFAULT_SETTINGS = { numDots = 6, difficulty = "easy" }
local settings  = playdate.datastore.read("settings") or {}
settings.numDots    = math.min(8, math.max(3, settings.numDots    or DEFAULT_SETTINGS.numDots))
settings.difficulty = (settings.difficulty == "medium") and "medium" or "easy"

local difficulties  = { "easy", "medium" }
local function difficultyIndex()  -- helper to map string → index
    return (settings.difficulty == "medium") and 2 or 1
end

-- ---------------------------------------------------------------------------
-- Global runtime state -------------------------------------------------------
-- ---------------------------------------------------------------------------
local appState       = "menu"             -- "menu", "settings", "pvc", "pvp"
local menuOptions    = { "1 Player", "2 Player", "Settings" }
local selectedOption = 1                 -- highlighted line in main menu

-- Settings‑screen cursor (1 = board‑size row, 2 = difficulty row)
local settingsCursor = 1

local ui = nil                           -- UI object active during a game

math.randomseed(playdate.getSecondsSinceEpoch())

-- ---------------------------------------------------------------------------
-- Helpers -------------------------------------------------------------------
-- ---------------------------------------------------------------------------
local function returnToMainMenu()
    appState       = "menu"
    ui             = nil
    selectedOption = 1
end

-- Expose “Main Menu” in the console menu ---------------------------
playdate.getSystemMenu():addMenuItem("Main Menu", returnToMainMenu)

local function initGame(mode)
    local board = Board.new(settings.numDots)
    ui         = UI.new(board)
    ui.mode    = mode
    appState   = mode
    Ai.setDifficulty(settings.difficulty)
end

-- ---------------------------------------------------------------------------
-- SETTINGS SCREEN -----------------------------------------------------------
-- ---------------------------------------------------------------------------
local function drawSettings()
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText("Settings", 40, 40)

    local rowY = { 90, 140 }
    local cursorMark

    -- Row 1 : board size selector ----------------------------------
    cursorMark = (settingsCursor == 1) and "> " or "  "
    gfx.drawText(cursorMark .. "Board size (dots):", 40, rowY[1])
    gfx.drawText(string.format("<  %d  >", settings.numDots), 280, rowY[1])

    -- Row 2 : difficulty selector -----------------------------------
    cursorMark = (settingsCursor == 2) and "> " or "  "
    gfx.drawText(cursorMark .. "Difficulty:", 40, rowY[2])
    gfx.drawText(string.format("<  %s  >", settings.difficulty), 280, rowY[2])

    gfx.drawText("Press A or B to save", 40, 200)
end

local function handleSettingsInput()
    if playdate.buttonJustPressed(playdate.kButtonUp) then
        settingsCursor = (settingsCursor == 1) and 2 or 1
        return
    elseif playdate.buttonJustPressed(playdate.kButtonDown) then
        settingsCursor = (settingsCursor == 2) and 1 or 2
        return
    end

    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        if settingsCursor == 1 then
            settings.numDots = math.max(3, settings.numDots - 1)
        else -- difficulty
            local idx = difficultyIndex()
            idx = (idx == 1) and #difficulties or (idx - 1)
            settings.difficulty = difficulties[idx]
        end
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        if settingsCursor == 1 then
            settings.numDots = math.min(8, settings.numDots + 1)
        else
            local idx = difficultyIndex()
            idx = (idx % #difficulties) + 1
            settings.difficulty = difficulties[idx]
        end
    elseif playdate.buttonJustPressed(playdate.kButtonA) or
           playdate.buttonJustPressed(playdate.kButtonB) then
        -- Save to disk and return
        playdate.datastore.write(settings, "settings")
        returnToMainMenu()
    end
end

-- ---------------------------------------------------------------------------
-- Main update loop ----------------------------------------------------------
-- ---------------------------------------------------------------------------
function playdate.update()
    gfx.clear()

    -- ------------------------------------------------------------- MENU ----
    if appState == "menu" then
        gfx.setColor(gfx.kColorBlack)
        gfx.drawText("Select Mode:", 40, 40)
        for i, label in ipairs(menuOptions) do
            local y = 80 + (i - 1) * 30
            local prefix = (i == selectedOption) and "> " or "  "
            gfx.drawText(prefix .. label, 40, y)
        end

        if playdate.buttonJustPressed(playdate.kButtonDown) then
            selectedOption = selectedOption % #menuOptions + 1
        elseif playdate.buttonJustPressed(playdate.kButtonUp) then
            selectedOption = (selectedOption - 2) % #menuOptions + 1
        elseif playdate.buttonJustPressed(playdate.kButtonA) then
            if selectedOption == 1 then
                initGame("pvc")
            elseif selectedOption == 2 then
                initGame("pvp")
            else
                appState       = "settings"
                settingsCursor = 1
            end
        end

    -- ---------------------------------------------------------- SETTINGS ---
    elseif appState == "settings" then
        handleSettingsInput()
        drawSettings()

    -- --------------------------------------------------------- GAMEPLAY ----
    else
        ui:handleInput()

        if ui.mode == "pvc" and ui.board.currentPlayer == 2 and not ui.board:isGameOver() then
            local move = Ai.chooseMove(ui.board)
            if move then ui.board:playEdge(move) end
        end

        ui:draw()
    end

    playdate.timer.updateTimers()
    gfx.sprite.update()
end
