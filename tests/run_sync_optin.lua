-- Login sync opens one bounded receive window automatically. Outside that
-- window, unsolicited build traffic is ignored; manual Sync Now reopens it.
local H = dofile("tests/harness.lua")
dofile("core/Codec.lua")
dofile("core/Sync.lua")
local Codec, Sync = Nexus.Codec, Nexus.Sync
local clock = 1000
GetTime = function() return clock end
time = function() return 50000 end
UnitName = function() return "Alice" end

local function EncodeBob(id, title, stamp)
    local saved = H.sentChatMessages
    H.sentChatMessages = {}
    Sync.BroadcastBuild({ id=id, title=title, description="d", author="Bob", class="ROGUE",
        echoes={{spellId=200100,quality=3,stacks=1}}, postedAt=stamp,lastModified=stamp })
    for i=1,40 do Sync.OnUpdate(0.2) end
    local msgs=H.sentChatMessages; H.sentChatMessages=saved
    return msgs
end

NexusDB = {}
Sync.Init(Codec,nil)
-- Generate payload before the automatic receive window fires.
local msgs=EncodeBob("bob-1","Bob's Build",100)
-- Login-time sync should have fired during the 8 seconds above.
assert(Sync.IsReceiving(),"automatic login sync should open the receive window")
for _,m in ipairs(msgs) do Sync.HandleIncoming(m.text,"Bob") end
assert(NexusDB.communityBuilds and NexusDB.communityBuilds["bob-1"],
    "automatic login sync did not accept current build metadata")
print("automatic login sync receives current mesh metadata -- OK")

-- Once the bounded window expires, unsolicited traffic is ignored.
clock=clock+70
assert(not Sync.IsReceiving(),"automatic receive window should expire")
local msgs2=EncodeBob("bob-2","Bob's Second",200)
for _,m in ipairs(msgs2) do Sync.HandleIncoming(m.text,"Bob") end
assert(not NexusDB.communityBuilds["bob-2"],"unsolicited data was accepted outside a sync window")
print("unsolicited data is ignored after the login window -- OK")

-- Manual Sync Now reopens convergence.
clock=clock+10
assert(Sync.RequestSync(),"manual sync should succeed")
for _,m in ipairs(msgs2) do Sync.HandleIncoming(m.text,"Bob") end
assert(NexusDB.communityBuilds["bob-2"],"manual sync did not accept missing metadata")
print("manual sync reopens the receive window -- OK")

-- Drain the manual request, then verify there is no recurring background chatter.
for i=1,20 do Sync.OnUpdate(0.2) end
clock=clock+70
H.sentChatMessages={}
for i=1,500 do clock=clock+1; Sync.OnUpdate(1.0) end
assert(#H.sentChatMessages==0,"idle addon repeated automatic sync traffic")
print("login sync is one-shot; idle addon stays quiet -- OK")
