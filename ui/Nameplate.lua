-- Nexus: ui/Nameplate.lua
-- Adds a non-intrusive Nexus badge and leaderboard rank to the unit
-- tooltip (GameTooltip) when you mouse over another player.
--
-- Based on the confirmed-working EbonBuilds pattern for 3.3.5:
--   • GameTooltip:HookScript("OnTooltipSetUnit", fn) — fn receives only
--     the tooltip frame as self, NOT the unit token
--   • tooltip:GetUnit() returns name, unitToken — that's how we get the unit
--   • tooltip:AddLine(...) + tooltip:Show() to make lines appear
--
-- What triggers this: any mouseover that causes GameTooltip to call
-- SetUnit — nameplates, unit frames, raid frames, the target frame, etc.
--
-- Shows for:
--   • Players recently discovered through the Nexus mesh protocol
--   • Players with a DPS record in the local Nexus leaderboard
--   • Players who authored a build in the local community library
-- Shows nothing for NPCs or unknown players. Your own tooltip is always
-- recognized because the addon is running locally.

Nexus = Nexus or {}
local M = {}
Nexus.Nameplate = M

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function NormalizeName(name)
    name = tostring(name or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    return (name:match("^([^-]+)") or name):lower()
end

local function IsCommunityAuthor(name)
    if not name or name == "" then return false end
    local builds = NexusDB and NexusDB.communityBuilds
    if not builds then return false end
    local lname = NormalizeName(name)
    for _, build in pairs(builds) do
        if NormalizeName(build.author) == lname then return true end
    end
    return false
end

local function ResolveTooltipUnit(tooltip)
    local shownName, unit
    if tooltip and tooltip.GetUnit then
        local ok, a, b = pcall(tooltip.GetUnit, tooltip)
        if ok then shownName, unit = a, b end
    end
    if unit and UnitExists and not UnitExists(unit) then unit = nil end
    if not unit and UnitExists and UnitExists("mouseover") and UnitIsPlayer and UnitIsPlayer("mouseover") then
        unit = "mouseover"
    end
    if not unit and UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target") then
        local targetName = UnitName and UnitName("target")
        if not shownName or NormalizeName(targetName) == NormalizeName(shownName) then unit = "target" end
    end
    return shownName, unit
end

------------------------------------------------------------------------
-- Core tooltip augmentation
-- Called by the HookScript handler with `tooltip` as self.
-- We use tooltip:GetUnit() to get the unit — do NOT rely on any
-- argument being passed as the unit (3.3.5 HookScript doesn't do that).
------------------------------------------------------------------------

local function AugmentUnitTooltip(tooltip)
    if not tooltip then return end
    local shownName, unit = ResolveTooltipUnit(tooltip)
    if not unit then return end
    if not (UnitIsPlayer and UnitIsPlayer(unit)) then return end

    local name = UnitName and UnitName(unit) or shownName
    if not name or name == "" then return end

    local normalizedName = NormalizeName(name)
    local me = UnitName and UnitName("player") or ""
    local isSelf = normalizedName == NormalizeName(me)
    if tooltip.__nexusAugmentedFor == normalizedName then return end

    local D = Nexus.DpsCapture
    local S = Nexus.Sync
    local info = D and D.GetPlayerInfo and D.GetPlayerInfo(name) or nil
    local isAuthor = IsCommunityAuthor(name)
    local isPeer = S and S.IsKnownPeer and S.IsKnownPeer(name) or false

    -- The local character is unconditionally a Nexus user. This also makes
    -- self-mouseover a reliable diagnostic even before mesh presence exists.
    if not info and not isAuthor and not isPeer and not isSelf then return end

    tooltip.__nexusAugmentedFor = normalizedName
    tooltip:AddLine("|cff7fd5ffNexus user|r")
    if info and tonumber(info.rank) then
        tooltip:AddLine("|cffffd200#" .. tostring(math.floor(tonumber(info.rank))) .. "|r")
    end

    tooltip:Show()
end

local function ClearTooltipFlag(tooltip)
    if tooltip then tooltip.__nexusAugmentedFor = nil end
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

local hooked = false

function M.Init()
    if hooked then return end
    if not GameTooltip then return end

    local installed = false
    if GameTooltip.HookScript then
        local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipCleared", ClearTooltipFlag)
        local ok2 = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(self)
            pcall(AugmentUnitTooltip, self)
        end)
        installed = ok2 or installed
    end

    -- Some 3.3.5/private-server tooltip implementations do not fire
    -- OnTooltipSetUnit reliably. A post-hook on SetUnit covers those clients.
    if hooksecurefunc and GameTooltip.SetUnit then
        local ok = pcall(hooksecurefunc, GameTooltip, "SetUnit", function(self)
            pcall(AugmentUnitTooltip, self)
        end)
        installed = ok or installed
    elseif not installed and GameTooltip.SetUnit then
        local orig = GameTooltip.SetUnit
        GameTooltip.SetUnit = function(self, unit, ...)
            ClearTooltipFlag(self)
            local results = { pcall(orig, self, unit, ...) }
            pcall(AugmentUnitTooltip, self)
            if not results[1] then return nil end
            return unpack(results, 2)
        end
        installed = true
    end

    hooked = installed
end

-- Expose the core function for testing without GameTooltip
M._AugmentUnitTooltip = AugmentUnitTooltip
