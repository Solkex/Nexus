-- Your own builds must auto-share on post AND on every edit, and those
-- edits must actually PROPAGATE to a peer (not get silently dropped by
-- the peer's dedup rule).
local H = dofile("tests/harness.lua")
dofile("core/Codec.lua")
dofile("core/Sync.lua")
dofile("data/DefaultProfile.lua")
dofile("logic/Model.lua")
dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Policy.lua")
dofile("core/Store.lua")
dofile("core/GameAdapter.lua")
dofile("ui/CommunityBuilds.lua")

local Codec, Sync = Nexus.Codec, Nexus.Sync
local CB = Nexus.CommunityBuilds
local clock = 1000
GetTime = function() return clock end
local wallclock = 50000
time = function() return wallclock end
UnitName = function() return "Alice" end

NexusDB = {}
H.wishlist = { name = "MyBuild", class = "MAGE", echoes = {
    { spellId = 200100, quality = 3, stacks = 1 },
} }
H.playerLevel = 5
local Adapter = Nexus.GameAdapter
CB.Init(Adapter, Nexus.Model)
Sync.Init(Codec, Adapter)

local function Drain()
    for i = 1, 60 do Sync.OnUpdate(0.2) end
    local m = H.sentChatMessages
    H.sentChatMessages = {}
    return m
end
H.sentChatMessages = {}

-- 1. POST auto-shares
local ok, id = CB.PostCurrentWishlist("Original Title", "Original description")
assert(ok, "post should succeed")
local postMsgs = Drain()
assert(#postMsgs > 0, "posting did not auto-share the build")
print("posting auto-shares immediately -- OK")

-- 2. EDIT auto-shares
local ok2 = CB.EditBuild(id, "Edited Title", "Edited description")
assert(ok2, "edit should succeed")
local editMsgs = Drain()
assert(#editMsgs > 0, "editing did not auto-share the updated build")
print("editing auto-shares immediately -- OK")

-- 3. UPDATE-FROM-WISHLIST auto-shares
H.wishlist = { name = "MyBuild", class = "MAGE", echoes = {
    { spellId = 200100, quality = 3, stacks = 1 },
    { spellId = 200102, quality = 2, stacks = 1 },
} }
local ok3, n = CB.UpdateFromWishlist(id)
assert(ok3, "update-from-wishlist should succeed: " .. tostring(n))
assert(n == 2, "should have captured the 2-echo wishlist, got " .. tostring(n))
local updMsgs = Drain()
assert(#updMsgs > 0, "update-from-wishlist did not auto-share")
print("updating from your current wishlist auto-shares immediately -- OK")

-- 4. CRITICAL: each successive edit must actually PROPAGATE to a peer.
-- Peers reject anything not strictly newer, so if edits didn't bump the
-- timestamp, edits 2+ would silently vanish. Replay all three onto a
-- fresh "peer" and confirm the FINAL state wins.
NexusDB = {}
Sync.Init(Codec, Adapter)   -- fresh peer state
clock = clock + 10
Sync.RequestSync()
for _, m in ipairs(postMsgs) do Sync.HandleIncoming(m.text, "Alice") end
for _, m in ipairs(editMsgs) do Sync.HandleIncoming(m.text, "Alice") end
for _, m in ipairs(updMsgs) do Sync.HandleIncoming(m.text, "Alice") end

local peerCopy = NexusDB.communityBuilds[id]
assert(peerCopy, "peer never received the build at all")
assert(peerCopy.title == "Edited Title",
    "peer did not receive the EDITED title -- edits are not propagating (got '" .. tostring(peerCopy.title) .. "')")
assert(peerCopy.echoCount == 2,
    "peer did not receive the UPDATED Echo count -- later edits are being dropped by dedup")
assert(not peerCopy.echoes or #peerCopy.echoes == 0,
    "automatic build sync should not include the full Echo list")
local count = 0
for _ in pairs(NexusDB.communityBuilds) do count = count + 1 end
assert(count == 1, "edits created duplicate entries instead of updating in place (got " .. count .. ")")
print("every successive edit propagates to peers, in place, with no duplicates -- OK")

-- 5. Editing/updating someone ELSE'S build must be refused
NexusDB.communityBuilds["theirs"] = { id = "theirs", title = "Theirs",
    description = "d", author = "Bob", class = "ROGUE",
    echoes = { { spellId = 1, quality = 0, stacks = 1 } },
    postedAt = 1, lastModified = 1, isMine = false }
local okE, errE = CB.EditBuild("theirs", "Hijacked", "nope")
assert(not okE, "editing someone else's build must be refused")
local okU, errU = CB.UpdateFromWishlist("theirs")
assert(not okU, "updating someone else's build must be refused")
assert(NexusDB.communityBuilds["theirs"].title == "Theirs",
    "someone else's build was modified anyway")
print("editing/updating another player's build is correctly refused -- OK")

-- 6. Answering a peer's sync request shares the full valid mesh library
H.sentChatMessages = {}
clock = clock + 100
Sync.HandleIncoming("WLRQ|Bob", "Bob")
local answer = Drain()
assert(#answer > 0, "a peer's sync request went unanswered -- nobody would ever receive anything")
local indexes = 0
for _, m in ipairs(answer) do
    if m.text:find("^WLBI|") then indexes = indexes + 1 end
    assert(not m.text:find("^WLRB|"), "normal peer response leaked a full loadout")
end
assert(indexes >= 2, "answering a request must redistribute the compact indexes for valid mesh builds")
print("answering a peer request redistributes the compact mesh index -- OK")

-- 7. We must never answer our OWN request (would echo endlessly)
H.sentChatMessages = {}
clock = clock + 100
Sync.HandleIncoming("WLRQ|Alice", "Alice")
local selfAnswer = Drain()
for _, m in ipairs(selfAnswer) do
    assert(not m.text:find("^WLRC|") and not m.text:find("^WLBI|") and not m.text:find("^WLRB|"),
        "the addon answered its own sync request -- would cause an echo loop")
end
print("own sync requests are correctly ignored (no echo loop) -- OK")
