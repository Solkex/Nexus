-- Confirms Nexus Builds is now reachable from both the repurposed editor
-- button and the new panel button, and that the OLD best-effort
-- Echo-Journal-guessing logic is genuinely gone, not just relabeled.
local H = dofile("tests/harness.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")

local allWidgets = {}
local realCreateFrame = CreateFrame
CreateFrame = function(...)
    local f = realCreateFrame(...)
    allWidgets[#allWidgets + 1] = f
    return f
end
dofile("ui/Panel.lua")

NexusDB = {}
local shown = false
Nexus.CommunityBuilds = { Show = function() shown = true end }
Nexus.Panel.Init({ ToggleAuto = function() return true end })
Nexus.Panel.Render({ status="t", cards={}, recommendation="", auto=true, version="v" })

-- find the panel's new Builds button by behavior (clicking it calls Show)
local found = false
for _, f in ipairs(allWidgets) do
    if f.scripts and f.scripts.OnClick then
        shown = false
        local ok = pcall(f.scripts.OnClick, f)
        if ok and shown then found = true end
    end
end
assert(found, "no button on the panel opens Nexus Builds")
print("panel has a working Builds button -- OK")

-- The editor's button must ALSO open Nexus Builds directly, and the old
-- best-effort Echo-Journal-guessing logic must be genuinely gone.
local src = io.open("ui/WishlistEditor.lua"):read("*a")
assert(not src:find("ToggleEchoJournal"), "old best-effort Echo Journal guessing logic still present")
assert(not src:find('"Community Loadouts"'), "old button label still present somewhere")
assert(src:find("Nexus%.CommunityBuilds%.Show"),
    "editor button does not call CommunityBuilds.Show()")
print("old best-effort button logic fully removed; editor now opens Nexus Builds directly -- OK")
