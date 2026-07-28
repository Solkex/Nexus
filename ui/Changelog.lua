-- Nexus: ui/Changelog.lua
-- One-time, dismissible release note for meaningful user-facing changes.
Nexus = Nexus or {}
local M = {}
Nexus.Changelog = M

local VERSION = "1.18"
local frame
local shownThisSession = false

local function Create()
    if frame then return frame end
    frame = CreateFrame("Frame", "NexusChangelogPopup", UIParent)
    frame:SetSize(410, 190)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 90)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Nexus 1.18")

    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", 28, -52)
    body:SetPoint("RIGHT", -28, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetText(
        "|cff4dff80Fixed:|r A guaranteed Echo only counts when its exact quality meets the wishlist target.\n" ..
        "|cffffd200Improved:|r Two-Snapshot relay, final-board search, exact quality-tier quotas, and saved wishlist associations now work together.\n" ..
        "|cffffd200Safety:|r Saves and relay activation verify exact Echo variants; disabled or refused search actions always fall through safely."
    )

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(92, 24)
    close:SetPoint("BOTTOM", 0, 14)
    close:SetText("Got it")
    close:SetScript("OnClick", function()
        NexusDB = NexusDB or {}
        NexusDB.lastChangelogSeen = VERSION
        frame:Hide()
    end)
    frame:Hide()
    return frame
end

function M.ShowIfNeeded()
    NexusDB = NexusDB or {}
    if not NexusDB.hasSeenQuickStart then
        NexusDB.lastChangelogSeen = VERSION
        return
    end
    if shownThisSession or NexusDB.lastChangelogSeen == VERSION then return end
    -- Mark it seen when displayed, not only when the button is clicked. This
    -- prevents reloads, disconnects, or another popup covering it from causing
    -- the same release note to appear on every login.
    shownThisSession = true
    NexusDB.lastChangelogSeen = VERSION
    Create():Show()
end

local ev = CreateFrame("Frame")
local elapsed, armed = 0, false
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function() armed = true; elapsed = 0 end)
ev:SetScript("OnUpdate", function(_, dt)
    if not armed then return end
    elapsed = elapsed + (tonumber(dt) or 0)
    if elapsed >= 2 then
        armed = false
        pcall(M.ShowIfNeeded)
    end
end)
