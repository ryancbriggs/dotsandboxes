-- fonts.lua – Central type hierarchy.
--
-- One Roobert family, four roles, so every screen reads as deliberately
-- designed instead of flat system font. Each falls back to the system font
-- if the SDK path can't be loaded (older SDKs / unusual installs).
--
-- Imported once by main.lua and handed to UI via opts (Playdate's `import`
-- returns the module only on first import, so other files must not re-import).
--
--   h1      – screen titles / menu labels        (Roobert-20-Medium)
--   h2      – section headers, tabs, emphasis     (Roobert-11-Bold)
--   body    – default running text                (Roobert-11-Medium)
--   caption – footers, hints, dense meta          (Roobert-10-Bold)

local gfx = playdate.graphics
local sys = gfx.getSystemFont()

local function load(path) return gfx.font.new(path) or sys end

local Fonts = {
    h1      = load("/System/Fonts/Roobert-20-Medium"),
    h2      = load("/System/Fonts/Roobert-11-Bold"),
    body    = load("/System/Fonts/Roobert-11-Medium"),
    caption = load("/System/Fonts/Roobert-10-Bold"),
}

return Fonts
