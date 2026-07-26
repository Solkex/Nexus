-- Public boards: one highest winning loadout per character, ranked separately by encounter.
local H=dofile("tests/harness.lua")
dofile("core/Codec.lua"); dofile("core/Sync.lua"); dofile("core/DpsCapture.lua")
dofile("data/DefaultProfile.lua"); dofile("logic/Model.lua"); dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua"); dofile("logic/Policy.lua"); dofile("core/Store.lua")
dofile("core/GameAdapter.lua"); dofile("ui/CommunityBuilds.lua")
local DPS=Nexus.DpsCapture
UnitName=function(unit) return unit=="player" and "Viewer" or nil end
UnitClass=function() return "Mage","MAGE" end
NexusDB={communityBuilds={},syncTombstones={},dpsCapture={}}
DPS.Init({}, {BroadcastBuild=function() return true end})
local a={{spellId=200001,stacks=2},{spellId=200002,stacks=1}}
local b={{spellId=200010,stacks=1},{spellId=200011,stacks=3}}
local fa,fb=DPS.GetEchoKey(a),DPS.GetEchoKey(b)
assert(DPS.ReceiveRecord({v=4,f=fa,e=a,c="dummy",d=24000000,u=65,t=100,p="Alpha",l=80}),"dummy A rejected")
assert(DPS.ReceiveRecord({v=4,f=fb,e=b,c="dummy",d=28000000,u=65,t=101,p="Bravo",l=80}),"dummy B rejected")
assert(DPS.ReceiveRecord({v=4,f=fa,e=a,c="lk",d=19000000,u=240,t=102,p="Alpha",l=80}),"LK A rejected")
assert(not DPS.ReceiveRecord({v=4,f=fb,e=b,c="dummy",d=23000000,u=65,t=103,p="Alpha",l=80}),"lower second loadout for the same character accepted")
local dummy=DPS.GetDpsBoard("dummy")
assert(#dummy==2,"dummy board should contain one row per character")
assert(dummy[1].player=="Bravo" and dummy[1].dps==28000000,"dummy board not DPS-ranked")
assert(dummy[1].build and dummy[1].buildId and #dummy[1].echoes==2,"board row lacks copyable exact build")
local lk=DPS.GetDpsBoard("lk")
assert(#lk==1 and lk[1].player=="Alpha" and lk[1].category=="lk","LK board not separate")
assert(DPS.GetDpsBoard("bad")[1]==nil,"invalid category should be empty")
print("separate Dummy/Lich boards, one row per character, exact loadout, and stale rejection -- OK")
