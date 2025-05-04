-- sound.lua
-- Uses built‑in playdate.sound API
local synth = playdate.sound.synth
local M = {}

-- 1) Basic arrow‑key click: little noise click
do
    local snap = playdate.sound.synth.new(playdate.sound.kWaveNoise)
    -- instant attack, 5 ms decay straight to zero, tiny release to avoid clicks
    snap:setADSR(0, 0.01, 0, 0.01)
    snap:setEnvelopeCurvature(1)   -- exponential, gives a sharper transient
    snap:setVolume(0.7)

    function M.basic()
        -- pitch is ignored for noise, length just determines envelope timing
        snap:playNote(440, nil, 0.02)  -- 20 ms total duration
    end
end

-- 2) A- and B‑button click: little percussive click
do
    local snap = playdate.sound.synth.new(playdate.sound.kWaveNoise)
    -- instant attack, 5 ms decay straight to zero, tiny release to avoid clicks
    snap:setADSR(0, 0.01, 0, 0.05)
    snap:setEnvelopeCurvature(1)   -- exponential, gives a sharper transient
    snap:setVolume(0.8)

    function M.select()
        -- pitch is ignored for noise, length just determines envelope timing
        snap:playNote(440, nil, 0.04)  -- 20 ms total duration
    end
end


-- 3) "Done" completion click: layered square‑wave thump + noise burst
do
    local thump = synth.new(playdate.sound.kWaveSquare)
    thump:setADSR(0.002, 0.05, 0, 0.02)
    thump:setVolume(0.4)

    local noise = synth.new(playdate.sound.kWaveNoise)
    noise:setADSR(0.001, 0.03, 0, 0)
    noise:setVolume(0.2)

    function M.done()
        thump:playNote(220, nil, 0.1)  -- low C3 thump
        noise:playNote(440, nil, 0.1)  -- noise overlay
    end
end

return M
