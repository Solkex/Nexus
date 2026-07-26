local H = dofile("tests/harness.lua")
dofile("ui/Panel.lua")

NexusDB = {}
Nexus.DpsCapture = {
    GetPersonalBestForEchoes = function(echoes, category)
        if category == "dummy" then return { dps=24080000, duration=60 } end
    end,
    GetLeaderboardForEchoes = function(echoes, category)
        if category == "dummy" then return {{ dps=25100000, player="Othermage" }} end
        return {}
    end,
}
Nexus.Panel.Init({ ToggleAuto=function() return true end })

Nexus.Panel.Render({progress={},cards={},recommendation="",auto=true,version="2.12"})
local panel = _G.NexusPanel
assert(panel and panel:GetHeight() == 172, "setup state should be compact and narrow")

Nexus.Panel.Render({progress={wishlistName="Leveling",owned=25,total=79,missing={"A","B"},shed={"C"},dpsEchoes={{spellId=1,stacks=1}}},cards={},recommendation="",auto=true,version="2.12"})
assert(panel:GetHeight() == 240, "progress state height incorrect")

Nexus.Panel.Render({progress={wishlistName="Complete",owned=79,total=79,missing={},shed={},dpsEchoes={{spellId=1,stacks=1}}},cards={},recommendation="",auto=true,version="2.12"})
assert(panel:GetHeight() == 242, "completed state should collapse progress lists")

Nexus.Panel.Render({progress={wishlistName="Complete",owned=79,total=79,missing={},shed={},dpsEchoes={{spellId=1,stacks=1}},activeSlot=3},cards={{text="Echo A"}},recommendation="Take Echo A",auto=true,version="2.12"})
assert(panel:GetHeight() == 348, "live roll should expand completed HUD")
print("adaptive panel states OK")
