-- badges.lua – Goal definitions and predicates.
-- Each goal: { id, goal, predicate(stats, ctx) -> bool }.
--   `goal`  is a clear, self-contained instruction shown on the Goals tab.
--   `stats` is the persistent Stats.data table AFTER this game is counted.
--   `ctx`   describes the just-finished game (see Stats.recordGame).

local Geometry = import "geometry"

local Badges = {}

local function totals(s)  return s.totals end
local function diffs(s)   return s.byDifficulty end

-- Geometric goals must be earned against a real opponent: PvC, and not
-- Easy (Easy blunders 30% of moves, so you can bait it into handing you
-- whatever shape you want — that defeats the point of a geometric feat).
local function geoQualifies(ctx)
    return ctx.humanWon and ctx.mode == "pvc" and ctx.difficulty ~= "easy"
end

local DIFFICULTIES <const> = { "easy", "medium", "hard", "expert" }

local HOUR_SECS <const> = 60 * 60

Badges.list = {
    -- ── Long-haul ─────────────────────────────────────────────────────────
    { id = "boxes_1000", goal = "Claim 1000 boxes in total",
      predicate = function(s, ctx) return totals(s).boxesClaimed >= 1000 end },
    { id = "games_100",  goal = "Play 100 games",
      predicate = function(s, ctx) return totals(s).gamesPlayed >= 100 end },
    { id = "marathon",   goal = "Play for over 1 hour",
      predicate = function(s, ctx) return totals(s).secondsPlayed >= HOUR_SECS end },

    -- ── Beat each difficulty ──────────────────────────────────────────────
    { id = "beat_easy",   goal = "Win a game on Easy",
      predicate = function(s, ctx) return diffs(s).easy.wins   >= 1 end },
    { id = "beat_medium", goal = "Win a game on Medium",
      predicate = function(s, ctx) return diffs(s).medium.wins >= 1 end },
    { id = "beat_hard",   goal = "Win a game on Hard",
      predicate = function(s, ctx) return diffs(s).hard.wins   >= 1 end },
    { id = "beat_expert", goal = "Win a game on Expert",
      predicate = function(s, ctx) return diffs(s).expert.wins >= 1 end },

    -- ── Quality of win ────────────────────────────────────────────────────
    { id = "landslide", goal = "Win by 8 or more boxes vs Hard or Expert",
      predicate = function(s, ctx)
          return ctx.humanWon
             and (ctx.difficulty == "hard" or ctx.difficulty == "expert")
             and ctx.margin >= 8
      end },
    { id = "underdog", goal = "Go second and beat Hard or Expert",
      predicate = function(s, ctx)
          return ctx.humanWon
             and ctx.mode == "pvc"
             and ctx.startingPlayer == 2
             and (ctx.difficulty == "hard" or ctx.difficulty == "expert")
      end },
    { id = "speed_run", goal = "Win a 5x5 or larger board in under a minute",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.durationSecs < 60 and ctx.boardSize >= 5
      end },
    { id = "endurance", goal = "Win a game lasting over 5 minutes",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.durationSecs >= 300
      end },
    { id = "perfect_loop", goal = "Claim a chain of 8 or more boxes in one turn",
      predicate = function(s, ctx)
          return ctx.longestHumanChain >= 8
      end },

    -- ── Skill / outcome ───────────────────────────────────────────────────
    { id = "shutout", goal = "Win without conceding a single box",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.aiScore == 0
      end },
    { id = "big_sweep", goal = "Claim 20 or more boxes in a single game",
      predicate = function(s, ctx)
          return ctx.humanScore >= 20
      end },
    { id = "double_up", goal = "Win with at least double the AI's score",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.humanScore >= 2 * ctx.aiScore
      end },
    { id = "the_long_game", goal = "Claim a chain of 12 or more boxes in one turn",
      predicate = function(s, ctx)
          return ctx.longestHumanChain >= 12
      end },
    { id = "from_the_brink", goal = "Win by exactly 1 box vs Hard or Expert",
      predicate = function(s, ctx)
          return ctx.humanWon
             and ctx.margin == 1
             and (ctx.difficulty == "hard" or ctx.difficulty == "expert")
      end },
    { id = "giant_slayer", goal = "Beat Expert on an 8x8 board",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.difficulty == "expert" and ctx.boardSize == 8
      end },
    { id = "big_board", goal = "Win a game on an 8x8 board",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.boardSize == 8
      end },
    { id = "vengeance", goal = "Beat Expert after losing to it by 10 or more",
      predicate = function(s, ctx)
          return ctx.humanWon
             and ctx.difficulty == "expert"
             and diffs(s).expert.worstLoss >= 10
      end },
    { id = "draw_artist", goal = "Finish a game in an exact tie",
      predicate = function(s, ctx)
          return ctx.margin == 0
      end },
    { id = "boxed_in", goal = "Lose without claiming a single box",
      predicate = function(s, ctx)
          return (not ctx.humanWon) and ctx.humanScore == 0
      end },

    -- ── Geometric ─────────────────────────────────────────────────────────
    { id = "four_corners", goal = "Win owning all four corner boxes (Medium+)",
      predicate = function(s, ctx)
          return geoQualifies(ctx)
             and Geometry.ownsAll(ctx.humanBoxes, Geometry.cornerBoxes(ctx.boardSize))
      end },
    { id = "full_stripe", goal = "Win owning a full row or column (Medium+)",
      predicate = function(s, ctx)
          return geoQualifies(ctx)
             and Geometry.hasFullStripe(ctx.humanBoxes, ctx.boardSize)
      end },

    -- ── Streaks ───────────────────────────────────────────────────────────
    { id = "iron_will", goal = "Win 3 Expert games in a row",
      predicate = function(s, ctx)
          return diffs(s).expert.bestStreak >= 3
      end },
    { id = "on_fire", goal = "Win 5 Expert games in a row",
      predicate = function(s, ctx)
          return diffs(s).expert.bestStreak >= 5
      end },
    { id = "untouchable", goal = "Win 10 games in a row on any difficulty",
      predicate = function(s, ctx)
          for _, d in ipairs(DIFFICULTIES) do
              if diffs(s)[d].bestStreak >= 10 then return true end
          end
          return false
      end },

    -- ── Collection capstones ──────────────────────────────────────────────
    { id = "survey_course", goal = "Win on every board size",
      predicate = function(s, ctx)
          for d = 4, 8 do
              if not s.bySize[d] or s.bySize[d].wins < 1 then return false end
          end
          return true
      end },
    { id = "tier_climber", goal = "Win on every difficulty",
      predicate = function(s, ctx)
          for _, d in ipairs(DIFFICULTIES) do
              if diffs(s)[d].wins < 1 then return false end
          end
          return true
      end },
    { id = "spectrum", goal = "Win on every board size and every difficulty",
      predicate = function(s, ctx)
          for d = 4, 8 do
              if not s.bySize[d] or s.bySize[d].wins < 1 then return false end
          end
          for _, d in ipairs(DIFFICULTIES) do
              if diffs(s)[d].wins < 1 then return false end
          end
          return true
      end },
}

Badges.byId = {}
for _, b in ipairs(Badges.list) do
    Badges.byId[b.id] = b
end

return Badges
