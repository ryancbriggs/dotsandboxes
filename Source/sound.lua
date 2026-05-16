-- sound.lua
-- Uses built-in playdate.sound API
import "CoreLibs/timer"

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

-- 3) Crank-review flick: a light paper-card tick as history advances.
do
    local flick = playdate.sound.synth.new(playdate.sound.kWaveNoise)
    flick:setADSR(0, 0.008, 0, 0.012)
    flick:setEnvelopeCurvature(1)
    flick:setVolume(0.58)

    function M.reviewStep()
        flick:playNote(440, nil, 0.018)
    end
end

-- 4) "Done" completion click: layered square-wave thump + noise burst.
-- Pass chainIndex (0-based: 0 for first box of a chain) to make the pitch
-- rise as a chain grows, so longer chains feel more satisfying.
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

-- 5) Game-over cadence: a short pencil-on-paper underline with outcome color.
do
    local tone = synth.new(playdate.sound.kWaveSquare)
    tone:setADSR(0.002, 0.07, 0, 0.035)
    tone:setVolume(0.28)

    local scratch = synth.new(playdate.sound.kWaveNoise)
    scratch:setADSR(0, 0.025, 0, 0.02)
    scratch:setEnvelopeCurvature(1)
    scratch:setVolume(0.18)

    local function playPair(hz)
        tone:playNote(hz, nil, 0.09)
        scratch:playNote(440, nil, 0.05)
    end

    function M.gameOver(result)
        local notes
        if result == "win" then
            notes = { 262, 330, 392 }
        elseif result == "loss" then
            notes = { 330, 294, 220 }
        else
            notes = { 262, 294, 262 }
        end

        playPair(notes[1])
        playdate.timer.performAfterDelay(95, function() playPair(notes[2]) end)
        playdate.timer.performAfterDelay(190, function() playPair(notes[3]) end)
    end
end

return M
