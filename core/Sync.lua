-- Nexus: core/Sync.lua v2.1
-- Peer-to-peer sharing for Nexus Builds.
--
-- A bounded lightweight sync runs once after login initialization. Sync Now
-- opens the same convergence window manually. Compact summaries arrive first,
-- then missing full builds are backfilled automatically with paced retries.
--
-- SHARING IS AUTOMATIC. Builds go out when you post or edit, and in
-- response to any peer sync request.
--
-- WIRE PROTOCOL (| separated; pipe escaped to || on send):
--   WLRQ|<sender>|<buildhash>|<dpshash>|<requestId> -- state request
--   WLRC|<sender>|<requester>|<requestId>|<buildhash>|<dpshash> -- claim
--   WLRB|<sender>|<id>|<m>|<idx>/<total>|<b64>  -- build chunk
--   WLRD|<sender>|<id>|<stamp>                   -- delete notification
--
-- PAYLOAD FORMAT (compact, ~65% smaller than verbose):
--   { id, t=title, a=author, c=class, m=lastModified,
--     d=description(omitted if empty), e=[[spellId,quality,stacks],...] }
--
-- ANTI-SPAM:
--   • 0.25s between compact queued sends; full loadouts remain on demand
--   • Eight build and DPS hash buckets: resend only changed subsets
--   • Responder claims: identical peers elect one sender; unique peers contribute
--   • 2s answer spacing between completed peer responses
--   • Hot-build window (120s): a build posted while no peer is listening
--     is still included in the next BroadcastMine so the peer catches it
--     on their next Sync Now
--   • Max 999 chunks per build (enforced before queuing)

Nexus = Nexus or {}
local Sync = {}
Nexus.Sync = Sync

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local SYNC_CHANNEL    = "wrbuildssync"
local CODE_BUILD      = "WLRB"
local CODE_INDEX      = "WLBI" -- lightweight build summary, no Echo list
local CODE_LOADOUT_REQ= "WLLQ" -- request one exact loadout by build id
local CODE_LOADOUT_CLAIM="WLLC" -- one peer claims an on-demand loadout response
local CODE_REQUEST    = "WLRQ"
local CODE_CLAIM      = "WLRC" -- responder claim; suppresses identical peer replies
local CODE_DELETE     = "WLRD"
local CODE_DPS        = "WLDS" -- legacy build-id DPS
local CODE_DPS2       = "WLD2" -- exact-set DPS chunks
local CODE_HELLO      = "NXHI" -- lightweight Nexus-presence announcement
local CODE_HELLO_ACK  = "NXHA" -- one-way acknowledgement so newcomers discover existing peers
local CHAT_LIMIT      = 255    -- WoW SendChatMessage hard cap
local CHAT_SAFETY     = 8      -- conservative margin
local MAX_BYTES       = 32768  -- refuse builds larger than this
local SEND_INTERVAL   = 0.75   -- hard minimum between addon-channel sends
local RECEIVE_WINDOW  = 60     -- seconds we accept builds after Sync Now
local INFLIGHT_GRACE  = 20     -- seconds to finish a transfer that started inside window
local REQUEST_COOLDOWN = 6     -- min seconds between our own Sync Now presses
local ANSWER_COOLDOWN  = 2     -- minimum gap between completed peer responses
local CLAIM_DELAY_MIN  = 0.35  -- deterministic responder-election delay
local CLAIM_DELAY_MAX  = 1.75
local HOT_WINDOW       = 120   -- seconds a just-posted build is re-included in answers
local JOIN_RETRY_INTERVAL = 10
local JOIN_MAX_ATTEMPTS   = 30
local AUTO_SYNC_DELAY_MIN  = 8
local AUTO_SYNC_DELAY_MAX  = 16
local BACKFILL_START_DELAY = 3     -- let compact summaries settle before large requests
local BACKFILL_SCAN_INTERVAL = 2   -- discover placeholders created by any sync path
local BACKFILL_REQUEST_INTERVAL = 0.75 -- pace exact-loadout requests
local BACKFILL_RESPONSE_TIMEOUT = 10   -- wait for a claimed/chunked response
local BACKFILL_RETRY_BASE = 12          -- increasing retry spacing
local BACKFILL_MAX_ATTEMPTS = 4         -- per login/manual convergence pass
local BACKFILL_MAX_OUTSTANDING = 1      -- only one large loadout request at a time
local SEND_WINDOW_SECONDS = 10           -- rolling global traffic budget
local SEND_WINDOW_MAX = 8                -- never exceed eight sends per ten seconds

------------------------------------------------------------------------
-- Module state
------------------------------------------------------------------------

local Codec, Adapter
local channelIndex
local sendQueue      = {}
local inflight       = {}
local dpsInflight    = {}   -- "sender:id" -> { chunks, total, t0, lastMod }
local seenRemoteIds  = {}   -- id -> lastModified we already hold
local tombstones     = {}   -- id -> stamp; never resurrect
local hotBuilds      = {}   -- id -> { build, t }; recently posted, include in answers
local ticker         = 0
local sentAtTimes    = {}   -- rolling global send timestamps
local joinRetryTicker = 0
local helloAckedAt   = {}   -- normalized peer -> session time last acknowledged
local joinAttempts   = 0
local receiveWindowUntil = 0
local lastRequestAt  = -math.huge
local lastAnsweredAt = -math.huge
local pendingResponses = {} -- requester:requestId -> deferred response candidate
local pendingLoadouts = {}  -- requester:buildId -> staggered on-demand response
local requestedLoadouts = {} -- buildId -> last request time; prevents UI refresh spam
local backfillJobs = {}       -- buildId -> retry state for automatic cold-start completion
local backfillScanTicker = 0
local backfillRequestTicker = 0
local lastSyncNewCount = 0
local recentActivity = {}      -- concise user-facing sync events
local ACTIVITY_CAP = 8
local ACTIVITY_VISIBLE_SECONDS = 8
local autoSyncPending = false
local autoSyncElapsed = 0
local autoSyncDelay = AUTO_SYNC_DELAY_MIN
local stats = {
    sent=0, received=0, duplicatesSkipped=0,
    malformedRejected=0, ignoredOutsideWindow=0,
    oversizeDropped=0, updated=0, skippedUpToDate=0,
}

------------------------------------------------------------------------
-- Diagnostic log
------------------------------------------------------------------------

local eventLog = {}
local LOG_CAP  = 300
local logSeq   = 0

local function LogEvent(cat, fmt, ...)
    logSeq = logSeq + 1
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then text = tostring(fmt) end
    eventLog[#eventLog+1] = { seq=logSeq, t=(GetTime and GetTime()) or 0,
        cat=cat, text=text }
    if #eventLog > LOG_CAP then table.remove(eventLog, 1) end
end

