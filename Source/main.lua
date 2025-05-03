-- main.lua – cleaned and consolidated (updated with AI module)

import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

local gfx = playdate.graphics

---------------------------------------------------------------------
-- Global state -----------------------------------------------------
---------------------------------------------------------------------
local appState       = "menu"             -- "menu", "pvp", "pvc", "pause"
local menuOptions    = {"1 Player", "2 Player"}
local selectedOption = 1
local ui             = nil                -- set after a game starts
local gotoMenu       = false              -- set by System‑menu callback

---------------------------------------------------------------------
-- System‑menu entry ------------------------------------------------
---------------------------------------------------------------------
local systemMenu = playdate.getSystemMenu()
systemMenu:addMenuItem("Main Menu", function()
    -- Executed while the game is PAUSED inside the System Menu. We
    -- can't change state until Playdate resumes, so set a flag.
    gotoMenu = true
end)

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
local function seekFreeEdge(board, startEdge, delta)
    local total = #board.edgeToCoord
    local e = startEdge
    for _ = 1, total do
        e = ((e - 1 + delta) % total) + 1
        if not board:edgeIsFilled(e) then return e end
    end
    return startEdge
end

local function initGame(mode)
    local board = Board.new()
    ui = UI.new(board)
    ui.mode = mode           -- "pvp" or "pvc"
    if mode == "pvc" then
        -- configure AI difficulty if desired
        Ai.setDifficulty("random")
    end
    appState = mode
end

---------------------------------------------------------------------
-- Playdate lifecycle callbacks ------------------------------------
---------------------------------------------------------------------
function playdate.gameWillResume()
    -- Called when the System Menu closes
    if gotoMenu then
        appState = "menu"
        ui = nil
        selectedOption = 1
        gotoMenu = false
    end
end

---------------------------------------------------------------------
-- Main update loop -------------------------------------------------
---------------------------------------------------------------------
function playdate.update()
    gfx.clear()

    -----------------------------------------------------------------
    -- MENU STATE ----------------------------------------------------
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
            initGame(selectedOption == 1 and "pvc" or "pvp")
        end

    -----------------------------------------------------------------
    -- GAMEPLAY STATE ------------------------------------------------
    -----------------------------------------------------------------
    else
        ui:handleInput()  -- player controls (A, B, d‑pad)

        -- AI turn for 1‑player mode -----------------------------------
        if ui.mode == "pvc" and ui.board.currentPlayer == 2 and not ui.board:isGameOver() then
            local choice = Ai.chooseMove(ui.board)
            if choice then
                ui.board:playEdge(choice)
                -- cursor stays where it is, so we no longer re‑seek a new free edge
                -- ui.cursorEdge = seekFreeEdge(ui.board, choice, 1)
            end
        end

        ui:draw()
    end

    playdate.timer.updateTimers()
end
