-- Nexus: ui/WishlistOverlay.lua
-- The always-on-screen wishlist list some players like to keep visible
-- while leveling -- modeled closely on the EchoWishlist addon's own
-- overlay: one line per echo, bright/quality-colored when you own it,
-- dimmed gray when you don't, locked (click-through) by default so it
-- never blocks clicks on the world underneath it, with a lock toggle,
-- drag-to-move when unlocked, and a scale slider.
--
-- Laid out in COLUMNS side-by-side columns rather than one long list --
-- a 70+ echo wishlist in a single column at the old row height would run
-- past 1000px tall on most screens. Columns + a scale slider keep the
-- whole thing on-screen regardless of wishlist size or display size.

Nexus = Nexus or {}
local M = {}
Nexus.WishlistOverlay = M

local MAX_LINES = 90
local COLUMNS = 3
local ROWS_PER_COLUMN = math.ceil(MAX_LINES / COLUMNS)
local ROW_HEIGHT = 15
local COLUMN_WIDTH = 210
local UPDATE_INTERVAL = 1.0

local QUALITY_COLORS = {
    [0] = { 1, 1, 1 },
    [1] = { 0.12, 1, 0.12 },
    [2] = { 0.2, 0.6, 1 },
    [3] = { 0.72, 0.36, 0.98 },
    [4] = { 1, 0.65, 0 },
}

local frame, lines, lockBtn, controlsFrame, hideBtn
local Adapter, Model
local ticker = 0

local function IsLocked()
    return NexusDB.overlayLocked ~= false
end

local function ApplyLockState()
    if not frame then return end
    if IsLocked() then
        -- Keep the large list click-through, but leave the tiny control
        -- strip interactive so the overlay can never become stuck.
        frame:EnableMouse(false)
        frame:RegisterForDrag()
        if lockBtn then lockBtn:SetText("Unlock") end
    else
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        if lockBtn then lockBtn:SetText("Lock") end
    end
    if controlsFrame then
        controlsFrame:EnableMouse(true)
        if frame:IsShown() then controlsFrame:Show() else controlsFrame:Hide() end
    end
end

local function ApplyPosition()
    if not frame then return end
    frame:ClearAllPoints()
    local pos = NexusDB.overlayPosition
    if type(pos) == "table" and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("LEFT", UIParent, "LEFT", 18, 0)
    end
end

local function SavePosition()
    if not frame then return end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    NexusDB.overlayPosition = {
        point = point or "LEFT", relativePoint = relativePoint or point or "LEFT",
        x = math.floor((x or 0) + 0.5), y = math.floor((y or 0) + 0.5),
    }
end

local function ApplyScale()
    if not frame then return end
    local scale = tonumber(NexusDB.overlayScale) or 1.0
    pcall(function() frame:SetScale(scale) end)
    pcall(function() if controlsFrame then controlsFrame:SetScale(scale) end end)
end

local function EnsureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "NexusOverlay", UIParent)
    frame:SetSize(COLUMNS * COLUMN_WIDTH + 20, ROWS_PER_COLUMN * ROW_HEIGHT + 30)
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(60)
    frame:SetMovable(true)
    frame:SetScript("OnDragStart", function(self)
        if not IsLocked() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnUpdate", function(_, elapsed)
        ticker = ticker + (elapsed or 0)
        if ticker >= UPDATE_INTERVAL then
            ticker = 0
            M.Refresh()
        end
    end)
    frame:Hide()

    lines = {}
    for i = 1, MAX_LINES do
        local col = math.floor((i - 1) / ROWS_PER_COLUMN)
        local row = (i - 1) % ROWS_PER_COLUMN
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 20 + col * COLUMN_WIDTH, -26 - (row * ROW_HEIGHT))
        fs:SetSize(COLUMN_WIDTH - 10, ROW_HEIGHT)
        fs:SetJustifyH("LEFT")
        pcall(function() fs:SetShadowColor(0, 0, 0, 1); fs:SetShadowOffset(1, -1) end)
        fs:Hide()
        lines[i] = fs
    end

    -- The control strip is a sibling of the click-through list. Disabling
    -- mouse input on the overlay body must never disable these controls.
    controlsFrame = CreateFrame("Frame", "NexusOverlayControls", UIParent)
    controlsFrame:SetSize(80, 22)
    controlsFrame:SetFrameStrata("DIALOG")
    controlsFrame:SetFrameLevel(75)
    controlsFrame:EnableMouse(true)
    controlsFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 4)
    controlsFrame:Hide()

    lockBtn = CreateFrame("Button", nil, controlsFrame, "UIPanelButtonTemplate")
    lockBtn:SetSize(50, 18)
    lockBtn:SetPoint("LEFT", 0, 0)
    lockBtn:SetScript("OnClick", function()
        NexusDB.overlayLocked = not IsLocked()
        ApplyLockState()
    end)

    -- Hide button: lets the player collapse the overlay without going
    -- into the editor or typing /nexus overlay.
    hideBtn = CreateFrame("Button", nil, controlsFrame, "UIPanelButtonTemplate")
    hideBtn:SetSize(22, 18)
    hideBtn:SetPoint("LEFT", lockBtn, "RIGHT", 4, 0)
    hideBtn:SetText("-")
    hideBtn:SetScript("OnClick", function() M.Hide() end)
    hideBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Hide the wishlist overlay", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("/nexus overlay to show it again", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    hideBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ApplyPosition()
    ApplyLockState()
    ApplyScale()
    return frame
