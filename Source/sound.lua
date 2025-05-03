-- sound.lua
import "CoreLibs/sound"
local Synth = playdate.sound.synth

local M = {}

-- basic arrow‑key click
local clickBasic = Synth.new()
clickBasic:setOscillator( Synth.kOscillatorTriangle )
clickBasic:setADSR( 0.001, 0.02, 0, 0 )
clickBasic:setAmplitude(0.2)
function M.basic()
    clickBasic:playNote(60, 0.05)
end

-- select A‑button click
local clickSelect = Synth.new()
clickSelect:setOscillator( Synth.kOscillatorSawtooth )
clickSelect:setADSR( 0.001, 0.01, 0.05, 0.01 )
clickSelect:setAmplitude(0.3)
clickSelect:setPitchBend( Synth.kPitchBendTypeDownward, 0.2, 0.05 )
function M.select()
    clickSelect:playNote(72, 0.1)
end

-- satisfying completion click (two‑voice)
local clickDone = Synth.new()
clickDone:addVoice( Synth.new() )
clickDone:addVoice( Synth.new() )
-- voice 1
clickDone.voices[1]:setOscillator( Synth.kOscillatorSquare )
clickDone.voices[1]:setADSR( 0.002, 0.05, 0, 0.02 )
clickDone.voices[1]:setAmplitude(0.4)
clickDone.voices[1]:setPitch(48)
-- voice 2
clickDone.voices[2]:setOscillator( Synth.kOscillatorWhiteNoise )
clickDone.voices[2]:setADSR( 0.001, 0.03, 0, 0 )
clickDone.voices[2]:setAmplitude(0.2)
function M.done()
    clickDone:playNote(nil, 0.2)
end

return M