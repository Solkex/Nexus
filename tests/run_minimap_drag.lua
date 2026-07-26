dofile("tests/harness.lua")
dofile("ui/Panel.lua")

NexusDB = {}
Nexus.Panel.Init({ ToggleAuto = function() return true end })

local btn = _G.NexusMinimapButton
assert(btn, "minimap button was never created")

-- Simulate dragging the cursor to a known position relative to the
-- minimap center, then check the button repositions to the SAME side,
-- not the mirror-opposite side (the actual live bug).
Minimap.GetCenter = function() return 100, 100 end
Minimap.GetEffectiveScale = function() return 1 end

-- cursor directly to the RIGHT of the minimap center (px > mx, py == my)
GetCursorPosition = function() return 200, 100 end

local dragStart = btn:GetScript("OnDragStart")
dragStart(btn)
local onUpdate = btn:GetScript("OnUpdate")
onUpdate(btn)

-- angle for "directly right" should be 0 degrees; cos(0)=1, sin(0)=0,
-- so the button's X offset from Minimap center should be POSITIVE
-- (same side as the cursor), not negative (opposite side).
local point, relTo, relPoint, x, y = btn:GetPoint()
print(string.format("cursor right of center -> button offset x=%s y=%s", tostring(x), tostring(y)))
assert(x and x > 0, "button moved to the OPPOSITE side of the cursor (x should be positive, got " .. tostring(x) .. ")")

-- cursor directly ABOVE the minimap center
GetCursorPosition = function() return 100, 200 end
onUpdate(btn)
local _, _, _, x2, y2 = btn:GetPoint()
print(string.format("cursor above center -> button offset x=%s y=%s", tostring(x2), tostring(y2)))
assert(y2 and y2 > 0, "button did not follow cursor correctly on the Y axis (got y=" .. tostring(y2) .. ")")

print("minimap drag sign convention OK -- button follows the cursor, not its mirror")
