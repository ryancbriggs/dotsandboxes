-- badges.lua – Badge definitions and predicates.
-- Each badge: { id, label, hint, predicate(stats, ctx) -> bool }.
-- `stats` is the persistent Stats.data table AFTER this game has been counted;
-- `ctx` describes the just-finished game (see Stats.recordGame).

local Badges = {}

local function totals(s)  return s.totals end
local function diffs(s)   return s.byDifficulty end

local DIFFICULTIES <const> = { "easy", "medium", "hard", "expert" }

-- 42.195 km marathon → 42.195 minutes of play.
local MARATHON_SECS <const> = math.floor(42.195 * 60)

Badges.list = {
    -- ── Long-haul anchors (the only two grind badges) ─────────────────────
    { id = "boxes_1000", label = "Thousand Strong", hint = "claim a truly absurd number of boxes",
      predicate = function(s, ctx) return totals(s).boxesClaimed >= 1000 end },
    { id = "games_100",  label = "Centurion",       hint = "play a hundred games",
      predicate = function(s, ctx) return totals(s).gamesPlayed >= 100 end },
    { id = "marathon",   label = "Marathon",        hint = "log 42.195 minutes of play",
      predicate = function(s, ctx) return totals(s).secondsPlayed >= MARATHON_SECS end },

    -- ── Beat each difficulty at least once ────────────────────────────────
    { id = "beat_easy",   label = "Eased In",   hint = "win on the easiest setting",
      predicate = function(s, ctx) return diffs(s).easy.wins   >= 1 end },
    { id = "beat_medium", label = "Solid",      hint = "win on medium",
      predicate = function(s, ctx) return diffs(s).medium.wins >= 1 end },
    { id = "beat_hard",   label = "Crafty",     hint = "win on hard",
      predicate = function(s, ctx) return diffs(s).hard.wins   >= 1 end },
    { id = "beat_expert", label = "Conqueror",  hint = "win on expert",
      predicate = function(s, ctx) return diffs(s).expert.wins >= 1 end },

    -- ── Quality of win ────────────────────────────────────────────────────
    { id = "landslide", label = "Landslide", hint = "trounce a strong opponent",
      predicate = function(s, ctx)
          return ctx.humanWon
             and (ctx.difficulty == "hard" or ctx.difficulty == "expert")
             and ctx.margin >= 8
      end },
    { id = "underdog", label = "Underdog", hint = "go second and still win",
      predicate = function(s, ctx)
          return ctx.humanWon
             and ctx.mode == "pvc"
             and ctx.startingPlayer == 2
             and (ctx.difficulty == "hard" or ctx.difficulty == "expert")
      end },
    { id = "speed_run", label = "Speed Run", hint = "win a 5x5+ board in under a minute",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.durationSecs < 60 and ctx.boardSize >= 5
      end },
    { id = "perfect_loop", label = "Perfect Loop", hint = "claim a long chain in one turn",
      predicate = function(s, ctx)
          return ctx.longestHumanChain >= 8
      end },

    -- ── Skill / outcome (no extra tracking) ───────────────────────────────
    { id = "shutout", label = "Shutout", hint = "win without conceding a single box",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.aiScore == 0
      end },
    { id = "perfectionist", label = "Perfectionist", hint = "shut out Expert",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.aiScore == 0 and ctx.difficulty == "expert"
      end },
    { id = "double_up", label = "Double Up", hint = "win with at least twice the score",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.humanScore >= 2 * ctx.aiScore
      end },
    { id = "the_long_game", label = "The Long Game", hint = "claim a chain of 12 in one turn",
      predicate = function(s, ctx)
          return ctx.longestHumanChain >= 12
      end },
    { id = "from_the_brink", label = "From the Brink", hint = "win by a single box vs Hard/Expert",
      predicate = function(s, ctx)
          return ctx.humanWon
             and ctx.margin == 1
             and (ctx.difficulty == "hard" or ctx.difficulty == "expert")
      end },
    { id = "giant_slayer", label = "Giant Slayer", hint = "beat Expert on the 8x8 board",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.difficulty == "expert" and ctx.boardSize == 8
      end },
    { id = "big_board", label = "Big Board Brawler", hint = "win a game on the 8x8 board",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.boardSize == 8
      end },
    { id = "vengeance", label = "Vengeance", hint = "beat Expert after it has crushed you",
      predicate = function(s, ctx)
          return ctx.humanWon
             and ctx.difficulty == "expert"
             and diffs(s).expert.worstLoss >= 10
      end },
    { id = "draw_artist", label = "Draw Artist", hint = "finish a game in a perfect tie",
      predicate = function(s, ctx)
          return ctx.margin == 0
      end },
    { id = "boxed_in", label = "Boxed In", hint = "lose without claiming a single box",
      predicate = function(s, ctx)
          return (not ctx.humanWon) and ctx.humanScore == 0
      end },

    -- ── Streaks ───────────────────────────────────────────────────────────
    { id = "on_fire", label = "On Fire", hint = "win 5 Expert games in a row",
      predicate = function(s, ctx)
          return diffs(s).expert.bestStreak >= 5
      end },
    { id = "untouchable", label = "Untouchable", hint = "a 10-win streak on any difficulty",
      predicate = function(s, ctx)
          for _, d in ipairs(DIFFICULTIES) do
              if diffs(s)[d].bestStreak >= 10 then return true end
          end
          return false
      end },

    -- ── Collection capstones ──────────────────────────────────────────────
    { id = "survey_course", label = "Survey Course", hint = "win on every board size",
      predicate = function(s, ctx)
          for d = 4, 8 do
              if not s.bySize[d] or s.bySize[d].wins < 1 then return false end
          end
          return true
      end },
    { id = "tier_climber", label = "Tier Climber", hint = "win on every difficulty",
      predicate = function(s, ctx)
          for _, d in ipairs(DIFFICULTIES) do
              if diffs(s)[d].wins < 1 then return false end
          end
          return true
      end },
    { id = "spectrum", label = "Spectrum", hint = "win on every size AND every difficulty",
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
