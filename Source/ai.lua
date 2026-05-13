-- ai.lua
-- Modular AI module with shared edge analysis, heuristics, and solvers.
-- Difficulty tiers (easy → expert) build on composable primitives:
--   • easy   – 30% blunders, otherwise greedy closers or random safes.
--   • medium – greedy closers, heuristic safe-edge ranking, chain solver fallback.
--   • hard   – medium’s plan plus 2-ply safe-edge lookahead.
--   • expert – hard’s opener with Berlekamp-style endgame resolution.

local Ai = {}
Ai.difficulty = "medium"

-- ─── Coroutine scheduler state ───────────────────────────────────────────
local SLICE_BUDGET_MS <const> = 15          -- per-frame compute slice
-- Per-difficulty pacing range: each AI move waits a random ms within
-- [min, max] before being applied. Gives each level a distinct tempo.
local MIN_DELAY_RANGE <const> = {
    easy   = {  80, 220 },   -- snappy, casual
    medium = { 220, 450 },   -- a beat of thought
    hard   = { 400, 800 },   -- deliberate
    expert = {   0,   0 },   -- as long as the search needs; otherwise instant
}

local runtime = {
    coro          = nil,
    board         = nil,
    result        = nil,
    startMs       = 0,
    minDelayMs    = 0,
    sliceDeadline = 0,
}

-- Tracks whether the board is currently in a tentative applyMove state.
-- While > 0, we MUST NOT yield: yielding here would let the renderer draw
-- the half-applied search candidate, producing visible "flicker".
local applyDepth = 0

local function nowMs()
    return playdate.getCurrentTimeMilliseconds()
end

local function yieldIfBudgetExceeded()
    if applyDepth > 0 then return end   -- never yield while the board is dirty
    if nowMs() > runtime.sliceDeadline then
        local co, isMain = coroutine.running()
        if co and not isMain then coroutine.yield() end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. EDGE ANALYSIS PRIMITIVES
-- ═══════════════════════════════════════════════════════════════════════════

local EdgeUtils = {}

-- Random blunder helper: returns true with probability p
function EdgeUtils.randomChance(p)
    return math.random() < p
end

-- Count how many edges in `list` are already filled on the board
function EdgeUtils.countFilled(board, list)
    local n = 0
    for _, e in ipairs(list) do
        if board.edgesFilled[e] then n = n + 1 end
    end
    return n
end

