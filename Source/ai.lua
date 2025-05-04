-- ai.lua
-- AI module for Dots & Boxes with three difficulty levels: "easy", "medium", "hard".
--   • Easy   – 5 % of the time makes a fully random blunder; otherwise
--              closes boxes, plays random safe edge, else random.
--   • Medium – same priorities, but orders safe edges by heuristics.
--   • Hard   – uses Medium until no safe edges remain, then runs an
--              end‑game chain/loop solver with alpha–beta pruning.

local Ai = {}
Ai.difficulty = "medium"   -- default; caller may override via Ai.setDifficulty

-- ---------------------------------------------------------------------------
-- Utility helpers -----------------------------------------------------------
-- ---------------------------------------------------------------------------
local function randomChance(p)   -- p in [0,1]
    return math.random() < p
end

local function countFilled(board, edgeList)
    local n = 0
    for _, e in ipairs(edgeList) do if board.edgesFilled[e] then n = n + 1 end end
    return n
end

local function listFreeEdges(board)
    return board:listFreeEdges()
end

local function edgesThatCloseBox(board)
    local list = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local adj = board.edgeBoxes[e]
        if adj then
            for _, b in ipairs(adj) do
                if countFilled(board, board.boxEdges[b]) == 3 then table.insert(list, e); break end
            end
        end
    end
    return list
end

local function safeEdges(board)
    local list = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local safe = true
        local adj  = board.edgeBoxes[e]
        if adj then
            for _, b in ipairs(adj) do
                if countFilled(board, board.boxEdges[b]) == 2 then safe = false; break end
            end
        end
        if safe then table.insert(list, e) end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Medium‑level heuristics ---------------------------------------------------
-- ---------------------------------------------------------------------------
local function scoreSafeEdge(board, e)
    local adj = board.edgeBoxes[e]; local maxF, bonus = 0, 0
    if adj then
        if #adj == 1 then bonus = 3 end   -- border edge
        for _, b in ipairs(adj) do
            local f = countFilled(board, board.boxEdges[b]); if f > maxF then maxF = f end
        end
    end
    return bonus + maxF
end

local function bestSafeEdge(board, list)
    table.sort(list, function(a,b)
        local sa, sb = scoreSafeEdge(board,a), scoreSafeEdge(board,b)
        return (sa==sb) and (a<b) or (sa>sb)
    end)
    return list[1]
end

-- ---------------------------------------------------------------------------
-- Hard difficulty: chain/loop solver ---------------------------------------
-- (unchanged from previous version) ----------------------------------------
-- ---------------------------------------------------------------------------
local function collectHotComponents(board)
    local comps, visited = {}, {}
    local boxEdges, edgeBoxes = board.boxEdges, board.edgeBoxes
    local function dfs(b, comp)
        visited[b] = true; comp.len = comp.len + 1
        local emptyEdge
        for _,e in ipairs(boxEdges[b]) do if not board.edgesFilled[e] then emptyEdge=e; break end end
        if not comp.edge then comp.edge = emptyEdge end
        local adj = edgeBoxes[emptyEdge]
        if #adj == 2 then
            local o = (adj[1]==b) and adj[2] or adj[1]
            if countFilled(board, boxEdges[o]) == 3 and not visited[o] then dfs(o,comp)
            else comp.ends = (comp.ends or 0) + 1 end
        else comp.ends = (comp.ends or 0) + 1 end -- border
    end
    for i=1,#boxEdges do
        if not visited[i] and countFilled(board, boxEdges[i])==3 then
            local c={len=0,edge=nil,ends=0}; dfs(i,c); c.isLoop=(c.ends==0); table.insert(comps,c)
        end
    end
    return comps
end

local function compValue(c) return c.isLoop and -1 or (4-c.len) end
local function multisetKey(vals)
    table.sort(vals,function(a,b)return a>b end); return table.concat(vals,",") end

local function negamax(vals, cache)
    local key = multisetKey(vals); local hit = cache[key]; if hit then return hit end
    local best = -64
    for i,v in ipairs(vals) do
        vals[i]=vals[#vals]; vals[#vals]=nil
        local score = -negamax(vals, cache) - v
        if score > best then best = score end
        table.insert(vals,v); vals[i],vals[#vals]=vals[#vals],vals[i]
        if best >= 0 then break end
    end
    cache[key]=best; return best
end

local function chooseHardMove(board)
    local closers = edgesThatCloseBox(board); if #closers>0 then return closers[1] end
    local safe    = safeEdges(board);        if #safe   >0 then return bestSafeEdge(board,safe) end

    local comps = collectHotComponents(board); if #comps==0 then
        local free=listFreeEdges(board); return (#free>0) and free[1] or nil end
    local vals,edges={},{}
    for i,c in ipairs(comps) do vals[i]=compValue(c); edges[i]=c.edge end
    local cache,bestScore,bestIdx={},-64,1
    for i,v in ipairs(vals) do
        vals[i]=vals[#vals]; vals[#vals]=nil
        local score = -negamax(vals,cache) - v
        table.insert(vals,v); vals[i],vals[#vals]=vals[#vals],vals[i]
        if score>bestScore then bestScore,bestIdx=score,i end
    end
    return edges[bestIdx]
end

-- ---------------------------------------------------------------------------
-- Public API ----------------------------------------------------------------
-- ---------------------------------------------------------------------------
function Ai.setDifficulty(level)
    if level=="easy" or level=="medium" or level=="hard" then Ai.difficulty=level else Ai.difficulty="easy" end
end

function Ai.chooseMove(board)
    -- 5 % random blunder for easy ---------------------------------
    if Ai.difficulty=="easy" and randomChance(0.05) then
        local free=listFreeEdges(board); return (#free>0) and free[math.random(#free)] or nil
    end

    if Ai.difficulty=="hard" then return chooseHardMove(board) end

    -- shared logic for easy/medium --------------------------------
    local closers = edgesThatCloseBox(board); if #closers>0 then return closers[1] end
    local safe    = safeEdges(board)
    if #safe>0 then
        return (Ai.difficulty=="medium") and bestSafeEdge(board,safe) or safe[math.random(#safe)]
    end
    local free=listFreeEdges(board); return (#free>0) and free[math.random(#free)] or nil
end

return Ai
