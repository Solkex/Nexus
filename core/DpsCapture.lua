-- Nexus: core/DpsCapture.lua
--
-- Automatically records completed Training Dummy and Lich King sessions
-- from Details!. Results are keyed by the player's EXACT owned Echo set.
-- This means the panel can keep a personal best while a wishlist is still
-- incomplete, and community build leaderboards only compare players using
-- the exact Echo loadout published by that build.

Nexus = Nexus or {}
local DPS = {}
Nexus.DpsCapture = DPS

------------------------------------------------------------------------
-- Constants / state
------------------------------------------------------------------------

local SAMPLE_INTERVAL  = 5
local MIN_SESSION_SECS = 30
local MAX_LB_ENTRIES   = 1
local PROTOCOL_VERSION = 7

local Adapter, Sync
local inCombat         = false
local sessionStart     = 0
local latestDps        = 0
local peakDps          = 0
local sampleTicker     = 0
local lastTargetGUID   = nil
local lastTargetName   = nil
local debugLog          = {}
local MAX_DEBUG_LINES   = 120

local TRAINING_DUMMIES = {
    [36476] = true, [36855] = true, [32541] = true, [30527] = true,
    [31144] = true, [16218] = true, [2673] = true,
}
local LICH_KING_NPCS = { [36597] = true, [72523] = true, [36730] = true }


