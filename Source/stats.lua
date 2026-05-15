-- stats.lua – Persistent per-player stats and badge tracking.
-- Stored via playdate.datastore under the key "stats". Versioned so future
-- schema changes can migrate forward without nuking saves.

local Badges = import "badges"

local Stats = {}
Stats.allBadges = Badges.list   -- exposed so callers don't need to re-import "badges"

local CURRENT_VERSION <const> = 1
local DIFFICULTIES    <const> = { "easy", "medium", "hard", "expert" }
local MIN_DOTS        <const> = 4
local MAX_DOTS        <const> = 8

local function defaults()
    local data = {
        version = CURRENT_VERSION,
        totals = {
            gamesPlayed   = 0,
            gamesPvp      = 0,
            gamesPvcP1    = 0,    -- human went first
            gamesPvcP2    = 0,    -- AI went first
            boxesClaimed  = 0,    -- human-side, PvC only
            boxesAgainst  = 0,    -- conceded to AI, PvC only
            longestChain  = 0,    -- best single-turn chain across all games (either side)
            secondsPlayed = 0,    -- total seconds across finished games
        },
        byDifficulty = {},
        bySize = {},
        badges = {},
    }
    for _, d in ipairs(DIFFICULTIES) do
        data.byDifficulty[d] = {
            games          = 0,
            wins           = 0,
            losses         = 0,
            draws          = 0,
            bestWin        = 0,    -- biggest positive margin in a win
            worstLoss      = 0,    -- biggest margin lost by (stored positive)
            fastestWinSecs = nil,
            currentStreak  = 0,    -- positive = win streak, negative = loss streak
            bestStreak     = 0,    -- best win streak
            boxes          = 0,    -- total boxes claimed by human at this difficulty
        }
    end
    for d = MIN_DOTS, MAX_DOTS do
        data.bySize[d] = { games = 0, wins = 0 }
    end
    return data
end

-- Best-effort merge of a saved table into the current default shape. Missing
-- fields fall back to defaults; unknown fields are dropped.
local function migrate(raw)
    local def = defaults()
    if type(raw) ~= "table" then return def end
    if raw.version == CURRENT_VERSION then return raw end

    for k, v in pairs(raw.totals or {}) do
        if def.totals[k] ~= nil then def.totals[k] = v end
    end
    for d, t in pairs(raw.byDifficulty or {}) do
        if def.byDifficulty[d] then
            for k, v in pairs(t) do
                if def.byDifficulty[d][k] ~= nil or k == "fastestWinSecs" then
                    def.byDifficulty[d][k] = v
                end
            end
        end
    end
    for sz, t in pairs(raw.bySize or {}) do
        local n = tonumber(sz)
        if n and def.bySize[n] then
            for k, v in pairs(t) do def.bySize[n][k] = v end
        end
    end
    for id, v in pairs(raw.badges or {}) do
        if Badges.byId[id] then def.badges[id] = v end
    end
    return def
end

function Stats.load()
    Stats.data = migrate(playdate.datastore.read("stats"))
end

function Stats.save()
    playdate.datastore.write(Stats.data, "stats")
end

function Stats.reset()
    Stats.data = defaults()
    Stats.save()
end

-- Record a finished game and evaluate badge unlocks.
--   board: a Board with endMs set (game over)
--   opts:  { mode = "pvc"|"pvp", difficulty = "easy"|... (pvc only), startingPlayer = 1|2 }
-- Returns a list of newly-earned badge definitions (possibly empty).
function Stats.recordGame(board, opts)
    if not board or not board.endMs or board.recorded then return {} end
    board.recorded = true

    local mode      = opts.mode
    local diffKey   = opts.difficulty
    local startingP = opts.startingPlayer or 1

    local p1, p2 = board.score[1], board.score[2]
    local humanScore, aiScore = p1, p2   -- in PvC, P1 is the human
    local margin = humanScore - aiScore
    local humanWon
    if mode == "pvc" then
        if     margin > 0 then humanWon = true
        elseif margin < 0 then humanWon = false
        else                   humanWon = nil end
    end

    local durationSecs = math.max(0, math.floor((board.endMs - board.startMs) / 1000))
    -- Only count chains made by a *human*: P1 in PvC, either side in PvP.
    local humanChain
    if mode == "pvc" then
        humanChain = board.longestChain[1] or 0
    else
        humanChain = math.max(board.longestChain[1] or 0, board.longestChain[2] or 0)
    end

    -- Totals -------------------------------------------------------------
    local t = Stats.data.totals
    t.gamesPlayed   = t.gamesPlayed + 1
    t.secondsPlayed = t.secondsPlayed + durationSecs
    if humanChain > t.longestChain then t.longestChain = humanChain end

    if mode == "pvp" then
        t.gamesPvp = t.gamesPvp + 1
    else
        if startingP == 1 then t.gamesPvcP1 = t.gamesPvcP1 + 1
        else                   t.gamesPvcP2 = t.gamesPvcP2 + 1 end
        t.boxesClaimed = t.boxesClaimed + humanScore
        t.boxesAgainst = t.boxesAgainst + aiScore
    end

    -- By board size ------------------------------------------------------
    local sz = Stats.data.bySize[board.DOTS]
    if sz then
        sz.games = sz.games + 1
        if humanWon == true then sz.wins = sz.wins + 1 end
    end

    -- By difficulty (PvC only) ------------------------------------------
    if mode == "pvc" and diffKey then
        local d = Stats.data.byDifficulty[diffKey]
        if d then
            d.games = d.games + 1
            d.boxes = d.boxes + humanScore
            if humanWon == true then
                d.wins = d.wins + 1
                if margin > d.bestWin then d.bestWin = margin end
                if d.fastestWinSecs == nil or durationSecs < d.fastestWinSecs then
                    d.fastestWinSecs = durationSecs
                end
                d.currentStreak = (d.currentStreak >= 0) and (d.currentStreak + 1) or 1
                if d.currentStreak > d.bestStreak then d.bestStreak = d.currentStreak end
            elseif humanWon == false then
                d.losses = d.losses + 1
                local loss = -margin
                if loss > d.worstLoss then d.worstLoss = loss end
                d.currentStreak = (d.currentStreak <= 0) and (d.currentStreak - 1) or -1
            else
                d.draws = d.draws + 1
                d.currentStreak = 0
            end
        end
    end

    -- Spatial context for geometric badges: the set of boxIds owned by the
    -- human-scored side (P1 — consistent with humanScore above). recordGame
    -- only fires on a finished board, so every box has an owner.
    local humanBoxes = {}
    for boxId, owner in pairs(board.boxOwner) do
        if owner == 1 then humanBoxes[boxId] = true end
    end

    -- Build badge context -----------------------------------------------
    local ctx = {
        mode              = mode,
        difficulty        = diffKey,
        startingPlayer    = startingP,
        boardSize         = board.DOTS,
        humanScore        = humanScore,
        aiScore           = aiScore,
        humanWon          = humanWon == true,
        margin            = margin,
        durationSecs      = durationSecs,
        longestHumanChain = humanChain,
        humanBoxes        = humanBoxes,
    }

    -- Evaluate badges (only those not yet earned) ------------------------
    local newlyEarned = {}
    for _, b in ipairs(Badges.list) do
        if not Stats.data.badges[b.id] then
            local ok, earned = pcall(b.predicate, Stats.data, ctx)
            if ok and earned then
                Stats.data.badges[b.id] = true
                newlyEarned[#newlyEarned + 1] = b
            end
        end
    end

    Stats.save()
    return newlyEarned
end

return Stats
