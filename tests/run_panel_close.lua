dofile("tests/harness.lua")
dofile("ui/Panel.lua")

NexusDB = {}
Nexus.Panel.Init({ ToggleAuto = function() return true end })

local model = { status="t", cards={}, recommendation="", auto=true, version="v" }

-- first render: should show (default state)
Nexus.Panel.Render(model)
local frame = _G.NexusPanel
assert(frame:IsShown(), "panel should be shown after first render")

-- explicit toggle-off via /wr panel path (Panel.Toggle)
Nexus.Panel.Toggle()
assert(not frame:IsShown(), "panel should be hidden immediately after Toggle()")

-- simulate the next several poll ticks calling Render() again (this is
-- exactly what happens every 0.2s in real play) -- it must NOT re-show
for i = 1, 5 do
    Nexus.Panel.Render(model)
    assert(not frame:IsShown(),
        "Render() re-showed the panel after an explicit hide (tick " .. i .. ")")
end
print("panel stays hidden across repeated Render() calls after Toggle-off -- OK")

-- toggling back on must work and then Render() must keep it visible
Nexus.Panel.Toggle()
assert(frame:IsShown(), "panel should be shown again after second Toggle()")
Nexus.Panel.Render(model)
assert(frame:IsShown(), "panel should remain shown on next render")
print("panel toggles back on correctly -- OK")
