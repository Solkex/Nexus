-- Nexus: ui/JournalTab.lua
-- An "Optimizer" tab inside ProjectEbonhold's Echo Journal, rendering
-- plain text sections supplied by an injected dataProvider callback.
-- Structures relied on (captured live against this exact client):
--   frame  ProjectEbonholdEchoJournal
--   tabs   ProjectEbonholdEchoJournalTab1..N (CharacterFrameTabButton
--          textures), parent = the journal frame
--   scroll ProjectEbonholdEchoJournalScroll = content area
-- The journal UI is built LAZILY on first open: a login-time install
-- succeeds only after /reload with the journal already built, so
-- "frames not present" is the NORMAL, SILENT state until the hooked
-- EchoJournal.Show/Toggle fires and the install retries. Our tab index
-- is existing-tab-count + 1 (a leftover EchoOptimizer Tab4 shifts us
-- to 5 instead of colliding).
-- SOFT-FAIL CONTRACT: TryInstall pcall-wraps everything and returns
-- false on any failure -- no tab, no error, retried on next Show.
-- All DATA arrives through the provider; this file touches journal
-- FRAMES only (documented presentation-layer exception), never
-- PerkService.

Nexus = Nexus or {}
local M = {}
Nexus.JournalTab = M

local installed = false
local hooked = false
local provider                -- dataProvider() -> { sections={ {title,lines={}} }, version }
local ourTab, panel, scroll, child
local theirTabCount = 0
local linePool, linesUsed = {}, 0

local ASSET = "Interface\\AddOns\\ProjectEbonhold\\assets\\"
local NOTE1 = "Targets the ACTIVE loadout — set via \"Play with\" in Loadouts."
local NOTE2 = "|cff8a8a8a(The journal's \"Echo Wishlist\" designed slots are a different store.)|r"

------------------------------------------------------------------------
-- Text lines
------------------------------------------------------------------------

local function AcquireLine()
    linesUsed = linesUsed + 1
    local fs = linePool[linesUsed]
    if not fs then
        fs = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        linePool[linesUsed] = fs
    end
    fs:Show()
    return fs
end

local function DoRefresh()
    local data
    if type(provider) == "function" then
        local okP, res = pcall(provider)
        if okP and type(res) == "table" then data = res end
    end

    linesUsed = 0
    local width = math.floor((scroll and scroll:GetWidth()) or 0)
    if width < 100 then width = 292 end
    width = width - 12
    local cy = -6

    local function AddLine(text, font, indent)
        indent = indent or 0
        local fs = AcquireLine()
        fs:SetFontObject(font or "GameFontHighlightSmall")
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", child, "TOPLEFT", 6 + indent, cy)
        fs:SetWidth(width - indent)
        -- Height 0 + fixed width = word-wrap; GetStringHeight is then
        -- the wrapped height.
        fs:SetHeight(0)
        fs:SetText(text or "")
        local h = fs:GetStringHeight()
        if not h or h < 12 then h = 12 end
        cy = cy - h - 2
    end

    AddLine(NOTE1, "GameFontNormalSmall")
    AddLine(NOTE2)
    cy = cy - 6

    local sections = data and data.sections
    if type(sections) ~= "table" or #sections == 0 then
        AddLine("|cff8a8a8ano data yet|r")
    else
        for i = 1, #sections do
            local sec = sections[i]
            if type(sec) == "table" then
                AddLine(tostring(sec.title or ""), "GameFontNormalSmall")
                local lines = sec.lines
                if type(lines) == "table" then
                    for j = 1, #lines do
                        AddLine(tostring(lines[j] or ""), nil, 8)
                    end
                end
                cy = cy - 4
            end
        end
    end

    if data and data.version ~= nil then
        cy = cy - 2
        AddLine("|cff8a8a8a" .. tostring(data.version) .. "|r")
    end

    for i = linesUsed + 1, #linePool do linePool[i]:Hide() end
    child:SetWidth(width + 12)
    child:SetHeight(-cy + 8)
end

function M.Refresh()
    if not (installed and panel and panel:IsShown()) then return end
    pcall(DoRefresh)
end

------------------------------------------------------------------------
-- Tab select / deselect
------------------------------------------------------------------------

local function SelectOurTab()
    if PanelTemplates_SelectTab then pcall(PanelTemplates_SelectTab, ourTab) end
    for i = 1, theirTabCount do
        local t = _G["ProjectEbonholdEchoJournalTab" .. i]
        if t and PanelTemplates_DeselectTab then
            pcall(PanelTemplates_DeselectTab, t)
        end
    end
    panel:Show()
    M.Refresh()
end

