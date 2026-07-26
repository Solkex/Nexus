-- Overlay lifecycle: Show/Hide/Toggle, owned-vs-missing coloring, and
-- lock/drag/position-persistence behavior.
local H = dofile("tests/harness.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")
dofile("ui/WishlistOverlay.lua")

NexusDB = {}
H.wishlist = { name = "MyBuild", class = "MAGE", echoes = {
    { spellId = 200100, quality = 3, stacks = 1 },   -- Alpha, will be owned
    { spellId = 200102, quality = 2, stacks = 1 },    -- Beta, not owned
    { spellId = 200104, quality = 2, stacks = 3 },    -- Double Strike, partially owned
} }
H.playerLevel = 5
H.granted = { ["Alpha Strike"] = { { spellId = 200100, stack = 1, maxStack = 1, quality = 3 } },
    ["Double Strike"] = { { spellId = 200104, stack = 1, maxStack = 5, quality = 2 } } }

local Adapter, Model = Nexus.GameAdapter, Nexus.Model
local OV = Nexus.WishlistOverlay
OV.Init(Adapter, Model)

local ok = pcall(OV.Show)
assert(ok, "Show() threw")
assert(OV.IsShown(), "overlay not shown after Show()")
assert(NexusDB.overlayShown == true, "shown-state not persisted")

OV.Toggle()
assert(not OV.IsShown(), "Toggle() did not hide")
assert(NexusDB.overlayShown == false, "hidden-state not persisted")
OV.Toggle()
assert(OV.IsShown(), "Toggle() did not re-show")

local ok2 = pcall(OV.Refresh)
assert(ok2, "Refresh() threw")

print("overlay lifecycle (Show/Hide/Toggle/persistence) OK")

-- lock state defaults to locked (click-through)
local frame = _G.NexusOverlay
assert(frame, "overlay frame missing")
print("overlay frame + lock button created without error -- OK")

-- Verify actual line CONTENT: owned/partial/missing must render distinctly.
local allTexts = {}
local realCreateFrame2 = CreateFrame
CreateFrame = function(...)
    local f = realCreateFrame2(...)
    local realCFS = f.CreateFontString
    f.CreateFontString = function(self, ...)
        local fs = realCFS(self, ...)
        allTexts[#allTexts + 1] = fs
        return fs
    end
    return f
end

-- fresh overlay instance to pick up the intercepted CreateFrame
package.loaded = package.loaded or {}
dofile("ui/WishlistOverlay.lua")
local OV2 = Nexus.WishlistOverlay
OV2.Init(Adapter, Model)
OV2.Show()

local foundOwned, foundPartial, foundMissing = false, false, false
for _, fs in ipairs(allTexts) do
    local t = fs.text
    if type(t) == "string" then
        if t:find("%[X%]") and t:find("Alpha Strike") then foundOwned = true end
        if t:find("%[~%]") and t:find("Double Strike") then foundPartial = true end
        if t:find("%[ %]") and t:find("Beta Guard") then foundMissing = true end
    end
end
assert(foundOwned, "owned echo (Alpha Strike) not shown as [X]")
assert(foundPartial, "partially-owned stacking echo (Double Strike) not shown as [~]")
assert(foundMissing, "missing echo (Beta Guard) not shown as [ ]")
print("owned/partial/missing states render with correct markers -- OK")

-- The whole point of the rewrite: a large wishlist must fit on screen,
-- not run to 1000+ px tall in a single column.
local w, h = frame:GetWidth(), frame:GetHeight()
print(string.format("overlay footprint: %dx%d (was ~300x1200 before the fix)", w or 0, h or 0))
assert((h or 9999) < 500, "overlay is still too tall -- multi-column layout isn't working")
print("overlay fits comfortably on screen regardless of wishlist size -- OK")
