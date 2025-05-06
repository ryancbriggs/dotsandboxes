-- ai.lua
-- AI module for Dots & Boxes with four difficulty levels
--   · Easy    – 5% random blunders; otherwise closes boxes, random safe.
--   · Medium  – depth‑2 safe‑edge heuristic.
--   · Hard    – Medium until few safe edges remain, then negamax chain solver.
--   · Expert  – treads Medium until the first real chain or split, then global Berlekamp Nim‑sum.

local Ai = {}
Ai.difficulty = "medium"

-- Basic helpers -------------------------------------------------------------
local function randomChance(p) return math.random() < p end
local function countFilled(board, list)
    local n = 0
    for _, e in ipairs(list) do if board.edgesFilled[e] then n = n + 1 end end
    return n
end
local function listFreeEdges(board) return board:listFreeEdges() end

-- Edge classifiers ----------------------------------------------------------
local function edgesThatCloseBox(board)
    local out = {}
    for _, e in ipairs(listFreeEdges(board)) do
        for _, b in ipairs(board.edgeBoxes[e] or {}) do
            if countFilled(board, board.boxEdges[b]) == 3 then
                table.insert(out, e) break
            end
        end
    end
    return out
end

local function safeEdges(board)
    local out = {}
    for _, e in ipairs(listFreeEdges(board)) do
        local ok = true
        for _, b in ipairs(board.edgeBoxes[e] or {}) do
            if countFilled(board, board.boxEdges[b]) == 2 then ok = false; break end
        end
        if ok then table.insert(out, e) end
    end
    return out
end

-- Hot edges (creates 3-sided box) ------------------------------------------
local function hotEdges(board)
    local out = {}
    for _, e in ipairs(listFreeEdges(board)) do
        for _, b in ipairs(board.edgeBoxes[e] or {}) do
            if countFilled(board, board.boxEdges[b]) == 2 then
                table.insert(out, e) break
            end
        end
    end
    return out
end

-- Chain/loop detection ------------------------------------------------------
local function collectHotComponents(board)
    local comps, seen = {}, {}
    local BE, EB = board.boxEdges, board.edgeBoxes
    local function dfs(b, comp)
        seen[b] = true; comp.len = comp.len + 1
        local empty
        for _, e in ipairs(BE[b]) do if not board.edgesFilled[e] then empty = e; break end end
        if not comp.edge then comp.edge = empty end
        local adj = EB[empty] or {}
        if #adj == 2 then
            local nb = (adj[1]==b) and adj[2] or adj[1]
            if countFilled(board, BE[nb])==3 and not seen[nb] then dfs(nb, comp)
            else comp.ends = (comp.ends or 0) + 1 end
        else comp.ends = (comp.ends or 0) + 1 end
    end
    for i=1,#board.boxEdges do
        if not seen[i] and countFilled(board, board.boxEdges[i])==3 then
            local c={len=0, edge=nil, ends=0}
            dfs(i,c)
            c.isLoop = (c.ends==0)
            table.insert(comps, c)
        end
    end
    return comps
end

-- Medium safe-edge heuristic ------------------------------------------------
local function scoreSafeEdge(board,e)
    local adj = board.edgeBoxes[e] or {}
    local bonus, maxF = 0, 0
    if #adj == 1 then bonus = 3 end
    for _, b in ipairs(adj) do
        local f = countFilled(board, board.boxEdges[b])
        if f > maxF then maxF = f end
    end
    return bonus + maxF
end

local function bestSafeEdge(board,list)
    local bestE, bestS = list[1], -math.huge
    for _, e in ipairs(list) do
        board.edgesFilled[e] = true
        local hotCount = #collectHotComponents(board)
        board.edgesFilled[e] = nil
        local s = -hotCount + scoreSafeEdge(board,e)
        if s > bestS then bestS, bestE = s, e end
    end
    return bestE
end

-- Negamax chain solver (Hard) ------------------------------------------------
local function compValue(c) return c.isLoop and -1 or (4 - c.len) end
local function multisetKey(vals)
    table.sort(vals, function(a,b) return a>b end)
    return table.concat(vals, ",")
end
local function negamax(vals,cache)
    local key = multisetKey(vals)
    if cache[key] then return cache[key] end
    local best = -64
    for i,v in ipairs(vals) do
        local last = table.remove(vals)
        local s = -negamax(vals,cache) - v
        table.insert(vals, last)
        if s>best then best=s end
        if best>=0 then break end
    end
    cache[key] = best; return best
