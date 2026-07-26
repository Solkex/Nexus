local H=dofile("tests/harness.lua")
dofile("core/Codec.lua"); dofile("core/Sync.lua"); dofile("core/DpsCapture.lua")
dofile("data/DefaultProfile.lua"); dofile("logic/Model.lua"); dofile("logic/Strategy.lua")
dofile("logic/Ratchet.lua"); dofile("logic/Policy.lua"); dofile("core/Store.lua")
dofile("core/GameAdapter.lua"); dofile("ui/CommunityBuilds.lua"); dofile("ui/Leaderboard.lua")
NexusDB={communityBuilds={},dpsCapture={}}
local D=Nexus.DpsCapture
D.Init({},nil)
local echoes={{spellId=200100,stacks=1}}
local id="verified-build"
NexusDB.communityBuilds[id]={id=id,title="Verified Mage",author="Mageone",class="MAGE",echoes=echoes,postedAt=1,lastModified=1}
local fp=D.GetEchoKey(echoes)
assert(not D.ReceiveRecord({v=7,f=fp,e=echoes,c="dummy",d=1000000,u=29,t=1,p="Mageone",k="MAGE",l=80,b=id}),"29 second current record accepted")
assert(D.ReceiveRecord({v=7,f=fp,e=echoes,c="dummy",d=1000000,u=30,t=2,p="Mageone",k="MAGE",l=80,b=id}),"30 second record rejected")
local verified=D.GetBuildVerification(id)
assert(verified and verified.duration==30,"verified build stamp missing")
Nexus.CommunityBuilds.Init(Nexus.GameAdapter,Nexus.Model)
Nexus.CommunityBuilds.Show()
assert(_G.NexusCommunityBuildsFrame._sortToggle:GetText()=="Sort: A-Z","redundant class sort still shown")
print("release UI polish and Details verification -- OK")
