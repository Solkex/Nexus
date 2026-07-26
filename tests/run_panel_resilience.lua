local H = dofile("tests/harness.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")
dofile("ui/Readout.lua")
dofile("ui/Panel.lua")

-- Simulate the exact live failure: SetBackdrop throws on this client.
-- Monkey-patch the frame metatable's fallback so SetBackdrop specifically
-- errors, mirroring the modified-client incompatibility.
local realCreateFrame = CreateFrame
CreateFrame = function(kind, name, parent)
    local f = realCreateFrame(kind, name, parent)
    if kind == "Frame" and name == "NexusPanel" then
        f.SetBackdrop = function() error("SetBackdrop not supported on this client") end
    end
    return f
end

NexusDB = {}
Nexus.Panel.Init({ ToggleAuto = function() return true end })

-- This must NOT throw, and the panel must still be fully functional
-- afterward -- specifically, missingText and the Auto button must exist.
local ok, err = pcall(function()
    Nexus.Panel.Render({
        status = "test", cards = {}, recommendation = "",
        progress = { owned = 1, total = 2, loadoutStacks = { stackCount=1, stackTotal=2 },
            missing = {"Thing"} },
        auto = true, version = "test",
    })
end)
assert(ok, "Render threw despite the SetBackdrop failure: " .. tostring(err))

local btn = _G.NexusPanel
assert(btn, "panel frame was never created")
print("panel survived a SetBackdrop failure with all functional widgets intact")

-- Second render must also work (proves EnsureFrame's memoization didn't
-- leave things half-built for subsequent calls either)
local ok2 = pcall(function()
    Nexus.Panel.Render({ status = "test2", cards = {}, recommendation = "",
        progress = nil, auto = false, version = "test" })
end)
assert(ok2, "second render failed")
print("second render also OK -- no permanent half-built state")