local function DeselectOurTab()
    if ourTab and PanelTemplates_DeselectTab then
        pcall(PanelTemplates_DeselectTab, ourTab)
    end
    if panel then panel:Hide() end
    -- Their tab-switcher may Hide() children it does not recognize:
    -- the tab BUTTON must survive every switch.
    if ourTab then ourTab:Show() end
end

------------------------------------------------------------------------
-- Install
------------------------------------------------------------------------

local function Install()
    local journal = _G["ProjectEbonholdEchoJournal"]
    local jScroll = _G["ProjectEbonholdEchoJournalScroll"]
    local tab1 = _G["ProjectEbonholdEchoJournalTab1"]
    if not (journal and jScroll and tab1) then
        error("journal frames not present")
    end

    local n = 0
    while _G["ProjectEbonholdEchoJournalTab" .. (n + 1)] do
        n = n + 1
    end
    theirTabCount = n
    local lastTab = _G["ProjectEbonholdEchoJournalTab" .. n]

    ourTab = CreateFrame("Button", "NexusJournalTab",
        journal, "CharacterFrameTabButtonTemplate")
    ourTab:SetText("Optimizer")
    -- Same row as their tabs, standard -16 overlap after the last one.
    ourTab:ClearAllPoints()
    ourTab:SetPoint("TOPLEFT", lastTab, "TOPRIGHT", -16, 0)
    ourTab:SetFrameLevel(lastTab:GetFrameLevel())
    -- A fresh template tab shows BOTH texture sets until its state is
    -- set; without this it renders as a mangled sliver.
    pcall(function() PanelTemplates_TabResize(ourTab, 0) end)
    pcall(function() PanelTemplates_DeselectTab(ourTab) end)
    ourTab:Show()
    ourTab:SetScript("OnClick", function() pcall(SelectOurTab) end)

    -- Their tabs return control to the journal's own content (and
    -- re-assert our tab button, in case their switcher hides unknown
    -- children).
    for i = 1, theirTabCount do
        local t = _G["ProjectEbonholdEchoJournalTab" .. i]
        if t and t.HookScript then
            t:HookScript("OnClick", function() pcall(DeselectOurTab) end)
        end
    end
    -- Opening the journal always lands on THEIR content with our tab
    -- visible and inactive.
    if journal.HookScript then
        journal:HookScript("OnShow", function() pcall(DeselectOurTab) end)
    end

    -- Our panel covers the journal's ENTIRE content region below the
    -- title bar: the per-tab top sections belong to THEIR tabs and
    -- their switcher rightly ignores our tab -- so we occlude rather
    -- than fight their state. EnableMouse blocks click-through.
    panel = CreateFrame("Frame", "NexusJournalPanel", journal)
    panel:SetPoint("TOPLEFT", journal, "TOPLEFT", 10, -32)
    panel:SetPoint("BOTTOMRIGHT", journal, "BOTTOMRIGHT", -8, 8)
    panel:SetFrameLevel(journal:GetFrameLevel() + 10)
    panel:EnableMouse(true)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(ASSET .. "UI-Background-Rock")

    scroll = CreateFrame("ScrollFrame", "NexusJournalScroll",
        panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -6)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(292, 100)
    scroll:SetScrollChild(child)

    panel:Hide()
end

-- Runs inside the client's own (pcall'd) handler paths: body must be
-- pcall-wrapped and minimal, or an error here aborts the remainder of
-- THEIR handler and gets misattributed to ProjectEbonhold.
local function OnJournalLifecycle()
    pcall(function()
        if not installed and pcall(Install) then
            installed = true
        end
        if installed then DeselectOurTab() end
    end)
end

local function EnsureLifecycleHooks()
    if hooked then return end
    if type(hooksecurefunc) ~= "function" then return end
    local pe = _G["ProjectEbonhold"]
    local ej = pe and pe.EchoJournal
    if type(ej) ~= "table" then return end
    local any = false
    if type(ej.Show) == "function" then
        hooksecurefunc(ej, "Show", OnJournalLifecycle)
        any = true
    end
    if type(ej.Toggle) == "function" then
        hooksecurefunc(ej, "Toggle", OnJournalLifecycle)
        any = true
    end
    hooked = any
end

-- Attach to the live journal (or arm the lazy Show/Toggle hooks and
-- attach on first open). Safe to call repeatedly; never errors.
function M.TryInstall(dataProvider)
    local ok = pcall(function()
        if type(dataProvider) == "function" then
            provider = dataProvider
        end
        EnsureLifecycleHooks()
        if not installed and pcall(Install) then
            installed = true
        end
    end)
    if not ok then return false end
    return installed and true or false
end