local function Debug(msg)
    local stamp = (date and date("%H:%M:%S")) or tostring((GetTime and GetTime()) or 0)
    debugLog[#debugLog + 1] = "[" .. stamp .. "] " .. tostring(msg)
    while #debugLog > MAX_DEBUG_LINES do table.remove(debugLog, 1) end
end

function DPS.GetDebugLog()
    local out = { "Nexus DPS capture log", "" }
    if #debugLog == 0 then
        out[#out + 1] = "No DPS activity logged this session."
    else
        for i = 1, #debugLog do out[#out + 1] = debugLog[i] end
    end
    return table.concat(out, "\n")
end

------------------------------------------------------------------------
-- Saved variables
------------------------------------------------------------------------

local function DB()
    NexusDB = NexusDB or {}
    NexusDB.dpsCapture = NexusDB.dpsCapture or {}
    return NexusDB.dpsCapture
end

-- Version 4 stores only the data the feature needs:
-- personalBest[fingerprint][category] = this character's highest pull
-- buildBest[fingerprint][category]    = highest known pull worldwide
-- Older per-player leaderboard rows are migrated once on access.
local function PersonalBestStore()
    local db = DB()
    db.personalBest = db.personalBest or {}
    return db.personalBest
end

local function BuildBestStore()
    local db = DB()
    db.buildBest = db.buildBest or {}
    return db.buildBest
end

-- Public mesh state is bounded to one winning loadout per character and
-- encounter. The row still carries the exact loadout fingerprint/build id,
-- but weaker loadouts from the same character are replaced.
local function CharacterBestStore()
    local db = DB()
    db.characterBest = db.characterBest or { dummy = {}, lk = {} }
    db.characterBest.dummy = db.characterBest.dummy or {}
    db.characterBest.lk = db.characterBest.lk or {}
    return db.characterBest
end

local VALID_CLASS = { WARRIOR=true, PALADIN=true, HUNTER=true, ROGUE=true, PRIEST=true,
    DEATHKNIGHT=true, SHAMAN=true, MAGE=true, WARLOCK=true, DRUID=true }

local function NormalizeClass(class)
    class = type(class) == "string" and class:upper() or nil
    return class and VALID_CLASS[class] and class or nil
end

local CLASS_LABEL = {
    WARRIOR="Warrior", PALADIN="Paladin", HUNTER="Hunter", ROGUE="Rogue",
    PRIEST="Priest", DEATHKNIGHT="Death Knight", SHAMAN="Shaman", MAGE="Mage",
    WARLOCK="Warlock", DRUID="Druid",
}

local function CurrentRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then realm = GetRealmName and GetRealmName() end
    return tostring(realm or "unknown"):lower():gsub("%s+", "")
end

local function OwnerKey(name, realm)
    name = tostring(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    realm = tostring(realm or CurrentRealm()):lower():gsub("%s+", "")
    return name .. "@" .. realm
end

local function PlayerKey(name, realm)
    return OwnerKey(name, realm) or "?@unknown"
end

local function ShortPlayerName(value)
    value = tostring(value or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return (value:match("^([^-]+)") or value):lower()
end

-- Historical clients sometimes stored the same character under both
-- name@unknown and name@realm. On a single-realm server those are aliases,
-- not separate leaderboard players. Collapse them before rendering, hashing,
-- or accepting another record so metadata edits can never create a duplicate row.
local function CoalesceCharacterBest(category)
    local bucket = CharacterBestStore()[category]
    if type(bucket) ~= "table" then return false end
    local winners, changed = {}, false
    for key, row in pairs(bucket) do
        if type(row) == "table" then
            local nameKey = ShortPlayerName(row.player)
            if nameKey ~= "" then
                local prior = winners[nameKey]
                if not prior or (tonumber(row.dps) or 0) > (tonumber(prior.row.dps) or 0) or ((tonumber(row.dps) or 0) == (tonumber(prior.row.dps) or 0) and (tonumber(row.ts) or 0) > (tonumber(prior.row.ts) or 0)) then
                    winners[nameKey] = { key=key, row=row }
                end
            end
        end
    end
    for key, row in pairs(bucket) do
        if type(row) == "table" then
            local winner = winners[ShortPlayerName(row.player)]
            if winner and winner.key ~= key then bucket[key] = nil; changed = true end
        end
    end
    return changed
end

-- Repair records created before class identity travelled with the DPS row.
-- SavedVariables are account-wide, so the only safe local repair is for rows
-- whose owner identity matches the character currently logged in. The current
-- character class is authoritative for those rows and their auto-generated
-- record page. Custom titles are preserved; only the old default
-- "<Class> Record Loadout" title is rewritten.
local function RepairCurrentCharacterClass()
    if not (UnitName and UnitClass) then return false end
    local me = tostring(UnitName("player") or "")
    local _, token = UnitClass("player")
    local class = NormalizeClass(token)
    if me == "" or not class then return false end

    local localOwner = OwnerKey(me, CurrentRealm())
    if not localOwner then return false end
    local changed = false
    local builds = NexusDB and NexusDB.communityBuilds or {}
    local character = CharacterBestStore()
    local personal = PersonalBestStore()

    for _, category in ipairs({ "dummy", "lk" }) do
        for _, row in pairs(character[category] or {}) do
            local rowOwner = tostring(row and row.ownerKey or ""):lower()
            local derivedOwner = row and OwnerKey(row.player, row.realm ~= "" and row.realm or CurrentRealm())
            if row and (rowOwner == localOwner or derivedOwner == localOwner) then
                if row.class ~= class then row.class = class; changed = true end
                if row.fingerprint and personal[row.fingerprint] and personal[row.fingerprint][category] then
                    local prow = personal[row.fingerprint][category]
                    if prow.class ~= class then prow.class = class; changed = true end
                    prow.ownerKey = prow.ownerKey or localOwner
                    prow.realm = prow.realm or CurrentRealm()
                end

                local build = row.buildId and builds[row.buildId]
                if build and build.autoDps then
                    local buildOwner = tostring(build.ownerKey or ""):lower()
                    local legacyOwned = buildOwner == "" and tostring(build.author or ""):lower() == me:lower()
                    if buildOwner == localOwner or legacyOwned then
                        local buildChanged = false
                        if build.class ~= class then build.class = class; buildChanged = true end
                        local title = tostring(build.title or "")
                        if title:match("^[%a%s]+ Record Loadout$") then
                            local corrected = (CLASS_LABEL[class] or class) .. " Record Loadout"
                            if title ~= corrected then build.title = corrected; buildChanged = true end
                        end
                        if not build.ownerKey then build.ownerKey = localOwner; buildChanged = true end
                        if buildChanged then
                            local now = (time and time()) or 0
                            local old = tonumber(build.lastModified or build.postedAt) or 0
                            build.lastModified = now > old and now or old + 1
                            changed = true
                        end
                    end
                end
            end
        end
    end

    if changed and Sync then
        if Sync.BroadcastBuildSummary then
            for _, build in pairs(builds) do
                if build and build.autoDps and tostring(build.ownerKey or ""):lower() == localOwner then
                    pcall(Sync.BroadcastBuildSummary, build)
                end
            end
        end
        -- Class is part of leaderboard identity metadata. Rebroadcast the
        -- corrected winning rows so peers that cached the old Shaman value
        -- repair without waiting for a new DPS pull.
        if Sync.BroadcastDpsRecord then
            for _, category in ipairs({ "dummy", "lk" }) do
                for _, row in pairs(character[category] or {}) do
                    if row and tostring(row.ownerKey or ""):lower() == localOwner then
                        pcall(Sync.BroadcastDpsRecord, {
                            protocolVersion = PROTOCOL_VERSION, fingerprint = row.fingerprint,
                            loadoutHash = row.loadoutHash, category = category, dps = row.dps,
                            duration = row.duration, ts = row.ts, player = row.player,
                            class = row.class, ownerKey = row.ownerKey, realm = row.realm,
                            level = row.level, buildId = row.buildId, echoes = row.echoes,
                        })
                    end
                end
            end
        end
    end
    return changed
end

local legacyMigrated = false
local function BetterRow(candidate, existing)
    if not existing then return true end
    local nd = math.floor(tonumber(candidate and candidate.dps) or 0)
    local od = math.floor(tonumber(existing and existing.dps) or 0)
    if nd ~= od then return nd > od end
    local nt = tonumber(candidate and candidate.ts) or 0
    local ot = tonumber(existing and existing.ts) or 0
    if nt > 0 and ot > 0 and nt ~= ot then return nt < ot end
    return tostring(candidate and candidate.fingerprint or "") < tostring(existing and existing.fingerprint or "")
end

local function MigrateLegacyLeaderboard()
    if legacyMigrated then return end
    legacyMigrated = true
    local db = DB()
    local me = (UnitName and UnitName("player")) or "?"
    local personal = PersonalBestStore()
    local character = CharacterBestStore()

    local function Consider(row, fingerprint, category, fallbackPlayer)
        if type(row) ~= "table" or not tonumber(row.dps) then return end
        row.player = row.player or fallbackPlayer or "?"
        row.fingerprint = row.fingerprint or fingerprint
        if PlayerKey(row.player) == PlayerKey(me) and fingerprint then
            personal[fingerprint] = personal[fingerprint] or {}
            if BetterRow(row, personal[fingerprint][category]) then
                personal[fingerprint][category] = row
            end
        end
        local bucket = character[category]
        if bucket then
            local pk = PlayerKey(row.player)
            if BetterRow(row, bucket[pk]) then bucket[pk] = row end
        end
    end

    local legacy = db.leaderboard
    if type(legacy) == "table" then
        for fingerprint, categories in pairs(legacy) do
            if type(categories) == "table" then
                for category, entries in pairs(categories) do
                    if type(entries) == "table" then
                        for player, row in pairs(entries) do Consider(row, fingerprint, category, player) end
                    end
                end
            end
        end
        db.leaderboard = nil
    end

    local oldGlobal = db.buildBest
    if type(oldGlobal) == "table" then
        for fingerprint, categories in pairs(oldGlobal) do
            if type(categories) == "table" then
                for _, category in ipairs({ "dummy", "lk" }) do
                    Consider(categories[category], fingerprint, category)
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Echo fingerprints
------------------------------------------------------------------------

local function NormalizeEchoes(source)
    if type(source) ~= "table" then return nil end
    local counts = {}
    for _, e in ipairs(source) do
        local spellId = tonumber(e and (e.spellId or e.id))
        local count = tonumber(e and (e.count or e.stacks or e.stack)) or 1
        if spellId and count > 0 then
            counts[spellId] = (counts[spellId] or 0) + count
        end
    end
    local snap = {}
    for spellId, count in pairs(counts) do
        snap[#snap + 1] = { spellId = spellId, count = count }
    end
    table.sort(snap, function(a, b) return a.spellId < b.spellId end)
    return #snap > 0 and snap or nil
end

local function SnapshotEchoes()
    if not (Adapter and Adapter.Owned) then return nil end
    local owned = Adapter.Owned()
    if not owned or type(owned.bySpell) ~= "table" then return nil end

    -- Locked perks are permanent baseline Echoes supplied outside the roll
    -- build. They must not alter a wishlist/build fingerprint; otherwise a
    -- 79-Echo completed build is captured under an 85-Echo key and can never
    -- be found by the panel or its posted community build.
    local lockedBySpell = {}
    if Adapter.LockedOwned then
        local locked = Adapter.LockedOwned()
        if locked and type(locked.bySpell) == "table" then
            lockedBySpell = locked.bySpell
        end
    end

    local source = {}
    for spellId, count in pairs(owned.bySpell) do
        local tracked = math.max(0, (tonumber(count) or 0)
            - (tonumber(lockedBySpell[spellId]) or 0))
        if tracked > 0 then
            source[#source + 1] = { spellId = spellId, count = tracked }
        end
    end
    return NormalizeEchoes(source)
end

local function EchoKey(snap)
    if not snap or #snap == 0 then return nil end
    local out = {}
    for _, e in ipairs(snap) do
        out[#out + 1] = tostring(e.spellId) .. "x" .. tostring(e.count)
    end
    return table.concat(out, ",")
end


local function EchoHashFromKey(key)
    if type(key) ~= "string" or key == "" then return nil end
    local h = 5381
    for i = 1, #key do h = ((h * 33) + key:byte(i)) % 2147483648 end
    return string.format("%x", h)
end

function DPS.GetEchoHash(echoes)
    return EchoHashFromKey(EchoKey(NormalizeEchoes(echoes)))
end

local migratedLockedBaseline = false
local function CorrectLockedRows(store)
    if not (Adapter and Adapter.LockedOwned) then return end
    local locked = Adapter.LockedOwned()
    local lockedBySpell = locked and locked.bySpell or {}
    -- If no locked echoes are known yet, abort. Subtracting zero from
    -- everything would produce identical keys (no-op), but if the locked
    -- data simply hasn't loaded yet we must not run at all -- a partially
    -- loaded lockedBySpell could subtract fewer echoes than the true
    -- baseline and generate wrong keys that orphan existing records.
    local anyLocked = false
    for _ in pairs(lockedBySpell) do anyLocked = true; break end
    if not anyLocked then return end

    local moves = {}
    for oldKey, categories in pairs(store) do
        for category, row in pairs(type(categories) == "table" and categories or {}) do
            local oldEchoes = row and NormalizeEchoes(row.echoes)
            if oldEchoes then
                local corrected = {}
                for _, e in ipairs(oldEchoes) do
                    local n = math.max(0, (tonumber(e.count) or 0) - (tonumber(lockedBySpell[e.spellId]) or 0))
                    if n > 0 then corrected[#corrected + 1] = { spellId=e.spellId, count=n } end
                end
                corrected = NormalizeEchoes(corrected)
                local newKey = EchoKey(corrected)
                -- Only move if we produced a valid, different key.
                -- If corrected is empty (all echoes were locked) keep
                -- the original record -- don't orphan it.
                if newKey and newKey ~= oldKey then
                    moves[#moves + 1] = {oldKey=oldKey,newKey=newKey,category=category,row=row,echoes=corrected}
                end
            end
        end
    end
    for _, m in ipairs(moves) do
        store[m.newKey] = store[m.newKey] or {}
        local current = store[m.newKey][m.category]
        if not current or (tonumber(m.row.dps) or 0) > (tonumber(current.dps) or 0) then
            m.row.echoes, m.row.fingerprint = m.echoes, m.newKey
            store[m.newKey][m.category] = m.row
        end
        -- Only clear the old slot after successfully writing the new one
        if store[m.newKey][m.category] then
            store[m.oldKey][m.category] = nil
        end
    end
end

local function MigrateLocalLockedBaseline()
    if migratedLockedBaseline then return end
    migratedLockedBaseline = true
    MigrateLegacyLeaderboard()
    CorrectLockedRows(PersonalBestStore())
    CorrectLockedRows(BuildBestStore())
    local character = CharacterBestStore()
    local locked = Adapter and Adapter.LockedOwned and Adapter.LockedOwned()
    local lockedBySpell = locked and locked.bySpell or {}
    -- Only correct the character store if we actually have locked echo data.
    -- If not loaded yet, skip -- the migration runs once so we must not
    -- corrupt fingerprints with a partial locked set.
    local anyLocked = false
    for _ in pairs(lockedBySpell) do anyLocked = true; break end
    if not anyLocked then return end
    for _, category in ipairs({ "dummy", "lk" }) do
        for _, row in pairs(character[category] or {}) do
            local oldEchoes = row and NormalizeEchoes(row.echoes)
            if oldEchoes then
                local corrected = {}
                for _, e in ipairs(oldEchoes) do
                    local n = math.max(0, (tonumber(e.count) or 0) - (tonumber(lockedBySpell[e.spellId]) or 0))
                    if n > 0 then corrected[#corrected + 1] = { spellId=e.spellId, count=n } end
                end
                corrected = NormalizeEchoes(corrected)
                local newKey = EchoKey(corrected)
                -- Only update if corrected is valid and different
                if newKey and newKey ~= row.fingerprint then
                    row.echoes, row.fingerprint = corrected, newKey
                    row.loadoutHash = EchoHashFromKey(newKey)
                end
            end
        end
    end
end

local function BuildSnapshot(build)
    return build and NormalizeEchoes(build.echoes)
end

local function FindMatchingBuild(snap)
    local key = EchoKey(snap)
    if not key then return nil, nil end
    local builds = (NexusDB and NexusDB.communityBuilds) or {}
    local fallbackId, fallbackBuild
    for id, build in pairs(builds) do
        if (build.fingerprint or EchoKey(BuildSnapshot(build))) == key then
            -- Prefer a player-authored build with its real title/description.
            -- Auto-generated record pages are only a fallback when no posted
            -- build exists for the exact same Echo IDs and stack quantities.
            if not build.autoDps then return id, build end
            fallbackId, fallbackBuild = fallbackId or id, fallbackBuild or build
        end
    end
    return fallbackId, fallbackBuild
end

local function BuildKey(buildId)
    local builds = (NexusDB and NexusDB.communityBuilds) or {}
    local build = builds[buildId]
    if not build then return nil, nil end
    local key = build.fingerprint or EchoKey(BuildSnapshot(build))
    if not key and build.fingerprintHash then key = "@"..tostring(build.fingerprintHash) end
    return key, build
end

------------------------------------------------------------------------
-- Target detection (3.3.5-compatible)
------------------------------------------------------------------------

local function NpcIdFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    -- Modern/private-core textual GUID.
    local id = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-%x+$")
    if id then return tonumber(id) end
    -- Some 3.3.5 cores expose a simple Creature-<entry>-... form.
    id = guid:match("[Cc]reature[^%d]+(%d+)")
    return tonumber(id)
end

local function ClassifyTarget(guid, name)
    local npcId = NpcIdFromGUID(guid)
    if npcId then
        if TRAINING_DUMMIES[npcId] then return "dummy" end
        if LICH_KING_NPCS[npcId] then return "lk" end
    end
    local n = type(name) == "string" and name:lower() or ""
    if n:find("training dummy", 1, true) or n:find("target dummy", 1, true) then
        return "dummy"
    end
    if n == "the lich king" or n:find("lich king", 1, true) then
        return "lk"
    end
    return nil
end

local function RememberTarget()
    if UnitExists and not UnitExists("target") then return end
    if UnitGUID then
        local guid = UnitGUID("target")
        if guid then lastTargetGUID = guid end
    end
    if UnitName then
        local name = UnitName("target")
        if name and name ~= "" then lastTargetName = name end
    end
end

------------------------------------------------------------------------
-- Details! integration
------------------------------------------------------------------------

function DPS.IsDetailsAvailable()
    return Details ~= nil and (type(Details.GetCurrentCombat) == "function"
        or type(Details.GetCombat) == "function")
end

local function ActorDps(combat)
    if not combat then return nil end
    local player = UnitName and UnitName("player")
    if not player then return nil end
    local result
    pcall(function()
        local attrDmg = DETAILS_ATTRIBUTE_DAMAGE or 1
        local actor = combat.GetActor and combat:GetActor(attrDmg, player)
        if not actor and player:find("%-", 1, true) then
            actor = combat:GetActor(attrDmg, player:match("^[^-]+"))
        end
        if not actor then return end
        local total = tonumber(actor.total)
        if not total or total <= 0 then return end
        local activeTime = actor.Tempo and tonumber(actor:Tempo())
        if activeTime and activeTime > 0 then
            result = total / activeTime
            return
        end
        local combatTime = combat.GetCombatTime and tonumber(combat:GetCombatTime())
        if combatTime and combatTime > 0 then result = total / combatTime end
    end)
    return result
end

local function ReadDetailsDps()
    if not DPS.IsDetailsAvailable() then return nil end
    local current
    pcall(function()
        if Details.GetCurrentCombat then current = Details:GetCurrentCombat() end
    end)
    local value = ActorDps(current)
    if value and value > 0 then return value end

    -- On some 3.3.5 Details builds the completed segment moves to history
    -- before PLAYER_REGEN_ENABLED. Only use history when current is empty;
    -- never take the larger of two unrelated segments.
    local previous
    pcall(function()
        if Details.GetCombat then previous = Details:GetCombat(1) end
    end)
    return ActorDps(previous)
end

------------------------------------------------------------------------
-- Leaderboard access
------------------------------------------------------------------------

local function StoreRow(store, key, category, create)
    if not key then return nil end
    if create then
        store[key] = store[key] or {}
    end
    return store[key] and store[key][category] or nil
end

local function SetStoreRow(store, key, category, row)
    store[key] = store[key] or {}
    store[key][category] = row
end

local function GlobalForKey(key, category)
    MigrateLegacyLeaderboard()
    local hash = EchoHashFromKey(key)
    local best
    local bucket = CharacterBestStore()[category] or {}
    for _, row in pairs(bucket) do
        local rowKey = row and row.fingerprint
        local rowHash = row and (row.loadoutHash or (rowKey and EchoHashFromKey(rowKey)))
        if row and (rowKey == key or (hash and rowHash == hash)) and BetterRow(row, best) then
            best = row
        end
    end
    return best
end

local function PersonalForKey(key, category)
    MigrateLegacyLeaderboard()
    return StoreRow(PersonalBestStore(), key, category, false)
end

local function SortedEntries(row)
    if not row then return {} end
    return {{
        player = row.player or "?", dps = tonumber(row.dps) or 0,
        level = tonumber(row.level) or 0, ts = tonumber(row.ts) or 0,
    }}
end

function DPS.GetLeaderboard(buildId, category)
    local key = BuildKey(buildId)
    return key and SortedEntries(GlobalForKey(key, category)) or {}
end


-- A build is Details-verified only when a valid public record exists for its
-- exact loadout and the captured combat duration met the 30-second floor.
function DPS.GetBuildVerification(buildId)
    local build = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[buildId]
    if not build then return nil end
    local key = BuildKey(buildId)
    if not key then return nil end
    local best
    for _, category in ipairs({"dummy", "lk"}) do
        local row = GlobalForKey(key, category)
        if row and (tonumber(row.duration) or 0) >= MIN_SESSION_SECS then
            if not best or (tonumber(row.dps) or 0) > (tonumber(best.dps) or 0) then
                best = {
                    category = category,
                    dps = tonumber(row.dps) or 0,
                    duration = tonumber(row.duration) or 0,
                    player = row.player,
                }
            end
        end
    end
    return best
end

function DPS.GetPersonalBest(buildId, category)
    local key = BuildKey(buildId)
    return key and PersonalForKey(key, category) or nil
end

function DPS.GetBestRecordForEchoes(echoes, category)
    return GlobalForKey(DPS.GetEchoKey(echoes), category)
end

local function HashStrings(items)
    table.sort(items)
    local h = 5381
    for _, text in ipairs(items) do
        for i = 1, #text do h = ((h * 33) + text:byte(i)) % 2147483648 end
    end
    return string.format("%x", h)
end

-- Compact digest of the only leaderboard state that matters: the highest
-- record known for each exact loadout and encounter. Peers with the same
-- digest do not resend any DPS payloads during Sync Now.
local DPS_BUCKETS = 8
local function DpsBucket(category, player)
    local text = tostring(category or "") .. ":" .. PlayerKey(player)
    local h = 5381
    for i = 1, #text do h = ((h * 33) + text:byte(i)) % 2147483648 end
    return (h % DPS_BUCKETS) + 1
end

local function SplitBucketHash(value)
    local out = {}
    value = tostring(value or "")
    local i = 1
    for part in value:gmatch("([^,]+)") do out[i] = part; i = i + 1 end
    return out
end

function DPS.GetSyncHash()
    MigrateLocalLockedBaseline()
    MigrateLegacyLeaderboard()
    local buckets = {}
    for i = 1, DPS_BUCKETS do buckets[i] = {} end
    local store = CharacterBestStore()
    CoalesceCharacterBest("dummy"); CoalesceCharacterBest("lk")
    for _, category in ipairs({ "dummy", "lk" }) do
        for playerKey, row in pairs(store[category] or {}) do
            if row and (tonumber(row.dps) or 0) > 0 then
                local b = DpsBucket(category, playerKey)
                buckets[b][#buckets[b]+1] = table.concat({ category, tostring(playerKey),
                    tostring(math.floor(tonumber(row.dps) or 0)),
                    tostring(row.loadoutHash or EchoHashFromKey(row.fingerprint or "") or "0"),
                    tostring(NormalizeClass(row.class) or "UNKNOWN") }, "|")
            end
        end
    end
    local hashes = {}
    for i = 1, DPS_BUCKETS do hashes[i] = #buckets[i] > 0 and HashStrings(buckets[i]) or "0" end
    return table.concat(hashes, ",")
end

-- Broadcast only the single highest known result for this exact build.
function DPS.BroadcastBestForBuild(buildId)
    local key, build = BuildKey(buildId)
    if not key or not build or not (Sync and Sync.BroadcastDpsRecord) then return false end
    local sent = false
    local store = CharacterBestStore()
    for _, category in ipairs({ "dummy", "lk" }) do
        for _, row in pairs(store[category] or {}) do
            if row and row.buildId == buildId and (tonumber(row.dps) or 0) > 0 then
                local record = {
                    protocolVersion = PROTOCOL_VERSION, fingerprint = row.fingerprint or key,
                    loadoutHash = row.loadoutHash or build.fingerprintHash or EchoHashFromKey(key),
                    category = category, dps = math.floor(tonumber(row.dps) or 0),
                    duration = tonumber(row.duration) or 0, ts = tonumber(row.ts) or 0,
                    player = row.player or "?", class = row.class, ownerKey = row.ownerKey, realm = row.realm,
                    level = tonumber(row.level) or 0, buildId = buildId,
                }
                local ok, result = pcall(Sync.BroadcastDpsRecord, record)
                if ok and result ~= false then sent = true end
            end
        end
    end
    return sent
end

function DPS.BroadcastAllBuildBests(peerHash)
    if peerHash and tostring(peerHash) == tostring(DPS.GetSyncHash()) then return 0 end
    MigrateLegacyLeaderboard()
    local peerBuckets = SplitBucketHash(peerHash)
    local myBuckets = SplitBucketHash(DPS.GetSyncHash())
    local legacyPeer = #peerBuckets ~= DPS_BUCKETS
    local n = 0
    local store = CharacterBestStore()
    for _, category in ipairs({ "dummy", "lk" }) do
        for playerKey, row in pairs(store[category] or {}) do
            local bucket = DpsBucket(category, playerKey)
            if (legacyPeer or tostring(peerBuckets[bucket] or "") ~= tostring(myBuckets[bucket] or ""))
                and row and (tonumber(row.dps) or 0) > 0 and Sync and Sync.BroadcastDpsRecord then
                local record = {
                    protocolVersion=PROTOCOL_VERSION, fingerprint=row.fingerprint,
                    loadoutHash=row.loadoutHash or EchoHashFromKey(row.fingerprint or ""),
                    category=category, dps=math.floor(tonumber(row.dps) or 0),
                    duration=tonumber(row.duration) or 0, ts=tonumber(row.ts) or 0,
                    player=row.player or "?", class=row.class, ownerKey=row.ownerKey, realm=row.realm,
                    level=tonumber(row.level) or 0, buildId=row.buildId,
                }
                local ok, result=pcall(Sync.BroadcastDpsRecord,record)
                if ok and result~=false then n=n+1 end
            end
        end
    end
    return n
end

-- Public board: one row per character for the selected encounter. The row is
-- that character's highest known DPS and retains the exact winning loadout.
function DPS.GetDpsBoard(category)
    if category ~= "dummy" and category ~= "lk" then return {} end
    CoalesceCharacterBest(category)
    MigrateLocalLockedBaseline()
    MigrateLegacyLeaderboard()
    RepairCurrentCharacterClass()
    local out = {}
    for _, row in pairs(CharacterBestStore()[category] or {}) do
        if type(row) == "table" and (tonumber(row.dps) or 0) > 0 then
            local buildId = row.buildId
            local build = (NexusDB and NexusDB.communityBuilds or {})[buildId]
            if not build and row.echoes then
                buildId, build = FindMatchingBuild(NormalizeEchoes(row.echoes))
            end
            if build then
                out[#out + 1] = {
                    player = row.player or "?", class = row.class,
                    ownerKey = row.ownerKey, realm = row.realm,
                    dps = math.floor(tonumber(row.dps) or 0),
                    level = tonumber(row.level) or 0, ts = tonumber(row.ts) or 0,
                    duration = tonumber(row.duration) or 0, category = category,
                    fingerprint = row.fingerprint, echoes = NormalizeEchoes(row.echoes) or BuildSnapshot(build),
                    buildId = buildId, build = build,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.dps ~= b.dps then return a.dps > b.dps end
        if a.ts ~= b.ts then return a.ts < b.ts end
        return tostring(a.player):lower() < tostring(b.player):lower()
    end)
    return out
end

-- Returns { rank, dps, category, buildTitle } for a named player, or nil
-- if they have no record in the local leaderboard. Rank is 1-based across
-- all players for their best category (dummy preferred over lk when tied).
-- Used by the nameplate module to decorate moused-over players.
function DPS.GetPlayerInfo(playerName)
    if not playerName or playerName == "" then return nil end
    MigrateLocalLockedBaseline()
    MigrateLegacyLeaderboard()
    local function ShortName(value)
        value = tostring(value or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        return (value:match("^([^-]+)") or value):lower()
    end
    local wanted = ShortName(playerName)
    local best, bestKey
    for _, category in ipairs({"dummy", "lk"}) do
        for pk, row in pairs(CharacterBestStore()[category] or {}) do
            if row and ShortName(row.player) == wanted
                and (tonumber(row.dps) or 0) > 0 then
                if not best or (tonumber(row.dps) or 0) > (tonumber(best.dps) or 0) then
                    best = { dps = tonumber(row.dps), category = category,
                             buildId = row.buildId, fingerprint = row.fingerprint }
                    bestKey = pk
                end
            end
        end
    end
    if not best then return nil end
    -- Compute rank: how many players have a higher DPS in the same category
    local category = best.category
    local rank = 1
    local bucket = CharacterBestStore()[category]
    for opk, row in pairs(bucket) do
        if opk ~= bestKey and (tonumber(row.dps) or 0) > best.dps then
            rank = rank + 1
        end
    end
    -- Resolve build title
    local buildTitle = nil
    if best.buildId then
        local build = (NexusDB and NexusDB.communityBuilds or {})[best.buildId]
        buildTitle = build and build.title or nil
    end
    return {
        rank     = rank,
        dps      = best.dps,
        category = best.category,
        buildId  = best.buildId,
        title    = buildTitle,
    }
end

function DPS.GetCurrentEchoCount()
    local snap = SnapshotEchoes()
    local total = 0
    for _, e in ipairs(snap or {}) do total = total + (tonumber(e.count) or 0) end
    return total
end

function DPS.GetCurrentEchoKey()
    return EchoKey(SnapshotEchoes())
end

function DPS.GetCurrentMatchingBuild()
    return FindMatchingBuild(SnapshotEchoes())
end

function DPS.GetCurrentLeaderboard(category)
    return SortedEntries(GlobalForKey(DPS.GetCurrentEchoKey(), category))
end

function DPS.GetCurrentPersonalBest(category)
    return PersonalForKey(DPS.GetCurrentEchoKey(), category)
end

-- Direct exact-set access for wishlist panel display. A wishlist does not
-- need to be posted as a community build before its own exact-set best can
-- be shown; posting only makes that same fingerprint shareable.
function DPS.GetEchoKey(echoes)
    return EchoKey(NormalizeEchoes(echoes))
end

function DPS.GetPersonalBestForEchoes(echoes, category)
    MigrateLocalLockedBaseline()
    return PersonalForKey(DPS.GetEchoKey(echoes), category)
end

function DPS.GetLeaderboardForEchoes(echoes, category)
    MigrateLocalLockedBaseline()
    return SortedEntries(GlobalForKey(DPS.GetEchoKey(echoes), category))
end

-- Exact build match for wishlist/community-page use.
function DPS.FindMatchingBuildPublic(wishlist)
    if not wishlist then return nil end
    local snap = NormalizeEchoes(wishlist.echoes or wishlist.entries)
    local id = FindMatchingBuild(snap)
    return id
end

------------------------------------------------------------------------
-- Session lifecycle
------------------------------------------------------------------------

local function StartSession()
    inCombat = true
    Debug("combat start")
    sessionStart = (GetTime and GetTime()) or 0
    latestDps = 0
    peakDps = 0
    sampleTicker = 0
    lastTargetGUID = nil
    lastTargetName = nil
    RememberTarget()
end

local function TakeSample()
    local dps = ReadDetailsDps()
    if dps and dps > 0 then
        latestDps = dps
        if dps > peakDps then peakDps = dps end
    end
end

local function CommitSession(category)
    inCombat = false
    Debug("combat end; category=" .. tostring(category) .. ", target=" .. tostring(lastTargetName))
    if not category then
        Nexus.lastDpsNote = "ignored: target was not a training dummy or the Lich King"
        Debug(Nexus.lastDpsNote)
        return
    end
    local elapsed = ((GetTime and GetTime()) or 0) - sessionStart
    if elapsed < MIN_SESSION_SECS then
        Nexus.lastDpsNote = "ignored: session shorter than " .. MIN_SESSION_SECS .. " seconds"
        Debug(Nexus.lastDpsNote .. "; elapsed=" .. tostring(elapsed))
        return
    end

    -- Prefer the completed segment's final DPS. Peak is only a fallback for
    -- Details builds that rotate the segment before PLAYER_REGEN_ENABLED.
    TakeSample()
    local sessionDps = latestDps > 0 and latestDps or peakDps
    if not sessionDps or sessionDps <= 0 then
        Nexus.lastDpsNote = "ignored: Details! returned no player DPS"
        Debug(Nexus.lastDpsNote)
        return
    end

    local snap = SnapshotEchoes()
    local key = EchoKey(snap)
    if not key then
        Nexus.lastDpsNote = "ignored: no owned Echo snapshot was available"
        Debug(Nexus.lastDpsNote)
        return
    end

    local buildId, build = FindMatchingBuild(snap)
    local player = (UnitName and UnitName("player")) or "?"
    local level = (UnitLevel and UnitLevel("player")) or 0
    MigrateLegacyLeaderboard()
    local dpsFloor = math.floor(sessionDps)
    local existing = PersonalForKey(key, category)
    Debug("commit " .. tostring(category) .. ": dps=" .. tostring(dpsFloor)
        .. ", key=" .. tostring(key) .. ", existing="
        .. tostring(existing and existing.dps or "none"))

    if not existing or dpsFloor > (tonumber(existing.dps) or 0) then
        local stamp = (time and time()) or 0
        local playerClass
        if UnitClass then
            local _, token = UnitClass("player")
            playerClass = NormalizeClass(token)
        end
        local ownerKey = OwnerKey(player, CurrentRealm())
        local personalRow = {
            dps = dpsFloor, level = level, ts = stamp,
            duration = elapsed, player = player, class = playerClass,
            ownerKey = ownerKey, realm = CurrentRealm(),
            buildId = buildId, echoes = snap, fingerprint = key,
            protocolVersion = PROTOCOL_VERSION,
        }
        SetStoreRow(PersonalBestStore(), key, category, personalRow)

        -- Only this character's highest result for the encounter enters the
        -- public mesh. Exact-set personal bests remain local, so experimenting
        -- with weaker loadouts cannot create or sync leaderboard bloat.
        local characterBucket = CharacterBestStore()[category]
        local pk = PlayerKey(player, CurrentRealm())
        local previousCharacterBest = characterBucket[pk]
        local becameCharacterBest = BetterRow(personalRow, previousCharacterBest)
        if becameCharacterBest then
            local C = Nexus.CommunityBuilds
            if C and C.EnsureDpsBuildForEchoes then
                local ok, ensuredId, ensuredBuild = pcall(C.EnsureDpsBuildForEchoes, snap, category, personalRow)
                if ok and ensuredId then buildId, build = ensuredId, ensuredBuild or build end
                personalRow.buildId = buildId
            end
            characterBucket[pk] = personalRow

            -- If the previous winning page was an automatically generated
            -- local record page and no leaderboard row references it anymore,
            -- remove it from the mesh instead of accumulating dead experiments.
            local oldBuildId = previousCharacterBest and previousCharacterBest.buildId
            if oldBuildId and oldBuildId ~= buildId and C and C.DeleteBuild then
                local stillUsed = false
                for _, encounter in ipairs({ "dummy", "lk" }) do
                    for _, publicRow in pairs(CharacterBestStore()[encounter] or {}) do
                        if publicRow and publicRow.buildId == oldBuildId then stillUsed = true; break end
                    end
                    if stillUsed then break end
                end
                local oldBuild = NexusDB and NexusDB.communityBuilds and NexusDB.communityBuilds[oldBuildId]
                if not stillUsed and oldBuild and oldBuild.autoDps and oldBuild.isMine then
                    pcall(C.DeleteBuild, oldBuildId)
                end
            end
        end
        local catLabel = category == "lk" and "Lich King" or "Training Dummy"
        local setLabel = build and build.title or "current Echo set"
        print(string.format(
            "|cff7fd5ffNexus:|r |cff4dff80New best for '%s' (%s): %s DPS!|r",
            tostring(setLabel), catLabel,
            dpsFloor >= 1000000 and string.format("%.2fM", dpsFloor / 1000000)
            or string.format("%dk", math.floor(dpsFloor / 1000))))

        -- Global comparison is only meaningful when the exact current Echo
        -- set is already a published community build.
        local characterNow = CharacterBestStore()[category][PlayerKey(player, CurrentRealm())]
        if characterNow == personalRow and Sync and Sync.BroadcastDpsRecord then
            pcall(Sync.BroadcastDpsRecord, {
                protocolVersion = PROTOCOL_VERSION, fingerprint = key,
                echoes = snap, category = category, dps = dpsFloor,
                duration = elapsed, ts = stamp, player = player,
                class = playerClass, ownerKey = ownerKey, realm = CurrentRealm(),
                level = level, buildId = buildId,
            })
        end
    end

    Nexus.lastDpsNote = string.format("%s: %d DPS (%s)",
        category, dpsFloor, build and build.title or "current Echo set")
    Debug("saved/retained best: " .. Nexus.lastDpsNote)

    if Nexus.CommunityBuilds and Nexus.CommunityBuilds.Refresh then
        pcall(Nexus.CommunityBuilds.Refresh)
    end
    if Nexus.RefreshPanel then
        pcall(Nexus.RefreshPanel)
    end
end

------------------------------------------------------------------------
-- Sync receive
------------------------------------------------------------------------

local function IsBetterPublicRecord(candidate, existing)
    if not existing then return true end
    local newDps = math.floor(tonumber(candidate and candidate.dps) or 0)
    local oldDps = math.floor(tonumber(existing and existing.dps) or 0)
    if newDps ~= oldDps then return newDps > oldDps end
    -- Equal-DPS ties converge deterministically across the mesh instead of
    -- leaving different peers with permanently different leaderboard hashes.
    local newPlayer = tostring(candidate and candidate.player or "?"):lower()
    local oldPlayer = tostring(existing and existing.player or "?"):lower()
    if newPlayer ~= oldPlayer then return newPlayer < oldPlayer end
    local newTs = tonumber(candidate and candidate.ts) or 0
    local oldTs = tonumber(existing and existing.ts) or 0
    if newTs > 0 and oldTs > 0 and newTs ~= oldTs then return newTs < oldTs end
    return false
end

function DPS.ReceiveRecord(record)
    if type(record) ~= "table" then return false end
    local version = tonumber(record.v or record.protocolVersion)
    local category = record.c or record.category
    local dps = tonumber(record.d or record.dps)
    local duration = tonumber(record.u or record.duration) or 0
    local ts = tonumber(record.t or record.ts) or 0
    local player = tostring(record.p or record.player or "")
    local rawClass = record.k or record.class
    local playerClass = NormalizeClass(rawClass)
    local realm = tostring(record.r or record.realm or ""):lower():gsub("%s+", "")
    local ownerKey = tostring(record.o or record.ownerKey or "")
    local level = tonumber(record.l or record.level) or 0
    local echoes = NormalizeEchoes(record.e or record.echoes)
    local computed = EchoKey(echoes)
    local claimed = record.f or record.fingerprint
    local hash = record.h or record.loadoutHash
    local fingerprint = computed or (type(claimed)=="string" and claimed or nil) or (type(hash)=="string" and ("@"..hash) or nil)

    -- Schema validation
    if (version ~= 2 and version ~= 3 and version ~= 4 and version ~= 5 and version ~= 6 and version ~= PROTOCOL_VERSION)
        or (category ~= "dummy" and category ~= "lk")
        or not dps or dps <= 0 or dps > 1000000000
        or duration < 0 or ts < 0 or player == "" or not fingerprint
        or (rawClass ~= nil and not playerClass)
        or (computed and claimed and claimed ~= computed)
        or (computed and hash and EchoHashFromKey(computed) ~= hash) then return false end

    -- Identity metadata is optional for old protocol rows, but when present
    -- it must be self-consistent. This prevents accidental cross-character
    -- ownership and class corruption while remaining compatible with v2-v6.
    if ownerKey ~= "" then
        local expectedOwner = PlayerKey(player, realm ~= "" and realm or "unknown")
        if ownerKey:lower() ~= expectedOwner then return false end
    else
        ownerKey = PlayerKey(player, realm ~= "" and realm or "unknown")
    end

    -- Integrity checks (deliberately silent -- legitimate clients never trip these)
    -- DPS floor: no real build produces under 1k active-time DPS
    if dps < 1000 then return false end
    -- Session duration floor must match local capture. Both supported
    -- encounters require at least 30 seconds of active combat.
    local minDur = 30
    -- Current Nexus records must include a qualifying Details duration.
    -- Legacy protocol rows may omit duration, but can never earn the
    -- DETAILS VERIFIED stamp until a new qualifying pull replaces them.
    if version == PROTOCOL_VERSION then
        if duration < minDur then return false end
    elseif duration > 0 and duration < minDur then
        return false
    end
    -- Hard DPS ceiling: set high to accommodate extreme builds while
    -- still blocking obviously fabricated absurd values.
    if dps > 500000000 then return false end
    -- Timestamp sanity: reject records claiming to be from the future
    local nowTs = (time and time()) or 0
    if nowTs > 1000000000 and ts > 0 and ts > nowTs + 300 then return false end
    -- Echo count sanity
    if echoes and (#echoes < 1 or #echoes > 120) then return false end

    MigrateLegacyLeaderboard()
    CoalesceCharacterBest(category)
    local bucket = CharacterBestStore()[category]
    -- Same-realm server: reuse any historical alias key for this character.
    local publicKey = PlayerKey(player, realm ~= "" and realm or "unknown")
    for existingKey, existingRow in pairs(bucket) do
        if existingRow and ShortPlayerName(existingRow.player) == ShortPlayerName(player) then
            publicKey = existingKey
            break
        end
    end
    local existing = bucket[publicKey]
    local row = {
        dps = math.floor(dps), level = level, ts = ts, duration = duration,
        player = player, class = playerClass, ownerKey = ownerKey, realm = realm,
        buildId = record.b or record.buildId,
        echoes = echoes, fingerprint = fingerprint, loadoutHash = hash or EchoHashFromKey(fingerprint),
        protocolVersion = PROTOCOL_VERSION,
    }
    -- Permit a same-record metadata repair. Older clients could save the
    -- viewer's class on a remote record; a corrected protocol row must be
    -- able to replace that stale class even though the DPS is identical.
    local metadataRepair = existing
        and math.floor(tonumber(existing.dps) or 0) == row.dps
        and tostring(existing.player or ""):lower() == player:lower()
        and tostring(existing.ownerKey or ""):lower() == ownerKey:lower()
        and (existing.fingerprint == fingerprint
            or (existing.loadoutHash and row.loadoutHash and existing.loadoutHash == row.loadoutHash))
        and playerClass and NormalizeClass(existing.class) ~= playerClass
    if not metadataRepair and not IsBetterPublicRecord(row, existing) then return false end
    -- A DPS row must always lead to a viewable/copyable exact loadout, even
    -- when the DPS chunks arrive before the corresponding build broadcast.
    local C = Nexus.CommunityBuilds
    if echoes and C and C.EnsureDpsBuildForEchoes then
        local ok, ensuredId = pcall(C.EnsureDpsBuildForEchoes, echoes, category, row)
        if ok and ensuredId then row.buildId = ensuredId end
    end
    bucket[publicKey] = row
    if Nexus.CommunityBuilds and Nexus.CommunityBuilds.Refresh then
        pcall(Nexus.CommunityBuilds.Refresh)
    end
    return true
end

function DPS.ReceiveSubmission(buildId, player, dps, level, category, ts)
    dps = tonumber(dps); level = tonumber(level) or 0
    category = (category == "lk" or category == "dummy") and category or "dummy"
    local key = BuildKey(buildId)
    if not (key and player and dps and dps > 0) then return end
    local bucket = CharacterBestStore()[category]
    local legacyKey = PlayerKey(player, "unknown")
    local existing = bucket[legacyKey]
    local row = {
        dps = dps, level = level, ts = ts or 0, player = player,
        class = NormalizeClass(((NexusDB.communityBuilds or {})[buildId] or {}).class),
        ownerKey = PlayerKey(player, "unknown"), realm = "unknown", buildId = buildId,
        echoes = BuildSnapshot((NexusDB.communityBuilds or {})[buildId]),
        fingerprint = key, protocolVersion = PROTOCOL_VERSION,
    }
    if not IsBetterPublicRecord(row, existing) then return end
    bucket[legacyKey] = row
    if Nexus.CommunityBuilds and Nexus.CommunityBuilds.Refresh then
        pcall(Nexus.CommunityBuilds.Refresh)
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

function DPS.OnCombatStart() StartSession() end

function DPS.OnCombatEnd()
    if not inCombat then return end
    RememberTarget()
    local category = ClassifyTarget(lastTargetGUID, lastTargetName)
    CommitSession(category)
end

function DPS.OnUpdate(elapsed)
    if not inCombat then return end
    RememberTarget()
    sampleTicker = sampleTicker + (elapsed or 0)
    if sampleTicker >= SAMPLE_INTERVAL then
        sampleTicker = 0
        TakeSample()
    end
end

function DPS.Init(adapter, sync)
    Adapter, Sync = adapter, sync
    migratedLockedBaseline = false
    MigrateLocalLockedBaseline()
    MigrateLegacyLeaderboard()
    RepairCurrentCharacterClass()
    Debug("initialized; current tracked key=" .. tostring(DPS.GetCurrentEchoKey()))
end

function DPS.IsEnabled() return true end
