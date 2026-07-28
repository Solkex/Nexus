-- Nexus: core/Store.lua
-- SavedVariables ownership ONLY (global: NexusDB): settings
-- plus per-character safety state. core/ may touch SavedVariables and
-- UnitName; nothing else. Main calls Store.Init() at ADDON_LOADED --
-- never earlier (the client replaces the global when the file loads).

Nexus = Nexus or {}
local Store = {}
Nexus.Store = Store

-- Bump on any settings-shape or default change: settings are then
-- replaced WHOLESALE with the shipped defaults (sibling pattern; hand
-- edits do not survive upgrades). Per-char state is rebuilt too, but
-- tomeTogglePending and flagDemotions carry forward -- a sent-but-
-- unconfirmed lever toggle and a demoted flag must survive an upgrade.
local SETTINGS_VERSION = 1

local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = DeepCopy(v) end
    return out
end

local function FreshState()
    return {
        tomeTogglePending = {}, -- [leverId (requiredSpell)] = sentAtTime
        priorAutoAccept = nil,  -- autoAcceptLoadoutEchoes before we touched it
        flagDemotions = {},     -- [flagName] = reason (runtime self-check)
        recordedPicks = {},     -- [spellId] = count (session; adapter-managed)
        loadoutWishlists = {},  -- [numbered loadout slot] = stable designed-wishlist identity
        relayPairs = {},        -- [wishlistKey] = { slotA=n, slotB=n }
        relayPending = nil,     -- confirmed inactive save to arm next level-1 visit
    }
end

-- Returned while the real store is unusable (pre-Init call, or
-- UnitName not yet real -- addendum B5: never latch a bad char key).
-- Deliberately never merged into the persisted store.
local transientState
local transientSettings

function Store.Init()
    -- ── One-time rename migration ─────────────────────────────────────
    -- The addon was renamed from WishlistRealizer to Nexus in 2.0.
    -- WoW tracks SavedVariables by the name declared in the .toc, so
    -- WishlistRealizerDB (the old name) still exists on disk after the
    -- update while NexusDB is brand-new and empty.  Copy everything
    -- across exactly once, then clear the old variable so it doesn't
    -- accumulate stale duplicates across future logins.
    if type(WishlistRealizerDB) == "table" and not NexusDB then
        NexusDB = WishlistRealizerDB
        WishlistRealizerDB = nil   -- release; WoW won't persist nil vars
    end
    -- ── End rename migration ──────────────────────────────────────────

    NexusDB = NexusDB or {}
    local db = NexusDB
    if type(db.chars) ~= "table" then db.chars = {} end

    local profile = Nexus.DefaultProfile
    local defaults = profile and profile.defaultSettings or {}

    if type(db.settings) ~= "table"
        or (db.settingsVersion or 0) ~= SETTINGS_VERSION then
        db.settings = DeepCopy(defaults)
        db.settingsVersion = SETTINGS_VERSION
        for name, old in pairs(db.chars) do
            local fresh = FreshState()
            if type(old) == "table" then
                if type(old.tomeTogglePending) == "table" then
                    fresh.tomeTogglePending = old.tomeTogglePending
                end
                if type(old.flagDemotions) == "table" then
                    fresh.flagDemotions = old.flagDemotions
                end
                -- the record of OUR flip of the client's auto-accept setting
                -- must survive upgrades or the flip becomes permanent+unrecorded
                if old.priorAutoAccept ~= nil then
                    fresh.priorAutoAccept = old.priorAutoAccept
                end
                if type(old.loadoutWishlists) == "table" then
                    fresh.loadoutWishlists = old.loadoutWishlists
                end
                if type(old.relayPairs) == "table" then
                    fresh.relayPairs = old.relayPairs
                end
                if type(old.relayPending) == "table" then
                    fresh.relayPending = old.relayPending
                end
            end
            db.chars[name] = fresh
        end
    end

    -- Field-fill for shape drift within one version (saves from older
    -- builds of the same settingsVersion).
    for _, state in pairs(db.chars) do
        if type(state.tomeTogglePending) ~= "table" then
            state.tomeTogglePending = {}
        end
        if type(state.flagDemotions) ~= "table" then
            state.flagDemotions = {}
        end
        if type(state.recordedPicks) ~= "table" then
            state.recordedPicks = {}
        end
        if type(state.loadoutWishlists) ~= "table" then
            state.loadoutWishlists = {}
        end
        if type(state.relayPairs) ~= "table" then
            state.relayPairs = {}
        end
        if state.relayPending ~= nil and type(state.relayPending) ~= "table" then
            state.relayPending = nil
        end
    end
end

-- Live subtable; callers re-fetch rather than caching (Init may replace
-- it on a version bump).
function Store.Settings()
    local db = NexusDB
    if db and type(db.settings) == "table" then return db.settings end
    if not transientSettings then
        local profile = Nexus.DefaultProfile
        transientSettings = DeepCopy(profile and profile.defaultSettings or {})
    end
    return transientSettings
end

-- Per-char live subtable. The key is re-read from UnitName on EVERY
-- call: while it reads nil/"Unknown" (login order) a transient table is
-- returned instead, and the first call with a real name switches to the
-- persisted one -- a bad key is never latched (addendum B5).
function Store.State()
    local name = UnitName and UnitName("player") or nil
    local db = NexusDB
    if not name or name == "" or name == "Unknown"
        or not db or type(db.chars) ~= "table" then
        transientState = transientState or FreshState()
        return transientState
    end
    local state = db.chars[name]
    if type(state) ~= "table" then
        state = FreshState()
        db.chars[name] = state
    end
    return state
end
