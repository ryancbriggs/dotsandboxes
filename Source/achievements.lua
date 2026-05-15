-- achievements.lua – dependency-free Playdate Achievements (pd-achievements)
-- exporter. We do NOT vendor the reference library; instead we ship a static
-- template (Source/achievements.json) that already conforms to the v1.0.0
-- schema, fill in the runtime-only fields (grantedAt, progress) from the
-- persistent Stats data, and write the result to the cross-game /Shared
-- location so viewers like Trophy Case can read it.
--
-- Schema/badge/bundle alignment is enforced at BUILD time by
-- tests/achievements_test.py (a hard Makefile gate, same as the C parity
-- gate), so this runtime code can stay minimal and trusting.

local Achievements = {}

local GAME_ID    <const> = "com.ryan.dotsandboxes"
local SHARED_DIR <const> = "/Shared/Achievements/" .. GAME_ID
local OUT_PATH   <const> = SHARED_DIR .. "/Achievements.json"
local TEMPLATE   <const> = "achievements.json"   -- bundled at the pdx root

-- Progress feeders for the eight progression achievements. Each maps the
-- persistent Stats.data table to a current progress integer. Keep the id set
-- here in lockstep with the `progressMax` entries in achievements.json — the
-- build test fails if a progressMax id is not one of these.
local DIFFS <const> = { "easy", "medium", "hard", "expert" }

local function diffsWon(s)
    local n = 0
    for _, d in ipairs(DIFFS) do
        local bd = s.byDifficulty[d]
        if bd and bd.wins >= 1 then n = n + 1 end
    end
    return n
end

local function sizesWon(s)
    local n = 0
    for d = 4, 8 do
        if s.bySize[d] and s.bySize[d].wins >= 1 then n = n + 1 end
    end
    return n
end

local function bestStreakAny(s)
    local best = 0
    for _, d in ipairs(DIFFS) do
        local bd = s.byDifficulty[d]
        if bd and bd.bestStreak > best then best = bd.bestStreak end
    end
    return best
end

local PROGRESS <const> = {
    boxes_1000    = function(s) return s.totals.boxesClaimed  end,
    games_100     = function(s) return s.totals.gamesPlayed   end,
    marathon      = function(s) return s.totals.secondsPlayed end,
    iron_will     = function(s) return s.byDifficulty.expert and s.byDifficulty.expert.bestStreak or 0 end,
    on_fire       = function(s) return s.byDifficulty.expert and s.byDifficulty.expert.bestStreak or 0 end,
    untouchable   = function(s) return bestStreakAny(s) end,
    survey_course = function(s) return sizesWon(s) end,
    tier_climber  = function(s) return diffsWon(s) end,
    spectrum      = function(s) return sizesWon(s) + diffsWon(s) end,
}

local manifest = nil   -- decoded template (lazy)

-- Preserve any grantedAt timestamps already written to /Shared so a badge's
-- unlock time stays stable across launches even though the bundled template
-- (authoritative for names/descriptions) never carries timestamps.
local function loadManifest()
    if manifest then return manifest end
    manifest = json.decodeFile(TEMPLATE)
    if not manifest then return nil end

    local prior = json.decodeFile(OUT_PATH)
    if prior and prior.achievements then
        local when = {}
        for _, a in ipairs(prior.achievements) do
            if a.grantedAt then when[a.id] = a.grantedAt end
        end
        for _, a in ipairs(manifest.achievements) do
            if when[a.id] then a.grantedAt = when[a.id] end
        end
    end
    return manifest
end

-- Mirror the persistent Stats into the achievements file and write /Shared.
-- `statsData` is Stats.data (badges = { [id] = true }, totals/byDifficulty/…).
function Achievements.sync(statsData)
    local m = loadManifest()
    if not m then return end

    local now = playdate.getSecondsSinceEpoch()   -- secs since 2000-01-01 UTC
    for _, a in ipairs(m.achievements) do
        -- Resolve grantedAt once, then leave it stable forever:
        --   • prior /Shared timestamp wins (merged in loadManifest)
        --   • else a numeric Stats mark = the real earn-time
        --   • else legacy `true` (pre-timestamp save) = unknown -> now
        if not a.grantedAt then
            local mark = statsData.badges[a.id]
            if mark then
                a.grantedAt = (type(mark) == "number") and mark or now
            end
        end
        local feeder = PROGRESS[a.id]
        if feeder then
            local p = feeder(statsData) or 0
            if p < 0 then p = 0 end
            if a.progressMax and p > a.progressMax then p = a.progressMax end
            a.progress = p
        end
    end

    playdate.file.mkdir(SHARED_DIR)
    json.encodeToFile(OUT_PATH, true, m)
end

-- Wipe the /Shared mirror back to a pristine, nothing-earned state. Called
-- from Stats.reset so clearing your stats also clears Trophy Case (sync only
-- ever ADDS grantedAt, so a reset needs this explicit clean slate).
function Achievements.reset()
    manifest = json.decodeFile(TEMPLATE)   -- fresh: no grantedAt / progress
    if not manifest then return end
    playdate.file.mkdir(SHARED_DIR)
    json.encodeToFile(OUT_PATH, true, manifest)
end

return Achievements