end
-- Negamax with random ties
local function chooseNegamaxMove(board)
  local closers = edgesThatCloseBox(board)
  if #closers > 0 then return closers[math.random(#closers)] end
  local safeList = safeEdges(board)
  if #safeList > 0 then return bestSafeEdge(board, safeList) end
  local comps = collectHotComponents(board)
  if #comps == 0 then local free = listFreeEdges(board) return free[math.random(#free)] end
  local vals, edges = {}, {}
  for i,c in ipairs(comps) do vals[i], edges[i] = compValue(c), c.edge end
  local cache, best, bestIdxs = {}, -math.huge, {}
  for i=1,#vals do
    local v = table.remove(vals, i)
    local sc = -negamax(vals,cache) - v
    table.insert(vals, i, v)
    if sc > best then best, bestIdxs = sc, {i}
    elseif sc == best then table.insert(bestIdxs, i) end
  end
  local choice = bestIdxs[ math.random(#bestIdxs) ]
  return edges[choice]
end

-- Flood-fill free-edge regions ----------------------------------------------
local function freeEdgeRegions(board)
    local all = listFreeEdges(board)
    local visited, regions = {}, {}
    local function adjacent(e1,e2)
        for _,b1 in ipairs(board.edgeBoxes[e1] or {}) do
            for _,b2 in ipairs(board.edgeBoxes[e2] or {}) do if b1==b2 then return true end end
        end
        return false
    end
    for _,e in ipairs(all) do
        if not visited[e] then
            visited[e]=true
            local stack, comp = {e}, {}
            while #stack>0 do
                local x = table.remove(stack)
                table.insert(comp, x)
                for _,y in ipairs(all) do
                    if not visited[y] and adjacent(x,y) then visited[y]=true; table.insert(stack,y) end
                end
            end
            table.insert(regions, comp)
        end
    end
    return regions
end

-- Berlekamp Nim-sum solver -----------------------------------------------
local function chooseBerlekampMove(board, comps)
    local xor = 0
    for _, c in ipairs(comps) do
        local heap = c.isLoop and 1 or (c.len - 1)
        xor = xor ~ heap
    end
    local candidates = {}
    if xor~=0 then
        for _, c in ipairs(comps) do
            if not c.isLoop then local h=c.len-1 if (h~xor)<h then table.insert(candidates,c.edge) end end
        end
    else
        for _, c in ipairs(comps) do if not c.isLoop and c.len>2 then table.insert(candidates,c.edge) end end
    end
    if #candidates>0 then return candidates[math.random(#candidates)] end
    return (comps[1] and comps[1].edge) or listFreeEdges(board)[1]
end

-- Difficulty-specific choosers --------------------------------------------
local function chooseEasyMove(board)
    if randomChance(0.05) then return listFreeEdges(board)[math.random(#listFreeEdges(board))] end
    local c=edgesThatCloseBox(board) if #c>0 then return c[1] end
    local s=safeEdges(board) if #s>0 then return s[math.random(#s)] end
    return listFreeEdges(board)[1]
end

local function chooseMediumMove(board)
    local c=edgesThatCloseBox(board) if #c>0 then return c[math.random(#c)] end
    local s=safeEdges(board) if #s>0 then return bestSafeEdge(board,s) end
    return chooseNegamaxMove(board)
end

local function chooseHardMove(board)
    local c=edgesThatCloseBox(board) if #c>0 then return c[1] end
    if #freeEdgeRegions(board)>1 then return chooseNegamaxMove(board) end
    local s=safeEdges(board) if #s>board.DOTS*board.DOTS/2 then return bestSafeEdge(board,s) end
    return chooseNegamaxMove(board)
end

-- Updated Expert chooser -----------------------------------------------
local function chooseExpertMove(board)
    -- 1) Early: no chain yet AND one region? medium play
    local comps = collectHotComponents(board)
    if #comps == 0 then
        local regs = freeEdgeRegions(board)
        if #regs == 1 then
            return chooseMediumMove(board)
        end
    end
    -- 2) Endgame: chains or split
    local finalComps = collectHotComponents(board)
    if #finalComps == 0 then
        -- split w/o chain: drain safe edges
        local s = safeEdges(board)
        if #s>0 then return bestSafeEdge(board,s) end
        return chooseNegamaxMove(board)
    end
    -- 3) True chain: Nim-sum solver
    return chooseBerlekampMove(board, finalComps)
end

-- Public API ----------------------------------------------------------------
function Ai.setDifficulty(level)
    if     level=="easy"   then Ai.difficulty="easy"
    elseif level=="medium" then Ai.difficulty="medium"
    elseif level=="hard"   then Ai.difficulty="hard"
    elseif level=="expert" then Ai.difficulty="expert"
    else   Ai.difficulty="easy" end
end

function Ai.chooseMove(board)
    if     Ai.difficulty=="easy"   then return chooseEasyMove(board)
    elseif Ai.difficulty=="medium" then return chooseMediumMove(board)
    elseif Ai.difficulty=="hard"   then return chooseHardMove(board)
    else                                return chooseExpertMove(board) end
end

return Ai
