local H=dofile('tests/harness.lua')
dofile('core/Codec.lua'); dofile('core/Sync.lua'); dofile('core/DpsCapture.lua')
local Sync=Nexus.Sync
local clock=1000; GetTime=function() return clock end; time=function() return 50000 end
local who='Author'; UnitName=function() return who end
local echoes={}; for i=1,79 do echoes[i]={spellId=200000+i,stacks=1,quality=3} end
local build={id='cold-build',title='Gnome Army',description='full guide',author='Author',ownerKey='author@ebonhold',class='MAGE',echoes=echoes,postedAt=10,lastModified=10,isMine=true}

-- Source answers normal sync with summary only.
NexusDB={communityBuilds={[build.id]=build},syncTombstones={},dpsCapture={}}
Sync.Init(Nexus.Codec,{})
H.sentChatMessages={}
Sync.HandleIncoming('WLRQ|Fresh|0|0|cold-req','Fresh')
for i=1,100 do clock=clock+0.2; Sync.OnUpdate(0.2) end
local summaries={}
for _,m in ipairs(H.sentChatMessages) do
  if m.text:find('^WLBI') then summaries[#summaries+1]=m end
  assert(not m.text:find('^WLRB'),'normal index response leaked full build')
end
assert(#summaries==1,'source did not send compact summary')

-- Fresh client receives summary and automatically asks for the exact build.
who='Fresh'; NexusDB={communityBuilds={},syncTombstones={},dpsCapture={}}
clock=2000; Sync.Init(Nexus.Codec,{})
Sync.RequestSync()
for _,m in ipairs(summaries) do Sync.HandleIncoming(m.text,'Author') end
H.sentChatMessages={}
for i=1,30 do clock=clock+0.2; Sync.OnUpdate(0.2) end
local requests={}
for _,m in ipairs(H.sentChatMessages) do if m.text:find('^WLLQ') then requests[#requests+1]=m end end
assert(#requests>=1,'fresh client did not automatically backfill missing loadout')
assert(NexusDB.communityBuilds['cold-build'] and not NexusDB.communityBuilds['cold-build'].loadoutAvailable,'placeholder should remain incomplete before response')

-- A relay peer, not the original author, can satisfy the request.
who='Relay'; NexusDB.communityBuilds['cold-build']=build
H.sentChatMessages={}; clock=2100
for _,m in ipairs(requests) do Sync.HandleIncoming(m.text,'Fresh') end
for i=1,100 do clock=clock+0.2; Sync.OnUpdate(0.2) end
local relayResponse=H.sentChatMessages
local chunks=0
for _,m in ipairs(relayResponse) do if m.text:find('^WLRB') then chunks=chunks+1 end end
assert(chunks>0,'relay peer did not serve full loadout while author was offline')

-- Fresh client completes the build and stops requesting it.
who='Fresh'
local placeholder=NexusDB.communityBuilds['cold-build'] or {id='cold-build',title='Gnome Army',author='Author',ownerKey='author@ebonhold',class='MAGE',lastModified=10,fingerprintHash='placeholder',echoCount=79,echoes=nil,loadoutAvailable=false}
NexusDB={communityBuilds={['cold-build']=placeholder},syncTombstones={},dpsCapture={}}
clock=2200; Sync.Init(Nexus.Codec,{})
Sync.RequestLoadout('cold-build')
for _,m in ipairs(relayResponse) do Sync.HandleIncoming(m.text,'Relay') end
local loaded=NexusDB.communityBuilds['cold-build']
assert(loaded and loaded.echoes and #loaded.echoes==79 and loaded.description=='full guide','fresh client failed to complete full build')
H.sentChatMessages={}
for i=1,100 do clock=clock+0.2; Sync.OnUpdate(0.2) end
for _,m in ipairs(H.sentChatMessages) do assert(not m.text:find('WLLQ.-cold%-build'),'completed build was requested again') end

-- Missing peers trigger bounded retries, not an infinite flood.
NexusDB.communityBuilds['never-online']={id='never-online',title='Offline',author='Gone',class='MAGE',lastModified=1,fingerprintHash='abc',echoCount=79,echoes=nil,loadoutAvailable=false}
Sync.RequestFullLoadoutSync(); H.sentChatMessages={}
for i=1,1200 do clock=clock+0.2; Sync.OnUpdate(0.2) end
local retryCount=0
for _,m in ipairs(H.sentChatMessages) do if m.text:find('WLLQ.-never%-online') then retryCount=retryCount+1 end end
assert(retryCount>=2 and retryCount<=4,'offline retry count was not bounded: '..tostring(retryCount))
print('cold-start automatic full-library backfill and relay -- OK')
