-- Regression for the exact gap that hid UploadServerBuildSlot's echo
-- data (2026-07-24): the sniffer used to print table arguments as a bare
-- memory address ("table: 210720A8") instead of their contents.
local H = dofile("tests/harness.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")
dofile("ui/Readout.lua")
dofile("ui/Panel.lua")
local provider
Nexus.LogViewer = { Init = function(p) provider = p end,
    Show = function() end, Toggle = function() end }
dofile("core/Main.lua")
NexusDB = {}
H.wishlist = { name = "MyBuild", class = "MAGE", echoes = {
    { spellId = 200100, quality = 3, stacks = 1 },
} }
H.playerLevel = 1
H.FireEvent("ADDON_LOADED", "Nexus")
H.FireEvent("SPELLS_CHANGED")
H.FireEvent("PLAYER_ENTERING_WORLD")
H.Advance(1)

-- the target write function already exists on PerkService (as it would
-- in the real game) before the sniffer is installed
ProjectEbonhold.PerkService.UploadServerBuildSlot = function(slot, name, echoes)
    return true
end

SlashCmdList["NEXUS"]("sniff")

-- simulate the real Echo Journal calling it with an actual echo table,
-- exactly the shape a build-slot save would need
ProjectEbonhold.PerkService.UploadServerBuildSlot(0, "Yoon", {
    { spellId = 200672, quality = 1, stacks = 9 },
    { spellId = 200100, quality = 3, stacks = 1 },
})

local text = provider("sniffer")
assert(text:find("UploadServerBuildSlot"), "call name missing from sniffer output")
assert(text:find("200672"), "table contents (spellId) NOT captured -- regression of the live bug")
assert(text:find("stacks=9") or text:find("9"), "stacks value not captured in table dump")
assert(not text:find("table: 0x") and not text:find("table:%s*%x+$"),
    "sniffer printed a bare table address instead of its contents")
print("sniffer now dumps table CONTENTS, not just addresses -- OK")
print("--- sample output ---")
for line in text:gmatch("[^\n]+") do
    if line:find("UploadServerBuildSlot") then print(line) end
end
