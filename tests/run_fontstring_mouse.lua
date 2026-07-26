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

-- Simulate the ACTUAL live failure: FontStrings on this client don't
-- support EnableMouse/SetScript at all. Patch CreateFontString's return
-- value so calling EnableMouse on it throws, exactly like the real client.
local realCreateFrame = CreateFrame
CreateFrame = function(kind, name, parent, ...)
    local f = realCreateFrame(kind, name, parent, ...)
    local realCreateFontString = f.CreateFontString
    f.CreateFontString = function(self, ...)
        local fs = realCreateFontString(self, ...)
        fs.EnableMouse = function() error("FontString has no EnableMouse on this client") end
        fs.SetScript = function() error("FontString has no SetScript on this client") end
        return fs
    end
    return f
end

NexusDB = {}
Nexus.Panel.Init({ ToggleAuto = function() return true end })

local ok, err = pcall(function()
    Nexus.Panel.Render({
        status = "test", cards = {}, recommendation = "",
        progress = { owned = 1, total = 2, loadoutStacks = { stackCount=1, stackTotal=2 },
            missing = {"Thing"} },
        auto = true, version = "test",
    })
end)
assert(ok, "Render threw despite FontStrings rejecting EnableMouse: " .. tostring(err))
print("panel survived FontString EnableMouse rejection")

-- The actual regression: autoBtn must be usable (this is exactly what
-- crashed live -- "attempt to index upvalue 'autoBtn' (a nil value)")
local ok2, err2 = pcall(function()
    Nexus.Panel.Render({ status = "t2", cards = {}, recommendation = "",
        progress = nil, auto = false, version = "test" })
end)
assert(ok2, "second render (the one that crashed live) failed: " .. tostring(err2))
print("second render OK -- autoBtn exists and is usable")
