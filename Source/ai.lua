-- ai.lua
-- Basic AI module for Dots & Boxes
-- For now, chooses moves randomly; later you can plug in smarter heuristics.

local Ai = {}

-- Difficulty setting ("random" for pure random; expand with "easy", "medium", "hard" later)
Ai.difficulty = "random"

--- Set the AI difficulty level. Placeholder for future use.
-- @param level string: "random", "easy", "medium", "hard", etc.
function Ai.setDifficulty(level)
    Ai.difficulty = level
end

--- Choose a move given the current board state.
-- @param board: the Board instance (expects .edgeToCoord and :edgeIsFilled(i))
-- @return integer: the index of the edge to play, or nil if none
function Ai.chooseMove(board)
    -- Dispatch based on difficulty
    if Ai.difficulty == "random" then
        return Ai.randomMove(board)
    end
    -- Future: add heuristics for other difficulties
    return Ai.randomMove(board)
end

--- Random move: pick any free edge at random
-- @param board: the Board instance
-- @return integer: edge index, or nil
function Ai.randomMove(board)
    local freeEdges = {}
    for e = 1, #board.edgeToCoord do
        if not board:edgeIsFilled(e) then
            table.insert(freeEdges, e)
        end
    end
    if #freeEdges == 0 then
        return nil
    end
    return freeEdges[math.random(#freeEdges)]
end

return Ai
