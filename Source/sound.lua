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


-- 3) "Done" completion click: layered square‑wave thump + noise burst.
-- Pass chainIndex (0-based: 0 for first box of a chain) to make the pitch
-- rise as a chain grows — longer chains feel more satisfying.
do
    local thump = synth.new(playdate.sound.kWaveSquare)
    thump:setADSR(0.002, 0.05, 0, 0.02)
    thump:setVolume(0.4)

    local noise = synth.new(playdate.sound.kWaveNoise)
    noise:setADSR(0.001, 0.03, 0, 0)
    noise:setVolume(0.2)

    local BASE_HZ <const> = 220     -- A3
    local MAX_STEPS <const> = 12    -- one octave cap

    function M.done(chainIndex)
        chainIndex = chainIndex or 0
        if chainIndex < 0 then chainIndex = 0 end
        if chainIndex > MAX_STEPS then chainIndex = MAX_STEPS end
        local hz = BASE_HZ * 2^(chainIndex / 12)  -- one semitone per step
        thump:playNote(hz, nil, 0.1)
        noise:playNote(440, nil, 0.1)
    end
end

return M
