dofile("tests/harness.lua")
dofile("ui/QuickStart.lua")

NexusDB = {}
local QS = Nexus.QuickStart

-- first time: no wishlist -> should show, with the "get one" content
QS.ShowIfFirstTime(false)
local frame = _G.NexusQuickStart
assert(frame and frame:IsShown(), "guide did not show on first launch")
assert(frame.body.text:find("Nexus Builds"), "missing-wishlist content not shown")
print("first-time guide shows with the no-wishlist content -- OK")

-- dismiss it
local gotIt
for name, f in pairs(_G) do end -- no direct access; simulate via the flag directly
NexusDB.hasSeenQuickStart = true
frame:Hide()

-- second "first time" check (e.g. next login) must NOT show again
QS.ShowIfFirstTime(false)
assert(not frame:IsShown(), "guide showed again after being dismissed once")
print("guide never shows again after dismissal -- OK")

-- fresh account, wishlist ALREADY present -> different content
NexusDB2 = {}
_G.NexusQuickStart = nil
NexusDB.hasSeenQuickStart = nil
dofile("ui/QuickStart.lua")
local QS2 = Nexus.QuickStart
QS2.ShowIfFirstTime(true)
local frame2 = _G.NexusQuickStart
assert(frame2:IsShown(), "guide did not show for the has-wishlist case")
assert(frame2.body.text:find("Nexus is ready"), "has-wishlist content not shown")
print("first-time guide shows different content when a wishlist already exists -- OK")
