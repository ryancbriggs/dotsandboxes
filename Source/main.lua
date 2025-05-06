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
local DEFAULT_SETTINGS = { numDots = 6, difficulty = "medium" }
local settings = playdate.datastore.read("settings") or {}
settings.numDots = math.min(8, math.max(3, settings.numDots or DEFAULT_SETTINGS.numDots))

-- validate difficulty string -------------------------------------------------
local difficulties = { "easy", "medium", "hard", "expert" }
local function isValidDiff(d) for _,v in ipairs(difficulties) do if d==v then return true end end end
if not isValidDiff(settings.difficulty) then settings.difficulty = DEFAULT_SETTINGS.difficulty end

local function difficultyIndex()
    for i,v in ipairs(difficulties) do if v == settings.difficulty then return i end end
    return 1
end

-- ---------------------------------------------------------------------------
-- Global runtime state -------------------------------------------------------
-- ---------------------------------------------------------------------------
local appState       = "menu"             -- "menu", "settings", "pvc", "pvp"
local menuOptions    = { "1 Player", "2 Player", "Settings" }
local selectedOption = 1
local settingsCursor = 1      -- 1 = board size, 2 = difficulty
local ui = nil

math.randomseed(playdate.getSecondsSinceEpoch())

-- helpers -------------------------------------------------------------------
local function returnToMainMenu()
    appState       = "menu";  ui = nil;  selectedOption = 1
end
playdate.getSystemMenu():addMenuItem("Main Menu", returnToMainMenu)

local function initGame(mode)
    local board = Board.new(settings.numDots)
    ui       = UI.new(board)
    ui.mode  = mode
    appState = mode
    Ai.setDifficulty(settings.difficulty)
end

-- ---------------------------------------------------------------------------
-- SETTINGS SCREEN -----------------------------------------------------------
-- ---------------------------------------------------------------------------
local function drawSettings()
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText("Settings", 40, 40)

    local rowY = { 90, 140 }
    local mark

    -- board size row
    mark = (settingsCursor==1) and "> " or "  "
    gfx.drawText(mark .. "Board size (dots):", 40, rowY[1])
    gfx.drawText(string.format("<  %d  >", settings.numDots), 280, rowY[1])

    -- difficulty row
    mark = (settingsCursor==2) and "> " or "  "
    gfx.drawText(mark .. "Difficulty:", 40, rowY[2])
    gfx.drawText(string.format("<  %s  >", settings.difficulty), 280, rowY[2])

    gfx.drawText("Press A or B to save", 40, 200)
end

local function handleSettingsInput()
    if playdate.buttonJustPressed(playdate.kButtonUp) then settingsCursor = (settingsCursor==1) and 2 or 1; return end
    if playdate.buttonJustPressed(playdate.kButtonDown) then settingsCursor = (settingsCursor==2) and 1 or 2; return end

    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        if settingsCursor == 1 then
            settings.numDots = math.max(3, settings.numDots - 1)
        else
            local idx = difficultyIndex() - 1; if idx < 1 then idx = #difficulties end
            settings.difficulty = difficulties[idx]
        end
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        if settingsCursor == 1 then
            settings.numDots = math.min(8, settings.numDots + 1)
        else
            local idx = difficultyIndex() + 1; if idx > #difficulties then idx = 1 end
            settings.difficulty = difficulties[idx]
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
        gfx.setColor(gfx.kColorBlack)
        gfx.drawText("Select Mode:", 40, 40)
        for i,label in ipairs(menuOptions) do
            local y = 80 + (i-1)*30
            gfx.drawText(((i==selectedOption) and "> " or "  ") .. label, 40, y)
        end

        if playdate.buttonJustPressed(playdate.kButtonDown) then selectedOption = selectedOption % #menuOptions + 1
        elseif playdate.buttonJustPressed(playdate.kButtonUp) then selectedOption = (selectedOption-2) % #menuOptions + 1
        elseif playdate.buttonJustPressed(playdate.kButtonA) then
            if selectedOption==1 then initGame("pvc")
            elseif selectedOption==2 then initGame("pvp")
            else appState="settings"; settingsCursor=1 end
        end

    elseif appState == "settings" then
        handleSettingsInput(); drawSettings()

    else  -- gameplay, only let the human move the cursor / place lines
        -- Always accept input if the game is over (to let “A to restart” work),
        -- or if it’s the human’s turn (PvP or PvC player).
        if ui.board:isGameOver()
            or ui.mode=="pvp"
            or (ui.mode=="pvc" and ui.board.currentPlayer==1)
        then
            ui:handleInput()
        end

        -- If we're in player‑vs‑computer and it's the AI’s turn, make its move
        if ui.mode=="pvc"
            and ui.board.currentPlayer==2
            and not ui.board:isGameOver()
        then
            local mv = Ai.chooseMove(ui.board)
            if mv then
                ui.board:playEdge(mv)
            end
        end
        ui:draw()
    end

    playdate.timer.updateTimers(); gfx.sprite.update()
end
