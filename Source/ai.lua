-- ai.lua
-- Modular AI module with shared edge analysis, heuristics, and solvers.
-- Difficulty tiers (easy → expert) build on composable primitives:
--   • easy   – 30% blunders, otherwise greedy closers or random safes.
--   • medium – greedy closers, heuristic safe-edge ranking, chain solver fallback.
--   • hard   – medium’s plan plus 2-ply safe-edge lookahead.
--   • expert – hard’s opener with Berlekamp-style endgame resolution.

local Ai = {}
Ai.difficulty = "medium"
Ai.debugLogging = false   -- toggled via system menu; logs go to the tethered console

-- Per-move profile counters; reset in Ai.beginChooseMove. Timings use
-- playdate.getElapsedTime() (high-res float seconds, monotonic — nothing
-- else resets the elapsed timer) since getCurrentTimeMilliseconds() can't
-- resolve the sub-millisecond per-node primitives. Accumulators are in
-- seconds; the log converts to ms. All gated behind Ai.debugLogging so
-- there is zero overhead in normal play.
local profSolveCalls   = 0
local profSolveTotalMs = 0
local profSolveFirstMs = 0
local profApplyCalls   = 0
local profApplyS       = 0   -- applyMove + undoMove wall time
local profClassifyCalls= 0
local profClassifyS    = 0   -- EdgeUtils.classify
local profColdCalls    = 0
local profColdS        = 0   -- Components.collectCold
local profHotCalls     = 0
local profHotS         = 0   -- collectHotComponents

local function profClock() return playdate.getElapsedTime() end

