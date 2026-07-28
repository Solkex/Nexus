local H = dofile("tests/harness.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Relay.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")
dofile("ui/Readout.lua")
dofile("ui/Panel.lua")
Nexus.LogViewer = { Init = function() end, Show = function() end }
dofile("core/Main.lua")
NexusDB = {}
H.wishlist = { name = "MyBuild", class = "MAGE", echoes = {
    { spellId = 200100, quality = 3, stacks = 1 },
} }
H.playerLevel = 5
H.FireEvent("ADDON_LOADED", "Nexus")
H.FireEvent("SPELLS_CHANGED")
H.FireEvent("PLAYER_ENTERING_WORLD")
H.Advance(2)

-- background polling produces calls to GetServerBuildSlots etc; count a
-- proxy call (IsTomeEchoDisabled) via the sniffer itself once installed,
-- confirming it stays essentially silent while paused vs busy once resumed
SlashCmdList["NEXUS"]("sniff")
local countAfterSniffStart = 0
H.Perks.probeCount = 0
local realGetGranted = ProjectEbonhold.PerkService.GetGrantedPerks
ProjectEbonhold.PerkService.GetGrantedPerks = function(...)
    H.Perks.probeCount = H.Perks.probeCount + 1
    return realGetGranted(...)
end

H.Advance(3)  -- several poll intervals worth of time
assert(H.Perks.probeCount == 0,
    "background polling (GetGrantedPerks) still ran while sniffer was paused: "
    .. tostring(H.Perks.probeCount) .. " calls")
print("background polling correctly PAUSED during /wr sniff")

SlashCmdList["NEXUS"]("sniffdump")
H.Advance(3)
assert(H.Perks.probeCount > 0,
    "background polling did not resume after /wr sniffdump")
print("background polling correctly RESUMED after /wr sniffdump")
