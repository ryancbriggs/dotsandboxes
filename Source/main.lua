-- main.lua – Main loop with persistent board‑size AND difficulty settings

import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

local sound = import "sound"    -- button‑click sounds
local Board = import "board"
local UI    = import "ui"
local Ai    = import "ai"
local Stats = import "stats"
local Fonts = import "fonts"   -- central type hierarchy (passed to UI via opts)

Stats.load()

local gfx <const> = playdate.graphics

-- Default running text everywhere unless a draw routine overrides it.
gfx.setFont(Fonts.body)

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
settings.numDots = math.min(8, math.max(4, settings.numDots or DEFAULT_SETTINGS.numDots))

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
local menuOptions    = { "1 Player", "2 Player", "Career", "Settings" }
local selectedOption = 1
local settingsCursor = 1             -- 1 = board size, 2 = difficulty, 3 = first player
local ui             = nil

-- ---------------------------------------------------------------------------
-- Coroutine-driven AI tick (called each frame during gameplay) -------------
-- ---------------------------------------------------------------------------
-- Mercy rule: the first box of a chain gets a full beat so the animation can
-- be enjoyed, but each subsequent box shrinks the pace exponentially. A
-- 12-box chain plays in about a second instead of three.
local CHAIN_PACE_MAX_MS <const> = 240    -- first chain step
local CHAIN_PACE_MIN_MS <const> = 30     -- floor (frame is ~50ms, so this is "as fast as possible")
local CHAIN_PACE_DECAY  <const> = 0.65   -- multiplicative shrink per box already claimed

local lastAIClaimMs = 0

local function chainPaceFor(boxesAlreadyClaimed)
    -- 1 -> max, 2 -> max*decay, 3 -> max*decay^2, etc.
    local d = CHAIN_PACE_MAX_MS * (CHAIN_PACE_DECAY ^ (boxesAlreadyClaimed - 1))
    if d < CHAIN_PACE_MIN_MS then d = CHAIN_PACE_MIN_MS end
    return d
end

local function tickAI()
    if not ui or ui.mode ~= "pvc" then return end
    if ui.board:isGameOver() then return end

    -- If a coroutine is already in flight, we MUST resume it regardless of
    -- the board's transient currentPlayer. The search calls playEdge through
    -- applyMove, which flips currentPlayer; if we bailed here, the board
    -- would stay in that half-applied state forever.
    if not Ai.isThinking() then
        if ui.board.currentPlayer ~= 2 then return end

        -- Mid-chain: wait for the chain-pace delay before starting the next search.
        if ui.board.chainLen > 0 then
            local pace = chainPaceFor(ui.board.chainLen)
            if (playdate.getCurrentTimeMilliseconds() - lastAIClaimMs) < pace then
                return
            end
        end

        Ai.beginChooseMove(ui.board)
    end

    local done, move = Ai.tick()
    if done and move then
        local claimed = ui.board:playEdge(move)
        if claimed and claimed > 0 then
            sound.done(ui.board.chainLen - 1)
            lastAIClaimMs = playdate.getCurrentTimeMilliseconds()
        end
    end
end

-- seed RNG once at load ----------------------------------------------------
math.randomseed(playdate.getSecondsSinceEpoch())
math.random()

-- helpers ------------------------------------------------------------------
local function returnToMainMenu()
    if appState == "settings" then
        playdate.datastore.write(settings, "settings")
    end
    Ai.cancel()
    appState       = "menu"
    ui             = nil
    selectedOption = 1
end
playdate.getSystemMenu():addMenuItem("Main Menu", returnToMainMenu)
playdate.getSystemMenu():addCheckmarkMenuItem("Debug logs", false, function(value)
    Ai.debugLogging = value
end)

-- initialize a new game ----------------------------------------------------
local function initGame(mode)
    Ai.cancel()
    local board = Board.new(settings.numDots)
    ui       = UI.new(board, {
        onRestart = function()
            initGame(mode)
        end,
        onMainMenu = returnToMainMenu,
        sound = sound,
        fonts = Fonts,
    })
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
    ui.board.startingPlayer = ui.board.currentPlayer
    -- If AI goes first, tickAI in the main loop will start the search.
