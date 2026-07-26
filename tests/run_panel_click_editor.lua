dofile("tests/harness.lua")

-- Capture EVERY frame CreateFrame produces (the hit-frame over the
-- Missing text is anonymous, so the harness's name-keyed registry
-- never sees it otherwise).
local allFrames = {}
local realCreateFrame = CreateFrame
CreateFrame = function(...)
    local f = realCreateFrame(...)
    allFrames[#allFrames + 1] = f
    return f
end

dofile("ui/Panel.lua")

NexusDB = {}
local shown = false
Nexus.WishlistEditor = { Show = function() shown = true end }
Nexus.Panel.Init({ ToggleAuto = function() return true end })

Nexus.Panel.Render({
    status = "t", cards = {}, recommendation = "", auto = true, version = "v",
    progress = { owned = 1, total = 2, loadoutStacks = { stackCount=1, stackTotal=2 },
        missing = {"Thing"} },
})

local clicked = 0
for _, f in ipairs(allFrames) do
    local fn = f.scripts and f.scripts.OnMouseUp
    if fn then
        clicked = clicked + 1
        pcall(fn, f)
    end
end
assert(clicked > 0, "no frame with an OnMouseUp handler was found at all")
assert(shown, "clicking the Missing hit-frame did not open the Wishlist Editor")
print("Missing text click correctly opens the Wishlist Editor -- OK")