-- Classify every free edge once so strategies can reuse the same snapshot.
function EdgeUtils.classify(board)
    local snapshot = {
        free    = {},
        closers = {},
        safes   = {}
    }

    for _, edge in ipairs(board:listFreeEdges()) do
        table.insert(snapshot.free, edge)

        local closesBox, isSafe = false, true
        for _, boxId in ipairs(board.edgeBoxes[edge] or {}) do
            local filled = EdgeUtils.countFilled(board, board.boxEdges[boxId])
            if filled == 3 then closesBox = true end
            if filled == 2 then isSafe = false end
        end

        if closesBox then snapshot.closers[#snapshot.closers + 1] = edge end
        if isSafe   then snapshot.safes[#snapshot.safes + 1]       = edge end
    end

    return snapshot
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. COMPONENT DETECTION (chains / loops)
-- ═══════════════════════════════════════════════════════════════════════════

local Components = {}

-- Detect prospective chains/loops with exactly two sides filled per box.
function Components.collectCold(board)
    local comps, seen = {}, {}
    local BE, EB = board.boxEdges, board.edgeBoxes

    local function dfs(boxId, comp)
        seen[boxId] = true
        comp.len = comp.len + 1
        for _, edge in ipairs(BE[boxId]) do
            if not board.edgesFilled[edge] then
                comp.firstEdge = comp.firstEdge or edge
                local adj = EB[edge] or {}
                local neighbor
                if #adj == 2 then
                    neighbor = (adj[1] == boxId) and adj[2] or adj[1]
                end

                if neighbor and EdgeUtils.countFilled(board, BE[neighbor]) == 2 then
                    if not seen[neighbor] then dfs(neighbor, comp) end
                else
                    comp.entryEdges = comp.entryEdges or {}
                    table.insert(comp.entryEdges, edge)
                end
            end
        end
    end

    for boxId = 1, #board.boxEdges do
        if not seen[boxId]
        and EdgeUtils.countFilled(board, board.boxEdges[boxId]) == 2
        then
            local comp = { len = 0 }
            dfs(boxId, comp)
            comp.isLoop = not comp.entryEdges or #comp.entryEdges == 0
            if not comp.isLoop then
                comp.edge = comp.entryEdges[1]
            else
                comp.edge = comp.firstEdge
            end
            table.insert(comps, comp)
        end
    end

    return comps
end

-- Helpers for Berlekamp solver bookkeeping.

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

-- Persistent memo for solveComponents — cleared in Ai.beginChooseMove and at
-- the top of each synchronous Ai.chooseMove call.
local solveMemo = {}

-- Mutate-and-restore inside `state` rather than allocating a new table per
-- branch. We snapshot the bucket keys up front because modifying a Lua table
-- while iterating with pairs() is undefined when keys are added/removed.
local function solveComponents(state)
    yieldIfBudgetExceeded()
    local key = stateKey(state)
    local cached = solveMemo[key]
    if cached ~= nil then return cached end

    local hasChain, hasLoop = next(state.chains), next(state.loops)
    if not hasChain and not hasLoop then
        solveMemo[key] = 0
        return 0
    end

    local best = -math.huge

    local chains = state.chains
    local chainLens = {}
    for len in pairs(chains) do chainLens[#chainLens + 1] = len end
    for _, len in ipairs(chainLens) do
        local count = chains[len]
        if count and count > 0 then
            if count == 1 then chains[len] = nil else chains[len] = count - 1 end
            local nextVal = solveComponents(state)
            chains[len] = count

            local worst = -len - nextVal
            if len >= 4 then
                local keep = -(len - 4) + nextVal
                if keep < worst then worst = keep end
            end
            if worst > best then best = worst end
        end
    end

    local loops = state.loops
    local loopLens = {}
    for len in pairs(loops) do loopLens[#loopLens + 1] = len end
    for _, len in ipairs(loopLens) do
        local count = loops[len]
        if count and count > 0 then
            if count == 1 then loops[len] = nil else loops[len] = count - 1 end
            local nextVal = solveComponents(state)
            loops[len] = count

            local worst = -len - nextVal
            if len >= 6 then
                local keep = -(len - 8) + nextVal
                if keep < worst then worst = keep end
            end
            if worst > best then best = worst end
        end
    end

    if best == -math.huge then best = 0 end
    solveMemo[key] = best
    return best
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. HEURISTICS
-- ═══════════════════════════════════════════════════════════════════════════

local Heuristics = {}

function Heuristics.scoreSafeEdge(board, edge)
    local adj, bonus, maxFilled = board.edgeBoxes[edge] or {}, 0, 0
    if #adj == 1 then bonus = 3 end
    for _, boxId in ipairs(adj) do
        local filled = EdgeUtils.countFilled(board, board.boxEdges[boxId])
        if filled > maxFilled then maxFilled = filled end
    end
    return bonus + maxFilled
end

-- Tuple comparator used by Hard / Expert when scores tie.
--   (rawScore, staticHeuristic, -edgeId) — higher tuple wins.
function Heuristics.beatsBest(score, h, edge, bestScore, bestH, bestEdge)
    if not bestEdge then return true end
    if score ~= bestScore then return score > bestScore end
    if h ~= bestH then return h > bestH end
    return edge < bestEdge
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. ENDGAME SOLVERS
-- ═══════════════════════════════════════════════════════════════════════════

local Endgame = {}

local function compValue(comp)
    return comp.isLoop and -1 or (4 - comp.len)
end

local function multisetKey(vals)
    table.sort(vals, function(a, b) return a > b end)
    return table.concat(vals, ",")
end

local function negamax(vals, cache)
    yieldIfBudgetExceeded()
    if #vals == 0 then return 0 end
    local key = multisetKey(vals)
    if cache[key] then return cache[key] end
    local best = -64
    local n = #vals
    -- Swap-and-pop: move the chosen element to the end and shrink virtually
    -- by nil-ing the last slot, then restore both slots after the recursion.
    -- Avoids the O(n) shift table.remove/insert incur from the middle.
    for i = 1, n do
        local v = vals[i]
        vals[i] = vals[n]
        vals[n] = nil
        local score = -negamax(vals, cache) - v
        vals[n] = vals[i]
        vals[i] = v
        if score > best then best = score end
        if best >= 0 then break end
    end

    cache[key] = best
    return best
end

function Endgame.negamaxSolver(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[math.random(#snapshot.closers)]
    end
    if #snapshot.safes > 0 then
        return snapshot.safes[math.random(#snapshot.safes)]
    end

    local comps = Components.collectCold(board)
    if #comps == 0 then
        return snapshot.free[math.random(#snapshot.free)]
    end

    local vals, edges = {}, {}
    for idx, comp in ipairs(comps) do
        vals[idx], edges[idx] = compValue(comp), comp.edge
    end

    local cache, bestScore, bestIndices = {}, -math.huge, {}
    local n = #vals
    for i = 1, n do
        yieldIfBudgetExceeded()
        local value = vals[i]
        vals[i] = vals[n]
        vals[n] = nil
        local score = -negamax(vals, cache) - value
        vals[n] = vals[i]
        vals[i] = value
        if score > bestScore then
            bestScore, bestIndices = score, { i }
        elseif score == bestScore then
            bestIndices[#bestIndices + 1] = i
        end
    end

    -- Deterministic tie-break: higher static heuristic on entry edge wins,
    -- then lowest edge id for stability.
    local choice = bestIndices[1]
    local bestH = Heuristics.scoreSafeEdge(board, edges[choice])
    for i = 2, #bestIndices do
        local idx = bestIndices[i]
        local h = Heuristics.scoreSafeEdge(board, edges[idx])
        if h > bestH or (h == bestH and edges[idx] < edges[choice]) then
            choice, bestH = idx, h
        end
    end
    return edges[choice]
end

function Endgame.berlekampSolver(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    local comps = Components.collectCold(board)
    if #comps == 0 then
        return snapshot.free[math.random(#snapshot.free)]
    end

    local state = componentState(comps)
    local bestScore, bestEdges = -math.huge, {}

    for _, comp in ipairs(comps) do
        local bucket = comp.isLoop and state.loops or state.chains
        local prev = bucket[comp.len]
        if prev == 1 then bucket[comp.len] = nil else bucket[comp.len] = prev - 1 end
        local nextVal = solveComponents(state)
        bucket[comp.len] = prev
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
            bestScore, bestEdges = worst, { comp.edge }
        elseif worst == bestScore then
            bestEdges[#bestEdges + 1] = comp.edge
        end
    end

    if #bestEdges == 0 then
        return Endgame.negamaxSolver(board, snapshot)
    end

    -- Deterministic tie-break: higher scoreSafeEdge, then lower edge id.
    local choice = bestEdges[1]
    local bestH = Heuristics.scoreSafeEdge(board, choice)
    for i = 2, #bestEdges do
        local e = bestEdges[i]
        local h = Heuristics.scoreSafeEdge(board, e)
        if h > bestH or (h == bestH and e < choice) then
            choice, bestH = e, h
        end
    end
    return choice
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. SEARCH-BASED EXPERT SUPPORT
-- ═══════════════════════════════════════════════════════════════════════════

local Expert = {}

local function scoreDiff(board)
    local p = board.currentPlayer
    return board.score[p] - board.score[3 - p]
end

local function evaluateTerminal(board)
    if board:isGameOver() then
        return scoreDiff(board)
    end

    local comps = Components.collectCold(board)
    if #comps == 0 then
        return scoreDiff(board)
    end

    local future = solveComponents(componentState(comps))
    return scoreDiff(board) + future
end

local function applyMove(board, edge)
    -- Defensive: refuse to "apply" an already-filled edge. If we did, the
    -- corresponding undoMove would nil out edgesFilled[edge] and erase a
    -- real, previously-played move. Return nil so undoMove becomes a no-op.
    if board.edgesFilled[edge] then return nil end

    -- Snapshot every field playEdge can mutate, including the stat fields
    -- (chainLen / longestChain / endMs) so AI search doesn't pollute them.
    local state = {
        prevPlayer    = board.currentPlayer,
        prevScores    = { board.score[1], board.score[2] },
        prevChainLen  = board.chainLen,
        prevLongest1  = board.longestChain[1],
        prevLongest2  = board.longestChain[2],
        prevEndMs     = board.endMs,
        edge          = edge,
        edgeOwner     = board.edgeOwner[edge],
        boxes         = {}
    }
    for _, boxId in ipairs(board.edgeBoxes[edge] or {}) do
        state.boxes[#state.boxes + 1] = { id = boxId, owner = board.boxOwner[boxId] }
    end
    applyDepth = applyDepth + 1
    board:playEdge(edge)
    return state
end

local function undoMove(board, state)
    if not state then return end  -- applyMove refused; nothing to roll back
    board.currentPlayer    = state.prevPlayer
    board.score[1], board.score[2] = state.prevScores[1], state.prevScores[2]
    board.chainLen         = state.prevChainLen
    board.longestChain[1]  = state.prevLongest1
    board.longestChain[2]  = state.prevLongest2
    board.endMs            = state.prevEndMs
    board.edgesFilled[state.edge] = nil
    board.edgeOwner[state.edge]   = state.edgeOwner
    for _, info in ipairs(state.boxes) do
        board.boxOwner[info.id] = info.owner
    end
    applyDepth = applyDepth - 1
end

local function selectTopSafes(board, safes, limit)
    local count = #safes
    if count <= limit then return safes end
    local scored = {}
    for _, edge in ipairs(safes) do
        scored[#scored + 1] = {
            edge = edge,
            score = Heuristics.scoreSafeEdge(board, edge)
        }
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local top = {}
    for i = 1, math.min(limit, #scored) do
        top[i] = scored[i].edge
    end
    return top
end

local function evaluateForPlayer(board, rootPlayer)
    local value = evaluateTerminal(board)
    if board.currentPlayer ~= rootPlayer then
        value = -value
    end
    return value
end

local SAFE_EVAL_LIMIT   <const> = 4
local CLOSER_EVAL_LIMIT <const> = 5
local SAFE_DEPTH_LIMIT  <const> = 2
local SAFE_DEPTH_MAX_DOTS <const> = 6
local SACRIFICE_LIMIT   <const> = 3
local SACRIFICE_THRESHOLD <const> = 0.75
local SACRIFICE_SAFE_CAP <const> = 2

function Expert.chooseMove(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    local rootPlayer = board.currentPlayer

    if #snapshot.closers > 0 then
        local bestEdge, bestScore = nil, -math.huge
        local candidates = snapshot.closers
        if #candidates > CLOSER_EVAL_LIMIT then
            candidates = selectTopSafes(board, candidates, CLOSER_EVAL_LIMIT)
        end
        for _, edge in ipairs(candidates) do
            yieldIfBudgetExceeded()
            local state = applyMove(board, edge)
            local score = evaluateForPlayer(board, rootPlayer)
            undoMove(board, state)
            if score > bestScore then
                bestScore, bestEdge = score, edge
            end
        end
        return bestEdge
    end

    local safeCount = #snapshot.safes

    if safeCount > 0 then
        local function evaluateSafeEdge(edge)
            yieldIfBudgetExceeded()
            local state = applyMove(board, edge)
            local baseline = evaluateForPlayer(board, rootPlayer)
            local adjusted = baseline

            if SAFE_DEPTH_LIMIT > 0 and board.DOTS <= SAFE_DEPTH_MAX_DOTS then
                local peerSnapshot = EdgeUtils.classify(board)
                if #peerSnapshot.safes > 0 then
                    local peers = selectTopSafes(board, peerSnapshot.safes, SAFE_EVAL_LIMIT)
                    local peerWorst = math.huge
                    for _, peerEdge in ipairs(peers) do
                        local peerState = applyMove(board, peerEdge)
                        local peerScore = evaluateForPlayer(board, rootPlayer)
                        undoMove(board, peerState)
                        if peerScore < peerWorst then peerWorst = peerScore end
                    end
                    adjusted = math.min(adjusted, peerWorst)
                end
            end

            undoMove(board, state)
            return adjusted
        end

        local safeBestEdge, safeBestScore = nil, -math.huge
        local safeCandidates = selectTopSafes(board, snapshot.safes, SAFE_EVAL_LIMIT)
        for _, edge in ipairs(safeCandidates) do
            local sc = evaluateSafeEdge(edge)
            if sc > safeBestScore then
                safeBestScore, safeBestEdge = sc, edge
            end
        end

        local safeLookup = {}
        for _, e in ipairs(snapshot.safes) do safeLookup[e] = true end

        local sacrifices = {}
        local comps = Components.collectCold(board)
        for _, comp in ipairs(comps) do
            if comp.edge and not safeLookup[comp.edge] then
                sacrifices[#sacrifices + 1] = { edge = comp.edge, len = comp.len }
            end
        end
        if #sacrifices > 1 then
            table.sort(sacrifices, function(a, b) return a.len > b.len end)
        end

        local sacrificeBestEdge, sacrificeBestScore = nil, -math.huge
        local sacLimit = math.min(SACRIFICE_LIMIT, #sacrifices)
        for i = 1, sacLimit do
            yieldIfBudgetExceeded()
            local edge = sacrifices[i].edge
            local state = applyMove(board, edge)
            local score = evaluateForPlayer(board, rootPlayer)
            undoMove(board, state)
            if score > sacrificeBestScore then
                sacrificeBestScore, sacrificeBestEdge = score, edge
            end
        end

        local allowSacrifice = (safeCount <= SACRIFICE_SAFE_CAP)
            and (not safeBestEdge or safeBestScore < 0)

        if sacrificeBestEdge
        and allowSacrifice
        and (not safeBestEdge or sacrificeBestScore > safeBestScore + SACRIFICE_THRESHOLD)
        then
            return sacrificeBestEdge
        end
        if safeBestEdge then
            return safeBestEdge
        end
    end

    return Endgame.berlekampSolver(board, snapshot)
end

-- ─── Hard: real 2-ply minimax over the top-K safe edges ──────────────────

local Hard = {}

local HARD_SAFE_LIMIT     <const> = 3
local HARD_DEPTH2_MAX_DOTS <const> = 6

function Hard.chooseMove(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    local rootPlayer = board.currentPlayer

    if #snapshot.closers > 0 then
        return snapshot.closers[1]
    end

    if #snapshot.safes > 0 then
        local depth = (board.DOTS <= HARD_DEPTH2_MAX_DOTS) and 2 or 1
        local candidates = selectTopSafes(board, snapshot.safes, HARD_SAFE_LIMIT)

        local bestEdge, bestScore, bestH = nil, -math.huge, -math.huge
        for _, edge in ipairs(candidates) do
            yieldIfBudgetExceeded()
            local hStatic = Heuristics.scoreSafeEdge(board, edge)
            local state = applyMove(board, edge)
            local score = evaluateForPlayer(board, rootPlayer)
            if depth >= 2 then
                local peerSnapshot = EdgeUtils.classify(board)
                if #peerSnapshot.safes > 0 then
                    local peers = selectTopSafes(board, peerSnapshot.safes, HARD_SAFE_LIMIT)
                    local peerWorst = math.huge
                    for _, peerEdge in ipairs(peers) do
                        local peerState = applyMove(board, peerEdge)
                        local peerScore = evaluateForPlayer(board, rootPlayer)
                        undoMove(board, peerState)
                        if peerScore < peerWorst then peerWorst = peerScore end
                    end
                    if peerWorst < score then score = peerWorst end
                end
            end
            undoMove(board, state)

            if Heuristics.beatsBest(score, hStatic, edge, bestScore, bestH, bestEdge) then
                bestScore, bestH, bestEdge = score, hStatic, edge
            end
        end
        if bestEdge then return bestEdge end
    end

    return Endgame.negamaxSolver(board, snapshot)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. STRATEGY HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local StrategyUtils = {}

function StrategyUtils.withBlunder(fn, p)
    return function(board)
        if EdgeUtils.randomChance(p) then
            local freeEdges = board:listFreeEdges()
            return freeEdges[math.random(#freeEdges)]
        else
            return fn(board)
        end
    end
end

function StrategyUtils.pickTopKRandom(board, edges, scorer, k)
    local scored = {}
    for _, edge in ipairs(edges) do
        scored[#scored + 1] = { edge = edge, score = scorer(board, edge) }
    end
    table.sort(scored, function(a, b) return a.score > b.score end)

    local cap = math.min(k, #scored)
    local subset = {}
    for i = 1, cap do
        subset[i] = scored[i].edge
    end
    return subset[math.random(#subset)]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. DIFFICULTY POLICIES
-- ═══════════════════════════════════════════════════════════════════════════

local Strategies = {}

-- Edge centrality: higher score = closer to the board's geometric center.
-- Used by Medium to give it a "bold, plays in the middle" personality.
local function centralityScore(board, edge)
    local coords = board.edgeToCoord[edge]
    local r, c, d = coords[1], coords[2], coords[3]
    local ey, ex
    if d == board.H then
        ey, ex = r, c + 0.5
    else
        ey, ex = r + 0.5, c
    end
    local mid = (board.DOTS + 1) / 2
    local dy, dx = ey - mid, ex - mid
    return -(dy * dy + dx * dx)
end

Strategies.easy = StrategyUtils.withBlunder(function(board)
    local snapshot = EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[math.random(#snapshot.closers)]
    end
    if #snapshot.safes > 0 then
        -- Tidy / orderly: scoreSafeEdge already rewards border edges with +3.
        return StrategyUtils.pickTopKRandom(board, snapshot.safes, Heuristics.scoreSafeEdge, 2)
    end
    return snapshot.free[math.random(#snapshot.free)]
end, 0.30)

Strategies.medium = function(board)
    local snapshot = EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[1]
    end
    if #snapshot.safes > 0 then
        -- Bold: play the most central safe edge (top-2 random for variety).
        return StrategyUtils.pickTopKRandom(board, snapshot.safes, centralityScore, 2)
    end
    return Endgame.negamaxSolver(board, snapshot)
end

Strategies.hard = function(board)
    return Hard.chooseMove(board)
end

Strategies.expert = function(board)
    local snapshot = EdgeUtils.classify(board)
    return Expert.chooseMove(board, snapshot)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

function Ai.setDifficulty(level)
    if Strategies[level] then
        Ai.difficulty = level
    else
        Ai.difficulty = "easy"
    end
end

-- Synchronous fallback: still safe to call from outside a coroutine, will
-- never yield because the budget check is wrapped in a coroutine.running guard.
function Ai.chooseMove(board)
    solveMemo = {}
    return Strategies[Ai.difficulty](board)
end

-- ─── Coroutine-driven scheduler ──────────────────────────────────────────

function Ai.cancel()
    runtime.coro       = nil
    runtime.board      = nil
    runtime.result     = nil
    runtime.startMs    = 0
    runtime.minDelayMs = 0
    applyDepth         = 0
end

function Ai.isThinking()
    return runtime.coro ~= nil
end

function Ai.beginChooseMove(board)
    Ai.cancel()
    solveMemo = {}
    runtime.board   = board
    runtime.startMs = nowMs()
    local range = MIN_DELAY_RANGE[Ai.difficulty] or { 0, 0 }
    if range[1] >= range[2] then
        runtime.minDelayMs = range[1]
    else
        runtime.minDelayMs = math.random(range[1], range[2])
    end
    local strategy = Strategies[Ai.difficulty]
    runtime.coro = coroutine.create(function()
        return strategy(board)
    end)
end

-- Returns (done, edge). When done == true, edge is the chosen edge.
function Ai.tick()
    if not runtime.coro then return false, nil end

    if runtime.result == nil then
        runtime.sliceDeadline = nowMs() + SLICE_BUDGET_MS
        local ok, val = coroutine.resume(runtime.coro)
        if not ok then
            -- Coroutine errored; fall back to any free edge.
            local frees = runtime.board:listFreeEdges()
            runtime.result = frees[math.random(#frees)] or 1
        elseif coroutine.status(runtime.coro) == "dead" then
            runtime.result = val
        end
    end

    if runtime.result == nil then
        return false, nil
    end

    if (nowMs() - runtime.startMs) < runtime.minDelayMs then
        return false, nil
    end

    local edge = runtime.result
    Ai.cancel()
    return true, edge
end

return Ai
