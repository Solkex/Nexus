dofile("tests/harness.lua")
dofile("ui/QuickStart.lua")

NexusDB = {}
local QS = Nexus.QuickStart

-- first time: should show the four-path release setup
QS.ShowIfFirstTime(false)
local frame = _G.NexusQuickStart
assert(frame and frame:IsShown(), "guide did not show on first launch")
assert(frame.body.text:find("Starting fresh", 1, true),
    "first-launch path guidance not shown")
print("first-time guide shows the release setup paths -- OK")

-- dismiss it
local gotIt
for name, f in pairs(_G) do end -- no direct access; simulate via the flag directly
NexusDB.hasSeenQuickStart = true
frame:Hide()

-- second "first time" check (e.g. next login) must NOT show again
QS.ShowIfFirstTime(false)
assert(not frame:IsShown(), "guide showed again after being dismissed once")
print("guide never shows again after dismissal -- OK")

-- fresh account with a wishlist already present still gets the same concise
-- path chooser; it is intentionally not a separate tutorial branch.
NexusDB2 = {}
_G.NexusQuickStart = nil
NexusDB.hasSeenQuickStart = nil
dofile("ui/QuickStart.lua")
local QS2 = Nexus.QuickStart
QS2.ShowIfFirstTime(true)
local frame2 = _G.NexusQuickStart
assert(frame2:IsShown(), "guide did not show for the has-wishlist case")
assert(frame2.body.text:find("Already have a finished build", 1, true),
    "current-build path not shown")
print("first-time guide remains useful when a wishlist already exists -- OK")