end

-- Hook called by the gameplay loop the first frame a game becomes "over".
local function recordIfFinished()
    local board = ui and ui.board
    if not board or not board:isGameOver() or board.recorded then return end

    local newBadges = Stats.recordGame(board, {
        mode           = ui.mode,
        difficulty     = (ui.mode == "pvc") and settings.difficulty or nil,
        startingPlayer = board.startingPlayer or 1,
    })
    ui.newBadges = newBadges
end

-- ---------------------------------------------------------------------------
-- SETTINGS SCREEN ----------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Settings rows: 1-3 are value-cycling, 4 is an action row.
local SETTINGS_ROW_COUNT <const> = 4
local SETTINGS_ROW_RESET <const> = 4

local function drawSettings()
    local sw = playdate.display.getWidth()
    gfx.setColor(gfx.kColorBlack)

    -- Header with underline
    gfx.setFont(Fonts.h1)
    gfx.drawText("Settings", 40, 16)
    gfx.setFont(Fonts.body)
    gfx.drawLine(40, 42, sw - 40, 42)

    -- Value rows (1-3), evenly spaced
    local rowY = { 65, 100, 135 }
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

    -- Divider above the destructive action
    gfx.setDitherPattern(0.5)
    gfx.drawLine(40, 168, sw - 40, 168)
    gfx.setDitherPattern(0)

    mark = (settingsCursor == SETTINGS_ROW_RESET) and "> " or "  "
    gfx.drawText(mark .. "Reset all stats & badges", 40, 180)

    gfx.setFont(Fonts.caption)
    gfx.drawText("A: select   B: back", 40, 220)
    gfx.setFont(Fonts.body)
end

local function handleSettingsInput()
    if playdate.buttonJustPressed(playdate.kButtonUp) then
        settingsCursor = (settingsCursor == 1) and SETTINGS_ROW_COUNT or (settingsCursor - 1)
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonDown) then
        settingsCursor = (settingsCursor == SETTINGS_ROW_COUNT) and 1 or (settingsCursor + 1)
        return
    end

    -- Value-cycling rows (1-3) react to Left/Right.
    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        if settingsCursor == 1 then
            settings.numDots = math.max(4, settings.numDots - 1)
        elseif settingsCursor == 2 then
            local idx = difficultyIndex() - 1
            if idx < 1 then idx = #difficulties end
            settings.difficulty = difficulties[idx]
        elseif settingsCursor == 3 then
            local idx = firstPlayerIndex() - 1
            if idx < 1 then idx = #firstPlayerOptions end
            settings.firstPlayer = firstPlayerOptions[idx]
        end
        return
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        if settingsCursor == 1 then
            settings.numDots = math.min(8, settings.numDots + 1)
        elseif settingsCursor == 2 then
            local idx = difficultyIndex() + 1
            if idx > #difficulties then idx = 1 end
            settings.difficulty = difficulties[idx]
        elseif settingsCursor == 3 then
            local idx = firstPlayerIndex() + 1
            if idx > #firstPlayerOptions then idx = 1 end
            settings.firstPlayer = firstPlayerOptions[idx]
        end
        return
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        if settingsCursor == SETTINGS_ROW_RESET then
            appState = "statsResetConfirm"
        else
            -- Rows 1-3: save and return to main menu.
            playdate.datastore.write(settings, "settings")
            returnToMainMenu()
        end
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        playdate.datastore.write(settings, "settings")
        returnToMainMenu()
    end
end

-- ---------------------------------------------------------------------------
-- STATS SCREEN -------------------------------------------------------------
-- ---------------------------------------------------------------------------
local STATS_TABS  <const> = { "Goals", "Record", "Summary" }
local STATS_CONTENT_TOP <const> = 40   -- first row of tab content
local STATS_FOOTER_Y    <const> = 218  -- pinned footer baseline; keep content above this
local statsTab     = 1   -- 1 = Badges, 2 = Totals, 3 = By Difficulty
local badgeScroll  = 0   -- top-of-window index for the badges list

