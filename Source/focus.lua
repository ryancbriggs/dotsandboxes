-- focus.lua - shared pulsing selection treatment for menus and gameplay.
import "CoreLibs/graphics"

local gfx <const> = playdate.graphics

Focus = Focus or {}

Focus.PULSE_MS  = 1400
Focus.PULSE_PAD = 2
Focus.LINE_W    = 3

function Focus.pulsePad()
    local phase = (playdate.getCurrentTimeMilliseconds() % Focus.PULSE_MS)
        / Focus.PULSE_MS
    local grow = Focus.PULSE_PAD * (1 - math.cos(phase * math.pi * 2)) / 2
    -- Quantize after easing so the rect grows equally on all sides.
    return math.floor(grow + 0.5)
end

function Focus.drawRect(x, y, w, h, opts)
    opts = opts or {}
    local pad = opts.pulse == false and 0 or Focus.pulsePad()
    local dither = opts.dither

    if dither then gfx.setDitherPattern(dither) end
    gfx.setLineWidth(opts.lineWidth or Focus.LINE_W)
    gfx.drawRect(math.floor(x) - pad, math.floor(y) - pad,
                 math.floor(w) + pad * 2, math.floor(h) + pad * 2)
    gfx.setLineWidth(1)
    if dither then gfx.setDitherPattern(0) end
end

return Focus
