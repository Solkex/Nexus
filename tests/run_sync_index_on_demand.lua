local H=dofile('tests/harness.lua')
dofile('core/Codec.lua'); dofile('core/Sync.lua'); dofile('core/DpsCapture.lua')
local Sync=Nexus.Sync
local clock=1000; GetTime=function() return clock end; time=function() return 50000 end
local who='Source'; UnitName=function() return who end
local echoes={}; for i=1,79 do echoes[i]={spellId=200000+i,stacks=(i%3)+1,quality=3} end
local build={id='build-79',title='Full Record Build',description=string.rep('description ',50),author='Source',class='MAGE',echoes=echoes,postedAt=10,lastModified=10,isMine=true}
NexusDB={communityBuilds={[build.id]=build},syncTombstones={},dpsCapture={}}
Sync.Init(Nexus.Codec,{})
Nexus.DpsCapture.Init({},Sync)

-- Normal mesh response must send compact index only, never the large Echo payload.
H.sentChatMessages={}
Sync.HandleIncoming('WLRQ|Receiver|0|0|req-index','Receiver')
for i=1,100 do Sync.OnUpdate(0.2) end
local indexMsgs, fullMsgs=0,0
for _,m in ipairs(H.sentChatMessages) do
  if m.text:find('^WLBI||') or m.text:find('^WLBI|') then indexMsgs=indexMsgs+1 end
  if m.text:find('^WLRB||') or m.text:find('^WLRB|') then fullMsgs=fullMsgs+1 end
  assert(#m.text<=255,'wire message exceeded 255 chars')
end
assert(indexMsgs==1,'normal sync did not send exactly one compact build index')
assert(fullMsgs==0,'normal sync leaked a full exact loadout')
local summaryMessages=H.sentChatMessages

-- Receiver stores metadata without the Echo array.
NexusDB={communityBuilds={},syncTombstones={},dpsCapture={}}
who='Receiver'; clock=1100; Sync.Init(Nexus.Codec,{})
Sync.RequestSync()
for _,m in ipairs(summaryMessages) do Sync.HandleIncoming(m.text,'Source') end
local placeholder=NexusDB.communityBuilds['build-79']
assert(placeholder and (not placeholder.echoes or #placeholder.echoes==0),'summary unexpectedly contained full Echo data')
assert(placeholder.echoCount==79 and placeholder.fingerprintHash,'summary metadata incomplete')

-- A view/copy request asks for this one loadout. One mesh peer claims and sends it.
who='Source'; NexusDB.communityBuilds['build-79']=build
H.sentChatMessages={}; clock=1200
Sync.HandleIncoming('WLLQ|Receiver|build-79','Receiver')
for i=1,100 do Sync.OnUpdate(0.2) end
local response=H.sentChatMessages; local claims,chunks=0,0
for _,m in ipairs(response) do
  if m.text:find('^WLLC') then claims=claims+1 end
  if m.text:find('^WLRB') then chunks=chunks+1 end
  assert(#m.text<=255,'on-demand loadout chunk exceeded 255 chars')
end
assert(claims==1 and chunks>1,'on-demand transfer did not claim and chunk the exact loadout')

who='Receiver'; NexusDB.communityBuilds['build-79']=placeholder
clock=1300; Sync.RequestLoadout('build-79')
for _,m in ipairs(response) do Sync.HandleIncoming(m.text,'Source') end
local loaded=NexusDB.communityBuilds['build-79']
assert(loaded and loaded.echoes and #loaded.echoes==79,'on-demand loadout did not reassemble')
assert(loaded.description:find('description'),'full build description was not restored with loadout')
print('compact index sync and on-demand exact loadout transfer -- OK')
