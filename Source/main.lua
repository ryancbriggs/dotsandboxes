-- main.lua – reliable Main‑Menu return + settings persistence

import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"
local sound = import "sound"    -- your sound.lua

-- one handler for ALL button-press sounds
local globalButtonHandler = {
    -- arrow keys → “basic” click
    leftButtonDown = function()  sound.basic()  return false end,
    rightButtonDown = function() sound.basic()  return false end,
    upButtonDown = function()    sound.basic()  return false end,
    downButtonDown = function()  sound.basic()  return false end,

    -- A or B → “select” click
    AButtonDown = function()     sound.select() return false end,
    BButtonDown = function()     sound.select() return false end,
}

playdate.inputHandlers.push(globalButtonHandler)

function playdate.update()
    -- your existing update loop:
    -- e.g. UI:update()
    playdate.timer.updateTimers()
    gfx.sprite.update()
end

local gfx = playdate.graphics

---------------------------------------------------------------------
-- Persistent settings ----------------------------------------------
---------------------------------------------------------------------
local DEFAULT_SETTINGS = { numDots = 6 }
local settings  = playdate.datastore.read("settings") or {}
settings.numDots = math.min(8, math.max(3,
                 settings.numDots or DEFAULT_SETTINGS.numDots))
local numDots   = settings.numDots        -- working copy while running

---------------------------------------------------------------------
-- Global state -----------------------------------------------------
---------------------------------------------------------------------
local appState       = "menu"             -- "menu","settings","pvc","pvp"
local menuOptions    = { "1 Player", "2 Player", "Settings" }
local selectedOption = 1
local ui             = nil               -- set when a game starts

---------------------------------------------------------------------
-- Easy helper to go home -------------------------------------------
---------------------------------------------------------------------
local function returnToMainMenu()
    appState       = "menu"
    ui             = nil
    selectedOption = 1
end

---------------------------------------------------------------------
-- System‑menu entry ------------------------------------------------
---------------------------------------------------------------------
local systemMenu = playdate.getSystemMenu()
systemMenu:addMenuItem("Main Menu", returnToMainMenu)

---------------------------------------------------------------------
-- Dependencies -----------------------------------------------------
---------------------------------------------------------------------
local Board = import "board"
local UI    = import "ui"
local Ai    = import "ai"

math.randomseed(playdate.getSecondsSinceEpoch())

---------------------------------------------------------------------
-- Helpers ----------------------------------------------------------
---------------------------------------------------------------------
local function initGame(mode)
    local board = Board.new(numDots)
    ui = UI.new(board)
    ui.mode  = mode                     -- remember game mode
    appState = mode                     -- "pvc" or "pvp"
end

---------------------------------------------------------------------
-- SETTINGS SCREEN --------------------------------------------------
---------------------------------------------------------------------
local function drawSettings()
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText("Settings", 40, 40)
    gfx.drawText("Board size (dots per side):", 40, 80)
    gfx.drawText(string.format("<  %d  >", numDots), 40, 110)
    gfx.drawText("left or right to change", 40, 150)
    gfx.drawText("A or B to save and go back", 40, 170)
end

local function handleSettingsInput()
    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        numDots = math.max(3, numDots - 1)
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        numDots = math.min(8, numDots + 1)
    elseif playdate.buttonJustPressed(playdate.kButtonA)
        or playdate.buttonJustPressed(playdate.kButtonB) then
        -- persist & return to menu
        settings.numDots = numDots
        playdate.datastore.write(settings, "settings")
        returnToMainMenu()
    end
end

---------------------------------------------------------------------
-- Main update loop -------------------------------------------------
---------------------------------------------------------------------
function playdate.update()
    gfx.clear()

    -----------------------------------------------------------------
    -- MENU ---------------------------------------------------------
    -----------------------------------------------------------------
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
            else -- Settings
                appState = "settings"
            end
        end

    -----------------------------------------------------------------
    -- SETTINGS -----------------------------------------------------
    -----------------------------------------------------------------
    elseif appState == "settings" then
        handleSettingsInput()
        drawSettings()

    -----------------------------------------------------------------
    -- GAMEPLAY -----------------------------------------------------
    -----------------------------------------------------------------
    else
        ui:handleInput()

        -- AI turn (only in 1‑player mode)
        if ui.mode == "pvc"
           and ui.board.currentPlayer == 2
           and not ui.board:isGameOver() then
            local choice = Ai.chooseMove(ui.board)
            if choice then ui.board:playEdge(choice) end
        end

        ui:draw()
    end

    playdate.timer.updateTimers()
end