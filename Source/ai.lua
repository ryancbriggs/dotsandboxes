-- ai.lua
-- Smarter AI module for Dots & Boxes with two difficulty levels: 'easy' and 'medium'.
-- Easy: closes boxes when possible, otherwise plays a safe edge, else random.
-- Medium: same priorities, but orders safe edges by positional/structural heuristics.

local Ai = {}
Ai.difficulty = "medium"      -- default; caller may change with Ai.setDifficulty

-- ---------------------------------------------------------------------------
-- Utility helpers
-- ---------------------------------------------------------------------------

-- Count how many of the edges in edgeList are already filled.
local function countFilled(board, edgeList)
    local n = 0
    for _, e in ipairs(edgeList) do
        if board.edgesFilled[e] then n = n + 1 end
    end
    return n
end

-- Return a list of all free edges.
local function listFreeEdges(board)
    return board:listFreeEdges()   -- Board provides this helper.
end

-- Return edges that, if played, immediately complete at least one box.
local function edgesThatCloseBox(board)
    local list = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local adj = board.edgeBoxes[e]
        if adj then
            for _, b in ipairs(adj) do
                if countFilled(board, board.boxEdges[b]) == 3 then
                    table.insert(list, e)
                    break
                end
            end
        end
    end
    return list
end

-- Return edges that do **not** create a 3‑edge box for the opponent.
-- I.e. after this edge is filled, no adjacent box will have exactly 3 filled edges.
local function safeEdges(board)
    local list = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local safe = true
        local adj = board.edgeBoxes[e]
        if adj then
            for _, b in ipairs(adj) do
                local filled = countFilled(board, board.boxEdges[b])
                if filled == 2 then  -- would become 3 after playing e
                    safe = false
                    break
                end
            end
        end
        if safe then table.insert(list, e) end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Medium‑level tie‑break heuristics
-- ---------------------------------------------------------------------------

-- How “good” is a safe edge?  Larger is better.
local function scoreSafeEdge(board, e)
    local adj = board.edgeBoxes[e]
    local maxFilled = 0
    local borderBonus = 0
    if adj then
        if #adj == 1 then borderBonus = 3 end   -- perimeter edge
        for _, b in ipairs(adj) do
            local filled = countFilled(board, board.boxEdges[b])
            if filled > maxFilled then maxFilled = filled end
        end
    end
    return borderBonus + maxFilled  -- simple linear weight
end

local function bestSafeEdge(board, safeList)
    table.sort(safeList, function(a, b)
        local sa = scoreSafeEdge(board, a)
        local sb = scoreSafeEdge(board, b)
        if sa == sb then return a < b else return sa > sb end
    end)
    return safeList[1]
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function Ai.setDifficulty(level)
    if level == "easy" or level == "medium" then
        Ai.difficulty = level
    else
        -- treat any unknown level as easy for forward compatibility
        Ai.difficulty = "easy"
    end
end

function Ai.chooseMove(board)
    local closers = edgesThatCloseBox(board)
    if #closers > 0 then
        -- Pick arbitrarily among closers (could add tie‑break later)
        return closers[1]
    end

    local safe = safeEdges(board)
    if #safe > 0 then
        if Ai.difficulty == "medium" then
            return bestSafeEdge(board, safe)
        else   -- easy
            return safe[math.random(#safe)]
        end
    end

    -- No safe move exists: just pick any free edge
    local free = listFreeEdges(board)
    if #free == 0 then return nil end
    return free[math.random(#free)]
end

return Ai