local function fmtDuration(secs)
    if not secs then return "-" end
    if secs < 60 then return secs .. "s" end
    local mins = math.floor(secs / 60)
    if mins < 60 then return string.format("%dm %02ds", mins, secs % 60) end
    return string.format("%dh %02dm", math.floor(mins / 60), mins % 60)
end

local function drawStatsHeader()
    local sw = playdate.display.getWidth()
    gfx.setFont(Fonts.h1)
    gfx.drawText("Career", 20, 8)

    -- Tab strip on the right.
    gfx.setFont(Fonts.h2)
    local f = Fonts.h2
    local x = sw - 10
    for i = #STATS_TABS, 1, -1 do
        local label = STATS_TABS[i]
        local w = f:getTextWidth(label)
        x = x - w
        if i == statsTab then
            gfx.fillRect(x - 4, 10, w + 8, f:getHeight() + 6)
            gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
            gfx.drawText(label, x, 13)
            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        else
            gfx.drawText(label, x, 13)
        end
        x = x - 12
    end
    gfx.setFont(Fonts.body)
    gfx.drawLine(20, 34, sw - 20, 34)
end


-- Win/Loss/Draw/Best grid. Fixed columns so nothing flows off the right.
local function drawDifficultyTab()
    local difficulties_ <const> = { "easy", "medium", "hard", "expert" }
    local f = Fonts.body
    local lineH = f:getHeight() + 8
    local nameX, wX, lX, dX, bestX, strkX = 30, 140, 180, 220, 265, 330

    -- Header row (bold).
    gfx.setFont(Fonts.h2)
    local hy = STATS_CONTENT_TOP
    gfx.drawText("W",      wX,    hy)
    gfx.drawText("L",      lX,    hy)
    gfx.drawText("D",      dX,    hy)
    gfx.drawText("Best",   bestX, hy)
    gfx.drawText("Streak", strkX, hy)
    gfx.setFont(f)

    local y = hy + lineH
    for _, key in ipairs(difficulties_) do
        local d = Stats.data.byDifficulty[key]
        local title = key:sub(1, 1):upper() .. key:sub(2)
        gfx.drawText(title,            nameX, y)
        gfx.drawText(tostring(d.wins),   wX,  y)
        gfx.drawText(tostring(d.losses), lX,  y)
        gfx.drawText(tostring(d.draws),  dX,  y)
        gfx.drawText(d.wins > 0 and ("+" .. d.bestWin) or "-", bestX, y)
        gfx.drawText(tostring(d.bestStreak), strkX, y)
        y = y + lineH
    end
end

