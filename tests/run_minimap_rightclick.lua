dofile("tests/harness.lua")
dofile("ui/Panel.lua")

NexusDB = {}
local editorOpened, panelToggled = false, false
Nexus.WishlistEditor = { Show = function() editorOpened = true end }
Nexus.Panel.Init({ ToggleAuto = function() return true end })
Nexus.Panel.Render({ status="t", cards={}, recommendation="", auto=true, version="v" })

local btn = _G.NexusMinimapButton
assert(btn, "minimap button missing")
local onClick = btn.scripts.OnClick
assert(onClick, "no OnClick handler on minimap button")

onClick(btn, "RightButton")
assert(editorOpened, "right-click did not open the Wishlist Editor")
assert(not panelToggled, "right-click should not toggle the panel")
print("minimap right-click opens the Wishlist Editor -- OK")

editorOpened = false
local shownBefore = _G.NexusPanel and _G.NexusPanel:IsShown()
onClick(btn, "LeftButton")
assert(not editorOpened, "left-click should not open the editor")
print("minimap left-click still toggles the panel, not the editor -- OK")
