-- Record class and per-character ownership regression coverage.
local H = dofile("tests/harness.lua")
dofile("core/Codec.lua"); dofile("core/Sync.lua"); dofile("core/DpsCapture.lua")
dofile("data/DefaultProfile.lua"); dofile("logic/Model.lua"); dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua"); dofile("logic/Policy.lua"); dofile("core/Store.lua")
dofile("core/GameAdapter.lua"); dofile("ui/CommunityBuilds.lua")

local DPS=Nexus.DpsCapture
local C=Nexus.CommunityBuilds
local A=Nexus.GameAdapter
local now=50000; time=function() return now end
GetNormalizedRealmName=function() return "Ebonhold" end
UnitName=function() return "Mageowner" end
UnitClass=function() return "Mage", "MAGE" end
NexusDB={communityBuilds={},syncTombstones={},dpsCapture={}}
DPS.Init(A,nil); C.Init(A,Nexus.Model)

local mageEchoes={{spellId=200100,stacks=1},{spellId=200101,stacks=1}}
local fp=DPS.GetEchoKey(mageEchoes)
local id,b=C.EnsureDpsBuildForEchoes(mageEchoes,"dummy",{
  player="Mageowner",class="MAGE",ownerKey="mageowner@ebonhold",realm="ebonhold",
  dps=24000000,duration=65,ts=now,fingerprint=fp,echoes=mageEchoes,
})
assert(id and b and b.class=="MAGE", "local Mage record must create a Mage build")
assert(C.IsOwnBuild(id), "capturing character must own its record page")

-- Account-wide SavedVariables do not grant ownership to another character.
UnitName=function() return "Shamanalt" end
UnitClass=function() return "Shaman", "SHAMAN" end
assert(not C.IsOwnBuild(id), "another character on the same account must not own the Mage build")
local ok,err=C.EditBuild(id,"Fraud edit","no")
assert(not ok and err=="not your build", "cross-character edit must be rejected")

-- Receiving a Mage record while logged into a Shaman must preserve Mage.
local remoteEchoes={{spellId=200102,stacks=1},{spellId=200103,stacks=2}}
local remoteFp=DPS.GetEchoKey(remoteEchoes)
assert(DPS.ReceiveRecord({v=7,f=remoteFp,e=remoteEchoes,c="dummy",d=25000000,u=65,t=now,
  p="Remotemage",k="MAGE",o="remotemage@ebonhold",r="ebonhold",l=80}),
  "valid remote Mage record should be accepted")
local found
for _,build in pairs(NexusDB.communityBuilds) do
  if build.author=="Remotemage" then found=build break end
end
assert(found and found.class=="MAGE", "remote Mage record must not inherit local Shaman class")
assert(not found.isMine and not C.IsOwnBuild(found), "remote record build must remain non-editable")

-- Explicitly invalid identity/class metadata is rejected.
assert(not DPS.ReceiveRecord({v=7,f=remoteFp,e=remoteEchoes,c="dummy",d=26000000,u=65,t=now,
  p="Remotemage",k="NOTACLASS",o="remotemage@ebonhold",r="ebonhold",l=80}),
  "invalid class token must be rejected")
assert(not DPS.ReceiveRecord({v=7,f=remoteFp,e=remoteEchoes,c="dummy",d=26000000,u=65,t=now,
  p="Remotemage",k="MAGE",o="someoneelse@ebonhold",r="ebonhold",l=80}),
  "mismatched owner identity must be rejected")

print("record class, ownership, and identity integrity -- OK")
