-- ai.lua
-- AI module for Dots & Boxes with four difficulty levels:
--   • easy   – 10% random blunders; otherwise greedy & random safe.
--   • medium – depth‑1 safe‑edge heuristic, randomized among top‑K.
--   • hard   – depth‑2 safe‑edge lookahead until safes deplete, then full chain/loop solver.
--   • expert – plays like hard early; upon first chain or split, switches to pocket‑aware Berlekamp Nim‑sum.

local Ai = {}
Ai.difficulty = "medium"

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. BUILDING BLOCKS: classifiers & solvers
-- ═══════════════════════════════════════════════════════════════════════════

-- Random blunder helper: returns true with probability p
local function randomChance(p) return math.random() < p end

-- Count how many edges in 'list' are already filled on the board
local function countFilled(board, list)
    local n = 0
    for _, e in ipairs(list) do
        if board.edgesFilled[e] then n = n + 1 end
    end
    return n
end

-- Shorthand for listing all free edges
local function freeEdges(board) return board:listFreeEdges() end

-- ────────────────────────────────────────────────────────────────────────────
-- Edge classifiers
-- ────────────────────────────────────────────────────────────────────────────

local function closers(board)
    local out = {}
    for _, e in ipairs(freeEdges(board)) do
        for _, b in ipairs(board.edgeBoxes[e] or {}) do
            if countFilled(board, board.boxEdges[b]) == 3 then
                table.insert(out, e)
                break
            end
        end
    end
    return out
end

local function safes(board)
    local out = {}
    for _, e in ipairs(freeEdges(board)) do
        local ok = true
        for _, b in ipairs(board.edgeBoxes[e] or {}) do
            if countFilled(board, board.boxEdges[b]) == 2 then
                ok = false; break
            end
        end
        if ok then table.insert(out, e) end
    end
    return out
end

-- Detect all 3‑sided boxes (chains/loops)
local function collectHotComponents(board)
    local comps, seen = {}, {}
    local BE, EB = board.boxEdges, board.edgeBoxes
    local function dfs(b, comp)
        seen[b] = true; comp.len = comp.len + 1
        local empty
        for _, e in ipairs(BE[b]) do
            if not board.edgesFilled[e] then empty = e; break end
        end
        if not comp.edge then comp.edge = empty end
        local adj = EB[empty] or {}
        if #adj == 2 then
            local nb = (adj[1]==b) and adj[2] or adj[1]
            if countFilled(board, BE[nb]) == 3 and not seen[nb] then
                dfs(nb, comp)
            else
                comp.ends = (comp.ends or 0) + 1
            end
        else
            comp.ends = (comp.ends or 0) + 1
        end
    end
    for i = 1, #board.boxEdges do
        if not seen[i] and countFilled(board, board.boxEdges[i]) == 3 then
            local c = { len = 0, edge = nil, ends = 0 }
            dfs(i, c)
            c.isLoop = (c.ends == 0)
            table.insert(comps, c)
        end
    end
    return comps
end

-- Detect prospective chains/loops where every box still has exactly 2 sides
-- filled. This is the configuration that appears the moment safe moves are
-- exhausted, before any chain has been opened.
local function collectColdComponents(board)
    local comps, seen = {}, {}
    local BE, EB = board.boxEdges, board.edgeBoxes

    local function dfs(b, comp)
        seen[b] = true
        comp.len = comp.len + 1
        for _, e in ipairs(BE[b]) do
            if not board.edgesFilled[e] then
                comp.firstEdge = comp.firstEdge or e
                local adj = EB[e] or {}
                local neighbor
                if #adj == 2 then
                    neighbor = (adj[1] == b) and adj[2] or adj[1]
                end

                if neighbor and countFilled(board, BE[neighbor]) == 2 then
                    if not seen[neighbor] then dfs(neighbor, comp) end
                else
                    comp.entryEdges = comp.entryEdges or {}
                    table.insert(comp.entryEdges, e)
                end
            end
        end
    end

    for i = 1, #board.boxEdges do
        if not seen[i] and countFilled(board, board.boxEdges[i]) == 2 then
            local c = { len = 0 }
            dfs(i, c)
            c.isLoop = not c.entryEdges or #c.entryEdges == 0
            if not c.isLoop then
                c.edge = c.entryEdges[1]
            else
                c.edge = c.firstEdge
            end
            table.insert(comps, c)
        end
    end
    return comps
end

-- Component bookkeeping helpers for Berlekamp endgame solver
local function copyCounts(counts)
    local out = {}
    for len, count in pairs(counts) do out[len] = count end
    return out
