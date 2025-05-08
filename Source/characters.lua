-- characters.lua – chunky 3x5 bitmap characters for digits and uppercase letters

local gfx <const> = playdate.graphics

local CHAR_BITS <const> = {
    ["0"] = 31599, ["1"] = 11415, ["2"] = 29671, ["3"] = 29647, ["4"] = 23497,
    ["5"] = 31183, ["6"] = 31215, ["7"] = 29257, ["8"] = 31727, ["9"] = 31695,

    A = 31721, B = 31695, C = 31279, D = 31647, E = 31295, F = 31280, G = 31287,
    H = 23481, I = 11415, J = 11983, K = 23481, L = 21520, M = 23513, N = 23489,
    O = 31727, P = 31688, Q = 31731, R = 31689, S = 31183, T = 11416, U = 23471,
    V = 23471, W = 23471, X = 23481, Y = 23488, Z = 29871
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