-- Word-wrap `str` into a list of lines that each render within `maxW` px.
-- A single word longer than maxW is left intact (won't infinite-loop).
local function wrapText(f, str, maxW)
    local lines, line = {}, ""
    for word in str:gmatch("%S+") do
        local trial = (line == "") and word or (line .. " " .. word)
        if f:getTextWidth(trial) <= maxW or line == "" then
            line = trial
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- A small checkbox bullet: outlined when locked, filled with a tick when
-- earned. Anchors the eye far better than "???".
local function drawCheckbox(x, y, s, checked)
    gfx.setColor(gfx.kColorBlack)
    if checked then
        gfx.fillRect(x, y, s, s)
        gfx.setColor(gfx.kColorWhite)
        gfx.setLineWidth(2)
        gfx.drawLine(x + 3, y + s // 2, x + s // 2 - 1, y + s - 4)
        gfx.drawLine(x + s // 2 - 1, y + s - 4, x + s - 3, y + 3)
        gfx.setLineWidth(1)
        gfx.setColor(gfx.kColorBlack)
    else
        gfx.drawRect(x, y, s, s)
    end
end

local function drawBadgesTab()
    local f = Fonts.body
    local lineH = f:getHeight() + 2
    local total = #Stats.allBadges
    local sw = playdate.display.getWidth()
    local BOX = 14
    local x0    = 30                          -- checkbox x
    local xText = x0 + BOX + 10               -- text x (first + continuation)
    local maxW  = sw - xText - 20
    local contW = maxW
    local bottomLimit = STATS_FOOTER_Y - 6    -- keep blocks clear of the footer

    -- Clamp scroll. maxScroll = total-1 guarantees the last badge is always
    -- reachable (it can scroll up to being the sole top entry).
    if badgeScroll < 0 then badgeScroll = 0 end
    local maxScroll = math.max(0, total - 1)
    if badgeScroll > maxScroll then badgeScroll = maxScroll end

    local y = STATS_CONTENT_TOP
    local idx, shown = badgeScroll, 0
    while true do
        idx = idx + 1
        local b = Stats.allBadges[idx]
        if not b then break end

        local earned = Stats.data.badges[b.id]
        -- The checkbox conveys locked/earned; the goal text is the same
        -- either way (bold when earned for a touch of emphasis).
        local head = b.goal

        local lines = wrapText(f, head, contW)
        local blockH = #lines * lineH

        -- Stop before a block would collide with the footer (but always
        -- show at least one badge so a tall entry can't blank the page).
        if shown > 0 and (y + blockH) > bottomLimit then break end

        drawCheckbox(x0, y + 1, BOX, earned)

        -- Consistent body weight for every goal; the checkbox alone conveys
        -- earned vs. locked.
        for _, ln in ipairs(lines) do
            gfx.drawText(ln, xText, y)
            y = y + lineH
        end
        y = y + 6                              -- gap between badges
        shown = shown + 1
        if y > bottomLimit then break end
    end

    if shown < total then
        local first = badgeScroll + 1
        local last  = badgeScroll + shown
        local label = string.format("%d-%d of %d", first, last, total)
        gfx.drawText(label, sw - 20 - f:getTextWidth(label), STATS_FOOTER_Y)
    end
end

-- Totals rendered as a short prose summary (singular/plural aware) rather
-- than a key/value table — easier to read at a glance.
local function drawTotalsTab()
    local t = Stats.data.totals

    local function plural(count, singular, pluralForm)
        if count == 1 then return "1 " .. singular end
        return count .. " " .. pluralForm
    end

    local games = t.gamesPlayed
    local pvc   = t.gamesPvcP1 + t.gamesPvcP2

    local s1 = "You've played " .. plural(games, "game", "games") .. "."

    local s2
    if t.gamesPvp == 0 then
        s2 = "All against the CPU."
    elseif pvc == 0 then
        s2 = "All two-player."
    else
        s2 = pvc .. " of those were vs the CPU and "
            .. plural(t.gamesPvp, "was two-player", "were two-player") .. "."
    end

    local s3 = "You've claimed " .. plural(t.boxesClaimed, "box", "boxes")
        .. " and conceded " .. t.boxesAgainst .. "."
    local s4 = "Your longest single-turn chain is " .. t.longestChain .. "."
    local s5 = "Total time played: " .. fmtDuration(t.secondsPlayed) .. "."

    local paragraph = table.concat({ s1, s2, s3, s4, s5 }, "  ")
    local f = Fonts.body
    local sw = playdate.display.getWidth()
    local lineH = f:getHeight() + 4
    local lines = wrapText(f, paragraph, sw - 60)
    -- Breathing room below the header bar; the paragraph is short so this
    -- also evens out the (otherwise large) empty space below it.
    local y = STATS_CONTENT_TOP + 22
    for _, ln in ipairs(lines) do
        gfx.drawText(ln, 30, y)
        y = y + lineH
    end
end

local function drawStats()
    gfx.setColor(gfx.kColorBlack)
    drawStatsHeader()

    if statsTab == 1 then
        drawBadgesTab()
    elseif Stats.data.totals.gamesPlayed == 0 then
        local msg = "No finished games yet - go play one!"
        local f = Fonts.body
        local sw = playdate.display.getWidth()
        gfx.drawText(msg, math.floor((sw - f:getTextWidth(msg)) / 2), 110)
    elseif statsTab == 2 then
        drawDifficultyTab()   -- "Record"
    else
        drawTotalsTab()       -- "Summary"
    end

    gfx.drawText("< > tabs   B back", 20, STATS_FOOTER_Y)
end

local function handleStatsInput()
    if playdate.buttonJustPressed(playdate.kButtonB) then
        returnToMainMenu()
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonLeft) then
        statsTab = (statsTab == 1) and #STATS_TABS or (statsTab - 1)
        badgeScroll = 0
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonRight) then
        statsTab = (statsTab % #STATS_TABS) + 1
        badgeScroll = 0
        return
    end
    if statsTab == 1 then
        if playdate.buttonJustPressed(playdate.kButtonDown) then badgeScroll = badgeScroll + 1 end
        if playdate.buttonJustPressed(playdate.kButtonUp)   then badgeScroll = badgeScroll - 1 end
    end
end

-- ---------------------------------------------------------------------------
-- STATS RESET CONFIRM ------------------------------------------------------
-- ---------------------------------------------------------------------------
local function drawStatsResetConfirm()
    local lines = {
        "Reset all stats and badges?",
        "This cannot be undone.",
        "",
        "A = Reset    B = Cancel",
    }
    local f = Fonts.body
    local lineH = f:getHeight() + 6
    local sw, sh = playdate.display.getSize()
    local totalH = #lines * lineH
    local panelW = 0
    for _, l in ipairs(lines) do
        local w = f:getTextWidth(l)
        if w > panelW then panelW = w end
    end
    panelW = panelW + 40
    local panelH = totalH + 20
    local px = math.floor((sw - panelW) / 2)
    local py = math.floor((sh - panelH) / 2)

    gfx.setColor(gfx.kColorWhite); gfx.fillRect(px, py, panelW, panelH)
    gfx.setColor(gfx.kColorBlack); gfx.drawRect(px, py, panelW, panelH)
    for i, l in ipairs(lines) do
        local w = f:getTextWidth(l)
        gfx.drawText(l, math.floor((sw - w) / 2), py + 10 + (i - 1) * lineH)
    end
end

local function handleStatsResetConfirmInput()
    if playdate.buttonJustPressed(playdate.kButtonA) then
        Stats.reset()
        appState = "settings"
        settingsCursor = SETTINGS_ROW_RESET
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        appState = "settings"
        settingsCursor = SETTINGS_ROW_RESET
    end
end

-- ---------------------------------------------------------------------------
-- HOME MENU ----------------------------------------------------------------
-- ---------------------------------------------------------------------------
local drawChunkyChar = UI.Characters.drawChunkyChar
local TITLE_SCALE <const> = 7   -- chunky pixel scale for the title

local function drawChunkyTitle(text, cy)
    local sw = playdate.display.getWidth()
    local charW = 3 * TITLE_SCALE
    local gap   = TITLE_SCALE
    local totalW = #text * (charW + gap) - gap
    local x = math.floor((sw - totalW) / 2)
    local y = math.floor(cy - (5 * TITLE_SCALE) / 2)
    for i = 1, #text do
        drawChunkyChar(text:sub(i, i), x + (i - 1) * (charW + gap), y, TITLE_SCALE)
    end
end

-- Menu icons --------------------------------------------------------------
-- All icons are drawn centered around (cx, cy) inside a ~24x24 area.
local function drawIconOnePlayer(cx, cy)
    -- A single dot with an edge stub: implies "you, drawing a line"
    gfx.fillCircleAtPoint(cx - 6, cy, 4)
    gfx.fillRect(cx - 2, cy - 2, 10, 4)
    gfx.fillCircleAtPoint(cx + 8, cy, 2)
end

local function drawIconTwoPlayer(cx, cy)
    -- Two dots connected by an edge
    gfx.fillCircleAtPoint(cx - 8, cy, 4)
    gfx.fillCircleAtPoint(cx + 8, cy, 4)
    gfx.fillRect(cx - 6, cy - 2, 12, 4)
end

local function drawIconBadges(cx, cy)
    -- 5-pointed star
    local pts = {}
    local outer, inner = 9, 4
    for i = 0, 9 do
        local angle = -math.pi / 2 + i * (math.pi / 5)
        local r = (i % 2 == 0) and outer or inner
        pts[#pts + 1] = cx + r * math.cos(angle)
        pts[#pts + 1] = cy + r * math.sin(angle)
    end
    gfx.fillPolygon(table.unpack(pts))
end

local function drawIconSettings(cx, cy)
    -- Three slider rows (line + knob)
    for i = -1, 1 do
        local y = cy + i * 5
        gfx.fillRect(cx - 9, y - 1, 18, 2)
        gfx.fillCircleAtPoint(cx + (i * 4) + 0, y, 3)
    end
end

local MENU_ICONS <const> = {
    drawIconOnePlayer,
    drawIconTwoPlayer,
    drawIconBadges,
    drawIconSettings,
}

-- Count earned badges across the current Stats table.
local function countEarnedBadges()
    local n = 0
    for _ in pairs(Stats.data.badges) do n = n + 1 end
    return n
end

-- Pretty label for currently-saved difficulty.
local function diffPretty()
    return settings.difficulty:sub(1, 1):upper() .. settings.difficulty:sub(2)
end

-- Draws `text` centered using whatever font is currently set on gfx.
local function drawCenteredText(text, y)
    local sw = playdate.display.getWidth()
    local w = (gfx.getFont() or gfx.getSystemFont()):getTextWidth(text)
    gfx.drawText(text, math.floor((sw - w) / 2), y)
end

local function drawContextLine(option, y)
    local text
    if option == 1 then
        text = "vs " .. diffPretty() .. "   " .. settings.numDots .. "x" .. settings.numDots .. " board"
    elseif option == 2 then
        text = settings.numDots .. "x" .. settings.numDots .. " board"
    elseif option == 3 then
        text = countEarnedBadges() .. " of " .. #Stats.allBadges .. " goals"
    else
        text = "board size, difficulty, first player"
    end
    drawCenteredText(text, y)
end

local function drawStatsRibbon(y)
    local t = Stats.data.totals
    if t.gamesPlayed == 0 then return end   -- on a fresh install: nothing to brag about
    local parts = {
        t.gamesPlayed   .. " games",
        t.boxesClaimed  .. " boxes",
        countEarnedBadges() .. "/" .. #Stats.allBadges .. " goals",
    }
    if t.longestChain > 0 then
        parts[#parts + 1] = "best chain " .. t.longestChain
    end
    drawCenteredText(table.concat(parts, "  -  "), y)
end

-- Aliases into the central type hierarchy (see fonts.lua).
local smallFont = Fonts.caption   -- context line + stats ribbon
local labelFont = Fonts.h1        -- menu labels

-- 2x2 menu grid:
--   col 0          col 1
--   1: 1 Player    3: Badges
--   2: 2 Player    4: Settings
local function optionToGrid(opt)
    if opt == 1 then return 0, 0 end
    if opt == 2 then return 0, 1 end
    if opt == 3 then return 1, 0 end
    return 1, 1
end
local function gridToOption(col, row)
    if col == 0 and row == 0 then return 1 end
    if col == 0 and row == 1 then return 2 end
    if col == 1 and row == 0 then return 3 end
    return 4
end

local MENU_ROW_Y      <const> = { 92, 138 }     -- y-positions for the two rows
local MENU_COL_ICON_X <const> = { 50, 230 }     -- icon x per column
local MENU_COL_LBL_X  <const> = { 78, 258 }     -- label x per column

local function drawMenu()
    local sw = playdate.display.getWidth()
    gfx.setColor(gfx.kColorBlack)

    -- 1. Chunky title with caption-weight tagline
    drawChunkyTitle("DOTS", 30)
    do
        gfx.setFont(Fonts.caption)
        local f = Fonts.caption
        local sub = "and boxes"
        local w = f:getTextWidth(sub)
        gfx.drawText(sub, math.floor((sw - w) / 2), 56)
        gfx.setFont(Fonts.body)
    end

    -- 2. Menu items, drawn in a 2x2 grid using the larger label font
    gfx.setFont(labelFont)
    local fh = labelFont:getHeight()
    for i, label in ipairs(menuOptions) do
        local col, row = optionToGrid(i)
        local x = MENU_COL_LBL_X[col + 1]
        local y = MENU_ROW_Y[row + 1]
        local iconFn = MENU_ICONS[i]
        if iconFn then iconFn(MENU_COL_ICON_X[col + 1], y + fh / 2) end
        gfx.drawText(label, x, y)
    end

    -- 3. Selection rect
    do
        local col, row = optionToGrid(selectedOption)
        local y = MENU_ROW_Y[row + 1]
        local label = menuOptions[selectedOption]
        local w = labelFont:getTextWidth(label)
        local padX, padY = 8, 4
        local left   = MENU_COL_ICON_X[col + 1] - 14 - padX
        local top    = y - padY
        local right  = MENU_COL_LBL_X[col + 1] + w + padX
        local bottom = y + fh + padY
        gfx.setDitherPattern(0.5); gfx.setLineWidth(3)
        gfx.drawRect(left, top, right - left, bottom - top)
        gfx.setDitherPattern(0); gfx.setLineWidth(1)
    end

    -- 4. Context line (smaller font) below the menu
    gfx.setFont(smallFont)
    drawContextLine(selectedOption, 185)
    -- 5. Stats ribbon (smaller font)
    drawStatsRibbon(220)
    gfx.setFont(Fonts.body)
end

-- Move the menu cursor based on a d-pad press.
local function moveMenuCursor(dx, dy)
    local col, row = optionToGrid(selectedOption)
    col = (col + dx) % 2
    row = (row + dy) % 2
    selectedOption = gridToOption(col, row)
end

-- ---------------------------------------------------------------------------
-- Main update loop ---------------------------------------------------------
-- ---------------------------------------------------------------------------
function playdate.update()
    gfx.clear()

    if appState == "menu" then
        drawMenu()

        if     playdate.buttonJustPressed(playdate.kButtonDown)  then moveMenuCursor(0,  1)
        elseif playdate.buttonJustPressed(playdate.kButtonUp)    then moveMenuCursor(0, -1)
        elseif playdate.buttonJustPressed(playdate.kButtonLeft)  then moveMenuCursor(-1, 0)
        elseif playdate.buttonJustPressed(playdate.kButtonRight) then moveMenuCursor( 1, 0)
        elseif playdate.buttonJustPressed(playdate.kButtonA) then
            if     selectedOption == 1 then initGame("pvc")
            elseif selectedOption == 2 then initGame("pvp")
            elseif selectedOption == 3 then appState = "stats"; statsTab = 1; badgeScroll = 0
            else   appState = "settings"; settingsCursor = 1
            end
        end

    elseif appState == "settings" then
        drawSettings()
        handleSettingsInput()

    elseif appState == "stats" then
        drawStats()
        handleStatsInput()

    elseif appState == "statsResetConfirm" then
        -- Re-draw the settings underneath so the confirm modal floats above it.
        drawSettings()
        drawStatsResetConfirm()
        handleStatsResetConfirmInput()

    else  -- =========== GAMEPLAY =============
        local turnOwner = ui.board.currentPlayer

        -- Allow human input only on actual human turns. If the AI's coroutine
        -- is mid-search, currentPlayer can be transiently flipped to 1 -- we
        -- must NOT treat that as a human turn, or the player can take an
        -- extra move that corrupts the search.
        local humanCanAct = ui.board:isGameOver()
            or ui.mode == "pvp"
            or (ui.mode == "pvc" and turnOwner == 1 and not Ai.isThinking())

        if humanCanAct then
            ui:handleInput()
        end

        -- handleInput may have torn down the game (B -> main menu), which
        -- nils `ui` and flips appState. Bail before touching ui again.
        if ui then
            recordIfFinished()
            ui:draw()
            tickAI()
        end
    end

    -- always process timers & sprites
    playdate.timer.updateTimers()
    gfx.sprite.update()
end