end

function M.Refresh()
    if not frame or not frame:IsShown() then return end
    local wl = Adapter and Adapter.Wishlist and Adapter.Wishlist()
    local owned = Adapter and Adapter.Owned and Adapter.Owned()
    local catalog = Adapter and Adapter.Catalog and Adapter.Catalog()
    local byFamily = (owned and owned.byFamily) or {}
    if not wl then
        lines[1]:SetText("|cff888888No wishlist set|r")
        lines[1]:Show()
        for i = 2, MAX_LINES do lines[i]:Hide() end
        return
    end

    local list = {}
    for _, e in ipairs(wl.entries or {}) do
        local row = catalog and catalog.rows and catalog.rows[e.spellId]
        list[#list + 1] = { spellId = e.spellId, quality = e.quality,
            stacks = e.stacks, family = e.family,
            name = (row and row.name) or ("spell " .. tostring(e.spellId)) }
    end
    table.sort(list, function(a, b)
        local ac = tonumber(a.quality) or 0
        local bc = tonumber(b.quality) or 0
        if ac ~= bc then return ac > bc end
        return tostring(a.name) < tostring(b.name)
    end)

    for i = 1, MAX_LINES do
        local e = list[i]
        local fs = lines[i]
        if e then
            local have = tonumber(byFamily[e.family]) or 0
            local want = tonumber(e.stacks) or 1
            local nm = e.name or ("spell " .. tostring(e.spellId))
            local suffix = want > 1 and string.format(" (%d/%d)", math.min(have, want), want) or ""
            if have >= want then
                local c = QUALITY_COLORS[e.quality] or QUALITY_COLORS[0]
                fs:SetTextColor(c[1], c[2], c[3])
                fs:SetText("|cff40ff80[X]|r " .. nm .. suffix)
            elseif have > 0 then
                local c = QUALITY_COLORS[e.quality] or QUALITY_COLORS[0]
                fs:SetTextColor(c[1] * 0.7, c[2] * 0.7, c[3] * 0.7)
                fs:SetText("[~] " .. nm .. suffix)
            else
                fs:SetTextColor(0.38, 0.38, 0.38)
                fs:SetText("[ ] " .. nm .. suffix)
            end
            fs:Show()
        else
            fs:Hide()
        end
    end
end

function M.Init(adapter, model)
    Adapter, Model = adapter, model
end

function M.Show()
    EnsureFrame()
    frame:Show()
    if controlsFrame then controlsFrame:Show() end
    NexusDB.overlayShown = true
    ApplyLockState()
    M.Refresh()
end

function M.Hide()
    if frame then frame:Hide() end
    if controlsFrame then controlsFrame:Hide() end
    NexusDB.overlayShown = false
end

function M.Toggle()
    EnsureFrame()
    if frame:IsShown() then M.Hide() else M.Show() end
end

function M.IsShown()
    return frame ~= nil and frame:IsShown()
end

-- Public lock accessors, so the Wishlist Editor's own Lock/Unlock button
-- can drive and reflect the same state without duplicating logic.
function M.IsLocked()
    return IsLocked()
end

function M.ToggleLock()
    NexusDB.overlayLocked = not IsLocked()
    ApplyLockState()
end

-- Scale control lives in the editor's settings popup, not on the
-- overlay itself (moved there per request 2026-07-24) -- these are the
-- read/write hooks it drives.
function M.ResetPosition()
    NexusDB.overlayPosition = nil
    ApplyPosition()
    if frame then
        frame:Show()
        if controlsFrame then controlsFrame:Show() end
        NexusDB.overlayShown = true
        ApplyLockState()
        M.Refresh()
    end
end

function M.GetScale()
    return tonumber(NexusDB.overlayScale) or 1.0
end

function M.SetScale(value)
    value = tonumber(value) or 1.0
    if value < 0.5 then value = 0.5 end
    if value > 1.6 then value = 1.6 end
    NexusDB.overlayScale = value
    ApplyScale()
end
