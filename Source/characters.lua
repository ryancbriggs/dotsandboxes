-- characters.lua – chunky 3x5 bitmap characters for digits and uppercase letters

local gfx <const> = playdate.graphics

-- 3x5 bitmaps. Each value is 15 bits, MSB-first, row-major.
-- Bit 14 = top-left, bit 0 = bottom-right.
local CHAR_BITS <const> = {
    ["0"] = 31599, ["1"] = 11415, ["2"] = 29671, ["3"] = 29647, ["4"] = 23497,
    ["5"] = 31183, ["6"] = 31215, ["7"] = 29257, ["8"] = 31727, ["9"] = 31695,

    A = 31725, B = 27566, C = 31015, D = 27502, E = 31207, F = 31204, G = 31087,
    H = 23533, I = 29847, J =  4719, K = 23469, L = 18727, M = 24429, N = 27499,
    O = 31599, P = 31716, Q = 31609, R = 27565, S = 31183, T = 29842, U = 23407,
    V = 23402, W = 23421, X = 23213, Y = 23186, Z = 29351,
}

local function drawChunkyChar(ch, x, y, scale)
    local bits = CHAR_BITS[ch]
    if not bits then return end
    for row = 0, 4 do
        for col = 0, 2 do
            local bitPos = 14 - (row*3 + col)
            if ((bits >> bitPos) & 1) == 1 then
                gfx.fillRect(x + col*scale, y + row*scale, scale, scale)
            end
        end
    end
end

return {
    CHAR_BITS = CHAR_BITS,
    drawChunkyChar = drawChunkyChar
}