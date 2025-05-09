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

-- Flood‑fill free‑edge graph to find disjoint regions (pockets)
local function freeEdgeRegions(board)
    local all = freeEdges(board)
    local visited, regions = {}, {}
    local function adjacent(e1, e2)
        for _, b1 in ipairs(board.edgeBoxes[e1] or {}) do
            for _, b2 in ipairs(board.edgeBoxes[e2] or {}) do
                if b1 == b2 then return true end
            end
        end
        return false
    end
    for _, e in ipairs(all) do
        if not visited[e] then
            visited[e] = true
            local stack, comp = { e }, {}
            while #stack > 0 do
                local x = table.remove(stack)
                table.insert(comp, x)
                for _, y in ipairs(all) do
                    if not visited[y] and adjacent(x, y) then
                        visited[y] = true
                        table.insert(stack, y)
                    end
                end
            end
            table.insert(regions, comp)
        end
    end
    return regions
end

-- Filter a list of edges down to those in one region
local function filterEdges(region, edges)
    local set, out = {}, {}
    for _, e in ipairs(region) do set[e] = true end
    for _, e in ipairs(edges) do
        if set[e] then table.insert(out, e) end
    end
    return out
end

-- Pocket‑specific Nim‑sum
local function pocketNimSum(board, region)
    local xor, myComps = 0, {}
    local inSet = {}
    for _, e in ipairs(region) do inSet[e] = true end
    for _, c in ipairs(collectHotComponents(board)) do
        if inSet[c.edge] then
            table.insert(myComps, c)
            local heap = c.isLoop and 1 or (c.len - 1)
            xor = xor ~ heap
        end
    end
    return xor, myComps
end

-- Pick best pocket: prefer any xor≠0, else smallest
local function selectPocket(board)
    local regs = freeEdgeRegions(board)
    for _, r in ipairs(regs) do
        if pocketNimSum(board, r) ~= 0 then return r end
    end
    table.sort(regs, function(a,b) return #a < #b end)
    return regs[1]
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
        local f = freeEdges(board)
        return f[math.random(#f)]
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

-- Berlekamp Nim‑sum solver with random tie-breaking
local function berlekampSolver(board)
    local comps = collectHotComponents(board)
    local xor, cand = 0, {}
    for _, c in ipairs(comps) do
        local h = c.isLoop and 1 or (c.len - 1)
        xor = xor ~ h
    end
    if xor ~= 0 then
        for _, c in ipairs(comps) do
            if not c.isLoop then
                local h = c.len - 1
                if (h ~ xor) < h then table.insert(cand, c.edge) end
            end
        end
    else
        for _, c in ipairs(comps) do
            if not c.isLoop and c.len > 2 then table.insert(cand, c.edge) end
        end
    end
    if #cand > 0 then return cand[math.random(#cand)] end
    return (comps[1] and comps[1].edge) or freeEdges(board)[1]
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

-- EXPERT: same as hard early, then pocket‑aware Berlekamp Nim‑sum
Strategies.expert = function(board)
    local c = closers(board)
    if #c>0 then return c[1] end

    -- drain safes first (depth‑2)
    local s = safes(board)
    if #s>0 then return bestSafeEdge(board, s) end

    local pocket = selectPocket(board)
    local xor, comps = pocketNimSum(board, pocket)
    if #comps>0 then return berlekampSolver(board) end

    -- fallback depth‑2 inside pocket
    local ps = filterEdges(pocket, safes(board))
    if #ps>0 then return bestSafeEdge(board, ps) end
    return pocket[math.random(#pocket)]
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