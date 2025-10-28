-- ai.lua
-- Modular AI module with shared edge analysis, heuristics, and solvers.
-- Difficulty tiers (easy → expert) build on composable primitives:
--   • easy   – 10% blunders, otherwise greedy closers or random safes.
--   • medium – greedy closers, heuristic safe-edge ranking, chain solver fallback.
--   • hard   – medium’s plan plus 2-ply safe-edge lookahead.
--   • expert – hard’s opener with Berlekamp-style endgame resolution.

local Ai = {}
Ai.difficulty = "medium"

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

-- Detect all 3-sided boxes (hot components).
function Components.collectHot(board)
    local comps, seen = {}, {}
    local BE, EB = board.boxEdges, board.edgeBoxes

    local function dfs(boxId, comp)
        seen[boxId] = true
        comp.len = comp.len + 1

        local empty
        for _, edge in ipairs(BE[boxId]) do
            if not board.edgesFilled[edge] then
                empty = edge
                break
            end
        end

        if not comp.edge then comp.edge = empty end
        local adj = EB[empty] or {}
        if #adj == 2 then
            local nb = (adj[1] == boxId) and adj[2] or adj[1]
            if EdgeUtils.countFilled(board, BE[nb]) == 3 then
                if not seen[nb] then
                    dfs(nb, comp)
                end
            else
                comp.ends = (comp.ends or 0) + 1
            end
        else
            comp.ends = (comp.ends or 0) + 1
        end
    end

    for boxId = 1, #board.boxEdges do
        if not seen[boxId]
        and EdgeUtils.countFilled(board, board.boxEdges[boxId]) == 3
        then
            local comp = { len = 0, edge = nil, ends = 0 }
            dfs(boxId, comp)
            comp.isLoop = (comp.ends == 0)
            table.insert(comps, comp)
        end
    end

    return comps
end

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

function Heuristics.bestSafeEdge(board, safeEdges)
    local bestEdge, bestScore = safeEdges[1], -math.huge
    for _, edge in ipairs(safeEdges) do
        board.edgesFilled[edge] = true
        local hotCount = #Components.collectHot(board)
        board.edgesFilled[edge] = nil
        local score = -hotCount + Heuristics.scoreSafeEdge(board, edge)
        if score > bestScore then
            bestScore, bestEdge = score, edge
        end
    end
    return bestEdge
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

local function safeYield()
    if coroutine.isyieldable then
        if coroutine.isyieldable() then coroutine.yield() end
    else
        local co, isMain = coroutine.running()
        if co and not isMain then coroutine.yield() end
    end
end

local function negamax(vals, cache)
    if #vals == 0 then return 0 end
    local key = multisetKey(vals)
    if cache[key] then return cache[key] end
    local best = -64
    for i = 1, #vals do
        local v = table.remove(vals, i)
        local score = -negamax(vals, cache) - v
        table.insert(vals, i, v)
        if score > best then best = score end
        if best >= 0 then break end
    end

    safeYield() -- Yield periodically to avoid freezing

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

    local comps = Components.collectHot(board)
    if #comps == 0 then
        comps = Components.collectCold(board)
        if #comps == 0 then
            return snapshot.free[math.random(#snapshot.free)]
        end
    end

    local vals, edges = {}, {}
    for idx, comp in ipairs(comps) do
        vals[idx], edges[idx] = compValue(comp), comp.edge
    end

    local cache, bestScore, bestIndices = {}, -math.huge, {}
    for i = 1, #vals do
        local value = table.remove(vals, i)
        local score = -negamax(vals, cache) - value
        table.insert(vals, i, value)
        if score > bestScore then
            bestScore, bestIndices = score, { i }
        elseif score == bestScore then
            bestIndices[#bestIndices + 1] = i
        end
    end

    safeYield() -- Yield periodically to avoid freezing

    local choice = bestIndices[math.random(#bestIndices)]
    return edges[choice]
end

function Endgame.berlekampSolver(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    local comps = Components.collectHot(board)
    if #comps == 0 then
        comps = Components.collectCold(board)
        if #comps == 0 then
            return snapshot.free[math.random(#snapshot.free)]
        end
    end

    local state = componentState(comps)
    local memo = {}
    local bestScore, bestEdges = -math.huge, {}

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
            bestScore, bestEdges = worst, { comp.edge }
        elseif worst == bestScore then
            bestEdges[#bestEdges + 1] = comp.edge
        end
    end

    if #bestEdges == 0 then
        return Endgame.negamaxSolver(board, snapshot)
    end
    return bestEdges[math.random(#bestEdges)]
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

    local comps = Components.collectHot(board)
    if #comps == 0 then
        comps = Components.collectCold(board)
        if #comps == 0 then
            return scoreDiff(board)
        end
    end

    local future = solveComponents(componentState(comps), {})
    return scoreDiff(board) + future
end

local function applyMove(board, edge)
    local state = {
        prevPlayer = board.currentPlayer,
        prevScores = { board.score[1], board.score[2] },
        edge = edge,
        edgeOwner = board.edgeOwner[edge],
        boxes = {}
    }
    for _, boxId in ipairs(board.edgeBoxes[edge] or {}) do
        state.boxes[#state.boxes + 1] = { id = boxId, owner = board.boxOwner[boxId] }
    end
    board:playEdge(edge)
    return state
end

local function undoMove(board, state)
    board.currentPlayer = state.prevPlayer
    board.score[1], board.score[2] = state.prevScores[1], state.prevScores[2]
    board.edgesFilled[state.edge] = nil
    board.edgeOwner[state.edge] = state.edgeOwner
    for _, info in ipairs(state.boxes) do
        board.boxOwner[info.id] = info.owner
    end
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

Strategies.easy = StrategyUtils.withBlunder(function(board)
    local snapshot = EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[math.random(#snapshot.closers)]
    end
    if #snapshot.safes > 0 then
        return snapshot.safes[math.random(#snapshot.safes)]
    end
    return snapshot.free[math.random(#snapshot.free)]
end, 0.30)

Strategies.medium = function(board)
    local snapshot = EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[1]
    end
    if #snapshot.safes > 0 then
        return StrategyUtils.pickTopKRandom(board, snapshot.safes, Heuristics.scoreSafeEdge, board.DOTS)
    end
    return Endgame.negamaxSolver(board, snapshot)
end

Strategies.hard = function(board)
    local snapshot = EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[1]
    end
    if #snapshot.safes > 0 then
        return Heuristics.bestSafeEdge(board, snapshot.safes)
    end
    return Endgame.negamaxSolver(board, snapshot)
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

function Ai.chooseMove(board)
    return Strategies[Ai.difficulty](board)
end

return Ai
