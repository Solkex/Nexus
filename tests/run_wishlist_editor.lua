local H = dofile("tests/harness.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")
dofile("ui/WishlistEditor.lua")

NexusDB = {}
H.wishlist = { name = "MyBuild", class = "MAGE", echoes = {
    { spellId = 200100, quality = 3, stacks = 1 },
    { spellId = 200104, quality = 2, stacks = 3 },
} }
H.playerLevel = 5
IsSpellKnown = function(id) return id == 300100 end

local Adapter, Model = Nexus.GameAdapter, Nexus.Model
local EW = Nexus.WishlistEditor
EW.Init(Adapter, Model)

local ok = pcall(EW.Show)
assert(ok, "Show() threw")
local frame = _G.NexusEditorFrame
assert(frame:IsShown(), "editor frame not shown after Show()")

-- pending list should be seeded from the real wishlist: 2 entries
assert(EW.DebugPendingCount() == 2,
    "expected pending seeded with 2 entries, got " .. EW.DebugPendingCount())

-- toggle hides/shows correctly
EW.Toggle()
assert(not frame:IsShown(), "Toggle() did not hide")
EW.Toggle()
assert(frame:IsShown(), "Toggle() did not re-show")

-- refresh never throws across repeated calls (search/filter changes etc.)
for i = 1, 5 do
    local ok2 = pcall(EW.Refresh)
    assert(ok2, "Refresh() threw on iteration " .. i)
end

print("wishlist editor: lifecycle + seeding OK (checks=5)")
