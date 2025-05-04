-- ai.lua
-- AI module for Dots & Boxes with three difficulty levels: "easy", "medium", "hard".
--   • Easy   – close boxes; else random safe; else random.
--   • Medium – same priorities, but orders safe edges by heuristics.
--   • Hard   – plays Medium until no safe edges remain, then invokes an
--              end‑game solver based on chain/loop decomposition and
--              alpha–beta search over components (fast <1 ms on Playdate).

local Ai = {}
Ai.difficulty = "medium"   -- default; caller may override via Ai.setDifficulty

-- ---------------------------------------------------------------------------
-- Utility helpers (shared) ---------------------------------------------------
-- ---------------------------------------------------------------------------
local function countFilled(board, edgeList)
    local n = 0
    for _, e in ipairs(edgeList) do if board.edgesFilled[e] then n = n + 1 end end
    return n
end

local function listFreeEdges(board)
    return board:listFreeEdges()        -- Board helper provided elsewhere
end

local function edgesThatCloseBox(board)
    local list = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local adj = board.edgeBoxes[e]
        if adj then
            for _, b in ipairs(adj) do
                if countFilled(board, board.boxEdges[b]) == 3 then
                    table.insert(list, e); break
                end
            end
        end
    end
    return list
end

local function safeEdges(board)
    local list = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local ok = true
        local adj = board.edgeBoxes[e]
        if adj then
            for _, b in ipairs(adj) do
                if countFilled(board, board.boxEdges[b]) == 2 then ok = false; break end
            end
        end
        if ok then table.insert(list, e) end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Medium‑level tie‑break heuristics -----------------------------------------
-- ---------------------------------------------------------------------------
local function scoreSafeEdge(board, e)
    local adj = board.edgeBoxes[e]
    local maxFilled, borderBonus = 0, 0
    if adj then
        if #adj == 1 then borderBonus = 3 end  -- perimeter edge preferred
        for _, b in ipairs(adj) do
            local f = countFilled(board, board.boxEdges[b])
            if f > maxFilled then maxFilled = f end
        end
    end
    return borderBonus + maxFilled
end

local function bestSafeEdge(board, safelist)
    table.sort(safelist, function(a, b)
        local sa, sb = scoreSafeEdge(board, a), scoreSafeEdge(board, b)
        return (sa == sb) and (a < b) or (sa > sb)
    end)
    return safelist[1]
end

-- ---------------------------------------------------------------------------
-- HARD difficulty: chain/loop end‑game solver -------------------------------
-- ---------------------------------------------------------------------------
-- Each component is { len = n, edge = someEmptyEdge, isLoop = true/false }

local function collectHotComponents(board)
    local comps, visitedBox = {}, {}
    local boxEdges, edgeBoxes = board.boxEdges, board.edgeBoxes

    local function dfs(boxIdx, comp)
        visitedBox[boxIdx] = true
        comp.len = comp.len + 1
        local unfilledEdge
        for _, e in ipairs(boxEdges[boxIdx]) do
            if not board.edgesFilled[e] then unfilledEdge = e; break end
        end
        if not comp.edge then comp.edge = unfilledEdge end
        -- adjacent box across that unfilled edge (if any)
        local adj = edgeBoxes[unfilledEdge]
        if #adj == 2 then
            local other = (adj[1] == boxIdx) and adj[2] or adj[1]
            if countFilled(board, boxEdges[other]) == 3 and not visitedBox[other] then
                dfs(other, comp)
            else
                comp.ends = (comp.ends or 0) + 1  -- found endpoint of chain
            end
        else
            -- edge on border → endpoint
            comp.ends = (comp.ends or 0) + 1
        end
    end

    for b = 1, #boxEdges do
        if not visitedBox[b] and countFilled(board, boxEdges[b]) == 3 then
            local comp = { len = 0, edge = nil, ends = 0 }
            dfs(b, comp)
            comp.isLoop = (comp.ends == 0)
            table.insert(comps, comp)
        end
    end
    return comps
end

-- Convert component to its *value* when you are forced to open it
local function componentValue(comp)
    if comp.isLoop then return -1 end           -- opponent gets 1
    return 4 - comp.len                         -- chain parity value
end

-- Build multiset key for memoization (sorted values string)
local function multisetKey(values)
    table.sort(values, function(a, b) return a > b end)
    return table.concat(values, ",")
end

-- Negamax with alpha–beta pruning over component choices --------------------
local function negamax(values, cache)
    local key = multisetKey(values)
    local cached = cache[key]
    if cached then return cached end
    local best = -64
    for i, v in ipairs(values) do
        values[i] = values[#values]; values[#values] = nil  -- pop i
        local child = -negamax(values, cache) - v
        if child > best then best = child end
        table.insert(values, v); values[i], values[#values] = values[#values], values[i]
        if best >= 0 then break end  -- alpha=0, beta=64 → prune when ≥0
    end
    cache[key] = best
    return best
end

local function chooseHardMove(board)
    -- first, replicate easy/medium frontline logic -----------------
    local closers = edgesThatCloseBox(board)
    if #closers > 0 then return closers[1] end
    local safe = safeEdges(board)
    if #safe > 0 then return bestSafeEdge(board, safe) end

    -- hot position: run solver ------------------------------------
    local comps = collectHotComponents(board)
    if #comps == 0 then                     -- fallback safety
        local free = listFreeEdges(board)
        return (#free > 0) and free[1] or nil
    end

    -- Build value list
    local vals, edges = {}, {}
    for i, c in ipairs(comps) do
        vals[i]  = componentValue(c)
        edges[i] = c.edge
    end

    -- Evaluate each choice
    local cache, bestScore, bestIdx = {}, -64, 1
    for i, v in ipairs(vals) do
        vals[i] = vals[#vals]; vals[#vals] = nil
        local score = -negamax(vals, cache) - v
        table.insert(vals, v); vals[i], vals[#vals] = vals[#vals], vals[i]
        if score > bestScore then bestScore, bestIdx = score, i end
    end
    return edges[bestIdx]
end

-- ---------------------------------------------------------------------------
-- Public API ----------------------------------------------------------------
-- ---------------------------------------------------------------------------
function Ai.setDifficulty(level)
    if level == "easy" or level == "medium" or level == "hard" then
        Ai.difficulty = level
    else
        Ai.difficulty = "easy"  -- default fallback
    end
end

function Ai.chooseMove(board)
    if Ai.difficulty == "hard" then
        return chooseHardMove(board)
    end

    -- shared easy/medium logic ------------------------------------
    local closers = edgesThatCloseBox(board)
    if #closers > 0 then return closers[1] end

    local safe = safeEdges(board)
    if #safe > 0 then
        return (Ai.difficulty == "medium") and bestSafeEdge(board, safe)
                                             or safe[math.random(#safe)]
    end

    local free = listFreeEdges(board)
    return (#free > 0) and free[math.random(#free)] or nil
end

return Ai