local function Activity(kind, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then text = tostring(fmt) end
    recentActivity[#recentActivity+1] = { t=(GetTime and GetTime()) or 0, kind=kind, text=text }
    while #recentActivity > ACTIVITY_CAP do table.remove(recentActivity, 1) end
end
Sync.Activity = Activity
function Sync.RecentActivity()
    local out = {}
    for i=1,#recentActivity do out[i] = recentActivity[i] end
    return out
end
function Sync.LatestActivity()
    local row = recentActivity[#recentActivity]
    if not row then return nil end
    local age = ((GetTime and GetTime()) or 0) - (tonumber(row.t) or 0)
    if age > ACTIVITY_VISIBLE_SECONDS then return nil end
    return row
end
Sync.LogEvent  = LogEvent
function Sync.EventLog()  return eventLog end
function Sync.ClearLog()  eventLog = {}; logSeq = 0 end
function Sync.LogRaw(e)   LogEvent("RX", "%s", tostring(e)) end
function Sync.RawLog()    return eventLog end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function Now()    return (GetTime and GetTime()) or 0 end
local function WallNow() return (time and time()) or 0 end
local function MyName() return (UnitName and UnitName("player")) or "?" end

local function NormalizePeerName(name)
    name = tostring(name or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local short = name:match("^([^-]+)") or name
    return short:lower(), short
end

local function PeerStore()
    NexusDB = NexusDB or {}
    NexusDB.nexusPeers = NexusDB.nexusPeers or {}
    return NexusDB.nexusPeers
end

function Sync.MarkPeer(name, version)
    local key, display = NormalizePeerName(name)
    local mine = NormalizePeerName(MyName())
    if key == "" or key == mine then return false end
    local store = PeerStore()
    local row = store[key] or {}
    row.name = display ~= "" and display or row.name or key
    row.lastSeen = WallNow()
    if version and version ~= "" then row.version = tostring(version) end
    store[key] = row
    return true
end

function Sync.IsKnownPeer(name)
    local key = NormalizePeerName(name)
    if key == "" then return false end
    local row = NexusDB and NexusDB.nexusPeers and NexusDB.nexusPeers[key]
    if not row then return false end
    local seen = tonumber(row.lastSeen) or 0
    local now = WallNow()
    -- Keep recently discovered users useful across relogs, but expire stale
    -- identities so a tooltip does not claim someone still runs Nexus forever.
    return now <= 0 or seen <= 0 or (now - seen) <= (30 * 24 * 60 * 60)
end

function Sync.GetPeerInfo(name)
    local key = NormalizePeerName(name)
    return NexusDB and NexusDB.nexusPeers and NexusDB.nexusPeers[key] or nil
end

local function EscapedLen(s)
    return #s + select(2, s:gsub("|", ""))
end

-- djb2 hash of the caller's library so peers can skip sends when already
-- up to date. Input: { [id] = { lastModified=N }, ... }
local BUILD_BUCKETS = 8
local function BuildBucket(id)
    local text = tostring(id or "")
    local h = 5381
    for i = 1, #text do h = ((h * 33) + text:byte(i)) % 2147483648 end
    return (h % BUILD_BUCKETS) + 1
end

local function SplitHashes(value)
    local out = {}
    local i = 1
    for part in tostring(value or ""):gmatch("([^,]+)") do out[i] = part; i = i + 1 end
    return out
end

local function TombStamp(value)
    if type(value) == "table" then return tonumber(value.stamp) or 0 end
    return tonumber(value) or 0
end

local function TombAuthor(value)
    return type(value) == "table" and tostring(value.author or "") or ""
end

local function LibraryHash(builds)
    local buckets = {}
    for i = 1, BUILD_BUCKETS do buckets[i] = {} end
    for id, b in pairs(builds or {}) do
        local bucket = BuildBucket(id)
        buckets[bucket][#buckets[bucket]+1] = id..":"..tostring(b.lastModified or b.postedAt or 0)
    end
    for id, tomb in pairs(tombstones or {}) do
        local bucket = BuildBucket(id)
        buckets[bucket][#buckets[bucket]+1] = "!"..id..":"..tostring(TombStamp(tomb))..":"..TombAuthor(tomb)
    end
    local hashes = {}
    for bucket = 1, BUILD_BUCKETS do
        table.sort(buckets[bucket])
        local h = 5381
        for _, text in ipairs(buckets[bucket]) do
            for i = 1, #text do h = ((h * 33) + text:byte(i)) % 2147483648 end
        end
        hashes[bucket] = #buckets[bucket] > 0 and string.format("%x", h) or "0"
    end
    return table.concat(hashes, ",")
end

local function CurrentBuildHash()
    return LibraryHash(NexusDB and NexusDB.communityBuilds or {})
end

local function CurrentDpsHash()
    local D = Nexus.DpsCapture
    if D and D.GetSyncHash then
        local ok, value = pcall(D.GetSyncHash)
        if ok and value then return tostring(value) end
    end
    return "0"
end

local function StableDelay(text)
    local h = 5381
    text = tostring(text or "")
    for i = 1, #text do h = ((h * 33) + text:byte(i)) % 1000003 end
    local span = CLAIM_DELAY_MAX - CLAIM_DELAY_MIN
    return CLAIM_DELAY_MIN + (h % 1000) / 999 * span
end

-- Compact payload: short field names + echo arrays instead of objects.
-- Cuts a 69-echo build from ~4100 bytes b64 down to ~1400 bytes b64
-- (8 chunks instead of 23).
local function CompactEncode(build)
    local e = {}
    for _, echo in ipairs(build.echoes or {}) do
        e[#e+1] = { tonumber(echo.spellId), tonumber(echo.quality) or 0,
                    math.max(1, tonumber(echo.stacks) or 1) }
    end
    return {
        id = build.id,
        t  = build.title,
        a  = build.author,
        o  = build.ownerKey,
        c  = build.class,
        m  = tonumber(build.lastModified) or tonumber(build.postedAt) or 0,
        d  = (type(build.description) == "string" and build.description ~= "")
             and build.description or nil,
        e  = e,
        x  = build.autoDps and 1 or nil,
        -- build link URL (optional; admin-set reference to external page)
        lk = (type(build.link) == "string" and build.link ~= "") and build.link or nil,
    }
end

-- Reverse compact -> standard shape (used on receive)
local function CompactDecode(data)
    if type(data) ~= "table" then return nil end
    -- Support both compact (t/a/c/m/e) and legacy verbose (title/author/...)
    local title  = data.t or data.title
    local author = data.a or data.author
    local ownerKey = data.o or data.ownerKey
    local class  = data.c or data.class
    local lastMod = tonumber(data.m or data.lastModified or data.postedAt) or 0
    local rawE   = data.e or data.echoes
    if not (data.id and title and type(rawE) == "table") then return nil end
    local echoes = {}
    for _, e in ipairs(rawE) do
        local spellId, quality, stacks
        if type(e) == "table" then
            -- compact array form [spellId, quality, stacks]
            if e[1] then
                spellId = tonumber(e[1])
                quality = tonumber(e[2]) or 0
                stacks  = math.max(1, tonumber(e[3]) or 1)
            else
                -- verbose object form (legacy)
                spellId = tonumber(e.spellId)
                quality = tonumber(e.quality) or 0
                stacks  = math.max(1, tonumber(e.stacks) or 1)
            end
        end
        if spellId and spellId > 0 then
            echoes[#echoes+1] = { spellId=spellId, quality=quality, stacks=stacks }
        end
    end
    if #echoes == 0 then return nil end
    return {
        id          = tostring(data.id),
        title       = tostring(title):sub(1, 120),
        author      = type(author) == "string" and author:sub(1, 80) or "Unknown",
        ownerKey    = type(ownerKey) == "string" and ownerKey:sub(1, 120) or nil,
        class       = type(class) == "string" and class:upper() or nil,
        description = type(data.d or data.description) == "string"
                      and (data.d or data.description):sub(1, 4000) or "",
        lastModified = lastMod,
        postedAt     = tonumber(data.postedAt) or lastMod,
        echoes       = echoes,
        autoDps      = data.x == 1 or data.autoDps == true,
        link         = (type(data.lk) == "string" and data.lk ~= "") and data.lk or nil,
    }
end

------------------------------------------------------------------------
-- Channel
------------------------------------------------------------------------

local function FindSyncChannel()
    if not GetChannelList then return nil end
    local all = { GetChannelList() }
    for i = 1, #all, 2 do
        local idx  = tonumber(all[i])
        local name = all[i+1]
        if idx and idx > 0 and type(name) == "string"
            and name:lower() == SYNC_CHANNEL then
            return idx
        end
    end
    return nil
end

local function HideChannelFromChat()
    if not NUM_CHAT_WINDOWS or not ChatFrame_RemoveChannel then return end
    for i = 1, NUM_CHAT_WINDOWS do
        local f = _G["ChatFrame"..i]
        if f then pcall(ChatFrame_RemoveChannel, f, SYNC_CHANNEL) end
    end
end

function Sync.EnsureChannel()
    local idx = FindSyncChannel()
    if idx then
        if channelIndex ~= idx then
            LogEvent("CHAN","already in '%s' at index %d", SYNC_CHANNEL, idx)
        end
        channelIndex = idx; return true
    end
    if JoinTemporaryChannel then pcall(JoinTemporaryChannel, SYNC_CHANNEL)
    elseif JoinChannelByName then pcall(JoinChannelByName, SYNC_CHANNEL) end
    idx = FindSyncChannel()
    if idx then
        channelIndex = idx
        HideChannelFromChat()
        LogEvent("CHAN","joined '%s' at index %d", SYNC_CHANNEL, idx)
        return true
    end
    LogEvent("CHAN","FAILED to join '%s'", SYNC_CHANNEL)
    return false
end

function Sync.ChannelName()  return SYNC_CHANNEL end
function Sync.ChannelIndex() return channelIndex end
function Sync.IsConnected()  return channelIndex ~= nil and channelIndex > 0 end
function Sync.Stats()        return stats end

------------------------------------------------------------------------
-- Receive window
------------------------------------------------------------------------

function Sync.IsReceiving()       return Now() < receiveWindowUntil end
function Sync.ReceiveTimeLeft()
    local l = receiveWindowUntil - Now(); return l > 0 and l or 0
end
function Sync.LastSyncNewCount()  return lastSyncNewCount end

local function CountMissingBuilds()
    local n = 0
    for _, build in pairs(NexusDB and NexusDB.communityBuilds or {}) do
        if build and ((type(build.echoes) ~= "table" or #build.echoes == 0) or build.needsFullBuild) then n = n + 1 end
    end
    return n
end

local function CountOutstandingBackfills()
    local now, n = Now(), 0
    for _, job in pairs(backfillJobs) do
        if job.lastRequest and now - job.lastRequest < BACKFILL_RESPONSE_TIMEOUT then n = n + 1 end
    end
    return n
end

function Sync.GetStatus()
    local missing = CountMissingBuilds()
    local outstanding = CountOutstandingBackfills()
    local queued = #sendQueue
    local receiving = Sync.IsReceiving()
    local throttled = false
    local now = Now()
    local recent = 0
    for _, t in ipairs(sentAtTimes) do if now - t < SEND_WINDOW_SECONDS then recent = recent + 1 end end
    if queued > 0 and (ticker < SEND_INTERVAL or recent >= SEND_WINDOW_MAX) then throttled = true end
    local phase, text
    if autoSyncPending then
        phase, text = "starting", "Sync starts after login settles"
    elseif outstanding > 0 then
        phase, text = "loadouts", string.format("Downloading exact loadouts: %d remaining", missing)
    elseif missing > 0 then
        phase, text = throttled and "throttled" or "loadouts", string.format("Completing library: %d loadout%s remaining", missing, missing == 1 and "" or "s")
    elseif queued > 0 then
        phase, text = throttled and "throttled" or "sending", string.format("Syncing safely: %d packet%s queued", queued, queued == 1 and "" or "s")
    elseif receiving then
        phase, text = "listening", string.format("Checking for updates: %ds", math.ceil(Sync.ReceiveTimeLeft()))
    else
        phase, text = "complete", "Library up to date"
    end
    if throttled then text = text .. " (rate limited)" end
    local cooldown = math.max(0, REQUEST_COOLDOWN - (now - lastRequestAt))
    local latest = Sync.LatestActivity and Sync.LatestActivity() or nil
    if latest and phase ~= "starting" and phase ~= "throttled" then
        if phase == "loadouts" then
            text = latest.text .. " - " .. tostring(missing) .. " loadout" .. (missing == 1 and "" or "s") .. " remaining"
        elseif phase == "sending" then
            text = latest.text .. " - syncing safely"
        else
            text = latest.text
        end
    end
    return { phase=phase, text=text, missing=missing, outstanding=outstanding, queued=queued,
        throttled=throttled, receiving=receiving, cooldown=cooldown, latest=latest }
end

------------------------------------------------------------------------
-- Send queue (globally rate-limited with backpressure)
------------------------------------------------------------------------

local function Enqueue(payload)
    if type(payload) ~= "string" or payload == "" then return false end
    sendQueue[#sendQueue+1] = payload
    return true
end

local function PumpQueue(elapsed)
    ticker = ticker + (elapsed or 0)
    if ticker < SEND_INTERVAL then return end
    local now = Now()
    local kept = {}
    for _, t in ipairs(sentAtTimes) do if now - t < SEND_WINDOW_SECONDS then kept[#kept+1] = t end end
    sentAtTimes = kept
    if #sentAtTimes >= SEND_WINDOW_MAX then return end
    local payload = sendQueue[1]
    if not payload then return end
    if not Sync.IsConnected() then
        Sync.EnsureChannel()
        if not Sync.IsConnected() then return end
    end
    table.remove(sendQueue, 1)
    ticker = 0
    local escaped = payload:gsub("|","||")
    if #escaped > CHAT_LIMIT then
        LogEvent("TX","DROPPED oversize msg (%d>%d): %s",
            #escaped, CHAT_LIMIT, payload:sub(1,40))
        stats.oversizeDropped = (stats.oversizeDropped or 0) + 1
        return
    end
    local ok = pcall(SendChatMessage, escaped, "CHANNEL", nil, channelIndex)
    if ok then
        sentAtTimes[#sentAtTimes+1] = Now()
        stats.sent = stats.sent + 1
        LogEvent("TX","sent %d chars ch=%s: %s",
            #escaped, tostring(channelIndex), payload:sub(1,44))
    else
        LogEvent("TX","SendChatMessage FAILED ch=%s", tostring(channelIndex))
    end
end


local function HashText(text)
    if type(text) ~= "string" or text == "" then return nil end
    local h = 5381
    for i=1,#text do h=((h*33)+text:byte(i))%2147483648 end
    return string.format("%x",h)
end

local ScheduleBackfill, ScheduleAllMissing, ProcessBackfill

-- Lightweight build index. Automatic mesh sync sends this metadata only;
-- the large Echo list is transferred on demand when a player views/copies it.
local function BuildFingerprint(build)
    local D = Nexus.DpsCapture
    if build and build.fingerprint then return tostring(build.fingerprint) end
    if D and D.GetEchoKey and build and type(build.echoes) == "table" then
        local ok, key = pcall(D.GetEchoKey, build.echoes)
        if ok and key then return key end
    end
    if build and type(build.echoes) == "table" then
        local counts = {}
        for _, e in ipairs(build.echoes) do
            local id = tonumber(e and (e.spellId or e.id))
            local n = tonumber(e and (e.count or e.stacks or e.stack)) or 1
            if id and n > 0 then counts[id] = (counts[id] or 0) + n end
        end
        local ids = {}; for id in pairs(counts) do ids[#ids+1]=id end
        table.sort(ids)
        local out = {}; for _,id in ipairs(ids) do out[#out+1]=tostring(id).."x"..tostring(counts[id]) end
        if #out > 0 then return table.concat(out, ",") end
    end
    return nil
end

local function SummaryEncode(build)
    return {
        id=build.id, t=build.title, a=build.author, o=build.ownerKey, c=build.class,
        m=tonumber(build.lastModified) or tonumber(build.postedAt) or 0,
        h=build.fingerprintHash or HashText(BuildFingerprint(build)), n=type(build.echoes)=="table" and #build.echoes or tonumber(build.echoCount) or 0,
        x=build.autoDps and 1 or nil,
        q=(type(build.link)=="string" and build.link~="") and HashText(build.link) or "0",
    }
end

local function BroadcastSummary(build)
    local payload = SummaryEncode(build)
    if not payload.id or not payload.h then return false end
    local data = Codec.Base64Encode(Codec.JSONEncode(payload))
    local msg = string.format("%s|%s|%s", CODE_INDEX, MyName(), data)
    if EscapedLen(msg) > CHAT_LIMIT - CHAT_SAFETY then return false end
    Enqueue(msg)
    LogEvent("TX","queuing summary '%s' (%d chars, no Echo list)", tostring(build.title), EscapedLen(msg))
    return true
end
Sync.BroadcastBuildSummary = BroadcastSummary

local function StoreSummary(data)
    if type(data)~="table" or not data.id or not data.t or not data.h then return false end
    NexusDB.communityBuilds = NexusDB.communityBuilds or {}
    local id = tostring(data.id)
    local old = NexusDB.communityBuilds[id]
    local incomingOwner = type(data.o) == "string" and data.o:lower() or nil
    local existingOwner = old and type(old.ownerKey) == "string" and old.ownerKey:lower() or nil
    if incomingOwner and existingOwner and incomingOwner ~= existingOwner then
        LogEvent("RX","REJECT summary '%s': owner identity changed", tostring(data.t))
        return false
    end
    local stamp = tonumber(data.m) or 0
    local tomb = tombstones[id]
    if tomb and stamp <= TombStamp(tomb) then
        LogEvent("RX","skip summary '%s': tombstoned", tostring(data.t))
        return false
    end
    local oldStamp = old and (tonumber(old.lastModified) or tonumber(old.postedAt) or 0) or nil
    if oldStamp and stamp < oldStamp then
        LogEvent("RX","skip summary '%s': older than local copy", tostring(data.t))
        return false
    end
    if oldStamp and stamp == oldStamp then
        stats.duplicatesSkipped = stats.duplicatesSkipped + 1
        LogEvent("RX","skip summary '%s': DUPLICATE", tostring(data.t))
        return false
    end
    local newHash = tostring(data.h)
    local incomingLinkHash = tostring(data.q or "0")
    local oldLinkHash = old and tostring(old.linkHash or ((type(old.link)=="string" and old.link~="") and HashText(old.link) or "0")) or "0"
    local keepEchoes = old and old.fingerprintHash == newHash and old.echoes or nil
    -- A summary carries title/class/hash but not description or the actual
    -- Discord link. Any newer summary for a build we already know must be
    -- followed by its full update, even when the Echo fingerprint is unchanged.
    local needsFullBuild = old ~= nil
    NexusDB.communityBuilds[id] = {
        id=id, title=tostring(data.t):sub(1,120), author=tostring(data.a or "Unknown"):sub(1,80),
        ownerKey=type(data.o)=="string" and data.o:sub(1,120) or (old and old.ownerKey),
        class=type(data.c)=="string" and data.c:upper() or nil, description=old and old.description or "",
        lastModified=stamp, postedAt=old and old.postedAt or stamp, isMine=old and old.isMine or false,
        autoDps=data.x==1, fingerprint=keepEchoes and old.fingerprint or nil,
        fingerprintHash=newHash, echoCount=tonumber(data.n) or 0,
        echoes=keepEchoes, loadoutAvailable=type(keepEchoes)=="table" and #keepEchoes>0,
        link=old and old.link or nil, linkHash=incomingLinkHash, needsFullBuild=needsFullBuild,
    }
    seenRemoteIds[id] = stamp
    stats.received = stats.received + 1
    lastSyncNewCount = lastSyncNewCount + 1
    if old then
        stats.updated = (stats.updated or 0) + 1
        LogEvent("RX","UPDATED summary '%s' by %s%s", tostring(data.t), tostring(data.a or "Unknown"),
            keepEchoes and " (loadout unchanged; metadata refresh needed)" or " (loadout needed)")
        Activity("build_updated", "Updated build: %s", tostring(data.t))
    else
        LogEvent("RX","STORED summary '%s' by %s (%d Echo entries queued for backfill)",
            tostring(data.t), tostring(data.a or "Unknown"), tonumber(data.n) or 0)
        Activity("build_found", "Found build: %s", tostring(data.t))
    end
    if ScheduleBackfill then ScheduleBackfill(id, BACKFILL_START_DELAY, false) end
    return true
end

local function BuildNeedsFullData(build)
    return build and ((type(build.echoes) ~= "table" or #build.echoes == 0) or build.needsFullBuild)
end

ScheduleBackfill = function(buildId, delay, resetAttempts)
    buildId = tostring(buildId or "")
    if buildId == "" then return false, false end
    local build = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[buildId]
    if not BuildNeedsFullData(build) then
        backfillJobs[buildId] = nil
        return false, false
    end
    local now = Now()
    local existed = backfillJobs[buildId] ~= nil
    local job = backfillJobs[buildId] or { attempts=0 }
    if resetAttempts then
        job.attempts = 0
        job.lastRequest = nil
    end
    local due = now + (tonumber(delay) or 0)
    if not job.nextAt or due < job.nextAt or resetAttempts then job.nextAt = due end
    backfillJobs[buildId] = job
    return true, not existed
end

ScheduleAllMissing = function(delay, resetAttempts)
    local n, added = 0, 0
    for id, build in pairs(NexusDB and NexusDB.communityBuilds or {}) do
        if BuildNeedsFullData(build) then
            local scheduled, created = ScheduleBackfill(id, delay, resetAttempts)
            if scheduled then n = n + 1 end
            if created then added = added + 1 end
        end
    end
    if added > 0 or (resetAttempts and n > 0) then
        LogEvent("SYNC","queued %d incomplete build(s) for automatic backfill", n)
    end
    return n
end

function Sync.RequestLoadout(buildId)
    buildId = tostring(buildId or "")
    local build = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[buildId]
    if buildId == "" or not BuildNeedsFullData(build) then
        backfillJobs[buildId] = nil
        return false
    end
    local now = Now()
    if requestedLoadouts[buildId] and now-requestedLoadouts[buildId] < 8 then return false end
    requestedLoadouts[buildId] = now
    receiveWindowUntil = math.max(receiveWindowUntil, now+INFLIGHT_GRACE)
    Enqueue(string.format("%s|%s|%s", CODE_LOADOUT_REQ, MyName(), buildId))
    local job = backfillJobs[buildId] or { attempts=0 }
    job.attempts = (tonumber(job.attempts) or 0) + 1
    job.lastRequest = now
    job.nextAt = now + BACKFILL_RETRY_BASE * math.min(job.attempts, 3)
    backfillJobs[buildId] = job
    LogEvent("SYNC","requested exact build '%s' (attempt %d)", buildId, job.attempts)
    return true
end

function Sync.RequestFullLoadoutSync()
    receiveWindowUntil = Now()+RECEIVE_WINDOW
    local n = ScheduleAllMissing(0, true)
    LogEvent("SYNC","scheduled %d incomplete exact build(s) for paced backfill", n)
    return true, n
end

ProcessBackfill = function(elapsed)
    local now = Now()
    backfillScanTicker = backfillScanTicker + (tonumber(elapsed) or 0)
    backfillRequestTicker = backfillRequestTicker + (tonumber(elapsed) or 0)
    if backfillScanTicker >= BACKFILL_SCAN_INTERVAL then
        backfillScanTicker = 0
        ScheduleAllMissing(BACKFILL_START_DELAY, false)
    end
    if not Sync.IsConnected() or backfillRequestTicker < BACKFILL_REQUEST_INTERVAL then return end
    local outstanding = 0
    for id, job in pairs(backfillJobs) do
        local build = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[id]
        if not BuildNeedsFullData(build) then
            backfillJobs[id] = nil
        elseif job.lastRequest and now - job.lastRequest < BACKFILL_RESPONSE_TIMEOUT then
            outstanding = outstanding + 1
        end
    end
    if outstanding >= BACKFILL_MAX_OUTSTANDING then return end
    local chosenId, chosenJob
    for id, job in pairs(backfillJobs) do
        if (tonumber(job.attempts) or 0) < BACKFILL_MAX_ATTEMPTS
            and now >= (tonumber(job.nextAt) or 0)
            and (not chosenJob or (tonumber(job.nextAt) or 0) < (tonumber(chosenJob.nextAt) or 0)
                or ((tonumber(job.nextAt) or 0) == (tonumber(chosenJob.nextAt) or 0) and tostring(id) < tostring(chosenId))) then
            chosenId, chosenJob = id, job
        end
    end
    if chosenId then
        backfillRequestTicker = 0
        Sync.RequestLoadout(chosenId)
    end
end

-- Header-aware chunking: measures the ACTUAL escaped header so no chunk
-- can ever exceed the hard limit.
local function SendChunked(buildId, lastMod, data)
    if type(data) ~= "string" or #data > MAX_BYTES then return false end
    local sender = MyName()
    -- Worst-case header = largest chunk index digits (999/999)
    local sampleHdr = string.format("%s|%s|%s|%s|999/999|",
        CODE_BUILD, sender, buildId, lastMod)
    local budget = CHAT_LIMIT - CHAT_SAFETY - EscapedLen(sampleHdr)
    if budget < 32 then return false, "id too long" end

    local single = string.format("%s|%s|%s|%s|1/1|%s",
        CODE_BUILD, sender, buildId, lastMod, data)
    if EscapedLen(single) <= CHAT_LIMIT - CHAT_SAFETY then
        Enqueue(single); return true
    end
    local total = math.ceil(#data / budget)
    if total > 999 then return false, "build too large" end
    for idx = 1, total do
        local s = (idx-1)*budget + 1
        Enqueue(string.format("%s|%s|%s|%s|%d/%d|%s",
            CODE_BUILD, sender, buildId, lastMod, idx, total,
            data:sub(s, s+budget-1)))
    end
    return true
end

------------------------------------------------------------------------
-- Outgoing
------------------------------------------------------------------------

function Sync.BroadcastBuild(build)
    if not build or type(build.echoes) ~= "table" or #build.echoes == 0 then
        return false, "no echoes"
    end
    local payload = CompactEncode(build)
    local json    = Codec.JSONEncode(payload)
    local b64     = Codec.Base64Encode(json)
    if #b64 > MAX_BYTES then
        LogEvent("TX","'%s' too large (%d bytes)", tostring(build.id), #b64)
        return false, "too large"
    end
    local lastMod = tostring(payload.m)
    LogEvent("TX","queuing '%s' %d echoes %d b64 bytes (compact)",
        tostring(build.title), #build.echoes, #b64)
    -- Mark hot: any BroadcastMine in the next HOT_WINDOW seconds includes this
    hotBuilds[build.id] = { build=build, t=Now() }
    return SendChunked(build.id, lastMod, b64)
end

function Sync.BroadcastMine()
    if not (NexusDB and NexusDB.communityBuilds) then return 0 end
    local now = Now()
    -- Expire hot builds
    for id, h in pairs(hotBuilds) do
        if now - h.t > HOT_WINDOW then hotBuilds[id] = nil end
    end
    local sent = {}   -- track by id to avoid double-sending
    local n = 0
    -- True mesh: redistribute every valid build held locally.
    for _, b in pairs(NexusDB.communityBuilds) do
        if BroadcastSummary(b) then n=n+1 end
        sent[b.id] = true
    end
    -- Also include hot builds not already sent (covers: posted while no
    -- peer was listening, then peer syncs within HOT_WINDOW)
    for id, h in pairs(hotBuilds) do
        if not sent[id] then
            if BroadcastSummary(h.build) then n=n+1 end
        end
    end
    return n
end

-- Only send builds the requester doesn't already have.
-- peerHash: djb2 hash of peer's library (from their WLRQ).
-- If hash matches ours, peer is fully up to date → send nothing.
local function BroadcastMineFiltered(peerHash)
    local myDB = NexusDB and NexusDB.communityBuilds or {}
    local myMine = {}
    for id, b in pairs(myDB) do myMine[id] = b end
    for id, h in pairs(hotBuilds) do
        if not myMine[id] and (Now()-h.t) <= HOT_WINDOW then myMine[id] = h.build end
    end
    if not next(myMine) and not next(tombstones or {}) then LogEvent("TX","nothing to share"); return 0 end
    local myHash = LibraryHash(myMine)
    if peerHash and tostring(peerHash) == tostring(myHash) then
        LogEvent("TX","peer build buckets match -- sending nothing")
        stats.skippedUpToDate = (stats.skippedUpToDate or 0) + 1
        return 0
    end
    local peerBuckets = SplitHashes(peerHash)
    local myBuckets = SplitHashes(myHash)
    local legacyPeer = #peerBuckets ~= BUILD_BUCKETS
    local n = 0
    for id, b in pairs(myMine) do
        local bucket = BuildBucket(id)
        if legacyPeer or tostring(peerBuckets[bucket] or "") ~= tostring(myBuckets[bucket] or "") then
            if BroadcastSummary(b) then n=n+1 end
        end
    end
    for id, tomb in pairs(tombstones or {}) do
        local bucket = BuildBucket(id)
        if legacyPeer or tostring(peerBuckets[bucket] or "") ~= tostring(myBuckets[bucket] or "") then
            Enqueue(string.format("%s|%s|%s|%s|%s", CODE_DELETE, MyName(), id,
                tostring(TombStamp(tomb)), TombAuthor(tomb)))
            n=n+1
        end
    end
    return n
end

function Sync.BroadcastPresence()
    if not Sync.IsConnected() then return false end
    Enqueue(string.format("%s|%s|%s", CODE_HELLO, MyName(), tostring(Nexus.VERSION or "?")))
    LogEvent("TX", "presence announced")
    return true
end

function Sync.RequestSync()
    if not Sync.IsConnected() and not Sync.EnsureChannel() then
        joinAttempts = 0
        LogEvent("SYNC","sync requested but not connected")
        return false, "not connected to the sync channel"
    end
    local now = Now()
    if now - lastRequestAt < REQUEST_COOLDOWN then
        local wait = math.max(1, math.ceil(REQUEST_COOLDOWN - (now - lastRequestAt)))
        LogEvent("SYNC","sync request ignored (cooldown %.1fs)", now-lastRequestAt)
        Activity("waiting", "Sync already requested - wait %ds", wait)
        return false, "sync already in progress — wait " .. tostring(wait) .. "s"
    end
    lastRequestAt = now
    lastSyncNewCount = 0
    receiveWindowUntil = now + RECEIVE_WINDOW
    -- Include independent build and leaderboard hashes. Identical peers can
    -- suppress their response entirely, and peers with the same state elect
    -- one responder instead of all flooding the channel with duplicates.
    local buildHash = CurrentBuildHash()
    local dpsHash = CurrentDpsHash()
    local requestId = tostring(math.floor(now * 1000)) .. "-" .. tostring(math.random(1000,9999))
    Enqueue(string.format("%s|%s|%s", CODE_HELLO, MyName(), tostring(Nexus.VERSION or "?")))
    Enqueue(string.format("%s|%s|%s|%s|%s", CODE_REQUEST, MyName(), buildHash, dpsHash, requestId))
    ScheduleAllMissing(BACKFILL_START_DELAY, true)
    LogEvent("SYNC","requested sync (build=%s dps=%s id=%s) -- window open %ds",
        buildHash, dpsHash, requestId, RECEIVE_WINDOW)
    Activity("sync", "Checking the mesh for updates")
    return true
end

-- Broadcast a validated exact-set DPS record. The JSON/base64 payload is
-- chunked using the same 255-byte-safe discipline as build sync.
function Sync.BroadcastDpsRecord(record)
    if type(record) ~= "table" or type(record.fingerprint) ~= "string"
        or not tonumber(record.dps) then return false end
    local loadoutHash = record.loadoutHash
    if not loadoutHash then
        local fp = tostring(record.fingerprint)
        loadoutHash = fp:sub(1,1) == "@" and fp:sub(2) or HashText(fp)
    end
    if not loadoutHash then return false end
    local payload = {
        v = tonumber(record.protocolVersion) or 5,
        h = loadoutHash,
        c = record.category, d = math.floor(tonumber(record.dps) or 0),
        u = tonumber(record.duration) or 0, t = tonumber(record.ts) or 0,
        p = tostring(record.player or "?"), k = record.class,
        o = record.ownerKey, r = record.realm,
        l = tonumber(record.level) or 0, b = record.buildId,
    }
    local encoded = Codec.Base64Encode(Codec.JSONEncode(payload))
    local transferId = tostring(payload.p) .. ":" .. tostring(payload.t) .. ":" .. tostring(payload.d)
    local header = CODE_DPS2 .. "|" .. MyName() .. "|" .. transferId .. "|999/999|"
    local chunkSize = CHAT_LIMIT - CHAT_SAFETY - EscapedLen(header)
    if chunkSize < 24 then return false end
    local total = math.ceil(#encoded / chunkSize)
    if total < 1 or total > 999 then return false end
    for i = 1, total do
        local data = encoded:sub((i - 1) * chunkSize + 1, i * chunkSize)
        Enqueue(string.format("%s|%s|%s|%d/%d|%s",
            CODE_DPS2, MyName(), transferId, i, total, data))
    end
    LogEvent("TX","DPS2 [%s] %.0f by %s (%d chunks)",
        tostring(payload.c), payload.d, payload.p, total)
    return true
end

-- Legacy wrapper retained for older callers/peers.
function Sync.BroadcastDps(buildId, player, dps, level, category)
    if not (buildId and player and dps and dps > 0) then return false end
    local payload = string.format("%s|%s|%s|%s|%s|%s|%s",
        CODE_DPS, MyName(), buildId, tostring(player),
        tostring(math.floor(dps)), tostring(level or 0), category or "dummy")
    if EscapedLen(payload) > CHAT_LIMIT - CHAT_SAFETY then return false end
    Enqueue(payload)
    return true
end

local function HandleDps(parts)
    local sender = parts[2] or ""
    local buildId, player = parts[3], parts[4]
    local dps, level = tonumber(parts[5]), tonumber(parts[6]) or 0
    local category = parts[7] or "dummy"
    -- Direct submission: player field must match the wire sender
    if player and player ~= "" and player:lower() ~= sender:lower() then
        LogEvent("RX","DROP direct DPS: player='%s' != sender='%s'", tostring(player), tostring(sender))
        return
    end
    if Nexus.DpsCapture and Nexus.DpsCapture.ReceiveSubmission then
        pcall(Nexus.DpsCapture.ReceiveSubmission,
            buildId, player, dps, level, category)
    end
end

local function HandleDps2(parts)
    local sender, transferId, spec, data = parts[2], parts[3], parts[4], parts[5]
    if not (sender and transferId and spec and data) then return end
    local idx, total = spec:match("^(%d+)/(%d+)$")
    idx, total = tonumber(idx), tonumber(total)
    if not (idx and total and idx >= 1 and idx <= total and total <= 999) then return end
    local key = sender .. ":" .. transferId
    local e = dpsInflight[key]
    if not e then
        e = { chunks = {}, total = total, t0 = Now() }
        dpsInflight[key] = e
    end
    if e.total ~= total then dpsInflight[key] = nil; return end
    e.chunks[idx] = data
    for i = 1, total do if not e.chunks[i] then return end end
    dpsInflight[key] = nil
    local raw = Codec.Base64Decode(table.concat(e.chunks, "", 1, total))
    local record = raw and Codec.JSONDecode(raw)
    if type(record) ~= "table" then return end
    if Nexus.DpsCapture and Nexus.DpsCapture.ReceiveRecord then
        local ok, accepted = pcall(Nexus.DpsCapture.ReceiveRecord, record)
        if ok and accepted then
            local label = tostring(record.category) == "lk" and "Lich King" or "Training Dummy"
            local dps = tonumber(record.dps) or 0
            local shown = dps >= 1000000 and string.format("%.2fM", dps/1000000) or tostring(math.floor(dps))
            Activity("leaderboard", "Leaderboard updated: %s - %s", tostring(record.player or "Unknown"), shown)
            -- Mesh redistribution: only a newly accepted higher record is relayed.
            Sync.BroadcastDpsRecord(record)
        end
    end
end

function Sync.BroadcastDelete(build)
    if not build or not build.id then return false end
    local stamp = tostring((time and time()) or 0)
    local author = tostring(build.author or MyName())
    tombstones[build.id] = { stamp=tonumber(stamp) or 0, author=author }
    Enqueue(string.format("%s|%s|%s|%s|%s",
        CODE_DELETE, MyName(), build.id, stamp, author))
    LogEvent("TX","delete '%s'", tostring(build.title or build.id))
    return true
end

------------------------------------------------------------------------
-- Incoming
------------------------------------------------------------------------

local function CleanExpiredInflight()
    local now = Now()
    for key, v in pairs(inflight) do
        if now - (v.t0 or now) > INFLIGHT_GRACE then inflight[key] = nil end
    end
end

local function ValidatePayload(data)
    if type(data) ~= "table" then return nil end
    if not Codec.IsSafeTree(data, 6, 2000) then return nil end
    return CompactDecode(data)
end

local function ShouldStore(id, lastMod)
    local tomb = tombstones[id]
    if tomb and (tonumber(lastMod) or 0) <= TombStamp(tomb) then return false, "deleted" end
    local known = seenRemoteIds[id]
    if known == nil then return true, "new" end
    local existing = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[id]
    if existing and (type(existing.echoes) ~= "table" or #existing.echoes == 0) then
        return true, "loadout"
    end
    if existing and existing.needsFullBuild and (tonumber(lastMod) or 0) >= known then
        return true, "metadata"
    end
    if (tonumber(lastMod) or 0) > known then return true, "updated" end
    return false, "duplicate"
end

local function StoreReceivedBuild(payload)
    NexusDB.communityBuilds = NexusDB.communityBuilds or {}
    local existing = NexusDB.communityBuilds[payload.id]
    if existing and existing.ownerKey and payload.ownerKey
        and tostring(existing.ownerKey):lower() ~= tostring(payload.ownerKey):lower() then
        LogEvent("RX","REJECT full build '%s': owner identity changed", tostring(payload.title or payload.id))
        return false
    end
    local mine = (existing and existing.isMine) or false
    -- Preserve an existing local link if the incoming payload has no link
    local link = payload.link or (existing and existing.link) or nil
    NexusDB.communityBuilds[payload.id] = {
        id=payload.id, title=payload.title, description=payload.description,
        author=payload.author, ownerKey=payload.ownerKey, class=payload.class, echoes=payload.echoes,
        postedAt=payload.postedAt, lastModified=payload.lastModified, isMine=mine,
        autoDps=payload.autoDps, fingerprint=BuildFingerprint(payload), fingerprintHash=HashText(BuildFingerprint(payload)), echoCount=#payload.echoes, loadoutAvailable=true,
        link=link, linkHash=(type(link)=="string" and link~="") and HashText(link) or "0", needsFullBuild=false,
    }
    seenRemoteIds[payload.id] = payload.lastModified
    requestedLoadouts[payload.id] = nil
    backfillJobs[payload.id] = nil
    stats.received = stats.received + 1
    lastSyncNewCount = lastSyncNewCount + 1
end

local function HandleComplete(buildId, lastMod, fullData)
    local json = Codec.Base64Decode(fullData)
    if not json then
        stats.malformedRejected = stats.malformedRejected + 1
        LogEvent("RX","REJECT '%s': bad base64 (%d bytes -- truncated?)",
            tostring(buildId), #tostring(fullData)); return
    end
    local data = Codec.JSONDecode(json)
    if not data then
        stats.malformedRejected = stats.malformedRejected + 1
        LogEvent("RX","REJECT '%s': JSON decode failed", tostring(buildId)); return
    end
    -- Silently drop legacy placeholder builds posted as "WR Team" before the rename
    if tostring(data.a or data.author or ""):lower() == "wr team" then
        LogEvent("RX","REJECT legacy placeholder '%s'", tostring(data.t or data.title))
        return
    end
    local payload = ValidatePayload(data)
    if not payload then
        stats.malformedRejected = stats.malformedRejected + 1
        LogEvent("RX","REJECT '%s': validation failed", tostring(buildId)); return
    end
    if payload.id ~= buildId then
        stats.malformedRejected = stats.malformedRejected + 1
        LogEvent("RX","REJECT id mismatch: envelope='%s' payload='%s'",
            tostring(buildId), tostring(payload.id)); return
    end
    local allowed, why = ShouldStore(payload.id, payload.lastModified)
    if not allowed then
        if why == "deleted" then
            LogEvent("RX","skip '%s': tombstoned", tostring(payload.title))
        else
            stats.duplicatesSkipped = stats.duplicatesSkipped + 1
            LogEvent("RX","skip '%s': DUPLICATE (have stamp %s)",
                tostring(payload.title), tostring(seenRemoteIds[payload.id]))
        end
        return
    end
    if StoreReceivedBuild(payload) == false then return end
    if why == "updated" then
        stats.updated = (stats.updated or 0) + 1
        LogEvent("RX","UPDATED '%s' by %s (%d echoes, %s->%s)",
            tostring(payload.title), tostring(payload.author), #payload.echoes,
            tostring(seenRemoteIds[payload.id]), tostring(payload.lastModified))
        Activity("build_updated", "Updated build: %s", tostring(payload.title))
    elseif why == "loadout" then
        LogEvent("RX","LOADED exact Echo list for '%s' by %s (%d echoes)",
            tostring(payload.title), tostring(payload.author), #payload.echoes)
        Activity("loadout", "Downloaded loadout: %s", tostring(payload.title))
    else
        LogEvent("RX","STORED (new) '%s' by %s (%d echoes)",
            tostring(payload.title), tostring(payload.author), #payload.echoes)
        Activity("build_received", "Received build: %s", tostring(payload.title))
    end
    if Nexus.CommunityBuilds and Nexus.CommunityBuilds.Refresh then
        pcall(Nexus.CommunityBuilds.Refresh)
    end
end

local function SendSyncResponse(entry)
    local now = Now()
    if now - lastAnsweredAt < ANSWER_COOLDOWN then
        entry.remaining = ANSWER_COOLDOWN
        pendingResponses[entry.key] = entry
        return
    end
    lastAnsweredAt = now
    local buildHash, dpsHash = CurrentBuildHash(), CurrentDpsHash()
    if buildHash == entry.peerBuildHash and dpsHash == entry.peerDpsHash then
        LogEvent("RX","request from %s already up to date", tostring(entry.requester))
        return
    end
    -- Claim before queueing payloads. Other peers holding the exact same state
    -- cancel their pending response; peers with different state still answer.
    Enqueue(string.format("%s|%s|%s|%s|%s|%s", CODE_CLAIM, MyName(),
        entry.requester, entry.requestId, buildHash, dpsHash))
    local n = BroadcastMineFiltered(entry.peerBuildHash)
    local dpsN = 0
    local D = Nexus.DpsCapture
    if dpsHash ~= entry.peerDpsHash and D and D.BroadcastAllBuildBests then
        local ok, result = pcall(D.BroadcastAllBuildBests, entry.peerDpsHash)
        if ok then dpsN = tonumber(result) or 0 end
    end
    LogEvent("RX","answering %s id=%s with %d build summaries, %d record set(s)",
        tostring(entry.requester), tostring(entry.requestId), n, dpsN)
end

local function HandleRequest(requester, peerBuildHash, peerDpsHash, requestId)
    if requester == MyName() then
        LogEvent("RX","ignoring own request (no echo loop)"); return
    end
    peerBuildHash = peerBuildHash or "0"
    peerDpsHash = peerDpsHash or "0"
    requestId = requestId or ("legacy-" .. tostring(requester) .. "-" .. tostring(math.floor(Now())))
    local myBuildHash, myDpsHash = CurrentBuildHash(), CurrentDpsHash()
    if myBuildHash == peerBuildHash and myDpsHash == peerDpsHash then
        stats.skippedUpToDate = (stats.skippedUpToDate or 0) + 1
        LogEvent("RX","request from %s skipped: both state hashes match", tostring(requester))
        return
    end
    local key = tostring(requester) .. ":" .. tostring(requestId)
    local delay = StableDelay(key .. ":" .. MyName())
    pendingResponses[key] = {
        key=key, requester=requester, requestId=requestId,
        peerBuildHash=peerBuildHash, peerDpsHash=peerDpsHash,
        myBuildHash=myBuildHash, myDpsHash=myDpsHash, remaining=delay,
    }
    LogEvent("RX","request from %s scheduled in %.2fs (id=%s)",
        tostring(requester), delay, tostring(requestId))
end

local function HandleClaim(responder, requester, requestId, buildHash, dpsHash)
    if not (requester and requestId) then return end
    local key = tostring(requester) .. ":" .. tostring(requestId)
    local pending = pendingResponses[key]
    if pending and responder ~= MyName()
        and tostring(buildHash) == tostring(pending.myBuildHash)
        and tostring(dpsHash) == tostring(pending.myDpsHash) then
        pendingResponses[key] = nil
        LogEvent("RX","suppressed duplicate response; %s claimed identical state for %s",
            tostring(responder), tostring(requester))
    end
end

local function ProcessPendingResponses(elapsed)
    local ready = {}
    elapsed = tonumber(elapsed) or 0
    for key, entry in pairs(pendingResponses) do
        entry.remaining = (tonumber(entry.remaining) or 0) - elapsed
        if entry.remaining <= 0 then
            pendingResponses[key] = nil
            ready[#ready+1] = entry
        end
    end
    table.sort(ready, function(a,b) return tostring(a.key) < tostring(b.key) end)
    for _, entry in ipairs(ready) do SendSyncResponse(entry) end
    local loadoutReady = {}
    for key, entry in pairs(pendingLoadouts) do
        entry.remaining = (tonumber(entry.remaining) or 0) - elapsed
        if entry.remaining <= 0 then pendingLoadouts[key]=nil; loadoutReady[#loadoutReady+1]=entry end
    end
    table.sort(loadoutReady, function(a,b) return tostring(a.key)<tostring(b.key) end)
    for _, entry in ipairs(loadoutReady) do
        local b = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[entry.buildId]
        if b and type(b.echoes)=="table" and #b.echoes>0 then
            Enqueue(string.format("%s|%s|%s|%s", CODE_LOADOUT_CLAIM, MyName(), entry.requester, entry.buildId))
            Sync.BroadcastBuild(b)
            LogEvent("TX","answered on-demand loadout '%s' for %s", tostring(entry.buildId), tostring(entry.requester))
        end
    end
end

local function HandleDelete(sender, buildId, stamp, originAuthor)
    local db = NexusDB and NexusDB.communityBuilds
    local existing = db and db[buildId]
    -- originAuthor is an optional 5th field; treat empty string same as nil
    local author = tostring((originAuthor and originAuthor ~= "") and originAuthor or sender or "")
    local tomb = { stamp=tonumber(stamp) or 0, author=author }
    local prior = tombstones[buildId]
    if prior and TombStamp(prior) >= tomb.stamp then return end
    if not existing then
        tombstones[buildId] = tomb
        LogEvent("RX","delete for '%s' relayed by %s (origin %s; tombstoned)",
            tostring(buildId), tostring(sender), author); return
    end
    if existing.isMine then
        LogEvent("RX","ignoring delete for MY build '%s' relayed by %s",
            tostring(existing.title), tostring(sender)); return
    end
    if tostring(existing.author) ~= author then
        LogEvent("RX","REJECT delete of '%s': origin %s is not the author (%s)",
            tostring(existing.title), author, tostring(existing.author)); return
    end
    db[buildId] = nil
    tombstones[buildId] = tomb
    seenRemoteIds[buildId] = nil
    LogEvent("RX","DELETED '%s' from origin %s (relay %s)",
        tostring(existing.title), author, tostring(sender))
    Activity("deleted", "Removed deleted build: %s", tostring(existing.title))
    if Nexus.CommunityBuilds and Nexus.CommunityBuilds.Refresh then
        pcall(Nexus.CommunityBuilds.Refresh)
    end
end

-- CHAT_MSG_CHANNEL handler. The wire has | escaped to || on send;
-- since none of our fields ever contain a literal |, collapsing ||→|
-- is unambiguous.
function Sync.HandleIncoming(text, sender)
    if type(text) ~= "string" then return end
    text = text:gsub("||", "|")
    local parts = {}
    for part in text:gmatch("([^|]*)|?") do
        parts[#parts+1] = part
        if #parts > 20 then break end
    end
    local code = parts[1]
    local wireSender = parts[2] or sender
    local recognized = code == CODE_HELLO or code == CODE_HELLO_ACK or code == CODE_REQUEST or code == CODE_CLAIM
        or code == CODE_DELETE or code == CODE_INDEX or code == CODE_LOADOUT_REQ
        or code == CODE_LOADOUT_CLAIM or code == CODE_DPS or code == CODE_DPS2
        or code == CODE_BUILD
    if recognized and wireSender then
        Sync.MarkPeer(wireSender, (code == CODE_HELLO or code == CODE_HELLO_ACK) and parts[3] or nil)
    end

    if code == CODE_HELLO then
        -- A newly visible peer may be the first one holding an exact loadout
        -- that previously timed out. Re-open bounded retries for incomplete data.
        ScheduleAllMissing(1, true)
        -- A newcomer announcing itself must also learn who is already online.
        -- Reply once per peer per session window; NXHA never receives a reply,
        -- so this cannot form an acknowledgement loop.
        local key = NormalizePeerName(wireSender)
        local now = Now()
        if key ~= "" and (not helloAckedAt[key] or now - helloAckedAt[key] > 30) then
            helloAckedAt[key] = now
            Enqueue(string.format("%s|%s|%s", CODE_HELLO_ACK, MyName(), tostring(Nexus.VERSION or "?")))
        end
        return
    end
    if code == CODE_HELLO_ACK then
        ScheduleAllMissing(1, true)
        return
    end
    if code == CODE_REQUEST then
        HandleRequest(parts[2] or sender, parts[3], parts[4], parts[5])
        return
    end
    if code == CODE_CLAIM then
        HandleClaim(parts[2] or sender, parts[3], parts[4], parts[5], parts[6])
        return
    end
    if code == CODE_DELETE then
        HandleDelete(parts[2] or sender, parts[3], parts[4], parts[5])
        return
    end
    if code == CODE_INDEX then
        local raw = parts[3] and Codec.Base64Decode(parts[3])
        local data = raw and Codec.JSONDecode(raw)
        -- New library discovery remains opt-in, but a newer update to a build
        -- already held locally is safe and should arrive live. This keeps title,
        -- description/link metadata current across world-tier changes without
        -- opening the client to unsolicited bulk library transfers.
        if not Sync.IsReceiving() then
            local known = data and data.id and NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[tostring(data.id)]
            local localStamp = known and (tonumber(known.lastModified) or tonumber(known.postedAt) or 0) or 0
            local incomingStamp = data and tonumber(data.m) or 0
            if not known or incomingStamp <= localStamp then
                stats.ignoredOutsideWindow = stats.ignoredOutsideWindow + 1
                LogEvent("RX","ignored summary from %s outside sync window", tostring(parts[2] or sender))
                return
            end
            receiveWindowUntil = math.max(receiveWindowUntil, Now()+INFLIGHT_GRACE)
            LogEvent("RX","accepting live update for known build '%s'", tostring(data.t or data.id))
        end
        if StoreSummary(data) and Nexus.CommunityBuilds and Nexus.CommunityBuilds.Refresh then
            pcall(Nexus.CommunityBuilds.Refresh)
        end
        return
    end
    if code == CODE_LOADOUT_REQ then
        local requester, buildId = parts[2] or sender, parts[3]
        if requester ~= MyName() and buildId then
            local b = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[buildId]
            if b and type(b.echoes)=="table" and #b.echoes>0 then
                local key = tostring(requester)..":"..tostring(buildId)
                pendingLoadouts[key] = { key=key, requester=requester, buildId=buildId,
                    remaining=StableDelay(key..":"..MyName()) }
            end
        end
        return
    end
    if code == CODE_LOADOUT_CLAIM then
        local requester, buildId = parts[3], parts[4]
        local key = tostring(requester)..":"..tostring(buildId)
        if parts[2] ~= MyName() and pendingLoadouts[key] then
            pendingLoadouts[key] = nil
            LogEvent("RX","suppressed duplicate loadout response; %s claimed %s", tostring(parts[2]), tostring(buildId))
        end
        return
    end
    if code == CODE_DPS then
        HandleDps(parts)
        return
    end
    if code == CODE_DPS2 then
        HandleDps2(parts)
        return
    end
    if code ~= CODE_BUILD then
        if code and code ~= "" then
            LogEvent("RX","unknown code '%s'", tostring(code))
        end
        return
    end

    local msgSender, buildId, lastMod, chunkSpec, data =
        parts[2], parts[3], parts[4], parts[5], parts[6]
    if not (msgSender and buildId and lastMod and chunkSpec and data) then return end
    local idx, total = chunkSpec:match("^(%d+)/(%d+)$")
    idx, total = tonumber(idx), tonumber(total)
    if not (idx and total and idx >= 1 and total >= 1 and idx <= total) then return end

    local key   = msgSender..":"..buildId
    local entry = inflight[key]

    if not entry then
        -- New full builds are opt-in. A newer full payload for a build already
        -- held locally is a live metadata update and may arrive outside a sync
        -- window (for example while players are on different world tiers).
        if not Sync.IsReceiving() then
            local known = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[buildId]
            local localStamp = known and (tonumber(known.lastModified) or tonumber(known.postedAt) or 0) or 0
            local incomingStamp = tonumber(lastMod) or 0
            local completingKnownUpdate = known and known.needsFullBuild and incomingStamp >= localStamp
            if not known or (incomingStamp <= localStamp and not completingKnownUpdate) then
                stats.ignoredOutsideWindow = stats.ignoredOutsideWindow + 1
                LogEvent("RX","ignored from %s outside sync window", tostring(msgSender))
                return
            end
            LogEvent("RX","accepting live full update for known build '%s'", tostring(buildId))
        end
        if total == 1 then
            LogEvent("RX","single-chunk build '%s' from %s", tostring(buildId), tostring(msgSender))
            HandleComplete(buildId, lastMod, data)
            return
        end
        CleanExpiredInflight()
        LogEvent("RX","starting %d-chunk build '%s' from %s",
            total, tostring(buildId), tostring(msgSender))
        entry = { chunks={}, total=total, t0=Now(), lastMod=lastMod }
        inflight[key] = entry
    end

    if total ~= entry.total then return end  -- inconsistent chunk spec
    entry.chunks[idx] = data
    local have = 0
    for i = 1, entry.total do if entry.chunks[i] then have=have+1 end end
    if have == entry.total then
        local full = table.concat(entry.chunks, "", 1, entry.total)
        inflight[key] = nil
        LogEvent("RX","transfer '%s' complete (%d/%d chunks, %d bytes)",
            tostring(buildId), have, entry.total, #full)
        HandleComplete(buildId, entry.lastMod, full)
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function Sync.TombstoneCount()
    local n = 0; for _ in pairs(tombstones) do n=n+1 end; return n
end

function Sync.OnUpdate(elapsed)
    ProcessPendingResponses(elapsed)
    ProcessBackfill(elapsed)
    PumpQueue(elapsed)
    if autoSyncPending then
        autoSyncElapsed = autoSyncElapsed + (tonumber(elapsed) or 0)
        if autoSyncElapsed >= autoSyncDelay and Sync.IsConnected() then
            autoSyncPending = false
            local ok, why = Sync.RequestSync()
            LogEvent("SYNC", ok and "automatic login sync requested" or "automatic login sync deferred: %s", tostring(why or "unknown"))
        end
    end
    -- Retry channel join if chat wasn't ready at login
    if not Sync.IsConnected() and joinAttempts < JOIN_MAX_ATTEMPTS then
        joinRetryTicker = joinRetryTicker + (elapsed or 0)
        if joinRetryTicker >= JOIN_RETRY_INTERVAL then
            joinRetryTicker = 0
            joinAttempts = joinAttempts + 1
            if Sync.EnsureChannel() then
                LogEvent("CHAN","connected on retry #%d", joinAttempts)
            elseif joinAttempts == JOIN_MAX_ATTEMPTS then
                LogEvent("CHAN","gave up after %d attempts (use /wr sync to retry)",
                    joinAttempts)
            end
        end
    end
end

function Sync.Init(codec, adapter)
    Codec, Adapter = codec, adapter
    hotBuilds    = {}  -- clear on init
    pendingResponses = {}
    pendingLoadouts = {}
    requestedLoadouts = {}
    backfillJobs = {}
    backfillScanTicker = 0
    backfillRequestTicker = 0
    seenRemoteIds = {} -- clear then re-seed from saved DB below
    NexusDB = NexusDB or {}
    NexusDB.syncTombstones = NexusDB.syncTombstones or {}
    NexusDB.nexusPeers = NexusDB.nexusPeers or {}
    tombstones = NexusDB.syncTombstones
    if NexusDB.communityBuilds then
        for id, b in pairs(NexusDB.communityBuilds) do
            seenRemoteIds[id] = tonumber(b.lastModified) or tonumber(b.postedAt) or 0
        end
    end
    autoSyncPending = true
    autoSyncElapsed = 0
    local key = NormalizePeerName(MyName())
    local h = 0; for i=1,#key do h = (h * 33 + key:byte(i)) % 997 end
    autoSyncDelay = AUTO_SYNC_DELAY_MIN + (h % (AUTO_SYNC_DELAY_MAX - AUTO_SYNC_DELAY_MIN + 1))
    sentAtTimes = {}
    recentActivity = {}
    Sync.EnsureChannel()
    ScheduleAllMissing(autoSyncDelay + BACKFILL_START_DELAY, true)
end
