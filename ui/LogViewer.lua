-- Nexus: ui/LogViewer.lua
-- The data-handoff window: /nexus log opens a tabbed, copy-friendly text
-- view of everything the addon knows -- recorded boards, manual-vs-
-- proposal mismatches, the parsed wishlist, and live state. Dumb view:
-- Main supplies a provider function(tabKey) -> text; this file only
-- renders. Select All + Ctrl-C is the intended workflow.

Nexus = Nexus or {}
local M = {}
Nexus.LogViewer = M

local TABS = {
    { key = "boards",   label = "Boards" },
    { key = "mismatch", label = "Mismatch" },
    { key = "wishlist", label = "Wishlist" },
    { key = "state",    label = "State" },
    { key = "sync",     label = "Sync" },
    { key = "dps",      label = "DPS" },
    { key = "sniffer",  label = "Sniffer" },
}

local frame, editBox, scroll, tabButtons, statusFS
local provider
local activeTab = "boards"

local function Repaint()
    if not (frame and editBox) then return end
    local text = "no data provider"
    if type(provider) == "function" then
        local ok, result = pcall(provider, activeTab)
        text = ok and tostring(result or "") or ("provider error: " .. tostring(result))
    end
    editBox:SetText(text)
    editBox:SetCursorPosition(0)
    if statusFS then
        statusFS:SetText(string.format("%d chars -- Select All, Ctrl-C, paste it over", #text))
    end
    for _, b in ipairs(tabButtons or {}) do
        if b.tabKey == activeTab then b:LockHighlight() else b:UnlockHighlight() end
    end
end

local function EnsureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "NexusLogViewer", UIParent)
    frame:SetSize(700, 440)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.92)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10)
    title:SetText("Nexus -- data log")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    tabButtons = {}
    local prev
    for i, tab in ipairs(TABS) do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(76, 22)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
        end
        b:SetText(tab.label)
        b.tabKey = tab.key
        b:SetScript("OnClick", function(self)
            activeTab = self.tabKey
            Repaint()
        end)
        tabButtons[i] = b
        prev = b
    end

    local selectAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    selectAll:SetSize(84, 22)
    selectAll:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -30)
    selectAll:SetText("Select All")
    selectAll:SetScript("OnClick", function()
        if editBox then
            editBox:SetFocus()
            editBox:HighlightText()
        end
    end)

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(70, 22)
    refresh:SetPoint("RIGHT", selectAll, "LEFT", -4, 0)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", Repaint)

    scroll = CreateFrame("ScrollFrame", "NexusLogScroll", frame,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -58)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 30)

    editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(646)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- read-only in spirit: typing is harmless (nothing reads it back),
    -- but keep the text restorable via Refresh
    scroll:SetScrollChild(editBox)

    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 10)
    statusFS:SetJustifyH("LEFT")

    frame:Hide()
    return frame
end

function M.Init(providerFn)
    if providerFn ~= nil then provider = providerFn end
end

function M.Show(tabKey)
    EnsureFrame()
    if tabKey then activeTab = tabKey end
    frame:Show()
    Repaint()
end

function M.Toggle(tabKey)
    EnsureFrame()
    if frame:IsShown() then frame:Hide() else M.Show(tabKey) end
end
