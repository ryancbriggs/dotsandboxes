-- ai.lua
-- AI module for Dots & Boxes with four difficulty levels
--   · Easy    – 5 % random blunders; otherwise closes boxes, random safe.
--   · Medium  – picks the *best* safe edge via a depth‑2 local heuristic.
--   · Hard    – plays as Medium until few safe edges remain, then runs a
--                negamax chain/loop solver.
--   · Expert  – plays like Medium, but as soon as any split or chain appears,
--                commits to a global Nim‑sum endgame, minimizing sacrifices.

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
  local out={}
  for _,e in ipairs(listFreeEdges(board)) do
    for _,b in ipairs(board.edgeBoxes[e] or {}) do
      if countFilled(board,board.boxEdges[b])==3 then table.insert(out,e); break end
    end
  end
  return out
end
local function safeEdges(board)
  local out={}
  for _,e in ipairs(listFreeEdges(board)) do
    local ok=true
    for _,b in ipairs(board.edgeBoxes[e] or {}) do
      if countFilled(board,board.boxEdges[b])==2 then ok=false; break end
    end
    if ok then table.insert(out,e) end
  end
  return out
end

-- Chain/loop detection ------------------------------------------------------
local function collectHotComponents(board)
  local comps, seen = {}, {}
  local boxEdges, edgeBoxes = board.boxEdges, board.edgeBoxes
  local function dfs(b, comp)
    seen[b]=true; comp.len=comp.len+1
    local empty
    for _,e in ipairs(boxEdges[b]) do if not board.edgesFilled[e] then empty=e; break end end
    if not comp.edge then comp.edge = empty end
    local adj = edgeBoxes[empty] or {}
    if #adj==2 then
      local nb = (adj[1]==b) and adj[2] or adj[1]
      if countFilled(board,boxEdges[nb])==3 and not seen[nb] then dfs(nb,comp)
      else comp.ends=(comp.ends or 0)+1 end
    else comp.ends=(comp.ends or 0)+1 end
  end
  for i=1,#boxEdges do
    if not seen[i] and countFilled(board,boxEdges[i])==3 then
      local c={len=0,edge=nil,ends=0}
      dfs(i,c)
      c.isLoop=(c.ends==0)
      table.insert(comps,c)
    end
  end
  return comps
end

-- Medium safe-edge heuristic ------------------------------------------------
local function scoreSafeEdge(board,e)
  local adj, maxF, bonus = board.edgeBoxes[e] or {}, 0, 0
  if #adj==1 then bonus=3 end
  for _,b in ipairs(adj) do local f=countFilled(board,board.boxEdges[b]); if f>maxF then maxF=f end end
  return bonus+maxF
end
local function bestSafeEdge(board,list)
  local bestE,list = list[1],list
  local bestS = -math.huge
  for _,e in ipairs(list) do
    board.edgesFilled[e]=true
    local hot = #collectHotComponents(board)
    board.edgesFilled[e]=nil
    local s = -hot + scoreSafeEdge(board,e)
    if s>bestS then bestS, bestE = s,e end
  end
  return bestE
end

-- Negamax chain-solver (Hard) ------------------------------------------------
local function compValue(c) return c.isLoop and -1 or (4-c.len) end
local function multisetKey(vals)
  table.sort(vals,function(a,b)return a>b end)
  return table.concat(vals,",")
end
local function negamax(vals,cache)
  local key=multisetKey(vals)
  if cache[key] then return cache[key] end
  local best=-64
  for i,v in ipairs(vals) do
    local last=table.remove(vals)
    local s=-negamax(vals,cache)-v
    table.insert(vals,last)
    if s>best then best=s end
    if best>=0 then break end
  end
  cache[key]=best
  return best
end
local function chooseNegamaxMove(board)
  local closers=edgesThatCloseBox(board); if #closers>0 then return closers[1] end
  local safe=safeEdges(board);   if #safe>0 then return bestSafeEdge(board,safe) end
  local comps=collectHotComponents(board)
  if #comps==0 then return listFreeEdges(board)[1] end
  local vals,edges={},{}
  for i,c in ipairs(comps) do vals[i],edges[i]=compValue(c),c.edge end
  local cache,best,bi={},-64,1
  for i,v in ipairs(vals) do
    local last=table.remove(vals)
    local s=-negamax(vals,cache)-v
    table.insert(vals,last)
    if s>best then best,bi=s,i end
  end
  return edges[bi]
