-- Optimized mesh: state hashes skip current peers and responder claims suppress duplicates.
local H=dofile("tests/harness.lua")
dofile("core/Codec.lua"); dofile("core/Sync.lua"); dofile("core/DpsCapture.lua")
local Sync,DPS=Nexus.Sync,Nexus.DpsCapture
local clock=1000; GetTime=function() return clock end; time=function() return 50000 end
local playerName="RelayB"; UnitName=function() return playerName end; UnitLevel=function() return 80 end
local echoes={{spellId=200001,stacks=2},{spellId=200002,stacks=1}}
local build={id="manual-build",title="Real Build",description="Real description",author="Author",class="MAGE",echoes=echoes,postedAt=10,lastModified=10,isMine=false}
NexusDB={communityBuilds={[build.id]=build},syncTombstones={},dpsCapture={}}
Sync.Init(Nexus.Codec,{})
DPS.Init({},Sync)
-- Let the login-time automatic sync fire, then clear it before targeted claims.
for i=1,40 do Sync.OnUpdate(0.2) end
H.sentChatMessages={}
local fp=DPS.GetEchoKey(echoes)
assert(DPS.ReceiveRecord({v=4,f=fp,e=echoes,c="dummy",d=24000000,u=65,t=50000,p="Winner",l=80,b=build.id}))
local function buildHash(builds)
  local buckets={}; for i=1,8 do buckets[i]={} end
  local function bucket(id) local h=5381; for i=1,#id do h=((h*33)+id:byte(i))%2147483648 end; return (h%8)+1 end
  for id,b in pairs(builds) do local n=bucket(id); buckets[n][#buckets[n]+1]=id..":"..tostring(b.lastModified or b.postedAt or 0) end
  local out={}
  for n=1,8 do table.sort(buckets[n]); local h=5381; for _,text in ipairs(buckets[n]) do for i=1,#text do h=((h*33)+text:byte(i))%2147483648 end end; out[n]=#buckets[n]>0 and string.format("%x",h) or "0" end
  return table.concat(out,",")
end
local bh=buildHash(NexusDB.communityBuilds)
local dh=DPS.GetSyncHash()
-- Fully current requester receives nothing.
H.sentChatMessages={}
Sync.HandleIncoming("WLRQ|Current|"..bh.."|"..dh.."|req-current","Current")
for i=1,20 do Sync.OnUpdate(0.2) end
assert(#H.sentChatMessages==0,"current requester should receive no duplicate traffic")
-- Identical peer claims the response first, so this peer suppresses its queued copy.
H.sentChatMessages={}
Sync.HandleIncoming("WLRQ|NewPeer|0|0|req-claim","NewPeer")
Sync.HandleIncoming("WLRC|RelayA|NewPeer|req-claim|"..bh.."|"..dh,"RelayA")
for i=1,20 do Sync.OnUpdate(0.2) end
assert(#H.sentChatMessages==0,"identical responder claim did not suppress duplicate reply")
-- A claim advertising different state must not suppress our useful contribution.
H.sentChatMessages={}
Sync.HandleIncoming("WLRQ|OtherPeer|0|0|req-different","OtherPeer")
Sync.HandleIncoming("WLRC|PartialPeer|OtherPeer|req-different|different|different","PartialPeer")
for i=1,100 do Sync.OnUpdate(0.2) end
local claim,buildMsg,dpsMsg=false,false,false
for _,m in ipairs(H.sentChatMessages) do
  claim=claim or not not m.text:find("^WLRC|")
  buildMsg=buildMsg or not not m.text:find("^WLBI|")
  dpsMsg=dpsMsg or not not m.text:find("^WLD2|")
end
assert(claim and buildMsg and dpsMsg,"different-state peer incorrectly suppressed useful mesh response")
print("mesh hashes, responder claims, duplicate suppression and differing-state contribution -- OK")