end

local function componentState(comps)
    local state = { chains = {}, loops = {} }
    for _, comp in ipairs(comps) do
        local bucket = comp.isLoop and state.loops or state.chains
        bucket[comp.len] = (bucket[comp.len] or 0) + 1
    end
    return state
end

local function stateKey(state)
    local chainParts, loopParts = {}, {}
    for len, count in pairs(state.chains) do
        chainParts[#chainParts + 1] = len .. ":" .. count
    end
    for len, count in pairs(state.loops) do
        loopParts[#loopParts + 1] = len .. ":" .. count
    end
    table.sort(chainParts)
    table.sort(loopParts)
    return "C" .. table.concat(chainParts, ",") .. "|L" .. table.concat(loopParts, ",")
end

local function removeComponent(state, isLoop, len)
    local nextState = {
        chains = copyCounts(state.chains),
        loops  = copyCounts(state.loops),
    }
    local bucket = isLoop and nextState.loops or nextState.chains
    local count = (bucket[len] or 0) - 1
    if count > 0 then
        bucket[len] = count
    else
        bucket[len] = nil
    end
    return nextState
end

local function solveComponents(state, memo)
    local key = stateKey(state)
    if memo[key] then return memo[key] end

    local hasChain, hasLoop = next(state.chains), next(state.loops)
    if not hasChain and not hasLoop then
        memo[key] = 0
        return 0
    end

    local best = -math.huge

    for len, count in pairs(state.chains) do
        if count > 0 then
            local nextState = removeComponent(state, false, len)
            local nextVal = solveComponents(nextState, memo)
            local worst = -len - nextVal
            if len >= 4 then
                local keep = -(len - 4) + nextVal
                if keep < worst then worst = keep end
            end
            if worst > best then best = worst end
        end
    end

    for len, count in pairs(state.loops) do
        if count > 0 then
            local nextState = removeComponent(state, true, len)
            local nextVal = solveComponents(nextState, memo)
            local worst = -len - nextVal
            if len >= 6 then
                local keep = -(len - 8) + nextVal
                if keep < worst then worst = keep end
            end
            if worst > best then best = worst end
        end
    end

    if best == -math.huge then best = 0 end
    memo[key] = best
    return best
end

-- ────────────────────────────────────────────────────────────────────────────
-- 1b) Heuristics
-- ────────────────────────────────────────────────────────────────────────────

-- Local score: border bonus + how “filled” its boxes already are
local function scoreSafeEdge(board, e)
    local adj, bonus, maxF = board.edgeBoxes[e] or {}, 0, 0
    if #adj == 1 then bonus = 3 end
    for _, b in ipairs(adj) do
        local f = countFilled(board, board.boxEdges[b])
        if f > maxF then maxF = f end
    end
    return bonus + maxF
end

-- 2‑ply safe‑edge lookahead: simulate each safe, count future hot‑components
local function bestSafeEdge(board, list)
    local bestE, bestS = list[1], -math.huge
    for _, e in ipairs(list) do
        board.edgesFilled[e] = true
        local hotCount = #collectHotComponents(board)
        board.edgesFilled[e] = nil
        local s = -hotCount + scoreSafeEdge(board, e)
        if s > bestS then bestS, bestE = s, e end
    end
    return bestE
end

-- ────────────────────────────────────────────────────────────────────────────
-- 1c) Solvers
-- ────────────────────────────────────────────────────────────────────────────

-- Negamax on chain‑lengths for perfect endgame
local function compValue(c) return c.isLoop and -1 or (4 - c.len) end
local function multisetKey(vals)
    table.sort(vals, function(a,b) return a>b end)
    return table.concat(vals, ",")
end
local function negamax(vals, cache)
    local key = multisetKey(vals)
    if cache[key] then return cache[key] end
    local best = -64
    for i, v in ipairs(vals) do
        local last = table.remove(vals)
        local s = -negamax(vals, cache) - v
        table.insert(vals, last)
        if s > best then best = s end
        if best >= 0 then break end
    end

    coroutine.yield() -- Yield periodically to avoid freezing

    cache[key] = best
    return best
end