end

-- Flood-fill free-edge regions ------------------------------------------------
local function freeEdgeRegions(board)
  local all=listFreeEdges(board)
  local visited,regions={},{}
  local function adjacent(e1,e2)
    for _,b1 in ipairs(board.edgeBoxes[e1] or {}) do
      for _,b2 in ipairs(board.edgeBoxes[e2] or {}) do
        if b1==b2 then return true end
      end
    end
    return false
  end
  for _,e in ipairs(all) do
    if not visited[e] then
      visited[e]=true
      local stack,comp={e},{}
      while #stack>0 do
        local x=table.remove(stack)
        table.insert(comp,x)
        for _,y in ipairs(all) do
          if not visited[y] and adjacent(x,y) then
            visited[y]=true; table.insert(stack,y)
          end
        end
      end
      table.insert(regions,comp)
    end
  end
  return regions
end

-- Chooses minimal chain-opening sacrifice when no existing chains ---------------
local function chooseMinimalSacrifice(board)
  local bestE, bestCost = nil, math.huge
  for _, e in ipairs(listFreeEdges(board)) do
    local cost=0
    for _, b in ipairs(board.edgeBoxes[e] or {}) do
      if countFilled(board, board.boxEdges[b])==2 then cost=cost+1 end
    end
    if cost<bestCost then bestCost, bestE = cost, e end
  end
  return bestE
end

-- Berlekamp Nim-sum solver (Expert) ------------------------------------------
local function chooseBerlekampMove(board, comps)
  local xor=0
  for _,c in ipairs(comps) do xor = xor ~ (c.isLoop and 1 or (c.len-1)) end
  if xor~=0 then
    for _,c in ipairs(comps) do
      if not c.isLoop then local h=c.len-1
        if (h~xor)<h then return c.edge end
      end
    end
  else
    for _,c in ipairs(comps) do if not c.isLoop and c.len>2 then return c.edge end end
  end
  return comps[1].edge
end

-- Difficulty-specific choosers ----------------------------------------------
local function chooseEasyMove(board)
  if randomChance(0.05) then
    local f=listFreeEdges(board)
    return f[math.random(#f)]
  end
  local c=edgesThatCloseBox(board); if #c>0 then return c[1] end
  local s=safeEdges(board);      if #s>0 then return s[math.random(#s)] end
  local f=listFreeEdges(board);  return f[math.random(#f)]
end

local function chooseMediumMove(board)
  local c=edgesThatCloseBox(board); if #c>0 then return c[1] end
  local s=safeEdges(board);      if #s>0 then return bestSafeEdge(board,s) end
  return chooseNegamaxMove(board)
end

local function chooseHardMove(board)
  local c=edgesThatCloseBox(board); if #c>0 then return c[1] end
  local s=safeEdges(board)
  if #s>board.DOTS*board.DOTS/2 then return bestSafeEdge(board,s) end
  return chooseNegamaxMove(board)
end

local function chooseExpertMove(board)
  -- detect any split or chain => global endgame
  local regions = freeEdgeRegions(board)
  if #regions>1 or #collectHotComponents(board)>0 then
    local comps = collectHotComponents(board)
    if #comps==0 then
      -- no existing chain but endgame triggered: sacrifice minimal chain
      return chooseMinimalSacrifice(board)
    end
    return chooseBerlekampMove(board, comps)
  end
  -- still early: play Medium
  return chooseMediumMove(board)
end

-- Public API ----------------------------------------------------------------
function Ai.setDifficulty(level)
  if level=="easy" or level=="medium" or level=="hard" or level=="expert" then
    Ai.difficulty=level else Ai.difficulty="easy" end
end
function Ai.chooseMove(board)
  if Ai.difficulty=="easy"   then return chooseEasyMove(board)   end
  if Ai.difficulty=="medium" then return chooseMediumMove(board) end
  if Ai.difficulty=="hard"   then return chooseHardMove(board)   end
  return chooseExpertMove(board)
end

return Ai
