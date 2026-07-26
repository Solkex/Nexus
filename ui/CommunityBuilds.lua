-- Nexus: ui/CommunityBuilds.lua
-- Nexus Builds community browser -- modeled on the in-game Echo Journal
-- Community Loadouts screen (see screenshots 2026-07-24): scrollable
-- list of build cards grouped under class headers, each showing echo
-- icons inline, author, and a +/... menu. Click any card to expand a
-- detail panel (all echoes, full description, Copy / owner Edit / Delete). Sync: posts broadcast automatically; receiving is opt-in via
-- "Sync Now".

Nexus = Nexus or {}
local M = {}
Nexus.CommunityBuilds = M

------------------------------------------------------------------------
-- Constants / lookup tables
------------------------------------------------------------------------

local CARD_HEIGHT    = 88      -- compact, readable build row
local ICON_SIZE      = 26      -- Echo preview icon size
local MAX_ROW_ICONS  = 12      -- preview icons before the remainder count
local ECHO_ICON_SIZE = 22      -- icons in the detail panel

local CLASS_COLOR = {
    DEATHKNIGHT = { 0.77, 0.12, 0.23 },
    DRUID       = { 1.00, 0.49, 0.04 },
    HUNTER      = { 0.67, 0.83, 0.45 },
    MAGE        = { 0.25, 0.78, 0.92 },
    PALADIN     = { 0.96, 0.55, 0.73 },
    PRIEST      = { 1.00, 1.00, 1.00 },
    ROGUE       = { 1.00, 0.96, 0.41 },
    SHAMAN      = { 0.00, 0.44, 0.87 },
    WARLOCK     = { 0.53, 0.53, 0.93 },
    WARRIOR     = { 0.78, 0.61, 0.43 },
}
local CLASS_ORDER = {
    DEATHKNIGHT=1, DRUID=2, HUNTER=3, MAGE=4, PALADIN=5,
    PRIEST=6,      ROGUE=7, SHAMAN=8, WARLOCK=9, WARRIOR=10,
}
local CLASS_LABEL = {
    DEATHKNIGHT="Death Knight", DRUID="Druid",   HUNTER="Hunter",
    MAGE="Mage",    PALADIN="Paladin", PRIEST="Priest",
    ROGUE="Rogue",  SHAMAN="Shaman",   WARLOCK="Warlock", WARRIOR="Warrior",
}
local CLASS_ICON = {
    DEATHKNIGHT="Interface\\Icons\\Spell_DeathKnight_IceboundFortitude",
    DRUID       ="Interface\\Icons\\Spell_Nature_NaturesBlessing",
    HUNTER      ="Interface\\Icons\\Ability_Hunter_BeastCall",
    MAGE        ="Interface\\Icons\\Spell_Frost_Frostbolt02",
    PALADIN     ="Interface\\Icons\\Spell_Holy_HolyBolt",
    PRIEST      ="Interface\\Icons\\Spell_Holy_PowerInfusion",
    ROGUE       ="Interface\\Icons\\Ability_BackStab",
    SHAMAN      ="Interface\\Icons\\Spell_Nature_Lightning",
    WARLOCK     ="Interface\\Icons\\Spell_Shadow_ShadowBolt",
    WARRIOR     ="Interface\\Icons\\Ability_Warrior_Charge",
}

------------------------------------------------------------------------
-- Module state
------------------------------------------------------------------------

local frame, scrollChild, scrollFrame, scrollBar
local detailPanel
local postPopup, editPopup
local searchBox, classDropBtn, dropPanel, sortToggle, syncStatusText, syncStatusHitbox, syncBtn
local leaderboardBtn, wishlistBtn
local Adapter, Model
local selectedId  = nil
local pendingLockIn = nil

------------------------------------------------------------------------
-- Saved-variable helpers
------------------------------------------------------------------------

local function IsAdmin()
    local name = UnitName and UnitName("player")
    return name and tostring(name):lower() == "explore"
end

local function RemoveLegacyBuilds()
    NexusDB.communityBuilds = NexusDB.communityBuilds or {}
    local db = NexusDB.communityBuilds
    for id, b in pairs(db) do
        if b and tostring(b.author or ""):lower() == "wr team" then
            db[id] = nil
            if selectedId == id then selectedId = nil end
        end
    end
    return db
end

local function Store()
    NexusDB.communityBuilds = NexusDB.communityBuilds or {}
    return NexusDB.communityBuilds
end

local function FilterSettings()
    NexusDB.buildFilters = NexusDB.buildFilters or {}
    return NexusDB.buildFilters
end

------------------------------------------------------------------------
-- Spell icon helper
------------------------------------------------------------------------

local function SpellIcon(spellId)
    if not spellId then return "Interface\\Icons\\INV_Misc_QuestionMark" end
    local ok, _, _, icon = pcall(GetSpellInfo, spellId)
    return (ok and icon and icon ~= "") and icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Infer the class the build actually belongs to from the echoes being
-- posted. This matters for the admin workflow: the character posting a
-- build does not have to be the class represented by the wishlist.
local CLASS_MASK = {
    WARRIOR=1, PALADIN=2, HUNTER=4, ROGUE=8, PRIEST=16,
    DEATHKNIGHT=32, SHAMAN=64, MAGE=128, WARLOCK=256, DRUID=1024,
}

local VALID_CLASS = {}
for class in pairs(CLASS_MASK) do VALID_CLASS[class] = true end

local function NormalizeClass(class)
    class = type(class) == "string" and class:upper() or nil
    return class and VALID_CLASS[class] and class or nil
end

-- Infer only from class-restricted Echoes. Universal/multi-class Echoes are
-- deliberately ignored because they create ties whose result depends on Lua
-- table iteration order (the source of record builds randomly becoming Shaman).
local function InferBuildClass(echoes)
    local scores = {}
    local cat = Adapter and Adapter.Catalog and Adapter.Catalog()
    local rows = cat and cat.rows
    if type(echoes) == "table" and type(rows) == "table" and bit and bit.band then
        for _, e in ipairs(echoes) do
            local row = rows[tonumber(e.spellId)]
            local mask = row and tonumber(row.classMask) or 0
            if mask > 0 then
                local matched, onlyClass = 0, nil
                for class, classMask in pairs(CLASS_MASK) do
                    if bit.band(mask, classMask) ~= 0 then
                        matched = matched + 1
                        onlyClass = class
                    end
                end
                if matched == 1 and onlyClass then
                    scores[onlyClass] = (scores[onlyClass] or 0) + 1
                end
            end
        end
    end
    local best, bestScore, tied = nil, 0, false
    for class, score in pairs(scores) do
        if score > bestScore then
            best, bestScore, tied = class, score, false
        elseif score == bestScore and score > 0 then
            tied = true
        end
    end
    return (bestScore > 0 and not tied) and best or nil
end

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

local function CurrentOwnerKey()
    return OwnerKey(UnitName and UnitName("player"), CurrentRealm())
end

------------------------------------------------------------------------
-- Sort / filter
------------------------------------------------------------------------

local function ClassRank(b)
    return CLASS_ORDER[(b.class or ""):upper()] or 99
end

