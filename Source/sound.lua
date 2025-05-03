-- sound.lua
-- Uses built‑in playdate.sound API
local synth = playdate.sound.synth
local M = {}

-- 1) Basic arrow‑key click: soft triangle pulse
do
    local click = synth.new(playdate.sound.kWaveTriangle)  -- triangle waveform
    click:setADSR(0.001, 0.02, 0, 0)                       -- quick percussive envelope
    click:setVolume(0.2)                                  -- lower volume
    function M.basic()
        click:playNote(440, nil, 0.05)                     -- A4 tone for 50 ms
    end
end

-- 2) "Select" A‑button click: snappier sawtooth
do
    local click = synth.new(playdate.sound.kWaveSawtooth) -- sawtooth waveform
    click:setADSR(0.001, 0.01, 0.05, 0.01)                -- short sustain for snap
    click:setVolume(0.3)
    function M.select()
        click:playNote(660, nil, 0.1)                      -- E5 tone for 100 ms
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
