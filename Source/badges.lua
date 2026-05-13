-- badges.lua – Badge definitions and predicates.
-- Each badge: { id, label, hint, predicate(stats, ctx) -> bool }.
-- `stats` is the persistent Stats.data table AFTER this game has been counted;
-- `ctx` describes the just-finished game (see Stats.recordGame).

local Badges = {}

local function totals(s)  return s.totals end
local function diffs(s)   return s.byDifficulty end

Badges.list = {
    -- ── Quantity milestones ────────────────────────────────────────────────
    { id = "boxes_100",  label = "First Hundred",   hint = "claim a lot of boxes",
      predicate = function(s, ctx) return totals(s).boxesClaimed >= 100 end },
    { id = "boxes_500",  label = "Five Hundred",    hint = "claim a whole lot more boxes",
      predicate = function(s, ctx) return totals(s).boxesClaimed >= 500 end },
    { id = "boxes_1000", label = "Thousand Strong", hint = "claim a truly absurd number of boxes",
      predicate = function(s, ctx) return totals(s).boxesClaimed >= 1000 end },

    { id = "games_10",  label = "Warming Up",  hint = "play a handful of games",
      predicate = function(s, ctx) return totals(s).gamesPlayed >= 10 end },
    { id = "games_50",  label = "Regular",     hint = "keep coming back",
      predicate = function(s, ctx) return totals(s).gamesPlayed >= 50 end },
    { id = "games_100", label = "Centurion",   hint = "play a hundred games",
      predicate = function(s, ctx) return totals(s).gamesPlayed >= 100 end },

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
    { id = "speed_run", label = "Speed Run", hint = "win in less than a minute",
      predicate = function(s, ctx)
          return ctx.humanWon and ctx.durationSecs < 60
      end },
    { id = "perfect_loop", label = "Perfect Loop", hint = "claim a long chain in one turn",
      predicate = function(s, ctx)
          return ctx.longestHumanChain >= 8
      end },
    { id = "survey_course", label = "Survey Course", hint = "win on every board size",
      predicate = function(s, ctx)
          for d = 3, 8 do
              if not s.bySize[d] or s.bySize[d].wins < 1 then return false end
          end
          return true
      end },
    { id = "tier_climber", label = "Tier Climber", hint = "win on every difficulty",
      predicate = function(s, ctx)
          return diffs(s).easy.wins   >= 1
             and diffs(s).medium.wins >= 1
             and diffs(s).hard.wins   >= 1
             and diffs(s).expert.wins >= 1
      end },
}

Badges.byId = {}
for _, b in ipairs(Badges.list) do
    Badges.byId[b.id] = b
end

return Badges