-- Full chain/loop solver with random tie‑breaking
local function negamaxSolver(board)
    local c = closers(board)
    if #c > 0 then return c[math.random(#c)] end
    local s = safes(board)
    if #s > 0 then return s[math.random(#s)] end
    local comps = collectHotComponents(board)
    if #comps == 0 then
        comps = collectColdComponents(board)
        if #comps == 0 then
            local f = freeEdges(board)
            return f[math.random(#f)]
        end
    end
    local vals, edges = {}, {}
    for i, comp in ipairs(comps) do
        vals[i], edges[i] = compValue(comp), comp.edge
    end
    local cache, bestScore, bestIdxs = {}, -math.huge, {}
    for i = 1, #vals do
        local v = table.remove(vals, i)
        local sc = -negamax(vals, cache) - v
        table.insert(vals, i, v)
        if sc > bestScore then
            bestScore, bestIdxs = sc, { i }
        elseif sc == bestScore then
            table.insert(bestIdxs, i)
        end
    end

    coroutine.yield() -- Yield periodically to avoid freezing

    local idx = bestIdxs[math.random(#bestIdxs)]
    return edges[idx]
end

-- Perfect Berlekamp endgame solver with dynamic programming tie-breaking
local function berlekampSolver(board)
    local comps = collectHotComponents(board)
    if #comps == 0 then
        comps = collectColdComponents(board)
        if #comps == 0 then
            local f = freeEdges(board)
            return f[math.random(#f)]
        end
    end

    local state = componentState(comps)
    local memo = {}
    local bestScore, best = -math.huge, {}

    for _, comp in ipairs(comps) do
        local nextState = removeComponent(state, comp.isLoop, comp.len)
        local nextVal = solveComponents(nextState, memo)
        local worst = -comp.len - nextVal
        if comp.isLoop then
            if comp.len >= 6 then
                local keep = -(comp.len - 8) + nextVal
                if keep < worst then worst = keep end
            end
        else
            if comp.len >= 4 then
                local keep = -(comp.len - 4) + nextVal
                if keep < worst then worst = keep end
            end
        end

        if worst > bestScore then
            bestScore, best = worst, { comp.edge }
        elseif worst == bestScore then
            table.insert(best, comp.edge)
        end
    end

    if #best == 0 then
        return negamaxSolver(board)
    end
    return best[math.random(#best)]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. HIGHER‑ORDER WRAPPERS
-- ═══════════════════════════════════════════════════════════════════════════

-- Inject a random blunder with probability p, otherwise call fn
local function withBlunder(fn, p)
    return function(board)
        if randomChance(p) then
            local all = freeEdges(board)
            return all[math.random(#all)]
        else
            return fn(board)
        end
    end
end

-- Random among the top‑K by scorer
local function pickTopKRandom(board, edges, scorer, K)
    local scored = {}
    for _, e in ipairs(edges) do
        table.insert(scored, { edge=e, score=scorer(board,e) })
    end
    table.sort(scored, function(a,b) return a.score>b.score end)
    local cap = math.min(K, #scored)
    local subset = {}
    for i=1,cap do subset[i]=scored[i].edge end
    return subset[math.random(#subset)]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. STRATEGIES
-- ═══════════════════════════════════════════════════════════════════════════

local Strategies = {}

-- EASY: 10% random → take box → random safe → random
Strategies.easy = withBlunder(function(board)
    local c = closers(board)
    if #c>0 then return c[1] end
    local s = safes(board)
    if #s>0 then return s[math.random(#s)] end
    return freeEdges(board)[1]
end, 0.10)

-- MEDIUM: take box → depth‑1 pickTopKRandom → negamax
Strategies.medium = function(board)
    local c = closers(board)
    if #c>0 then return c[1] end
    local s = safes(board)
    if #s>0 then return pickTopKRandom(board, s, scoreSafeEdge, board.DOTS) end
    return negamaxSolver(board)
end

-- HARD: take box → depth‑2 bestSafeEdge → negamax when safes dry up
Strategies.hard = function(board)
    local c = closers(board)
    if #c>0 then return c[1] end

    local s = safes(board)
    if #s>0 then
        -- **2‑ply lookahead** on safe edges:
        return bestSafeEdge(board, s)
    end

    -- no safes left → full chain/loop solver
    return negamaxSolver(board)
end

-- EXPERT: same as hard early, then perfect Berlekamp endgame play
Strategies.expert = function(board)
    local c = closers(board)
    if #c>0 then return c[1] end

    -- drain safes first (depth‑2)
    local s = safes(board)
    if #s>0 then return bestSafeEdge(board, s) end

    return berlekampSolver(board)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════════════════════

function Ai.setDifficulty(level)
    if Strategies[level] then
        Ai.difficulty = level
    else
        Ai.difficulty = "easy"
    end
end

function Ai.chooseMove(board)
    return Strategies[Ai.difficulty](board)
end

return Ai