local function SortedBuilds()
    local fs = FilterSettings()
    local search = (fs.search or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    local classFilter = fs.classFilter
    local out = {}
    for _, b in pairs(Store()) do
        local classMatch = not classFilter or (b.class or ""):upper() == classFilter
        local searchMatch = search == "" or
            (b.title or ""):lower():find(search, 1, true) or
            (b.author or ""):lower():find(search, 1, true) or
            (b.description or ""):lower():find(search, 1, true)
        if classMatch and searchMatch then out[#out+1] = b end
    end
    if (fs.sortMode or "name") == "recent" then
        table.sort(out, function(a,b)
            local at = a.lastModified or a.postedAt or 0
            local bt = b.lastModified or b.postedAt or 0
            if at ~= bt then return at > bt end
            return (a.title or ""):lower() < (b.title or ""):lower()
        end)
    else
        table.sort(out, function(a,b)
            local ta, tb = (a.title or ""):lower(), (b.title or ""):lower()
            if ta ~= tb then return ta < tb end
            return tostring(a.author or ""):lower() < tostring(b.author or ""):lower()
        end)
    end
    return out
end

local function DpsBoardRows(category)
    local D = Nexus.DpsCapture
    if not (D and D.GetDpsBoard) then return {} end
    local ok, rows = pcall(D.GetDpsBoard, category)
    if not ok or type(rows) ~= "table" then return {} end
    local fs = FilterSettings()
    local search = (fs.search or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    local classFilter = fs.classFilter
    local out = {}
    for _, row in ipairs(rows) do
        local build = row.build or {}
        local classMatch = not classFilter or (build.class or ""):upper() == classFilter
        local searchMatch = search == ""
            or tostring(row.player or ""):lower():find(search, 1, true)
            or tostring(build.title or ""):lower():find(search, 1, true)
            or tostring(build.author or ""):lower():find(search, 1, true)
        if classMatch and searchMatch then out[#out + 1] = row end
    end
    return out
end

local function DpsText(value)
    value = tonumber(value) or 0
    if value >= 1000000 then return string.format("%.2fM", value / 1000000) end
    if value >= 1000 then return string.format("%dk", math.floor(value / 1000)) end
    return tostring(math.floor(value))
end

------------------------------------------------------------------------
-- Monotonic stamp & broadcast helpers
------------------------------------------------------------------------

local function NextStamp(previous)
    local now = (time and time()) or 0
    local prev = tonumber(previous) or 0
    return now > prev and now or prev + 1
end

local function IsOwnBuild(build)
    if not build then return false end
    local mine = CurrentOwnerKey()
    if not mine then return false end
    if build.ownerKey then
        return tostring(build.ownerKey):lower() == mine
    end
    -- Legacy builds predate ownerKey. They are editable only when BOTH the
    -- local-only marker and author name match this exact character. Merely
    -- sharing the account-wide SavedVariables file is never sufficient.
    if not build.isMine then return false end
    local me = tostring((UnitName and UnitName("player")) or ""):lower()
    return me ~= "" and tostring(build.author or ""):lower() == me
end


local function NormalizeDiscordBuildLink(value)
    local link = tostring(value or ""):gsub("^%s+",""):gsub("%s+$","")
    if link == "" then return nil end
    link = link:gsub("^<",""):gsub(">$","")
    link = link:gsub("^http://", "https://")
    link = link:gsub("^https://www%.discord%.com/", "https://discord.com/")
    link = link:gsub("^https://discordapp%.com/", "https://discord.com/")
    local guildId, channelId, messageId = link:match("^https://discord%.com/channels/(%d+)/(%d+)/(%d+)/?$")
    if guildId then
        return string.format("https://discord.com/channels/%s/%s/%s", guildId, channelId, messageId)
    end

    guildId, channelId = link:match("^https://discord%.com/channels/(%d+)/(%d+)/?$")
    if guildId then
        return string.format("https://discord.com/channels/%s/%s", guildId, channelId)
    end

    return nil, "Paste a Discord channel or message link from discord.com/channels/."
end


local function ShowDiscordGuideLink(link)
    link = tostring(link or "")
    if link == "" then return end

    -- WoW 3.3.5 addons cannot launch an external browser or write directly
    -- to the system clipboard. Use a focused, pre-selected copy dialog so
    -- opening the linked Discord guide is still only Ctrl+C and paste away.
    StaticPopupDialogs = StaticPopupDialogs or {}
    if not StaticPopupDialogs["NEXUS_DISCORD_GUIDE"] then
        StaticPopupDialogs["NEXUS_DISCORD_GUIDE"] = {
            text = "Discord guide link\n\nPress Ctrl+C, then paste it into Discord or your browser.",
            button1 = "Done",
            hasEditBox = 1,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
            preferredIndex = 3,
            OnShow = function(self, data)
                local box = self.editBox or _G[self:GetName() .. "EditBox"]
                if box then
                    box:SetText(tostring(data or ""))
                    box:SetFocus()
                    box:HighlightText()
                end
            end,
            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
            EditBoxOnEnterPressed = function(self)
                self:HighlightText()
            end,
        }
    end

    if StaticPopup_Show then
        StaticPopup_Show("NEXUS_DISCORD_GUIDE", nil, nil, link)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat(link)
    end
end

local function BroadcastIfPossible(record)
    if Nexus.Sync then
        pcall(Nexus.Sync.BroadcastBuildSummary
            or Nexus.Sync.BroadcastBuild, record)
    end
end

------------------------------------------------------------------------
-- Data mutations (post / edit / update / delete)
------------------------------------------------------------------------

-- Normalize every wishlist source to the same Echo list shape.
-- This helper must be declared before PostCurrentWishlist so Lua closes
-- over the local function instead of accidentally resolving a global.
local function WishlistEchoes(wl)
    if not wl then return nil end
    if type(wl.echoes) == "table" and #wl.echoes > 0 then return wl.echoes end
    if type(wl.entries) == "table" and #wl.entries > 0 then return wl.entries end
    return nil
end

local function FingerprintHash(text)
    local h1, h2 = 5381, 2166136261
    for i = 1, #text do
        local b = text:byte(i)
        h1 = (h1 * 33 + b) % 2147483647
        h2 = (h2 * 131 + b) % 2147483629
    end
    return string.format("%08x%08x", h1, h2)
end

-- Ensure a personal-best Echo snapshot has a copyable community build page.
-- Existing manual or automatic builds with the exact fingerprint are reused;
-- a new deterministic record-loadout page is created only when none exists.
function M.EnsureDpsBuildForEchoes(echoes, category, record)
    local D = Nexus.DpsCapture
    if not (D and D.GetEchoKey) then return nil end
    local key = D.GetEchoKey(echoes)
    if not key then return nil end
    local explicitClass = NormalizeClass(record and (record.class or record.k))
    local player = tostring(record and record.player or (UnitName and UnitName("player")) or "Unknown")
    local recordOwner = record and record.ownerKey
    local ownAutoId, ownAutoBuild
    local manualId, manualBuild
    for id, build in pairs(Store()) do
        if D.GetEchoKey(build.echoes) == key then
            if not build.autoDps then
                if IsOwnBuild(build) then return id, build end
                manualId, manualBuild = manualId or id, manualBuild or build
            else
                local sameOwner = recordOwner and build.ownerKey
                    and tostring(recordOwner):lower() == tostring(build.ownerKey):lower()
                local sameLegacyAuthor = not recordOwner and tostring(build.author or ""):lower() == player:lower()
                if sameOwner or sameLegacyAuthor then
                    ownAutoId, ownAutoBuild = id, build
                end
            end
        end
    end
    -- A real posted build is the canonical page for an exact loadout. An
    -- automatic record page is reused only for the same character; another
    -- player's auto page must never steal edit ownership from this record.
    if manualId then return manualId, manualBuild end

    local copied = {}
    for _, e in ipairs(echoes or {}) do
        copied[#copied + 1] = { spellId=e.spellId or e.id, stacks=e.count or e.stacks or 1 }
    end
    local me = tostring((UnitName and UnitName("player")) or "")
    local playerIsLocal = player:lower() == me:lower()
    local localClass
    if playerIsLocal and UnitClass then
        local _, token = UnitClass("player")
        localClass = NormalizeClass(token)
    end
    local class = explicitClass or InferBuildClass(copied) or localClass or "UNKNOWN"

    if ownAutoId then
        -- Repair old automatically-created pages that inherited the viewer's
        -- class. An explicit class captured with the record is authoritative.
        if explicitClass and ownAutoBuild.class ~= explicitClass then
            ownAutoBuild.class = explicitClass
            ownAutoBuild.title = (CLASS_LABEL[explicitClass] or explicitClass) .. " Record Loadout"
            ownAutoBuild.lastModified = NextStamp(ownAutoBuild.lastModified or ownAutoBuild.postedAt)
            BroadcastIfPossible(ownAutoBuild)
        end
        return ownAutoId, ownAutoBuild
    end

    local stamp = NextStamp(0)
    local ownerKey = recordOwner or (playerIsLocal and CurrentOwnerKey() or nil)
    local identity = ownerKey or player:lower()
    local id = "dps-" .. FingerprintHash(key) .. "-" .. FingerprintHash(identity):sub(1, 8)
    local build = {
        id=id, title=(CLASS_LABEL[class] or class) .. " Record Loadout",
        description="Automatically created from a verified DPS record. Exact Echo IDs and stack quantities are preserved for copying and comparison.",
        author=player, ownerKey=ownerKey, class=class, echoes=copied, postedAt=stamp,
        lastModified=stamp, isMine=(ownerKey and ownerKey == CurrentOwnerKey()) or false,
        autoDps=true, fingerprint=key,
    }
    Store()[id] = build
    BroadcastIfPossible(build)
    return id, build
end

function M.PostCurrentWishlist(title, description, selectedWishlist, selectedClass)
    if not (Adapter and Adapter.Wishlist) then return false, "adapter not ready" end

    -- A selected Echo Wishlist is identified by its server slot.  Do not
    -- trust a UI candidate's cached echo array blindly: older adapter
    -- snapshots could carry count=79 while the copied echoes table was
    -- empty.  Resolve the selected slot against the live server mirror
    -- before declaring that no wishlist was selected.
    local wl = selectedWishlist
    local sourceEchoes = WishlistEchoes(wl)
    if (not sourceEchoes or #sourceEchoes == 0) and wl and wl.slot
        and Adapter.Slots then
        local slots = Adapter.Slots()
        local live = slots and slots.bySlot and slots.bySlot[wl.slot]
        if live and type(live.echoes) == "table" and #live.echoes > 0 then
            wl = {
                slot = wl.slot,
                name = live.name or wl.name,
                count = #live.echoes,
                echoes = live.echoes,
                active = slots.activeSlot == wl.slot,
            }
            sourceEchoes = wl.echoes
        end
    end
    if not wl then wl = Adapter.Wishlist() end
    sourceEchoes = sourceEchoes or WishlistEchoes(wl)
    if not wl or not sourceEchoes or #sourceEchoes == 0 then
        return false, "no wishlist selected to post"
    end
    title = (title or ""):gsub("^%s+",""):gsub("%s+$","")
    if title == "" then title = (wl.name ~= "" and wl.name) or "Untitled" end
    local echoes = {}
    for _, e in ipairs(sourceEchoes) do
        echoes[#echoes+1] = { spellId=e.spellId, quality=e.quality, stacks=e.stacks or 1 }
    end
    local stamp = NextStamp(0)
    local id = string.format("mine-%d-%d", stamp, math.random(100000,999999))
    local record = {
        id=id, title=title, description=description or "",
        author=(UnitName and UnitName("player")) or "You",
        ownerKey=CurrentOwnerKey(),
        class=NormalizeClass(selectedClass) or InferBuildClass(echoes) or NormalizeClass(wl.class),
        echoes=echoes, postedAt=stamp, lastModified=stamp, isMine=true,
    }
    Store()[id] = record
    BroadcastIfPossible(record)
    local D = Nexus.DpsCapture
    if D and D.BroadcastBestForBuild then
        pcall(D.BroadcastBestForBuild, id)
    end
    return true, id
end

local function HasLeaderboardRecord(build)
    if not build then return false end
    if build.autoDps then return true end
    local D = Nexus.DpsCapture
    if not D or not D.GetLeaderboard then return false end
    local dummy = D.GetLeaderboard(build.id, "dummy") or {}
    local lk = D.GetLeaderboard(build.id, "lk") or {}
    return #dummy > 0 or #lk > 0
end

function M.EditBuild(id, title, description, discordLink)
    local b = Store()[id]
    if not b then return false, "not found" end
    if not IsOwnBuild(b) then return false, "not your build" end
    title = (title or ""):gsub("^%s+",""):gsub("%s+$","")
    if title ~= "" then b.title = title end
    if description ~= nil then b.description = description end
    if discordLink ~= nil then
        local raw = tostring(discordLink or "")
        local normalized, linkErr = NormalizeDiscordBuildLink(raw)
        if raw:match("^%s*$") then
            b.link = nil
        elseif not normalized then
            return false, linkErr or "invalid Discord build link"
        else
            b.link = normalized
        end
    end
    b.lastModified = NextStamp(b.lastModified or b.postedAt)
    BroadcastIfPossible(b)
    return true
end

function M.UpdateFromWishlist(id)
    local b = Store()[id]
    if not b then return false, "not found" end
    if not IsOwnBuild(b) then return false, "not your build" end
    if HasLeaderboardRecord(b) then
        return false, "this exact loadout has a leaderboard record and is locked; post a new build to change its Echoes"
    end
    if not (Adapter and Adapter.Wishlist) then return false, "adapter not ready" end
    local wl = Adapter.Wishlist()
    if not wl or not wl.entries or #wl.entries == 0 then
        return false, "no active wishlist"
    end
    local echoes = {}
    for _, e in ipairs(wl.entries) do
        echoes[#echoes+1] = { spellId=e.spellId, quality=e.quality, stacks=e.stacks or 1 }
    end
    b.echoes = echoes
    b.lastModified = NextStamp(b.lastModified or b.postedAt)
    BroadcastIfPossible(b)
    local D = Nexus.DpsCapture
    if D and D.BroadcastBestForBuild then
        pcall(D.BroadcastBestForBuild, id)
    end
    return true, #echoes
end

function M.DeleteBuild(id)
    local b = Store()[id]
    if not b then return false, "not found" end
    if not IsOwnBuild(b) and not IsAdmin() then
        return false, "not your build"
    end
    if IsOwnBuild(b) and Nexus.Sync then
        pcall(Nexus.Sync.BroadcastDelete, b)
    end
    Store()[id] = nil
    if selectedId == id then selectedId = nil end
    return true
end


function M.IsOwnBuild(idOrBuild)
    local build = type(idOrBuild) == "table" and idOrBuild or Store()[idOrBuild]
    return IsOwnBuild(build)
end

------------------------------------------------------------------------
-- Friendly error messages
------------------------------------------------------------------------

local FRIENDLY_ERRORS = {
    spacing  = "the server is busy -- try again in a moment",
    refused  = "the server refused the change",
    ["no echoes"]       = "that build has no echoes",
    ["no valid echoes"] = "none of its echoes are valid",
}
local function Friendly(err)
    return FRIENDLY_ERRORS[tostring(err)] or tostring(err)
end

------------------------------------------------------------------------
-- Lock-in with retry
------------------------------------------------------------------------

local function TryLockIn(title, echoes)
    local ok, err = Adapter.UploadWishlist(0, title, echoes)
    if ok then
        print("|cff4dff80Nexus:|r locked in '"..tostring(title).."'.")
        pendingLockIn = nil
        M.Refresh()
        return true
    end
    if tostring(err) == "spacing" then
        pendingLockIn = { title=title, echoes=echoes, tries=0 }
        return false
    end
    print("|cffff6060Nexus:|r couldn't lock in: "..Friendly(err))
    pendingLockIn = nil
    return false
end

function M._PumpPendingLockIn()
    if not pendingLockIn then return end
    pendingLockIn.tries = pendingLockIn.tries + 1
    if pendingLockIn.tries > 12 then
        print("|cffff6060Nexus:|r couldn't lock in: "..Friendly("spacing"))
        pendingLockIn = nil; return
    end
    TryLockIn(pendingLockIn.title, pendingLockIn.echoes)
end

function M.IsLockInPending() return pendingLockIn ~= nil end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["NEXUS_LOCKIN_BUILD"] = {
    text = "Lock in '%s'?\nThis overwrites your current active wishlist.",
    button1 = "Lock In", button2 = "Cancel",
    OnAccept = function(_, data) TryLockIn(data.title, data.echoes) end,
    timeout=0, whileDead=true, hideOnEscape=true,
}

function M.LockInSelected()
    if not selectedId then return end
    local build = Store()[selectedId]
    if not build then return end
    if type(build.echoes) ~= "table" or #build.echoes == 0 then
        if Nexus.Sync and Nexus.Sync.RequestLoadout then
            Nexus.Sync.RequestLoadout(selectedId)
            print("|cff7fd5ffNexus:|r requesting the exact Echo loadout from the mesh...")
        end
        return
    end
    StaticPopup_Show("NEXUS_LOCKIN_BUILD", build.title, nil,
        { title=build.title, echoes=build.echoes })
end

------------------------------------------------------------------------
-- Detail panel (shown on the right when a card is selected)
------------------------------------------------------------------------

local function EnsureDetailPanel(parent)
    if detailPanel then return detailPanel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(500, 530)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", 520, -94)
    p:SetFrameLevel(parent:GetFrameLevel() + 2)
    p:Hide()

    pcall(function()
        p:SetBackdrop({
            bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=16, edgeSize=12,
            insets={left=3,right=3,top=3,bottom=3},
        })
        p:SetBackdropColor(0,0,0,0.9)
    end)

    p.classIcon = p:CreateTexture(nil,"ARTWORK")
    p.classIcon:SetSize(34,34)
    p.classIcon:SetPoint("TOPLEFT",10,-10)
    p.classIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    p.title = p:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    p.title:SetPoint("TOPLEFT",p.classIcon,"TOPRIGHT",8,-1)
    p.title:SetSize(390,20)
    p.title:SetJustifyH("LEFT")

    p.closeBtn = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    p.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    p.closeBtn:SetScript("OnClick", function()
        selectedId = nil
        M.Refresh()
    end)

    p.verifiedBadge = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.verifiedBadge:SetPoint("TOPRIGHT",-34,-18)
    p.verifiedBadge:SetSize(130,14)
    p.verifiedBadge:SetJustifyH("RIGHT")
    p.verifiedBadge:SetText("|cff4dff80DETAILS VERIFIED|r")
    p.verifiedBadge:Hide()

    p.author = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    p.author:SetPoint("TOPLEFT",p.title,"BOTTOMLEFT",0,-2)
    p.author:SetSize(350,12)
    p.author:SetJustifyH("LEFT")

    p.desc = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.desc:SetPoint("TOPLEFT",10,-56)
    p.desc:SetSize(350,50)
    p.desc:SetJustifyH("LEFT")
    p.desc:SetJustifyV("TOP")

    -- Discord guide: viewers get a single obvious action. WoW cannot open
    -- external URLs directly, so the action opens a pre-selected copy dialog.
    local linkLabel = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    linkLabel:SetPoint("TOPLEFT",10,-108)
    linkLabel:SetText("|cff888888DISCORD GUIDE|r")
    p.linkLabel = linkLabel

    local linkStatus = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    linkStatus:SetPoint("TOPLEFT",10,-124)
    linkStatus:SetSize(250,18)
    linkStatus:SetJustifyH("LEFT")
    linkStatus:SetText("Guide link available")
    p.linkStatus = linkStatus

    local linkOpenBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    linkOpenBtn:SetSize(138,20)
    linkOpenBtn:SetPoint("TOPRIGHT",-10,-120)
    linkOpenBtn:SetText("Open Discord Guide")
    linkOpenBtn:SetScript("OnClick", function()
        ShowDiscordGuideLink(linkOpenBtn._link)
    end)
    linkOpenBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self,"ANCHOR_TOP")
        GameTooltip:AddLine("Open Discord guide",1,1,1)
        GameTooltip:AddLine("Opens the full link already selected. Press Ctrl+C, then paste it into Discord or your browser.",0.8,0.8,0.8,true)
        GameTooltip:Show()
    end)
    linkOpenBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.linkOpenBtn = linkOpenBtn

    p.echoLabel = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    p.echoLabel:SetPoint("TOPLEFT",10,-148)
    p.echoLabel:SetText("Echoes:")

    -- echo icon grid: up to 80 icons, 13 per row
    p.echoIcons = {}
    local COLS = 13
    for i = 1, 80 do
        local col = (i-1) % COLS
        local row = math.floor((i-1) / COLS)
        local ic = p:CreateTexture(nil,"ARTWORK")
        ic:SetSize(ECHO_ICON_SIZE, ECHO_ICON_SIZE)
        ic:SetPoint("TOPLEFT", 10 + col*(ECHO_ICON_SIZE+2), -162 - row*(ECHO_ICON_SIZE+2))
        ic:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        ic:Hide()
        p.echoIcons[i] = ic
    end

    p.missingText = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.missingText:SetPoint("TOPLEFT",10,-334)
    p.missingText:SetSize(470,14)
    p.missingText:SetJustifyH("LEFT")

    -- Compact record summary. Full rankings live in the dedicated Leaderboard.
    p.recordsTitle = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    p.recordsTitle:SetPoint("TOPLEFT",10,-358)
    p.recordsTitle:SetText("BEST RECORDS FOR THIS LOADOUT")

    p.dummyRecord = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.dummyRecord:SetPoint("TOPLEFT",10,-380)
    p.dummyRecord:SetSize(470,16)
    p.dummyRecord:SetJustifyH("LEFT")

    p.lkRecord = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.lkRecord:SetPoint("TOPLEFT",10,-402)
    p.lkRecord:SetSize(470,16)
    p.lkRecord:SetJustifyH("LEFT")

    -- Legacy row widgets are retained but hidden for saved UI compatibility.
    -- DPS section: Training Dummy
    local dummyHeader = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    dummyHeader:SetPoint("TOPLEFT",10,-302)
    dummyHeader:SetText("|cffffd200Training Dummy - Best DPS|r")

    p.lbDummyRows = {}
    for i = 1, 5 do
        local row = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        row:SetPoint("TOPLEFT",10,-318-(i-1)*16)
        row:SetSize(440,14); row:SetJustifyH("LEFT"); row:Hide()
        p.lbDummyRows[i] = row
    end
    p.lbDummyEmpty = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    p.lbDummyEmpty:SetPoint("TOPLEFT",10,-318)
    p.lbDummyEmpty:SetSize(440,14)
    p.lbDummyEmpty:SetText("|cff666666No recorded DPS yet -- hit a training dummy|r")

    p.lbDummyPersonal = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.lbDummyPersonal:SetPoint("TOPLEFT",10,-402)
    p.lbDummyPersonal:SetSize(440,14); p.lbDummyPersonal:SetJustifyH("LEFT")
    p.lbDummyPersonal:Hide()

    -- DPS section: Lich King
    local lkHeader = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    lkHeader:SetPoint("TOPLEFT",10,-422)
    lkHeader:SetText("|cffffd200Lich King - Best DPS|r")

    p.lbLKRows = {}
    for i = 1, 5 do
        local row = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        row:SetPoint("TOPLEFT",10,-438-(i-1)*16)
        row:SetSize(440,14); row:SetJustifyH("LEFT"); row:Hide()
        p.lbLKRows[i] = row
    end
    p.lbLKEmpty = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    p.lbLKEmpty:SetPoint("TOPLEFT",10,-438)
    p.lbLKEmpty:SetSize(440,14)
    p.lbLKEmpty:SetText("|cff666666No Lich King results yet|r")

    p.lbLKPersonal = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    p.lbLKPersonal:SetPoint("TOPLEFT",10,-522)
    p.lbLKPersonal:SetSize(440,14); p.lbLKPersonal:SetJustifyH("LEFT")
    p.lbLKPersonal:Hide()

    dummyHeader:Hide()
    lkHeader:Hide()
    p.lbDummyEmpty:Hide()
    p.lbDummyPersonal:Hide()
    p.lbLKEmpty:Hide()
    p.lbLKPersonal:Hide()
    for _, row in ipairs(p.lbDummyRows) do row:Hide() end
    for _, row in ipairs(p.lbLKRows) do row:Hide() end

    -- Details! availability note (shown once at bottom if not installed)
    p.detailsNote = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    p.detailsNote:SetPoint("BOTTOMLEFT",8,60)
    p.detailsNote:SetSize(470,12)
    p.detailsNote:SetJustifyH("LEFT")
    p.detailsNote:SetText("|cff666666Install Details! damage meter to enable DPS tracking.|r")

    p.editState = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    p.editState:SetPoint("BOTTOMLEFT",8,42)
    p.editState:SetSize(470,14)
    p.editState:SetJustifyH("LEFT")
    p.editState:Hide()

    -- buttons row
    p.lockBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    p.lockBtn:SetSize(130,22)
    p.lockBtn:SetPoint("BOTTOMLEFT",8,8)
    p.lockBtn:SetText("Copy Exact Build")
    p.lockBtn:SetScript("OnClick", function() M.LockInSelected() end)

    p.editBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    p.editBtn:SetSize(96,22)
    p.editBtn:SetPoint("LEFT",p.lockBtn,"RIGHT",6,0)
    p.editBtn:SetText("Edit Build")
    p.editBtn:SetScript("OnClick", function() if selectedId then M.ToggleEditPopup(selectedId) end end)

    p.deleteBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    p.deleteBtn:SetSize(60,22)
    p.deleteBtn:SetPoint("BOTTOMRIGHT",-8,8)
    p.deleteBtn:SetText("Delete")
    p.deleteBtn:SetScript("OnClick", function()
        if selectedId then
            local ok, err = M.DeleteBuild(selectedId)
            if not ok then print("|cffff6060Nexus:|r " .. tostring(err)) end
            M.Refresh()
        end
    end)

    detailPanel = p
    return p
end

local function RefreshDetailPanel(build)
    if not detailPanel then return end
    if not build then
        if detailPanel.verifiedBadge then detailPanel.verifiedBadge:Hide() end
        detailPanel:Hide()
        return
    end

    local D = Nexus.DpsCapture
    local c = CLASS_COLOR[(build.class or ""):upper()] or {1,1,1}
    detailPanel.title:SetTextColor(c[1],c[2],c[3])
    detailPanel.title:SetText(build.title or "")
    local verification = D and D.GetBuildVerification and D.GetBuildVerification(build.id)
    if detailPanel.verifiedBadge then
        if verification then detailPanel.verifiedBadge:Show() else detailPanel.verifiedBadge:Hide() end
    end
    if detailPanel.classIcon then
        detailPanel.classIcon:SetTexture(CLASS_ICON[(build.class or ""):upper()] or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
    detailPanel.author:SetText("by "..(build.author or "?"))
    detailPanel.desc:SetText((build.description ~= "" and build.description) or "|cff666666(no description)|r")

    -- Discord links are edited in Edit Build. Viewers get one obvious action
    -- that opens the full URL in a pre-selected copy dialog.
    local hasLink = type(build.link) == "string" and build.link ~= ""
    if detailPanel.linkOpenBtn then
        if hasLink then
            detailPanel.linkLabel:Show()
            detailPanel.linkStatus:Show()
            detailPanel.linkOpenBtn:Show()
            detailPanel.linkOpenBtn._link = build.link
        else
            detailPanel.linkLabel:Hide()
            detailPanel.linkStatus:Hide()
            detailPanel.linkOpenBtn:Hide()
            detailPanel.linkOpenBtn._link = nil
        end
    end

    -- echo icons
    local owned = Adapter and Adapter.Owned and Adapter.Owned()
    local bySpell = (owned and owned.bySpell) or {}
    local echoes = build.echoes or {}
    local hasLoadout = type(build.echoes) == "table" and #build.echoes > 0
    if (not hasLoadout or build.needsFullBuild) and Nexus.Sync and Nexus.Sync.RequestLoadout then
        Nexus.Sync.RequestLoadout(build.id)
    end
    local missing = 0
    for i, ic in ipairs(detailPanel.echoIcons) do
        local e = echoes[i]
        if e then
            ic:SetTexture(SpellIcon(e.spellId))
            local have = tonumber(bySpell[e.spellId]) or 0
            local want = tonumber(e.stacks) or 1
            if have < want then
                missing=missing+1
                pcall(function() ic:SetVertexColor(0.4,0.4,0.4) end)
            else
                pcall(function() ic:SetVertexColor(1,1,1) end)
            end
            ic:Show()
        else ic:Hide() end
    end
    if hasLoadout then
        detailPanel.missingText:SetText(string.format(
            "|cff888888%d echoes|r  --  |cffff9040%d missing|r", #echoes, missing))
    else
        detailPanel.missingText:SetText("|cffffd200Requesting exact loadout from the mesh...|r")
    end

    local mine = IsOwnBuild(build)
    local admin = IsAdmin()
    local loadoutLocked = HasLeaderboardRecord(build)
    if mine then
        detailPanel.editBtn:Show()
        detailPanel.deleteBtn:Show()
        detailPanel.deleteBtn:SetText("Delete")
    elseif admin then
        detailPanel.editBtn:Hide()
        detailPanel.deleteBtn:Show()
        detailPanel.deleteBtn:SetText("Remove")
    else
        detailPanel.editBtn:Hide()
        detailPanel.deleteBtn:Hide()
    end

    if mine and loadoutLocked then
        detailPanel.editState:SetText("|cffffd200Leaderboard loadout locked.|r Title and description may still be edited.")
        detailPanel.editState:Show()
    elseif mine then
        detailPanel.editState:SetText("You own this build. Edit can also replace its Echoes from your active wishlist.")
        detailPanel.editState:Show()
    else
        detailPanel.editState:Hide()
    end

    detailPanel.lockBtn:SetText(not hasLoadout and "Request Loadout" or (M.IsLockInPending() and "Copying..." or "Copy Exact Build"))

    -- DPS leaderboards
    local hasDetails = D and D.IsDetailsAvailable()

    local function RenderLbSection(rows, emptyLabel, personalLabel, lb, personal)
        if #lb == 0 then
            emptyLabel:Show()
            for _, r in ipairs(rows) do r:Hide() end
        else
            emptyLabel:Hide()
            for i, row in ipairs(rows) do
                local e = lb[i]
                if e then
                    local dpsStr = e.dps >= 1000000
                        and string.format("%.2fM", e.dps/1000000)
                        or  string.format("%dk",   math.floor(e.dps/1000))
                    row:SetText(string.format(
                        "|cffffd200#%-2d|r  %-16s  |cff4dff80%s|r",
                        i, tostring(e.player):sub(1,16), dpsStr))
                    row:Show()
                else
                    row:Hide()
                end
            end
        end
        if personal then
            local dpsStr = personal.dps >= 1000000
                and string.format("%.2fM", personal.dps/1000000)
                or  string.format("%dk",   math.floor(personal.dps/1000))
            personalLabel:SetText(string.format(
                "|cff888888Your best:|r  |cff4dff80%s|r  (Lv%d)", dpsStr, personal.level))
            personalLabel:Show()
        else
            personalLabel:Hide()
        end
    end

    local function RecordText(label, rows, personal)
        local top = rows and rows[1]
        local best = top and DpsText(top.dps) or "—"
        local holder = top and tostring(top.player or "Unknown") or "No record yet"
        local yours = personal and DpsText(personal.dps) or "—"
        return string.format("|cffffffff%s|r   |cffffd200%s|r  |cff888888%s|r    Your best: |cff4dff80%s|r",
            label, best, holder, yours)
    end

    if D then
        local dummyLb  = D.GetLeaderboard(build.id, "dummy") or {}
        local dummyPB  = D.GetPersonalBest(build.id, "dummy")
        local lkLb     = D.GetLeaderboard(build.id, "lk") or {}
        local lkPB     = D.GetPersonalBest(build.id, "lk")
        detailPanel.dummyRecord:SetText(RecordText("Training Dummy", dummyLb, dummyPB))
        detailPanel.lkRecord:SetText(RecordText("Lich King", lkLb, lkPB))
    else
        detailPanel.dummyRecord:SetText("Training Dummy   —")
        detailPanel.lkRecord:SetText("Lich King   —")
    end

    for _, row in ipairs(detailPanel.lbDummyRows) do row:Hide() end
    for _, row in ipairs(detailPanel.lbLKRows) do row:Hide() end
    detailPanel.lbDummyEmpty:Hide(); detailPanel.lbDummyPersonal:Hide()
    detailPanel.lbLKEmpty:Hide(); detailPanel.lbLKPersonal:Hide()

    -- Show/hide the "install Details!" note
    if detailPanel.detailsNote then
        if hasDetails then detailPanel.detailsNote:Hide()
        else detailPanel.detailsNote:Show() end
    end

    detailPanel:Show()
end

------------------------------------------------------------------------
-- Card pool (reuse pre-built frames to avoid GC churn during scroll)
------------------------------------------------------------------------

local cardPool = {}   -- reusable card frames
local activeCards = {}  -- currently visible cards

local function GetCard(parent)
    if #cardPool > 0 then
        local c = table.remove(cardPool)
        c:SetParent(parent)
        c:Show()
        return c
    end

    local card = CreateFrame("Button", nil, parent)
    card:SetHeight(CARD_HEIGHT)
    card:EnableMouse(true)

    pcall(function()
        card:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 10,
            insets = { left=3, right=3, top=3, bottom=3 },
        })
        card:SetBackdropColor(0.035, 0.035, 0.045, 0.94)
        card:SetBackdropBorderColor(0.24, 0.24, 0.28, 0.9)
    end)

    card.selectedHighlight = card:CreateTexture(nil, "BACKGROUND")
    card.selectedHighlight:SetAllPoints(card)
    pcall(function() card.selectedHighlight:SetTexture(0.18, 0.38, 0.62, 0.22) end)
    card.selectedHighlight:Hide()

    card.classIcon = card:CreateTexture(nil, "ARTWORK")
    card.classIcon:SetSize(30, 30)
    card.classIcon:SetPoint("TOPLEFT", 10, -9)
    card.classIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.title:SetPoint("TOPLEFT", card.classIcon, "TOPRIGHT", 8, 0)
    card.title:SetSize(250, 16)
    card.title:SetJustifyH("LEFT")

    card.author = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.author:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -2)
    card.author:SetSize(245, 12)
    card.author:SetJustifyH("LEFT")

    card.echoCount = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.echoCount:SetPoint("TOPRIGHT", -12, -12)
    card.echoCount:SetSize(90, 12)
    card.echoCount:SetJustifyH("RIGHT")

    card.icons = {}
    for i = 1, MAX_ROW_ICONS do
        local ic = card:CreateTexture(nil, "ARTWORK")
        ic:SetSize(ICON_SIZE, ICON_SIZE)
        ic:SetPoint("BOTTOMLEFT", 10 + (i-1)*(ICON_SIZE+2), 9)
        ic:Hide()
        card.icons[i] = ic
    end

    card.moreText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.moreText:SetPoint("LEFT", card.icons[MAX_ROW_ICONS], "RIGHT", 6, 0)
    card.moreText:SetText("")

    card.mineBadge = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.mineBadge:SetPoint("BOTTOMRIGHT", -64, 13)
    card.mineBadge:SetSize(70, 12)
    card.mineBadge:SetJustifyH("RIGHT")
    card.mineBadge:Hide()

    card.verifiedBadge = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.verifiedBadge:SetPoint("BOTTOMRIGHT", -64, 29)
    card.verifiedBadge:SetSize(110, 12)
    card.verifiedBadge:SetJustifyH("RIGHT")
    card.verifiedBadge:SetText("|cff4dff80DETAILS VERIFIED|r")
    card.verifiedBadge:Hide()

    card.addBtn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    card.addBtn:SetSize(52, 22)
    card.addBtn:SetPoint("BOTTOMRIGHT", -8, 7)
    card.addBtn:SetText("View")
    card.addBtn:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent.buildId then
            selectedId = parent.buildId
            M.Refresh()
        end
    end)
    card.addBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Open build details", 1,1,1)
        GameTooltip:AddLine("Inspect records, exact Echoes, and copy the loadout.", 0.8,0.8,0.8, true)
        GameTooltip:Show()
    end)
    card.addBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Retained for compatibility with older pooled rows; the whole card and
    -- the explicit View button now perform the same clear action.
    card.menuBtn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    card.menuBtn:SetSize(1, 1)
    card.menuBtn:SetPoint("BOTTOMRIGHT", -1, 1)
    card.menuBtn:Hide()

    card:SetScript("OnEnter", function(self)
        if not self.buildId then return end
        pcall(function()
            self:SetBackdropColor(0.07, 0.08, 0.11, 0.98)
            self:SetBackdropBorderColor(0.45, 0.55, 0.7, 1)
        end)
    end)
    card:SetScript("OnLeave", function(self)
        pcall(function()
            self:SetBackdropColor(0.035, 0.035, 0.045, 0.94)
            self:SetBackdropBorderColor(0.24, 0.24, 0.28, 0.9)
        end)
    end)
    card:SetScript("OnClick", function(self)
        if not self.buildId then return end
        selectedId = self.buildId
        M.Refresh()
    end)
    return card
end

local function ReleaseCard(card)
    card:Hide()
    card:ClearAllPoints()
    card:SetParent(nil)
    cardPool[#cardPool+1] = card
end

local function ReleaseAllCards()
    for _, c in ipairs(activeCards) do ReleaseCard(c) end
    activeCards = {}
end

------------------------------------------------------------------------
-- Class header frames
------------------------------------------------------------------------

local headerPool = {}
local activeHeaders = {}

local function GetHeader(parent)
    if #headerPool > 0 then
        local h = table.remove(headerPool)
        h:SetParent(parent); h:Show(); return h
    end
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(22)
    h.label = h:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    h.label:SetPoint("BOTTOMLEFT",2,-2)
    h.sep = h:CreateTexture(nil,"ARTWORK")
    h.sep:SetHeight(1)
    h.sep:SetPoint("BOTTOMLEFT",h,"BOTTOMLEFT",0,0)
    h.sep:SetPoint("BOTTOMRIGHT",h,"BOTTOMRIGHT",0,0)
    pcall(function() h.sep:SetTexture(0.4,0.4,0.4,0.6) end)
    return h
end
local function ReleaseHeader(h)
    h:Hide(); h:ClearAllPoints(); h:SetParent(nil)
    headerPool[#headerPool+1] = h
end
local function ReleaseAllHeaders()
    for _, h in ipairs(activeHeaders) do ReleaseHeader(h) end
    activeHeaders = {}
end

------------------------------------------------------------------------
-- Main frame construction
------------------------------------------------------------------------

local function EnsureFrame()
    if frame then return frame end

    -- Main browser window: list and detail panel live together in one surface.
    frame = CreateFrame("Frame","NexusCommunityBuildsFrame",UIParent)
    frame:SetSize(1040,600)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(50)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart",function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local retryTicker, refreshTicker = 0, 0
    frame:SetScript("OnUpdate",function(_,elapsed)
        retryTicker = retryTicker + elapsed
        if retryTicker >= 0.5 then
            retryTicker = 0
            if M._PumpPendingLockIn then M._PumpPendingLockIn() end
        end
        refreshTicker = refreshTicker + elapsed
        local interval = (Nexus.Sync and Nexus.Sync.IsReceiving()) and 0.5 or 2.0
        if refreshTicker >= interval then
            refreshTicker = 0
            M.Refresh()
        end
    end)
    frame:Hide()

    pcall(function()
        frame:SetBackdrop({
            bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true, tileSize=32, edgeSize=32,
            insets={left=11,right=12,top=12,bottom=11},
        })
    end)

    -- Title bar
    local titleText = frame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    titleText:SetPoint("TOP",0,-14)
    titleText:SetText("Nexus  —  Builds")

    local closeBtn = CreateFrame("Button",nil,frame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",-6,-6)

    -- Top toolbar: browse controls on the left, actions on the right.
    -- The list and detail panel below never overlap the toolbar.


    local browseLabel = frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    browseLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -36)
    browseLabel:SetText("FIND A BUILD")

    local actionLabel = frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    actionLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -36)
    actionLabel:SetText("LIBRARY ACTIONS")

    searchBox = CreateFrame("EditBox","NexusBuildsSearch",frame,"InputBoxTemplate")
    searchBox:SetSize(210,22)
    searchBox:SetPoint("TOPLEFT",20,-50)
    searchBox:SetAutoFocus(false)
    searchBox:SetText(FilterSettings().search or "")
    searchBox:SetScript("OnTextChanged",function(self)
        FilterSettings().search = self:GetText() or ""
        M.Refresh()
    end)
    local searchLabel = frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    searchLabel:SetPoint("LEFT",searchBox,"LEFT",6,0)
    searchLabel:SetText("Search builds...")
    searchBox:SetScript("OnEditFocusGained",function() searchLabel:Hide() end)
    searchBox:SetScript("OnEditFocusLost",function(self)
        if self:GetText() == "" then searchLabel:Show() end
    end)
    if (FilterSettings().search or "") ~= "" then searchLabel:Hide() end

    -- Class dropdown (filter)
    local CLASSES_DD = {
        {key=nil,  label="All Classes"},
        {key="DEATHKNIGHT", label="Death Knight"},
        {key="DRUID",       label="Druid"},
        {key="HUNTER",      label="Hunter"},
        {key="MAGE",        label="Mage"},
        {key="PALADIN",     label="Paladin"},
        {key="PRIEST",      label="Priest"},
        {key="ROGUE",       label="Rogue"},
        {key="SHAMAN",      label="Shaman"},
        {key="WARLOCK",     label="Warlock"},
        {key="WARRIOR",     label="Warrior"},
    }

    classDropBtn = CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
    classDropBtn:SetSize(150,22)
    classDropBtn:SetPoint("TOPLEFT",240,-50)
    frame._classDropBtn = classDropBtn

    dropPanel = CreateFrame("Frame","NexusClassDropPanel",UIParent)
    dropPanel:SetFrameStrata("TOOLTIP")
    dropPanel:SetSize(150, #CLASSES_DD * 20 + 8)
    dropPanel:EnableMouse(true)
    dropPanel:Hide()
    pcall(function()
        dropPanel:SetBackdrop({
            bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=16, edgeSize=12,
            insets={left=3,right=3,top=3,bottom=3},
        })
        dropPanel:SetBackdropColor(0.05,0.05,0.05,0.97)
    end)

    for i, entry in ipairs(CLASSES_DD) do
        local row = CreateFrame("Button",nil,dropPanel)
        row:SetSize(140,20)
        row:SetPoint("TOPLEFT",5,-(4+(i-1)*20))
        row:EnableMouse(true)
        local lbl = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        lbl:SetPoint("LEFT",6,0)
        if entry.key then
            local c = CLASS_COLOR[entry.key] or {1,1,1}
            lbl:SetTextColor(c[1],c[2],c[3])
        end
        lbl:SetText(entry.label)
        row:SetScript("OnEnter",function() lbl:SetAlpha(0.7) end)
        row:SetScript("OnLeave",function() lbl:SetAlpha(1.0) end)
        row:SetScript("OnClick",function()
            FilterSettings().classFilter = entry.key
            dropPanel:Hide()
            M.Refresh()
        end)
    end

    classDropBtn:SetScript("OnClick",function(self)
        if dropPanel:IsShown() then dropPanel:Hide()
        else
            dropPanel:ClearAllPoints()
            dropPanel:SetPoint("TOPLEFT",self,"BOTTOMLEFT",0,-2)
            dropPanel:Show()
        end
    end)

    -- Persistent feature navigation. Leaderboards live in their own dense
    -- window instead of being mixed into build sorting modes.
    leaderboardBtn = CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
    leaderboardBtn:SetSize(104,22)
    leaderboardBtn:SetPoint("TOPLEFT",400,-50)
    leaderboardBtn:SetText("Leaderboard")
    leaderboardBtn:SetScript("OnClick",function()
        frame:Hide()
        if Nexus.Leaderboard then Nexus.Leaderboard.Show() end
    end)

    wishlistBtn = CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
    wishlistBtn:SetSize(86,22)
    wishlistBtn:SetPoint("LEFT",leaderboardBtn,"RIGHT",4,0)
    wishlistBtn:SetText("Wishlists")
    wishlistBtn:SetScript("OnClick",function()
        frame:Hide()
        if Nexus.WishlistEditor then Nexus.WishlistEditor.Show() end
    end)

    -- Sort toggle
    sortToggle = CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
    sortToggle:SetSize(110,22)
    sortToggle:SetPoint("LEFT",wishlistBtn,"RIGHT",4,0)
    frame._sortToggle = sortToggle
    sortToggle:SetScript("OnClick",function()
        local fs = FilterSettings()
        fs.sortMode = (fs.sortMode == "recent") and "name" or "recent"
        M.Refresh()
    end)
    sortToggle:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_TOP")
        GameTooltip:AddLine("Toggle sort order",1,1,1)
        local mode = FilterSettings().sortMode or "name"
        GameTooltip:AddLine(mode == "recent"
            and "Currently: newest updated first. Click for alphabetical order."
            or  "Currently: alphabetical by build name. Click for newest updated first.",
            0.8,0.8,0.8,true)
        GameTooltip:Show()
    end)
    sortToggle:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Sync status line (below toolbar)
    syncStatusText = frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    syncStatusText:SetPoint("TOPLEFT",20,-78)
    syncStatusText:SetSize(600,12)
    syncStatusText:SetJustifyH("LEFT")

    syncStatusHitbox = CreateFrame("Frame", nil, frame)
    syncStatusHitbox:SetPoint("TOPLEFT", syncStatusText, "TOPLEFT", -2, 3)
    syncStatusHitbox:SetSize(610, 18)
    syncStatusHitbox:EnableMouse(true)
    syncStatusHitbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Nexus sync activity", 1, 1, 1)
        GameTooltip:AddLine("Nexus is rate-limited automatically. You do not need to repeatedly press Sync Now.", 0.8, 0.8, 0.8, true)
        local rows = Nexus.Sync and Nexus.Sync.RecentActivity and Nexus.Sync.RecentActivity() or {}
        if #rows > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Recent activity", 1, 0.82, 0)
            local first = math.max(1, #rows - 4)
            for i = #rows, first, -1 do
                GameTooltip:AddLine("- " .. tostring(rows[i].text or ""), 0.75, 0.9, 1, true)
            end
        end
        GameTooltip:Show()
    end)
    syncStatusHitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Sync Now button
    syncBtn = CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
    syncBtn:SetSize(78,22)
    syncBtn:SetPoint("TOPRIGHT",-133,-50)
    frame._syncBtn = syncBtn
    syncBtn:SetText("Sync Now")
    syncBtn:SetScript("OnClick",function()
        if not Nexus.Sync then return end
        local ok, err = Nexus.Sync.RequestSync()
        if not ok then print("|cffff6060Nexus:|r "..tostring(err)) end
    end)
    syncBtn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_TOP")
        GameTooltip:AddLine("Get builds and DPS records from other players",1,1,1)
        GameTooltip:AddLine("Nexus syncs automatically after login and safely downloads missing loadouts.",0.8,0.8,0.8,true)
        GameTooltip:AddLine("Press once to check again. Repeated clicks do not make it faster.",0.8,0.8,0.8,true)
        GameTooltip:Show()
    end)
    syncBtn:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Exact Echo lists are fetched automatically when a build is opened or copied.
    -- The bulk loadout API remains available internally, but is intentionally
    -- removed from the primary toolbar to keep the normal workflow simple.

    -- Post Build button
    local postBtn = CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
    postBtn:SetSize(110,22)
    postBtn:SetPoint("TOPRIGHT",-15,-50)
    postBtn:SetText("Post Build")
    postBtn:SetScript("OnClick",function() M.ShowPostBuild() end)
    postBtn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_TOP")
        GameTooltip:AddLine("Share your current wishlist as a build",1,1,1)
        GameTooltip:AddLine("Opens a preview of your echoes so you can add",0.8,0.8,0.8,true)
        GameTooltip:AddLine("a title and description before posting.",0.8,0.8,0.8,true)
        GameTooltip:Show()
    end)
    postBtn:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Left: scrollable card list -----------------------------------------
    -- Clip region (SetClipsChildren is retail-only on 3.3.5 -- same class
    -- of API as SetColorTexture; wrap defensively so everything below still
    -- gets created even if this call throws)
    local listClip = CreateFrame("Frame",nil,frame)
    listClip:SetPoint("TOPLEFT",20,-94)
    listClip:SetSize(480, 520)
    pcall(function() listClip:SetClipsChildren(true) end)

    scrollFrame = CreateFrame("ScrollFrame",nil,listClip)
    scrollFrame:SetAllPoints(listClip)
    scrollFrame:EnableMouseWheel(true)

    scrollChild = CreateFrame("Frame",nil,scrollFrame)
    scrollChild:SetWidth(460)
    scrollChild:SetHeight(1)     -- set dynamically in Refresh
    scrollFrame:SetScrollChild(scrollChild)

    -- Simple scroll offset tracking -- no template, no SetVerticalScroll,
    -- just keep an offset and SetVerticalScroll via pcall (different API
    -- names across WoW versions).
    scrollBar = { value = 0, min = 0, max = 0 }  -- plain table, no template
    local function SetScroll(val)
        val = math.max(scrollBar.min, math.min(scrollBar.max, val))
        scrollBar.value = val
        pcall(function() scrollFrame:SetVerticalScroll(val) end)
    end
    scrollBar.SetValue = function(_, val) SetScroll(val) end
    scrollBar.GetValue = function(_) return scrollBar.value end
    scrollBar.SetMinMaxValues = function(_, mn, mx) scrollBar.min = mn; scrollBar.max = mx end
    scrollBar.GetMinMaxValues = function(_) return scrollBar.min, scrollBar.max end

    scrollFrame:SetScript("OnMouseWheel",function(_,delta)
        SetScroll(scrollBar.value - delta * CARD_HEIGHT * 3)
    end)

    local emptyState = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyState:SetPoint("TOPLEFT", listClip, "TOPLEFT", 20, 34)
    emptyState:SetSize(400, 80)
    emptyState:SetJustifyH("CENTER")
    emptyState:SetJustifyV("TOP")
    emptyState:Hide()
    frame._emptyState = emptyState

    -- Right: detail panel ------------------------------------------------
    EnsureDetailPanel(frame)
    detailPanel:ClearAllPoints()
    detailPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 520, -94)
    detailPanel:SetSize(500, 530)
    detailPanel:SetFrameLevel(frame:GetFrameLevel() + 10)

    return frame
end


function M.GetSelectedBuildForPanel()
    if not frame or not frame:IsShown() or not selectedId then return nil end
    return Store()[selectedId]
end

------------------------------------------------------------------------
-- Refresh  (called every tick while open, and whenever data changes)
------------------------------------------------------------------------

function M.Refresh()
    if not frame or not frame:IsShown() then return end

    -- Sync status
    if syncStatusText and Nexus.Sync then
        local s = Nexus.Sync
        local status = s.GetStatus and s.GetStatus() or nil
        if status then
            local color = status.phase == "complete" and "|cff4dff80" or (status.throttled and "|cffffd24d" or "|cff73b9ff")
            syncStatusText:SetText(color .. status.text .. "|r")
            if syncBtn then
                local busy = status.phase ~= "complete" or (tonumber(status.cooldown) or 0) > 0
                if status.phase == "complete" and (tonumber(status.cooldown) or 0) <= 0 then
                    syncBtn:SetText("Sync Now")
                elseif status.phase == "loadouts" then
                    syncBtn:SetText("Loading...")
                elseif (tonumber(status.cooldown) or 0) > 0 and status.phase == "complete" then
                    syncBtn:SetText("Wait " .. tostring(math.ceil(status.cooldown)) .. "s")
                else
                    syncBtn:SetText("Syncing...")
                end
                if busy then syncBtn:Disable() else syncBtn:Enable() end
            end
        elseif s.IsReceiving() then
            syncStatusText:SetText(string.format("|cff73b9ffChecking for updates... %ds|r", math.ceil(s.ReceiveTimeLeft())))
            if syncBtn then syncBtn:SetText("Syncing..."); syncBtn:Disable() end
        else
            local total = 0; for _ in pairs(Store()) do total = total + 1 end
            syncStatusText:SetText(string.format("|cff888888%d build(s) available. Sync Now checks the nearby mesh for updates.|r", total))
            if syncBtn then syncBtn:SetText("Sync Now"); syncBtn:Enable() end
        end
    end

    -- Update control labels
    local fs = FilterSettings()
    local ARROW = "  v"
    if classDropBtn then
        local cf = fs.classFilter
        if cf then
            classDropBtn:SetText("Class: "..(CLASS_LABEL[cf] or cf)..ARROW)
        else
            classDropBtn:SetText("Class: All"..ARROW)
        end
    end
    if sortToggle then
        if (fs.sortMode or "name") == "recent" then
            sortToggle:SetText("Sort: Newest")
        else
            sortToggle:SetText("Sort: A-Z")
        end
        sortToggle:Show()
    end

    -- Build browser contains builds only. DPS rankings are rendered in the
    -- dedicated Leaderboard window.
    local boardRows = nil
    local builds = SortedBuilds()
    ReleaseAllCards()
    ReleaseAllHeaders()

    local yOffset = 0
    local lastClass = "__none__"
    local showHeaders = false

    for index, b in ipairs(builds) do
        local bClass = (b.class or ""):upper()

        -- Class header when sorted by class and not filtered
        if showHeaders and bClass ~= lastClass then
            lastClass = bClass
            local h = GetHeader(scrollChild)
            h:SetWidth(460)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -yOffset)
            local c = CLASS_COLOR[bClass] or {0.8,0.8,0.8}
            h.label:SetTextColor(c[1],c[2],c[3])
            h.label:SetText(CLASS_LABEL[bClass] or bClass)
            activeHeaders[#activeHeaders+1] = h
            yOffset = yOffset + 26
        end

        -- Build card
        local card = GetCard(scrollChild)
        card:SetWidth(460)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -yOffset)
        card.buildId = b.id

        -- Selection highlight
        if b.id == selectedId then
            card.selectedHighlight:Show()
        else
            card.selectedHighlight:Hide()
        end

        -- Use a stable class-themed icon instead of a question mark.
        pcall(function() card.classIcon:SetTexture(CLASS_ICON[bClass] or "Interface\\Icons\\INV_Misc_QuestionMark") end)

        -- Title (class colored)
        local c = CLASS_COLOR[bClass] or {1,1,1}
        card.title:SetTextColor(c[1],c[2],c[3])
        card.title:SetText(b.title or "")
        card.author:SetText("by "..(b.author or "?"))

        -- Echo icons
        local echoes = b.echoes or {}
        local shown = math.min(#echoes, MAX_ROW_ICONS)
        for i, ic in ipairs(card.icons) do
            if i <= shown then
                ic:SetTexture(SpellIcon(echoes[i].spellId))
                pcall(function() ic:SetVertexColor(1,1,1) end)
                ic:Show()
            else
                ic:Hide()
            end
        end
        local extra = #echoes - shown
        card.moreText:SetText(extra > 0 and ("|cffff9040+"..extra.."|r") or "")
        if #echoes > 0 then
            card.echoCount:SetText(string.format("%d Echoes", #echoes))
        else
            card.echoCount:SetText("Loadout on demand")
        end

        if IsOwnBuild(b) then
            card.mineBadge:SetText("|cffffd200YOUR BUILD|r")
            card.mineBadge:Show()
        else
            card.mineBadge:Hide()
        end
        local D = Nexus.DpsCapture
        local verification = D and D.GetBuildVerification and D.GetBuildVerification(b.id)
        if verification then card.verifiedBadge:Show() else card.verifiedBadge:Hide() end
        card.addBtn:SetText("View")
        card.addBtn:SetSize(52,22)
        card.addBtn:Show()
        card.menuBtn:Hide()
        card.record = nil

        activeCards[#activeCards+1] = card
        yOffset = yOffset + CARD_HEIGHT + 4
    end

    -- Empty state
    if #builds == 0 then
        local total = 0; for _ in pairs(Store()) do total=total+1 end
        local msg
        msg = total == 0
            and "No builds yet.\n\nPost a build from your active Echo Wishlist, or press Sync Now to find builds from other players."
            or  "No builds match your current search or class filter."
        if frame._emptyState then
            frame._emptyState:SetText(msg)
            frame._emptyState:Show()
        end
        scrollChild:SetHeight(80)
        scrollBar:SetMinMaxValues(0,0)
        scrollBar:SetValue(0)
        RefreshDetailPanel(nil)
    else
        if frame._emptyState then frame._emptyState:Hide() end
        scrollChild:SetHeight(math.max(yOffset, 10))
        local visibleH = 490
        local overflow = math.max(0, yOffset - visibleH)
        scrollBar:SetMinMaxValues(0, overflow)
        local curVal = tonumber(scrollBar:GetValue()) or 0
        if curVal > overflow then scrollBar:SetValue(overflow) end
    end

    -- Detail panel
    RefreshDetailPanel(selectedId and Store()[selectedId])

    -- Search placeholder visibility
    if searchBox then
        local lbl = searchBox:GetParent() and searchBox:GetParent().searchLabel
        -- just handle via the text directly: show placeholder if empty
    end
end

------------------------------------------------------------------------
-- Post popup
------------------------------------------------------------------------

local postTitleBox, postDescBox
local postPreviewIcons = {}
local postSelectedWishlist, postSelectedClass
local postWishlistBtn, postClassBtn, postWishlistMenu, postClassMenu
local RefreshPostPopupPreview

local CLASS_PICK_ORDER = {
    "DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "PALADIN",
    "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

local function MakeDropdownMenu(parent, width)
    local menu = CreateFrame("Frame", nil, parent)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetWidth(width)
    menu:SetBackdrop({
        bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true,tileSize=16,edgeSize=12,
        insets={left=3,right=3,top=3,bottom=3},
    })
    menu:SetBackdropColor(0.03,0.03,0.03,0.98)
    menu:Hide()
    return menu
end

local function AddMenuButton(menu, text, onClick, index)
    local b = CreateFrame("Button", nil, menu)
    b:SetHeight(22); b:SetPoint("TOPLEFT",6,-6-(index-1)*22); b:SetPoint("TOPRIGHT",-6,0-(index-1)*22)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    local fs = b:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    fs:SetPoint("LEFT",6,0); fs:SetPoint("RIGHT",-6,0); fs:SetJustifyH("LEFT"); fs:SetText(text)
    b:SetScript("OnClick", function() menu:Hide(); onClick() end)
    return b
end

local function HidePostMenus()
    if postWishlistMenu then postWishlistMenu:Hide() end
    if postClassMenu then postClassMenu:Hide() end
end

local function BuildWishlistCandidates()
    local out = {}
    local candidates = Adapter and Adapter.GetWishlistCandidates and Adapter.GetWishlistCandidates()
    if type(candidates) == "table" then
        for _, c in ipairs(candidates) do
            local echoes = c.echoes
            -- Repair stale/partial candidate objects from the live slot mirror.
            if (type(echoes) ~= "table" or #echoes == 0) and c.slot and Adapter.Slots then
                local slots = Adapter.Slots()
                local live = slots and slots.bySlot and slots.bySlot[c.slot]
                if live and type(live.echoes) == "table" and #live.echoes > 0 then
                    echoes = live.echoes
                    c.echoes = echoes
                    c.count = #echoes
                    c.active = slots.activeSlot == c.slot
                end
            end
            if type(echoes) == "table" and #echoes > 0 then out[#out+1] = c end
        end
    end
    if #out == 0 then
        local wl = Adapter and Adapter.Wishlist and Adapter.Wishlist()
        local echoes = wl and (wl.echoes or wl.entries)
        if wl and type(echoes) == "table" and #echoes > 0 then
            out[1] = { slot=wl.slot, name=wl.name or "Current Wishlist", count=#echoes, echoes=echoes, active=true }
        end
    end
    return out
end

local function WishlistLabel(wl)
    local name = (wl and wl.name and wl.name ~= "") and wl.name or "Unnamed Wishlist"
    return string.format("%s (%d Echoes)", name, tonumber(wl and wl.count or #(wl and wl.echoes or {})))
end

local function RefreshPostWishlistMenu()
    if not postWishlistMenu then return end
    for _, child in ipairs({postWishlistMenu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
    local candidates = BuildWishlistCandidates()
    local h = math.min(300, 12 + #candidates * 24)
    postWishlistMenu:SetHeight(h)
    for i, c in ipairs(candidates) do
        AddMenuButton(postWishlistMenu, WishlistLabel(c), function()
            postSelectedWishlist = c
            postWishlistBtn:SetText("Wishlist: " .. ((c.name and c.name ~= "") and c.name or "Unnamed"))
            RefreshPostPopupPreview()
        end, i)
    end
    if #candidates == 0 then
        AddMenuButton(postWishlistMenu, "No Echo Wishlists found", function() end, 1)
        postWishlistMenu:SetHeight(40)
    end
end

local function RefreshPostClassMenu()
    if not postClassMenu then return end
    for _, child in ipairs({postClassMenu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
    postClassMenu:SetHeight(12 + #CLASS_PICK_ORDER * 24)
    for i, token in ipairs(CLASS_PICK_ORDER) do
        AddMenuButton(postClassMenu, CLASS_LABEL[token], function()
            postSelectedClass = token
            local cc = CLASS_COLOR[token] or {1,1,1}
            postClassBtn:SetText("Class: " .. CLASS_LABEL[token])
            postClassBtn:GetFontString():SetTextColor(cc[1],cc[2],cc[3])
            RefreshPostPopupPreview()
        end, i)
    end
end

local function EnsurePostPopup()
    if postPopup then return postPopup end
    local p = CreateFrame("Frame","NexusPostPopup",UIParent)
    p:SetSize(760, 560)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:EnableMouse(true); p:SetMovable(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart",function(self) self:StartMoving() end)
    p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    p:Hide()
    pcall(function() p:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}}) end)

    local titleBar = p:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    titleBar:SetPoint("TOP",0,-14); titleBar:SetText("Post Build")
    local close = CreateFrame("Button",nil,p,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-2,-2); close:SetScript("OnClick",function() HidePostMenus(); p:Hide() end)

    local tl = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); tl:SetPoint("TOPLEFT",16,-38); tl:SetText("Build Title:")
    postTitleBox = CreateFrame("EditBox",nil,p,"InputBoxTemplate"); postTitleBox:SetSize(330,20); postTitleBox:SetPoint("TOPLEFT",16,-54); postTitleBox:SetAutoFocus(false)

    local dl = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); dl:SetPoint("TOPLEFT",16,-88); dl:SetText("Description (what makes this build stand out):")
    local descBg = CreateFrame("Frame",nil,p); descBg:SetPoint("TOPLEFT",14,-104); descBg:SetSize(334,180)
    pcall(function() descBg:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=16,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}}); descBg:SetBackdropColor(0,0,0,0.5) end)
    postDescBox = CreateFrame("EditBox",nil,descBg); postDescBox:SetMultiLine(true); postDescBox:SetSize(318,170); postDescBox:SetPoint("TOPLEFT",6,-6); postDescBox:SetAutoFocus(false); postDescBox:SetFontObject("GameFontHighlightSmall"); postDescBox:EnableMouse(true); postDescBox:SetScript("OnMouseDown", function(self) self:SetFocus() end); postDescBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local chooseLabel = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); chooseLabel:SetPoint("TOPLEFT",16,-302); chooseLabel:SetText("Publish this exact wishlist as:")
    postWishlistBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate"); postWishlistBtn:SetSize(334,26); postWishlistBtn:SetPoint("TOPLEFT",16,-320); postWishlistBtn:SetText("Wishlist: Select a wishlist")
    postWishlistMenu = MakeDropdownMenu(p,334); postWishlistMenu:SetPoint("TOPLEFT",16,-348)
    postWishlistBtn:SetScript("OnClick",function() HidePostMenus(); RefreshPostWishlistMenu(); postWishlistMenu:Show() end)

    postClassBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate"); postClassBtn:SetSize(334,26); postClassBtn:SetPoint("TOPLEFT",16,-360); postClassBtn:SetText("Class: Select a class")
    postClassMenu = MakeDropdownMenu(p,334); postClassMenu:SetPoint("TOPLEFT",16,-388)
    postClassBtn:SetScript("OnClick",function() HidePostMenus(); RefreshPostClassMenu(); postClassMenu:Show() end)

    local previewLabel = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); previewLabel:SetPoint("TOPLEFT",380,-38); previewLabel:SetText("Exact Echo Wishlist Being Posted:")
    local previewWishlist = p:CreateFontString(nil,"OVERLAY","GameFontHighlight"); previewWishlist:SetPoint("TOPLEFT",380,-54); previewWishlist:SetSize(350,16); previewWishlist:SetJustifyH("LEFT"); p._previewWishlist=previewWishlist
    local previewClass = p:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); previewClass:SetPoint("TOPLEFT",380,-74); previewClass:SetSize(350,14); previewClass:SetJustifyH("LEFT"); p._previewClass=previewClass
    local previewSummary = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); previewSummary:SetPoint("TOPLEFT",380,-92); previewSummary:SetSize(350,14); previewSummary:SetJustifyH("LEFT"); p._previewSummary=previewSummary
    local previewClip=CreateFrame("Frame",nil,p); previewClip:SetPoint("TOPLEFT",374,-112); previewClip:SetSize(370,390); pcall(function() previewClip:SetClipsChildren(true) end); p._previewClip=previewClip
    local previewScroll=CreateFrame("ScrollFrame",nil,previewClip); previewScroll:SetAllPoints(previewClip); previewScroll:EnableMouseWheel(true); p._previewScroll=previewScroll
    local previewChild=CreateFrame("Frame",nil,previewScroll); previewChild:SetWidth(360); previewChild:SetHeight(1); previewScroll:SetScrollChild(previewChild); p._previewChild=previewChild
    p._previewRows={}
    for i=1,100 do
        local row=CreateFrame("Frame",nil,previewChild); row:SetSize(355,22)
        local icon=row:CreateTexture(nil,"ARTWORK"); icon:SetSize(20,20); icon:SetPoint("LEFT",0,0); row.icon=icon
        local text=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); text:SetPoint("LEFT",26,0); text:SetSize(325,20); text:SetJustifyH("LEFT"); row.text=text; row:Hide(); p._previewRows[i]=row
    end
    local noWishlistNote=p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); noWishlistNote:SetPoint("TOPLEFT",380,-112); noWishlistNote:SetSize(350,80); noWishlistNote:SetJustifyH("LEFT"); noWishlistNote:SetJustifyV("TOP"); p._noWishlistNote=noWishlistNote

    local postGoBtn=CreateFrame("Button",nil,p,"UIPanelButtonTemplate"); postGoBtn:SetSize(150,28); postGoBtn:SetPoint("BOTTOM",0,16); postGoBtn:SetText("Post Build"); p._postGoBtn=postGoBtn
    postGoBtn:SetScript("OnClick",function()
        if not postSelectedWishlist or not postSelectedClass then print("|cffff6060Nexus:|r Select both a wishlist and a class before posting."); return end
        local ok,err=M.PostCurrentWishlist(postTitleBox:GetText(),postDescBox:GetText(),postSelectedWishlist,postSelectedClass)
        if ok then print("|cff4dff80Nexus:|r build posted!"); p:Hide(); M.Refresh() else print("|cffff6060Nexus:|r "..tostring(err)) end
    end)
    postPopup=p; return p
end

local function EchoDisplayName(spellId)
    local cat=Adapter and Adapter.Catalog and Adapter.Catalog(); local row=cat and cat.rows and cat.rows[tonumber(spellId)]
    if row and row.name and row.name ~= "" then return row.name end
    local name=GetSpellInfo and GetSpellInfo(spellId); return name or ("Echo "..tostring(spellId))
end

RefreshPostPopupPreview = function()
    if not postPopup or not postPopup:IsShown() then return end
    local wl=postSelectedWishlist
    local echoes = WishlistEchoes(wl)
    if not wl or not echoes or #echoes==0 then
        for _,row in ipairs(postPopup._previewRows or {}) do row:Hide() end
        postPopup._noWishlistNote:SetText("|cffff6060No wishlist selected.|r\n\nChoose the exact Echo Wishlist you want to publish.")
        postPopup._noWishlistNote:Show(); postPopup._previewWishlist:SetText(""); postPopup._previewSummary:SetText(""); postPopup._previewClass:SetText(""); postPopup._postGoBtn:Disable(); return
    end
    postPopup._noWishlistNote:Hide(); postPopup._postGoBtn:Enable()
    local wishlistName=(wl.name and wl.name~="") and wl.name or "Unnamed Echo Wishlist"
    local classToken=postSelectedClass or InferBuildClass(echoes) or ""
    postPopup._previewWishlist:SetText("|cffffd200"..wishlistName.."|r")
    postPopup._previewSummary:SetText(string.format("|cff888888%d current echoes in this wishlist|r",#echoes))
    local cc=CLASS_COLOR[(classToken or ""):upper()] or {1,1,1}; postPopup._previewClass:SetTextColor(cc[1],cc[2],cc[3]); postPopup._previewClass:SetText("Posting as: "..(CLASS_LABEL[(classToken or ""):upper()] or classToken or "Select a class"))
    local child=postPopup._previewChild
    for i,row in ipairs(postPopup._previewRows or {}) do
        local e=echoes[i]
        if e then row:ClearAllPoints(); row:SetPoint("TOPLEFT",child,"TOPLEFT",0,-(i-1)*22); row.icon:SetTexture(SpellIcon(e.spellId)); local stacks=tonumber(e.stacks) or 1; local suffix=stacks>1 and ("  x"..stacks) or ""; row.text:SetText(string.format("%02d. %s%s",i,EchoDisplayName(e.spellId),suffix)); row:Show() else row:Hide() end
    end
    child:SetHeight(math.max(1,#echoes*22)); pcall(function() postPopup._previewScroll:SetVerticalScroll(0) end)
end

function M.ShowPostBuild()
    EnsurePostPopup()
    if postPopup:IsShown() then HidePostMenus(); postPopup:Hide(); return end
    local candidates=BuildWishlistCandidates(); postSelectedWishlist=candidates[1]
    local wl=postSelectedWishlist
    -- Auto-detect class from echo catalog, then fall back to player's own class
    postSelectedClass = InferBuildClass(WishlistEchoes(wl) or {}) or ""
    if postSelectedClass == "" and UnitClass then
        local _, classToken = UnitClass("player")
        postSelectedClass = (classToken and classToken ~= "UNKNOWN") and tostring(classToken) or ""
    end
    postTitleBox:SetText((wl and wl.name and wl.name~="") and wl.name or "")
    postDescBox:SetText("")
    postWishlistBtn:SetText("Wishlist: "..((wl and wl.name and wl.name~="") and wl.name or "Select a wishlist"))
    if postSelectedClass ~= "" then
        local cc = CLASS_COLOR[postSelectedClass:upper()] or {1,1,1}
        postClassBtn:SetText("Class: "..(CLASS_LABEL[postSelectedClass:upper()] or postSelectedClass))
        pcall(function() postClassBtn:GetFontString():SetTextColor(cc[1],cc[2],cc[3]) end)
    else
        postClassBtn:SetText("Class: Select a class")
    end
    postPopup:ClearAllPoints(); postPopup:SetPoint("CENTER"); postPopup:Show(); RefreshPostPopupPreview()
end

function M.TogglePostPopup(anchor) M.ShowPostBuild() end

------------------------------------------------------------------------
-- Edit popup
------------------------------------------------------------------------

local editTitleBox, editDescBox, editLinkBox, editEchoBtn, editLockText

local function EnsureEditPopup()
    if editPopup then return editPopup end
    local p = CreateFrame("Frame","NexusEditPopup",UIParent)
    p:SetSize(390,338); p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:EnableMouse(true); p:Hide()

    local title = p:CreateFontString(nil,"OVERLAY","GameFontNormal")
    title:SetPoint("TOP",0,-12); title:SetText("Edit Build")

    local close = CreateFrame("Button",nil,p,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-2,-2); close:SetScript("OnClick",function() p:Hide() end)

    local tl = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    tl:SetPoint("TOPLEFT",16,-36); tl:SetText("Title:")
    editTitleBox = CreateFrame("EditBox",nil,p,"InputBoxTemplate")
    editTitleBox:SetSize(310,20); editTitleBox:SetPoint("TOPLEFT",20,-52); editTitleBox:SetAutoFocus(false)

    local dl = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    dl:SetPoint("TOPLEFT",16,-80); dl:SetText("Description:")
    local descBg = CreateFrame("Frame",nil,p)
    descBg:SetPoint("TOPLEFT",18,-96); descBg:SetSize(324,86)
    pcall(function()
        descBg:SetBackdrop({ bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=16,edgeSize=12, insets={left=3,right=3,top=3,bottom=3} })
        descBg:SetBackdropColor(0,0,0,0.5)
    end)
    editDescBox = CreateFrame("EditBox",nil,descBg)
    editDescBox:SetMultiLine(true); editDescBox:SetSize(310,76)
    editDescBox:SetPoint("TOPLEFT",6,-6); editDescBox:SetAutoFocus(false)
    editDescBox:SetFontObject("GameFontHighlightSmall")

    local ll = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    ll:SetPoint("TOPLEFT",16,-190); ll:SetText("Discord Build Post or Channel:")
    editLinkBox = CreateFrame("EditBox",nil,p,"InputBoxTemplate")
    editLinkBox:SetSize(278,20)
    editLinkBox:SetPoint("TOPLEFT",20,-206)
    editLinkBox:SetAutoFocus(false)
    editLinkBox:SetMaxLetters(200)
    editLinkBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editLinkBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    editLinkBox:SetScript("OnEditFocusGained", function(self)
        pcall(function() self:HighlightText() end)
    end)

    local clearLinkBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    clearLinkBtn:SetSize(60,20)
    clearLinkBtn:SetPoint("LEFT",editLinkBox,"RIGHT",6,0)
    clearLinkBtn:SetText("Clear")
    clearLinkBtn:SetScript("OnClick", function()
        editLinkBox:SetText("")
        editLinkBox:SetFocus()
    end)

    editLockText = p:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    editLockText:SetPoint("TOPLEFT",18,-238)
    editLockText:SetSize(354,30)
    editLockText:SetJustifyH("LEFT")
    editLockText:SetJustifyV("TOP")

    editEchoBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    editEchoBtn:SetSize(210,22)
    editEchoBtn:SetPoint("BOTTOMLEFT",18,16)
    editEchoBtn:SetText("Use Active Wishlist Echoes")
    editEchoBtn:SetScript("OnClick",function()
        if not p._editingId then return end
        local ok, result = M.UpdateFromWishlist(p._editingId)
        if ok then
            print(string.format("|cff4dff80Nexus:|r Echo list replaced with the active wishlist (%d Echoes).", result))
            p:Hide(); M.Refresh()
        else
            print("|cffff6060Nexus:|r " .. tostring(result))
        end
    end)

    local saveBtn = CreateFrame("Button",nil,p,"UIPanelButtonTemplate")
    saveBtn:SetSize(118,22); saveBtn:SetPoint("BOTTOMRIGHT",-18,16); saveBtn:SetText("Save Details")
    saveBtn:SetScript("OnClick",function()
        if not p._editingId then return end
        local ok, err = M.EditBuild(p._editingId, editTitleBox:GetText(), editDescBox:GetText(), editLinkBox:GetText())
        if ok then print("|cff4dff80Nexus:|r build updated and re-shared."); p:Hide(); M.Refresh()
        else print("|cffff6060Nexus:|r "..tostring(err)) end
    end)
    pcall(function()
        p:SetBackdrop({ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=32,edgeSize=32, insets={left=11,right=12,top=12,bottom=11} })
    end)
    editPopup = p; return p
end

function M.ToggleEditPopup(id)
    EnsureEditPopup()
    if editPopup:IsShown() then editPopup:Hide(); return end
    local b = Store()[id]
    if not b or not IsOwnBuild(b) then return end
    editPopup._editingId = id
    local locked = HasLeaderboardRecord(b)
    if locked then
        editEchoBtn:Disable()
        editLockText:SetText("|cffffd200Echo list locked by leaderboard record.|r Post a new build to use a different loadout.")
    else
        editEchoBtn:Enable()
        editLockText:SetText("Change title/description, or replace the Echo list with your current active wishlist.")
    end
    editTitleBox:SetText(b.title or "")
    editDescBox:SetText(b.description or "")
    editLinkBox:SetText(b.link or "")
    editPopup:ClearAllPoints(); editPopup:SetPoint("CENTER")
    editPopup:Show()
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- Community data is intentionally empty on first install.
-- The admin can publish real builds from the Post Build flow.

function M.Init(adapter, model)
    Adapter, Model = adapter, model
    RemoveLegacyBuilds()  -- once at startup, not on every Store() access
end

function M.Select(id)
    selectedId = id
    M.Refresh()
end

function M.SetViewMode(mode)
    if mode == "dummy" or mode == "lk" then
        if frame then frame:Hide() end
        if Nexus.Leaderboard then Nexus.Leaderboard.Show(mode) end
        return
    end
    M.Refresh()
end

function M.GetViewMode() return "builds" end

function M.Show()
    EnsureFrame()
    if Nexus.Leaderboard then Nexus.Leaderboard.Hide() end
    frame:Show()
    M.Refresh()
end

function M.ShowBuild(id)
    selectedId = id
    M.Show()
    if id and Store()[id] and (not Store()[id].echoes or #Store()[id].echoes == 0)
        and Nexus.Sync and Nexus.Sync.RequestLoadout then
        Nexus.Sync.RequestLoadout(id)
    end
    M.Refresh()
end

function M.Hide() if frame then frame:Hide() end end
function M.IsShown() return frame and frame:IsShown() or false end

function M.Toggle()
    EnsureFrame()
    if frame:IsShown() then frame:Hide()
    else M.Show() end
end