-- ─── Coroutine scheduler state ───────────────────────────────────────────
local SLICE_BUDGET_MS <const> = 15          -- per-frame compute slice
-- Global pacing floor: a single, difficulty-independent minimum so a move
-- never lands so fast it reads as a misclick. The *decision* move of a turn
-- gets this floor; chain-continuation moves get none — those are obvious and
-- are already paced by main.lua's decaying chainPace, so stacking a floor on
-- each box of a long chain just feels clunky ("it's obvious, do it!").
local AI_MIN_DELAY_MS <const> = 150
-- Leave roughly two frames of the half-second Expert allowance for fallback.
local EXPERT_EXACT_BUDGET_MS <const> = 400

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
    local _t = Ai.debugLogging and profClock() or nil
    local snapshot = {
        free    = board:listFreeEdges(),
        closers = {},
        safes   = {}
    }

    for _, edge in ipairs(snapshot.free) do
        local closesBox, isSafe = false, true
        for _, boxId in ipairs(board.edgeBoxes[edge] or {}) do
            local filled = EdgeUtils.countFilled(board, board.boxEdges[boxId])
            if filled == 3 then closesBox = true end
            if filled == 2 then isSafe = false end
        end

        if closesBox then snapshot.closers[#snapshot.closers + 1] = edge end
        if isSafe   then snapshot.safes[#snapshot.safes + 1]       = edge end
    end

    if _t then
        profClassifyS     = profClassifyS + (profClock() - _t)
        profClassifyCalls = profClassifyCalls + 1
    end
    return snapshot
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. COMPONENT DETECTION (chains / loops)
-- ═══════════════════════════════════════════════════════════════════════════

local Components = {}

-- Detect prospective chains/loops with exactly two sides filled per box.
-- `excludedBoxes` (optional) is a {[boxId]=true} set whose boxes will be
-- treated as already-seen; useful when the caller has identified those
-- boxes as belonging to an active hot chain that should be analyzed
-- separately rather than rolled into a cold component.
function Components.collectCold(board, excludedBoxes)
    local _t = Ai.debugLogging and profClock() or nil
    local comps, seen = {}, {}
    if excludedBoxes then
        for k in pairs(excludedBoxes) do seen[k] = true end
    end
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

    if _t then
        profColdS     = profColdS + (profClock() - _t)
        profColdCalls = profColdCalls + 1
    end
    return comps
end

-- ─── C-accelerated cold decomposition ───────────────────────────────────────
-- Components.collectCold above is the readable, audited reference (and the
-- no-C fallback). When the C extension is loaded we push the static board
-- topology once per board size, then each call only marshals the edge-fill
-- bitset. tests/native_test.py compares both implementations directly.

local coldTopoDots = nil   -- board size whose topology is currently resident

local function ensureColdTopo(board)
    if not (dotsai and dotsai.cold_init) then return false end
    if coldTopoDots == board.DOTS then return true end

    local numBoxes = #board.boxEdges
    local numEdges = #board.edgeToCoord
    local be, eb = {}, {}
    for b = 1, numBoxes do
        local e = board.boxEdges[b]
        be[#be + 1] = e[1]; be[#be + 1] = e[2]
        be[#be + 1] = e[3]; be[#be + 1] = e[4]
    end
    for e = 1, numEdges do
        local boxes = board.edgeBoxes[e] or {}
        eb[#eb + 1] = boxes[1] or 0
        eb[#eb + 1] = boxes[2] or 0
    end
    dotsai.cold_init(numBoxes, numEdges,
        string.char(table.unpack(be)), string.char(table.unpack(eb)))
    coldTopoDots = board.DOTS
    return true
end

-- C-preferring cold decomposition. Returns the same shape collectCold does:
-- a list of { len, isLoop, edge, entryEdges } (entryEdges nil for loops).
function Components.cold(board, excludedBoxes)
    local _t = Ai.debugLogging and profClock() or nil
    if not (dotsai and dotsai.cold) or not ensureColdTopo(board) then
        -- Fallback path is already timed inside collectCold; don't double-count.
        return Components.collectCold(board, excludedBoxes)
    end

    local numEdges = #board.edgeToCoord
    local numBoxes = #board.boxEdges
    local fbytes = {}
    for e = 1, numEdges do fbytes[e] = board.edgesFilled[e] and 1 or 0 end
    local filledStr = string.char(table.unpack(fbytes))

    local excludedStr = ""
    if excludedBoxes then
        local xb = {}
        for b = 1, numBoxes do xb[b] = excludedBoxes[b] and 1 or 0 end
        excludedStr = string.char(table.unpack(xb))
    end

    local packed = dotsai.cold(filledStr, excludedStr)
    if not packed then
        return Components.collectCold(board, excludedBoxes)
    end

    local comps = {}
    local pos = 1
    local n = packed:byte(pos); pos = pos + 1
    for _ = 1, n do
        local len      = packed:byte(pos);     pos = pos + 1
        local isLoop   = packed:byte(pos) == 1; pos = pos + 1
        local edge     = packed:byte(pos);     pos = pos + 1
        local nEntries = packed:byte(pos);     pos = pos + 1
        local comp = { len = len, isLoop = isLoop, edge = edge }
        if nEntries > 0 then
            local entries = {}
            for i = 1, nEntries do
                entries[i] = packed:byte(pos); pos = pos + 1
            end
            comp.entryEdges = entries
        end
        comps[#comps + 1] = comp
    end

    if _t then
        profColdS     = profColdS + (profClock() - _t)
        profColdCalls = profColdCalls + 1
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
local captureMemo = {}

-- Single source of truth for the value, to the player who OPENS one
-- component of `len` boxes, of that choice. `nextVal` is the solveComponents
-- value of the state with this component removed (perspective: whoever moves
-- next there). The opponent consumes optimally, picking the option that
-- minimises the opener's value:
--   greedy:       opp takes all `len`, becomes mover of the rest
--                   -> -len - nextVal
--   double-cross: opp leaves a 2-domino (chain) / 4-loop (loop), handing
--                 control back to the opener
--                   -> -(len-4) + nextVal   (chain, len>=3)
--                   -> -(len-8) + nextVal   (loop,  geometrically len>=4)
-- A two-chain is opened at its internal edge: both boxes become independent
-- captures, so the opponent cannot hand them back to retain control.
--
-- IMPORTANT: this arithmetic is mirrored verbatim by the C kernel in
-- Source/main.c (solve()), which is the fast path used via dotsai.solve.
-- Keep the two in lockstep — any change here must be made there too.
local function componentOpenValue(len, isLoop, nextVal)
    local worst = -len - nextVal
    if isLoop then
        if len >= 4 then
            local keep = -(len - 8) + nextVal
            if keep < worst then worst = keep end
        end
    else
        if len >= 3 then
            local keep = -(len - 4) + nextVal
            if keep < worst then worst = keep end
        end
    end
    return worst
end

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

            local worst = componentOpenValue(len, false, nextVal)
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

            local worst = componentOpenValue(len, true, nextVal)
            if worst > best then best = worst end
        end
    end

    if best == -math.huge then best = 0 end
    solveMemo[key] = best
    return best
end

-- Compute the endgame future-value either via the C kernel (`dotsai.solve`)
-- when it's been loaded by the C extension, or the Lua `solveComponents`
-- fallback. The C path is ~10x faster on device for the mid-late game hot
-- band; Lua remains as a no-build-deps fallback. Defined here (above the
-- Endgame solvers) so berlekampSolver can take the fast path too.
local function endgameFuture(comps)
    if dotsai and dotsai.solve then
        local chains, loops = {}, {}
        for _, comp in ipairs(comps) do
            if comp.isLoop then loops[#loops + 1] = comp.len
            else                chains[#chains + 1] = comp.len end
        end
        local chainStr = (#chains > 0) and string.char(table.unpack(chains)) or ""
        local loopStr  = (#loops  > 0) and string.char(table.unpack(loops))  or ""
        return dotsai.solve(chainStr, loopStr)
    end
    return solveComponents(componentState(comps))
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

-- Random tie-break among evaluated candidates with the same top primary score.
-- Callers decide the candidate set; this helper never selects a lower-scored move.
function Heuristics.pickRandomBestByScore(candidates)
    local bestScore, best = -math.huge, {}
    for _, candidate in ipairs(candidates) do
        local score = candidate.score
        if score > bestScore then
            bestScore, best = score, { candidate }
        elseif score == bestScore then
            best[#best + 1] = candidate
        end
    end
    if #best == 0 then return nil, bestScore end
    return best[math.random(#best)], bestScore
end

-- Edge centrality: higher score = closer to the board's geometric center.
-- Used by Medium directly, and by Expert as one ingredient in its aggression
-- personality.
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

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. ENDGAME SOLVERS
-- ═══════════════════════════════════════════════════════════════════════════

local Endgame = {}

local function compValue(comp)
    return comp.isLoop and -1 or (4 - comp.len)
end

local function componentDraftValue(vals)
    -- In this static heuristic, each player takes the lowest remaining value.
    -- Sort a copy so root scores stay attached to their physical entry edges.
    local sorted = { table.unpack(vals) }
    table.sort(sorted)
    local score = 0
    for i, value in ipairs(sorted) do
        score = score + (i % 2 == 0 and value or -value)
    end
    return score
end

function Endgame.componentHeuristic(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    if #snapshot.closers > 0 then
        return snapshot.closers[math.random(#snapshot.closers)]
    end
    if #snapshot.safes > 0 then
        return snapshot.safes[math.random(#snapshot.safes)]
    end

    local comps = Components.cold(board)
    if #comps == 0 then
        return snapshot.free[math.random(#snapshot.free)]
    end

    local vals, edges = {}, {}
    for idx, comp in ipairs(comps) do
        vals[idx], edges[idx] = compValue(comp), comp.edge
    end

    local bestScore, bestIndices = -math.huge, {}
    local n = #vals
    for i = 1, n do
        yieldIfBudgetExceeded()
        local value = vals[i]
        vals[i] = vals[n]
        vals[n] = nil
        local score = -componentDraftValue(vals) - value
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

local function coldOpeningEdge(board, comp)
    if comp.len == 2 and not comp.isLoop then
        for _, box in ipairs(board.edgeBoxes[comp.edge]) do
            if EdgeUtils.countFilled(board, board.boxEdges[box]) == 2 then
                for _, edge in ipairs(board.boxEdges[box]) do
                    local adj = board.edgeBoxes[edge]
                    if not board.edgesFilled[edge] and #adj == 2 then
                        local other = adj[1] == box and adj[2] or adj[1]
                        if EdgeUtils.countFilled(board, board.boxEdges[other]) == 2 then
                            return edge
                        end
                    end
                end
            end
        end
    end
    return comp.edge
end

-- Bounded fallback for junctions: give away as few immediately collectable
-- boxes as possible. This is approximate; independent-chain theory is invalid.
local function approximateJunctionOpening(board, free)
    local bestEdge, bestLoss = free[1], math.huge
    for _, first in ipairs(free) do
        yieldIfBudgetExceeded()
        local used, counts = {}, {}
        for b, edges in ipairs(board.boxEdges) do
            counts[b] = 4 - EdgeUtils.countFilled(board, edges)
        end
        local function play(edge)
            used[edge] = true
            local claimed = 0
            for _, b in ipairs(board.edgeBoxes[edge]) do
                counts[b] = counts[b] - 1
                if counts[b] == 0 then claimed = claimed + 1 end
            end
            return claimed
        end
        play(first)
        local loss = 0
        while true do
            local closer
            for _, edge in ipairs(free) do
                if not used[edge] then
                    for _, b in ipairs(board.edgeBoxes[edge]) do
                        if counts[b] == 1 then closer = edge; break end
                    end
                end
                if closer then break end
            end
            if not closer then break end
            loss = loss + play(closer)
        end
        if loss < bestLoss then bestEdge, bestLoss = first, loss end
    end
    return bestEdge
end

-- Exact future box margin, including extra turns, on a separate edge mask.
-- Native batches search up to 18 free edges; the Lua fallback caps at 14.
-- No result is used unless the search finishes within its wall-time budget.
local function endgameEdgeSearch(board, free, deadline)
    if #free <= 18 and dotsai and dotsai.exact_begin and dotsai.exact_step
        and ensureColdTopo(board) and dotsai.exact_begin(string.char(table.unpack(free))) then
        while true do
            yieldIfBudgetExceeded()
            if deadline and nowMs() >= deadline then return nil end
            local edge = dotsai.exact_step()
            if edge then return edge end
        end
    end
    if #free > 14 then return nil end

    local bits, masks = {}, {}
    for i, edge in ipairs(free) do bits[edge] = 1 << (i - 1) end
    for b, edges in ipairs(board.boxEdges) do
        local mask = 0
        for _, edge in ipairs(edges) do mask = mask | (bits[edge] or 0) end
        masks[b] = mask
    end
    local memo = { [0] = 0 }
    local function solve(remaining)
        yieldIfBudgetExceeded()
        if deadline and nowMs() >= deadline then return nil end
        if memo[remaining] ~= nil then return memo[remaining] end
        local best = -math.huge
        for _, edge in ipairs(free) do
            local bit = bits[edge]
            if remaining & bit ~= 0 then
                local gained = 0
                for _, b in ipairs(board.edgeBoxes[edge]) do
                    if remaining & masks[b] == bit then gained = gained + 1 end
                end
                local rest = solve(remaining ~ bit)
                if rest == nil then return nil end
                local value = gained > 0 and (gained + rest) or -rest
                if value > best then best = value end
            end
        end
        memo[remaining] = best
        return best
    end
    local remaining = (1 << #free) - 1
    local bestEdge, best = free[1], -math.huge
    for _, edge in ipairs(free) do
        local bit, gained = bits[edge], 0
        for _, b in ipairs(board.edgeBoxes[edge]) do
            if remaining & masks[b] == bit then gained = gained + 1 end
        end
        local rest = solve(remaining ~ bit)
        if rest == nil then return nil end
        local value = gained > 0 and (gained + rest) or -rest
        if value > best then bestEdge, best = edge, value end
    end
    return bestEdge
end

function Endgame.berlekampSolver(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    local comps = Components.cold(board)
    local represented = 0
    for _, comp in ipairs(comps) do represented = represented + comp.len end
    local remaining = #board.boxEdges - board.score[1] - board.score[2]
    if represented ~= remaining then
        return endgameEdgeSearch(board, snapshot.free, nowMs() + EXPERT_EXACT_BUDGET_MS)
            or approximateJunctionOpening(board, snapshot.free)
    end
    if #comps == 0 then
        return snapshot.free[math.random(#snapshot.free)]
    end

    local bestScore, bestComps = -math.huge, {}
    local typeScores = {}

    for i, comp in ipairs(comps) do
        yieldIfBudgetExceeded()
        -- Removing equivalent components leaves the same multiset. Share the
        -- value, but retain physical components for the opening-edge tie-break.
        local kind = comp.isLoop and -comp.len or comp.len
        local worst = typeScores[kind]
        if worst == nil then
            local rest = {}
            for j, c in ipairs(comps) do
                if j ~= i then rest[#rest + 1] = c end
            end
            local nextVal = endgameFuture(rest)
            worst = componentOpenValue(comp.len, comp.isLoop, nextVal)
            typeScores[kind] = worst
        end

        if worst > bestScore then
            bestScore, bestComps = worst, { comp }
        elseif worst == bestScore then
            bestComps[#bestComps + 1] = comp
        end
    end

    if #bestComps == 0 then
        return Endgame.componentHeuristic(board, snapshot)
    end

    -- Deterministic tie-break: among equal-value cold openings, give the
    -- opponent the smallest component first. This avoids "Expert" choosing an
    -- equal-margin line that visibly hands over the longest loop/chain.
    local choice = bestComps[1]
    for i = 2, #bestComps do
        local comp = bestComps[i]
        if comp.len < choice.len
        or (comp.len == choice.len and comp.edge < choice.edge)
        then
            choice = comp
        end
    end
    return coldOpeningEdge(board, choice)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. SEARCH-BASED EXPERT SUPPORT
-- ═══════════════════════════════════════════════════════════════════════════

local Expert = {}

local function scoreDiff(board)
    local p = board.currentPlayer
    return board.score[p] - board.score[3 - p]
end

local function applyMove(board, edge)
    -- Defensive: refuse to "apply" an already-filled edge. If we did, the
    -- corresponding undoMove would nil out edgesFilled[edge] and erase a
    -- real, previously-played move. Return nil so undoMove becomes a no-op.
    if board.edgesFilled[edge] then return nil end
    local _t = Ai.debugLogging and profClock() or nil

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
    if _t then
        profApplyS     = profApplyS + (profClock() - _t)
        profApplyCalls = profApplyCalls + 1
    end
    return state
end

local function undoMove(board, state)
    if not state then return end  -- applyMove refused; nothing to roll back
    local _t = Ai.debugLogging and profClock() or nil
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
    if _t then profApplyS = profApplyS + (profClock() - _t) end
end

-- Find every active "hot" component: connected 2-/3-sided boxes containing
-- at least one 3-sided box. Capture evaluation must consider all of them;
-- treating only the first hot area as active can misclassify another live
-- closer as cold and badly overrate fake double-crosses.
local function collectHotComponents(board)
    local _t = Ai.debugLogging and profClock() or nil
    local boxEdges    = board.boxEdges
    local edgeBoxes   = board.edgeBoxes
    local edgesFilled = board.edgesFilled
    local numBoxes    = #boxEdges

    local fillCache = {}
    local function fillCount(boxId)
        local c = fillCache[boxId]
        if c then return c end
        c = 0
        local edges = boxEdges[boxId]
        for j = 1, #edges do
            if edgesFilled[edges[j]] then c = c + 1 end
        end
        fillCache[boxId] = c
        return c
    end

    local comps, seen = {}, {}
    for seed = 1, numBoxes do
        if not seen[seed] and fillCount(seed) == 3 then
            local hot = { [seed] = true }
            local count = 1
            local stack = { seed }
            seen[seed] = true

            -- Walk every 2- or 3-filled box reachable through unfilled shared
            -- edges. Multiple 3-sided boxes in the same region are one hot
            -- component; disconnected 3-sided boxes become separate components.
            while #stack > 0 do
                local cur = stack[#stack]
                stack[#stack] = nil
                local edges = boxEdges[cur]
                for j = 1, #edges do
                    local e = edges[j]
                    if not edgesFilled[e] then
                        local adj = edgeBoxes[e]
                        if adj then
                            for k = 1, #adj do
                                local nb = adj[k]
                                if not seen[nb] then
                                    local f = fillCount(nb)
                                    if f == 2 or f == 3 then
                                        seen[nb] = true
                                        hot[nb] = true
                                        count = count + 1
                                        stack[#stack + 1] = nb
                                    end
                                end
                            end
                        end
                    end
                end
            end
            comps[#comps + 1] = { len = count, boxes = hot }
        end
    end

    if _t then
        profHotS     = profHotS + (profClock() - _t)
        profHotCalls = profHotCalls + 1
    end
    return comps
end

-- Whether the consumer of `hotBoxes` has a non-claiming move available
-- within the hot region. The DX (double-cross) play exists only if there's
-- at least one unfilled edge in the hot region that, if played, doesn't
-- close any box (i.e., neither neighbor is already 3-sided).
--
-- The pathological case this guards against: a "ready 2-domino" hot region
-- (two adjacent 3-sided boxes connected by one unfilled edge), which arises
-- right after a DX play. Geometrically the consumer has no DX option there;
-- their only move closes both boxes. Without this check the Berlekamp
-- formula would happily apply `dx = hotLen-4-cv` and conclude the consumer
-- can hand the domino back — they can't.
local function hotDXCandidates(board, hotBoxes)
    local edgesFilled = board.edgesFilled
    local boxEdges    = board.boxEdges
    local edgeBoxes   = board.edgeBoxes
    local seenEdges   = {}
    local candidates  = {}
    for boxId = 1, #boxEdges do
        if hotBoxes[boxId] then
            local edges = boxEdges[boxId]
            for j = 1, #edges do
                local e = edges[j]
                if not edgesFilled[e] and not seenEdges[e] then
                    seenEdges[e] = true
                    local adj = edgeBoxes[e] or {}
                    local closes = false
                    for k = 1, #adj do
                        local nb = adj[k]
                        local fc = 0
                        local nbEdges = boxEdges[nb]
                        for m = 1, #nbEdges do
                            if edgesFilled[nbEdges[m]] then fc = fc + 1 end
                        end
                        if fc == 3 then closes = true; break end
                    end
                    if not closes then candidates[#candidates + 1] = e end
                end
            end
        end
    end
    return candidates
end

local function addHotDXCandidates(board, candidates, seen)
    for _, comp in ipairs(collectHotComponents(board)) do
        -- Take surplus boxes before handing back two from an opened chain
        -- or four from an opened loop. An early cut can let the opponent
        -- return the handout and keep control instead of taking everything.
        local ends = 0
        for box in pairs(comp.boxes) do
            if EdgeUtils.countFilled(board, board.boxEdges[box]) == 3 then ends = ends + 1 end
        end
        if (comp.len == 2 and ends == 1) or (comp.len == 4 and ends == 2) then
            for _, edge in ipairs(hotDXCandidates(board, comp.boxes)) do
                if not seen[edge] then
                    candidates[#candidates + 1] = edge
                    seen[edge] = true
                end
            end
        end
    end
end

local function onlyHotCapturesRemain(board)
    local hotComps = collectHotComponents(board)
    if #hotComps == 0 then return false end

    local excluded = {}
    for _, comp in ipairs(hotComps) do
        for boxId in pairs(comp.boxes) do
            excluded[boxId] = true
        end
    end
    return #Components.cold(board, excluded) == 0
end

local function collectClosers(board)
    if not (board and board.boxEdges and board.edgesFilled) then
        return {}
    end
    local closers, seen = {}, {}
    local boxEdges = board.boxEdges
    local edgesFilled = board.edgesFilled
    for boxId = 1, #boxEdges do
        local edges = boxEdges[boxId]
        local filled, freeEdge = 0, nil
        for i = 1, #edges do
            local edge = edges[i]
            if edgesFilled[edge] then
                filled = filled + 1
            else
                freeEdge = edge
            end
        end
        if filled == 3 and freeEdge and not seen[freeEdge] then
            closers[#closers + 1] = freeEdge
            seen[freeEdge] = true
        end
    end
    return closers
end

local function captureKey(board, allowDX)
    local bytes = {
        allowDX and 1 or 0,
        board.currentPlayer,
        board.score[1],
        board.score[2]
    }
    for edge = 1, #board.edgeToCoord do
        bytes[#bytes + 1] = board.edgesFilled[edge] and 1 or 0
    end
    return string.char(table.unpack(bytes))
end

local function evaluateColdTerminal(board)
    local startMs = Ai.debugLogging and nowMs() or nil
    local comps = Components.cold(board)
    local coldValue = 0
    if #comps > 0 then
        coldValue = endgameFuture(comps)
    end
    if startMs then
        local elapsed = nowMs() - startMs
        profSolveCalls   = profSolveCalls + 1
        profSolveTotalMs = profSolveTotalMs + elapsed
        if profSolveCalls == 1 then profSolveFirstMs = elapsed end
    end

    return scoreDiff(board) + coldValue
end

local function evaluateGreedyCaptures(board)
    local states = {}
    while not board:isGameOver() do
        local closers = collectClosers(board)
        if #closers == 0 then break end
        local state = applyMove(board, closers[1])
        if not state then break end
        states[#states + 1] = state
    end

    local score = board:isGameOver() and scoreDiff(board) or evaluateColdTerminal(board)
    for i = #states, 1, -1 do
        undoMove(board, states[i])
    end
    return score
end

-- Returns the value of the position to the CURRENT player. If any boxes are
-- immediately claimable, first resolve the real capture frontier until the
-- board is quiet. Legal double-cross moves are considered at the frontier,
-- then the resulting forced captures are resolved greedily; this catches
-- multi-hot sweeps without expanding every nested double-cross permutation.
local function evaluateTerminal(board, allowDX)
    if board:isGameOver() then
        return scoreDiff(board)
    end

    local closers = collectClosers(board)
    if #closers == 0 then
        return evaluateColdTerminal(board)
    end

    local key = captureKey(board, allowDX ~= false)
    local cached = captureMemo[key]
    if cached ~= nil then return cached end

    if allowDX == false then
        local score = evaluateGreedyCaptures(board)
        captureMemo[key] = score
        return score
    end

    local rootPlayer = board.currentPlayer
    local candidates, seen = {}, {}
    for _, edge in ipairs(closers) do
        candidates[#candidates + 1] = edge
        seen[edge] = true
    end
    if allowDX ~= false then
        addHotDXCandidates(board, candidates, seen)
    end

    local best = -math.huge
    for _, edge in ipairs(candidates) do
        yieldIfBudgetExceeded()
        local state = applyMove(board, edge)
        if state then
            local score = evaluateTerminal(board, false)
            if board.currentPlayer ~= rootPlayer then
                score = -score
            end
            undoMove(board, state)
            if score > best then best = score end
        end
    end

    if best == -math.huge then
        best = evaluateColdTerminal(board)
    end
    captureMemo[key] = best
    return best
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

local function evaluateForPlayer(board, rootPlayer, allowDX)
    local value = evaluateTerminal(board, allowDX)
    if board.currentPlayer ~= rootPlayer then
        value = -value
    end
    return value
end

-- Evaluate one safe move, optionally checking the opponent's best safe
-- replies. A zero peerLimit keeps the cheaper one-ply search on big boards.
local function evaluateSafeEdge(board, edge, rootPlayer, peerLimit)
    yieldIfBudgetExceeded()
    local state = applyMove(board, edge)
    local score = evaluateForPlayer(board, rootPlayer)
    if peerLimit > 0 then
        local peers = selectTopSafes(board, EdgeUtils.classify(board).safes, peerLimit)
        for _, peerEdge in ipairs(peers) do
            local peerState = applyMove(board, peerEdge)
            local peerScore = evaluateForPlayer(board, rootPlayer)
            undoMove(board, peerState)
            if peerScore < score then score = peerScore end
        end
    end
    undoMove(board, state)
    return score
end

local SAFE_EVAL_LIMIT     <const> = 4
local SAFE_AGGRO_LIMIT    <const> = 2
local AGGRESSION_TEMP     <const> = 2.0
local CLOSER_EVAL_LIMIT   <const> = 5
local SAFE_DEPTH_MAX_DOTS <const> = 6
local SACRIFICE_LIMIT     <const> = 4    -- a touch wider than the original 3
local SACRIFICE_THRESHOLD <const> = 0.75
local SACRIFICE_SAFE_CAP  <const> = 2

local function minMaxScale(value, minValue, maxValue)
    if maxValue <= minValue then return 0.5 end
    return (value - minValue) / (maxValue - minValue)
end

local function expertAggressionFeatures(board, edge)
    local pressure = 0
    for _, boxId in ipairs(board.edgeBoxes[edge] or {}) do
        if EdgeUtils.countFilled(board, board.boxEdges[boxId]) == 1 then
            pressure = pressure + 1
        end
    end
    return {
        centrality = centralityScore(board, edge),
        pressure   = pressure,
        border     = (#(board.edgeBoxes[edge] or {}) == 1) and 1 or 0
    }
end

local function attachExpertAggressionScores(board, candidates)
    local mins, maxs = {}, {}
    for _, candidate in ipairs(candidates) do
        local features = expertAggressionFeatures(board, candidate.edge)
        candidate.aggressionFeatures = features
        for k, v in pairs(features) do
            mins[k] = mins[k] and math.min(mins[k], v) or v
            maxs[k] = maxs[k] and math.max(maxs[k], v) or v
        end
    end

    for _, candidate in ipairs(candidates) do
        local features = candidate.aggressionFeatures
        local centrality = minMaxScale(features.centrality, mins.centrality, maxs.centrality)
        local pressure   = minMaxScale(features.pressure,   mins.pressure,   maxs.pressure)
        local border     = minMaxScale(features.border,     mins.border,     maxs.border)
        candidate.aggression = 0.7 * centrality
                             + 0.4 * pressure
                             - 0.2 * border
    end
end

local function addUniqueEdge(edges, seen, edge)
    if not seen[edge] then
        edges[#edges + 1] = edge
        seen[edge] = true
    end
end

local function selectExpertSafes(board, safes)
    local selected, seen = {}, {}
    for _, edge in ipairs(selectTopSafes(board, safes, SAFE_EVAL_LIMIT)) do
        addUniqueEdge(selected, seen, edge)
    end

    local aggressiveCandidates = {}
    for _, edge in ipairs(safes) do
        aggressiveCandidates[#aggressiveCandidates + 1] = { edge = edge }
    end
    attachExpertAggressionScores(board, aggressiveCandidates)
    table.sort(aggressiveCandidates, function(a, b)
        return a.aggression > b.aggression
    end)

    for i = 1, math.min(SAFE_AGGRO_LIMIT, #aggressiveCandidates) do
        addUniqueEdge(selected, seen, aggressiveCandidates[i].edge)
    end
    return selected
end

local function pickExpertAggressiveTie(board, candidates)
    local bestScore = -math.huge
    for _, candidate in ipairs(candidates) do
        if candidate.score > bestScore then bestScore = candidate.score end
    end

    local pool = {}
    for _, candidate in ipairs(candidates) do
        if candidate.score == bestScore then
            pool[#pool + 1] = candidate
        end
    end
    if #pool <= 1 then return pool[1], bestScore end

    attachExpertAggressionScores(board, pool)
    local maxAggression = -math.huge
    for _, candidate in ipairs(pool) do
        if candidate.aggression > maxAggression then
            maxAggression = candidate.aggression
        end
    end

    local total = 0
    for _, candidate in ipairs(pool) do
        candidate.weight = math.exp((candidate.aggression - maxAggression) / AGGRESSION_TEMP)
        total = total + candidate.weight
    end

    local draw = math.random() * total
    for _, candidate in ipairs(pool) do
        draw = draw - candidate.weight
        if draw <= 0 then return candidate, bestScore end
    end
    return pool[#pool], bestScore
end

function Expert.chooseMove(board, snapshot)
    snapshot = snapshot or EdgeUtils.classify(board)
    local rootPlayer = board.currentPlayer

    -- Mixed positions need real move order, not independent-chain estimates.
    -- Keep the faster component solver for already-cold endgames.
    local exactLimit = (dotsai and dotsai.exact_begin and dotsai.exact_step) and 18 or 12
    if #snapshot.free <= exactLimit and (#snapshot.closers > 0 or #snapshot.safes > 0) then
        local edge = endgameEdgeSearch(board, snapshot.free, nowMs() + EXPERT_EXACT_BUDGET_MS)
        if edge then return edge end
    end

    if #snapshot.closers > 0 then
        local midChain = (board.chainLen or 0) > 0
        if onlyHotCapturesRemain(board) then
            return snapshot.closers[1]
        end

        local bestEdge, bestScore = nil, -math.huge
        -- 1) Greedy chain continuation: take a closer.
        local candidates = snapshot.closers
        if midChain then
            candidates = { snapshot.closers[1] }
        elseif #candidates > CLOSER_EVAL_LIMIT then
            candidates = selectTopSafes(board, candidates, CLOSER_EVAL_LIMIT)
        end
        for _, edge in ipairs(candidates) do
            yieldIfBudgetExceeded()
            local state = applyMove(board, edge)
            local score = evaluateForPlayer(board, rootPlayer, not midChain)
            undoMove(board, state)
            if score > bestScore then
                bestScore, bestEdge = score, edge
            end
        end

        -- 2) Double-cross setup: try non-closing edges in the hot region.
        -- This includes cold entry edges connected to a current closer.
        local dxCandidates, seenDX = {}, {}
        addHotDXCandidates(board, dxCandidates, seenDX)

        local dxLimit = math.min(midChain and 1 or 4, #dxCandidates)
        for i = 1, dxLimit do
            yieldIfBudgetExceeded()
            local edge = dxCandidates[i]
            local state = applyMove(board, edge)
            local score = evaluateForPlayer(board, rootPlayer, false)
            undoMove(board, state)
            if score >= bestScore then
                bestScore, bestEdge = score, edge
            end
        end

        return bestEdge
    end

    local safeCount = #snapshot.safes

    if safeCount > 0 then
        local peerLimit = (board.DOTS <= SAFE_DEPTH_MAX_DOTS) and SAFE_EVAL_LIMIT or 0
        local safeBestEdge, safeBestScore = nil, -math.huge
        local safeCandidates = selectExpertSafes(board, snapshot.safes)
        local safeEvaluations = {}
        for _, edge in ipairs(safeCandidates) do
            local sc = evaluateSafeEdge(board, edge, rootPlayer, peerLimit)
            safeEvaluations[#safeEvaluations + 1] = { edge = edge, score = sc }
        end
        local safeBest = pickExpertAggressiveTie(board, safeEvaluations)
        if safeBest then
            safeBestScore, safeBestEdge = safeBest.score, safeBest.edge
        end

        -- Conservative policy: only consider a sacrifice when safe choices
        -- are scarce and evaluate unfavourably. Skip work we cannot select.
        local allowSacrifice = (safeCount <= SACRIFICE_SAFE_CAP)
            and (not safeBestEdge or safeBestScore < 0)
        if safeBestEdge and not allowSacrifice then return safeBestEdge end

        local safeLookup = {}
        for _, e in ipairs(snapshot.safes) do safeLookup[e] = true end

        local sacrifices = {}
        local comps = Components.cold(board)
        for _, comp in ipairs(comps) do
            if comp.edge and not safeLookup[comp.edge] then
                sacrifices[#sacrifices + 1] = { edge = comp.edge, len = comp.len }
            end
        end
        -- Evaluate the SHORTEST sacrifices first: they're cheaper to give up
        -- and are almost always the right hand-out when one is needed. The
        -- SACRIFICE_SAFE_CAP / SACRIFICE_THRESHOLD gates below still guard
        -- against picking one in the wrong situation.
        if #sacrifices > 1 then
            table.sort(sacrifices, function(a, b) return a.len < b.len end)
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
        local peerLimit = (board.DOTS <= HARD_DEPTH2_MAX_DOTS) and HARD_SAFE_LIMIT or 0
        local candidates = selectTopSafes(board, snapshot.safes, HARD_SAFE_LIMIT)

        local evaluations = {}
        for _, edge in ipairs(candidates) do
            local score = evaluateSafeEdge(board, edge, rootPlayer, peerLimit)
            evaluations[#evaluations + 1] = { edge = edge, score = score }
        end
        local best = Heuristics.pickRandomBestByScore(evaluations)
        if best then return best.edge end
    end

    return Endgame.componentHeuristic(board, snapshot)
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
    return Endgame.componentHeuristic(board, snapshot)
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
    captureMemo = {}
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

-- `midChain` true ⇒ this is a forced chain-continuation move; skip the floor.
function Ai.beginChooseMove(board, midChain)
    Ai.cancel()
    solveMemo = {}
    captureMemo = {}
    if dotsai and dotsai.solve_reset then dotsai.solve_reset() end
    profSolveCalls, profSolveTotalMs, profSolveFirstMs, profApplyCalls = 0, 0, 0, 0
    profApplyS = 0
    profClassifyCalls, profClassifyS = 0, 0
    profColdCalls, profColdS = 0, 0
    profHotCalls, profHotS = 0, 0
    runtime.board   = board
    runtime.startMs = nowMs()
    runtime.minDelayMs = midChain and 0 or AI_MIN_DELAY_MS
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
            if Ai.debugLogging then
                print("[AI] coroutine error: " .. tostring(val))
            end
            -- Coroutine errored; fall back to any free edge.
            local frees = runtime.board:listFreeEdges()
            runtime.result = frees[math.random(#frees)] or 1
        elseif coroutine.status(runtime.coro) == "dead" then
            runtime.result = val
            if Ai.debugLogging then
                local thinkMs = nowMs() - runtime.startMs
                local b = runtime.board
                local free = #b:listFreeEdges()
                local kernel = (dotsai and dotsai.solve) and "C" or "L"
                print(string.format(
                    "[AI %s] %s %dx%d  edge=%s  think=%dms  apply=%d/%.1fms  classify=%d/%.1fms  cold=%d/%.1fms  hot=%d/%.1fms  solve=%d/%dms(first=%dms)  free=%d  heap=%.1fKB",
                    kernel,
                    Ai.difficulty, b.DOTS, b.DOTS,
                    tostring(runtime.result),
                    thinkMs,
                    profApplyCalls,    profApplyS    * 1000,
                    profClassifyCalls, profClassifyS * 1000,
                    profColdCalls,     profColdS     * 1000,
                    profHotCalls,      profHotS      * 1000,
                    profSolveCalls,    profSolveTotalMs, profSolveFirstMs,
                    free,
                    collectgarbage("count")
                ))
            end
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
