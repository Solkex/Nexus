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
local rowButtons, rowFrames = {}, {}
local associationPanel
local scanFrame, associationVisible = nil, false
local pendingOpenLoadoutsUntil = 0
local theirTabCount = 0
local stockTabs = {}
local linePool, linesUsed = {}, 0

local ASSET = "Interface\\AddOns\\ProjectEbonhold\\assets\\"
local NOTE1 = "Targets the wishlist associated with the ACTIVE saved loadout."
local NOTE2 = "|cff8a8a8aSet associations on the game's My Builds screen; loadout activation remains server-controlled and level-1-only.|r"

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


local function MenuOpen(items, anchor)
    if type(EasyMenu) ~= "function" then return end
    M._menuFrame = M._menuFrame or CreateFrame("Frame", "NexusJournalAssociationMenu", UIParent, "UIDropDownMenuTemplate")
    EasyMenu(items, M._menuFrame, anchor, 0, 0, "MENU")
end

local function FrameText(frame)
    local out = {}
    local function Walk(f, depth)
        if not f or depth > 5 then return end
        if f.GetText then
            local ok, v = pcall(f.GetText, f)
            if ok and type(v) == "string" and v ~= "" then out[#out + 1] = v end
        end
        if f.GetRegions then
            local regs = { f:GetRegions() }
            for i = 1, #regs do
                local r = regs[i]
                if r and r.GetText then
                    local ok, v = pcall(r.GetText, r)
                    if ok and type(v) == "string" and v ~= "" then out[#out + 1] = v end
                end
            end
        end
        if f.GetChildren then
            local kids = { f:GetChildren() }
            for i = 1, #kids do Walk(kids[i], depth + 1) end
        end
    end
    Walk(frame, 0)
    return table.concat(out, "\n")
end

local function NormalizedText(frame)
    return FrameText(frame):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function FindButtonByText(root, wanted)
    local match
    local function Walk(f, depth)
        if match or not f or depth > 10 then return end
        local objectType = f.GetObjectType and f:GetObjectType() or ""
        if objectType == "Button" then
            local txt = NormalizedText(f)
            for line in txt:gmatch("[^\n]+") do
                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if line == wanted then match = f; return end
            end
        end
        if f.GetChildren then
            local kids = { f:GetChildren() }
            for i = 1, #kids do Walk(kids[i], depth + 1) end
        end
    end
    Walk(root, 0)
    return match
end

local function IsLoadoutCard(frame)
    if not frame or not frame.GetWidth or not frame.GetHeight then return false end
    local w, h = tonumber(frame:GetWidth()) or 0, tonumber(frame:GetHeight()) or 0
    if w < 420 or w > 700 or h < 82 or h > 180 then return false end
    local txt = NormalizedText(frame)
    if txt:find("Empty slot %d+") then return true end
    if txt:find("Save Build", 1, true) then return true end
    -- A populated card normally has LOADOUT plus its echo icons / overflow menu.
    if txt:find("LOADOUT", 1, true) and (txt:find("...", 1, true) or h >= 95) then return true end
    return false
end

local function CollectCards(root)
    local found, seen = {}, {}

    local function AddCandidate(frame)
        local f = frame
        for _ = 1, 7 do
            if not f then break end
            if f.GetWidth and f.GetHeight then
                local w, h = tonumber(f:GetWidth()) or 0, tonumber(f:GetHeight()) or 0
                -- Stock loadout cards on this client are wide, shallow panels.
                -- Find the first ancestor with card-like dimensions instead of
                -- relying on the card parent itself exposing all child text.
                if w >= 430 and w <= 680 and h >= 80 and h <= 190 then
                    if not seen[f] then
                        seen[f] = true
                        found[#found + 1] = f
                    end
                    return
                end
            end
            f = f.GetParent and f:GetParent() or nil
        end
    end

    local function Walk(f, depth)
        if not f or depth > 14 then return end

        if f.GetRegions then
            local regs = { f:GetRegions() }
            for i = 1, #regs do
                local r = regs[i]
                if r and r.GetText then
                    local ok, text = pcall(r.GetText, r)
                    if ok and type(text) == "string" then
                        text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                        text = text:gsub("^%s+", ""):gsub("%s+$", "")
                        if text == "LOADOUT" or text:match("^Empty slot %d+$") then
                            AddCandidate(r.GetParent and r:GetParent() or f)
                        end
                    end
                end
            end
        end

        if f.GetObjectType and f:GetObjectType() == "Button" and f.GetText then
            local ok, text = pcall(f.GetText, f)
            if ok and type(text) == "string" then
                text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                if text == "LOADOUT" or text:match("^Empty slot %d+$") then
                    AddCandidate(f)
                end
            end
        end

        if f.GetChildren then
            local kids = { f:GetChildren() }
            for i = 1, #kids do Walk(kids[i], depth + 1) end
        end
    end

    Walk(root, 0)

    -- Fallback for alternate client revisions where card text is only
    -- discoverable through recursive frame text.
    if #found == 0 then
        local fallbackSeen = {}
        local function Fallback(f, depth)
            if not f or depth > 12 then return end
            if IsLoadoutCard(f) and not fallbackSeen[f] then
                fallbackSeen[f] = true
                found[#found + 1] = f
                return
            end
            if f.GetChildren then
                local kids = { f:GetChildren() }
                for i = 1, #kids do Fallback(kids[i], depth + 1) end
            end
        end
        Fallback(root, 0)
    end

    table.sort(found, function(a, b)
        local at, bt = (a.GetTop and a:GetTop()) or 0, (b.GetTop and b:GetTop()) or 0
        if at == bt then
            local al, bl = (a.GetLeft and a:GetLeft()) or 0, (b.GetLeft and b:GetLeft()) or 0
            return al < bl
        end
        return at > bt
    end)
    return found
end

local function HasVisibleText(root, wanted)
    local found = false
    local function Walk(f, depth)
        if found or not f or depth > 16 then return end
        local shown = true
        if f.IsShown then
            local ok, v = pcall(f.IsShown, f)
            if ok then shown = v and true or false end
        end
        if shown then
            if f.GetText then
                local ok, text = pcall(f.GetText, f)
                if ok and type(text) == "string" then
                    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                    if text:find(wanted, 1, true) then found = true return end
                end
            end
            if f.GetRegions then
                local regs = { f:GetRegions() }
                for i = 1, #regs do
                    local r = regs[i]
                    if r and r.GetText then
                        local ok, text = pcall(r.GetText, r)
                        if ok and type(text) == "string" then
                            text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                            if text:find(wanted, 1, true) then found = true return end
                        end
                    end
                end
            end
        end
        if f.GetChildren then
            local kids = { f:GetChildren() }
            for i = 1, #kids do Walk(kids[i], depth + 1) end
        end
    end
    Walk(root, 0)
    return found
end

local function IsLoadoutsVisible(journal)
    if not journal or not journal.IsShown or not journal:IsShown() then return false end
    -- The stock page always exposes this section title. This is intentionally
    -- independent of card frame names, dimensions, verification flags, and
    -- Project Ebonhold client revisions.
    if HasVisibleText(journal, "Your loadouts") then return true end
    if HasVisibleText(journal, "Empty slot 2") or HasVisibleText(journal, "Empty slot 3") then return true end
    return false
end

local function FindLoadoutsTab(journal)
    local function IsWantedButton(f)
        if not f or not f.GetObjectType or f:GetObjectType() ~= "Button" then return false end
        local txt = NormalizedText(f)
        for line in txt:gmatch("[^\n]+") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line == "Loadouts" then return true end
        end
        return false
    end

    -- Prefer the stock named tabs when present. On the current client the
    -- Loadouts button is Tab3, but validate the visible label rather than
    -- assuming the index.
    for i = 1, 12 do
        local t = _G["ProjectEbonholdEchoJournalTab" .. tostring(i)]
        if IsWantedButton(t) then return t end
    end

    local exact
    local function Walk(f, depth)
        if exact or not f or depth > 18 then return end
        if IsWantedButton(f) then exact = f return end
        if f.GetChildren then
            local kids = { f:GetChildren() }
            for i = 1, #kids do Walk(kids[i], depth + 1) end
        end
    end
    Walk(journal, 0)
    if not exact and UIParent and UIParent ~= journal then Walk(UIParent, 0) end
    return exact
end

local function ClickLoadoutsTab(journal)
    if IsLoadoutsVisible(journal) then return true end
    local tab = FindLoadoutsTab(journal)
    if not tab then return false end
    if tab.Click then
        local ok = pcall(tab.Click, tab)
        if ok then return true end
    end
    local click = tab.GetScript and tab:GetScript("OnClick")
    if type(click) == "function" then
        return pcall(click, tab, "LeftButton")
    end
    return false
end

local function FindButtonByText(root, wanted)
    local found
    local function Walk(frame, depth)
        if found or not frame or depth > 18 then return end
        if frame.GetText then
            local ok, text = pcall(frame.GetText, frame)
            if ok and type(text) == "string" and text:lower() == wanted:lower() then
                found = frame
                return
            end
        end
        if frame.GetChildren then
            local kids = { frame:GetChildren() }
            for i = 1, #kids do Walk(kids[i], depth + 1) end
        end
    end
    Walk(root, 0)
    return found
end

local function ClickFrame(frame)
    if not frame then return false end
    if frame.Click then
        local ok = pcall(frame.Click, frame)
        if ok then return true end
    end
    local click = frame.GetScript and frame:GetScript("OnClick")
    if type(click) == "function" then
        return pcall(click, frame, "LeftButton")
    end
    return false
end

local function OpenNexusWishlistEditor(journal)
    -- The stock New Wishlist button is not consistently addressable across
    -- Project Ebonhold UI revisions. Nexus owns a reliable editor, so use it
    -- directly and close the journal to avoid overlapping full-size panels.
    if associationPanel then associationPanel:Hide() end
    if journal and journal.Hide then pcall(journal.Hide, journal) end
    local editor = Nexus and Nexus.WishlistEditor
    if editor and type(editor.NewWishlist) == "function" then
        pcall(editor.NewWishlist)
    elseif editor and type(editor.Show) == "function" then
        pcall(editor.Show)
    else
        print("|cffff6060Nexus:|r Wishlist Editor is unavailable.")
    end
end

local function EnsureAssociationPanel(journal)
    if not journal then return nil end
    if not associationPanel then
        associationPanel = CreateFrame("Frame", "NexusLoadoutAssociationPanel", UIParent)
        associationPanel:SetSize(210, 122)
        associationPanel:SetFrameStrata("DIALOG")
        associationPanel:SetClampedToScreen(true)
        if associationPanel.SetBackdrop then
            associationPanel:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
        end

        associationPanel.title = associationPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        associationPanel.title:SetPoint("TOPLEFT", 11, -10)
        associationPanel.title:SetWidth(188)
        associationPanel.title:SetJustifyH("LEFT")

        associationPanel.help = associationPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        associationPanel.help:SetPoint("TOPLEFT", associationPanel.title, "BOTTOMLEFT", 0, -3)
        associationPanel.help:SetWidth(188)
        associationPanel.help:SetHeight(28)
        associationPanel.help:SetJustifyH("LEFT")
        associationPanel.help:SetJustifyV("TOP")
        associationPanel.help:SetText("Wishlist Nexus progresses for this saved build.")

        associationPanel.selector = CreateFrame("Button", "NexusActiveWishlistSelector", associationPanel, "UIPanelButtonTemplate")
        associationPanel.selector:SetSize(188, 22)
        associationPanel.selector:SetPoint("TOPLEFT", associationPanel.help, "BOTTOMLEFT", 0, -5)
        associationPanel.selector:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Associated Wishlist", 1, 0.82, 0)
            GameTooltip:AddLine("Choose which wishlist Nexus should progress for the active saved loadout.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        associationPanel.selector:SetScript("OnLeave", function() GameTooltip:Hide() end)

        associationPanel.newButton = CreateFrame("Button", "NexusCreateWishlistButton", associationPanel, "UIPanelButtonTemplate")
        associationPanel.newButton:SetSize(188, 20)
        associationPanel.newButton:SetPoint("TOPLEFT", associationPanel.selector, "BOTTOMLEFT", 0, -5)
        associationPanel.newButton:SetText("+ Create New Wishlist")
        associationPanel.newButton:SetScript("OnClick", function()
            OpenNexusWishlistEditor(_G["ProjectEbonholdEchoJournal"])
        end)
    end

    associationPanel:ClearAllPoints()
    local parentRight = journal.GetRight and journal:GetRight() or 0
    local screenWidth = UIParent and UIParent.GetWidth and UIParent:GetWidth() or 0
    if parentRight > 0 and screenWidth > 0 and parentRight + 218 > screenWidth then
        associationPanel:SetPoint("TOPRIGHT", journal, "TOPLEFT", -4, -150)
    else
        associationPanel:SetPoint("TOPLEFT", journal, "TOPRIGHT", 4, -150)
    end
    return associationPanel
end

local function HideRowButtons()
    if associationPanel then associationPanel:Hide() end
    for _, row in pairs(rowButtons) do row:Hide() end
end

local function RefreshAssociationRows()
    local journal = _G["ProjectEbonholdEchoJournal"]
    if not journal or not IsLoadoutsVisible(journal) then HideRowButtons(); return end
    local A = Nexus and Nexus.GameAdapter
    local slots = A and A.Slots and A.Slots()
    if not slots then HideRowButtons(); return end

    local active = tonumber(slots.activeSlot) or 0
    local activeRow = slots.bySlot and slots.bySlot[active]
    local activePopulated = activeRow and type(activeRow.echoes) == "table" and #activeRow.echoes > 0
    if active < 1 or active > (tonumber(slots.maxSlots) or 5) or not activePopulated then
        HideRowButtons()
        return
    end

    local host = EnsureAssociationPanel(journal)
    local wishes = A.GetWishlistCandidates and A.GetWishlistCandidates() or {}
    local linked = A.GetLoadoutWishlist and A.GetLoadoutWishlist(active)
    local loadoutName = tostring(activeRow.name or "")
    if loadoutName == "" then loadoutName = "Loadout " .. tostring(active) end
    host.title:SetText(loadoutName .. "  |cff55ff55ACTIVE|r")

    local linkedName = linked and linked.name or nil
    host.selector:SetText(linkedName and ("Wishlist: " .. ((#linkedName > 22) and (linkedName:sub(1, 19) .. "...") or linkedName)) or "Choose Wishlist...")
    host.selector:SetScript("OnClick", function(self)
        local items = {}
        if #wishes == 0 then
            items[1] = { text = "No wishlists available", disabled = true, notCheckable = true }
        else
            for i = 1, #wishes do
                local c = wishes[i]
                items[#items + 1] = {
                    text = ((linked and linked.key == c.key) and "|cff55ff55✓ |r" or "") .. ((c.name ~= "" and c.name) or "Unnamed Wishlist"),
                    notCheckable = true,
                    func = function()
                        local ok, err = A.SetLoadoutWishlist(active, c.slot)
                        if not ok then
                            print("|cffff6060Nexus:|r " .. tostring(err))
                            return
                        end
                        print("|cff66ff66Nexus:|r " .. loadoutName .. " will now progress " .. tostring(c.name or "this wishlist") .. ".")
                        M.RefreshAssociations()
                        if Nexus.Panel and Nexus.Panel.Refresh then pcall(Nexus.Panel.Refresh) end
                    end,
                }
            end
        end
        MenuOpen(items, self)
    end)
    host:Show()
end

function M.RefreshAssociations()
    pcall(RefreshAssociationRows)
end

local function EnsureAssociationScanner()
    if scanFrame then return end
    -- This scanner must not depend on the optional Nexus Optimizer tab
    -- installing successfully. The stock journal is lazy-created, and older
    -- code accidentally disabled BOTH opening Loadouts and drawing association
    -- controls whenever a named stock scroll frame was absent.
    scanFrame = CreateFrame("Frame", "NexusLoadoutAssociationScanner", UIParent)
    local elapsed = 0
    scanFrame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (tonumber(dt) or 0)
        if elapsed < 0.20 then return end
        elapsed = 0

        pcall(function()
            local journal = _G["ProjectEbonholdEchoJournal"]
            local now = GetTime and GetTime() or 0
            if journal and journal.IsShown and journal:IsShown() then
                if pendingOpenLoadoutsUntil > 0 and now <= pendingOpenLoadoutsUntil then
                    if not IsLoadoutsVisible(journal) then ClickLoadoutsTab(journal) end
                    if IsLoadoutsVisible(journal) then pendingOpenLoadoutsUntil = 0 end
                elseif pendingOpenLoadoutsUntil > 0 then
                    pendingOpenLoadoutsUntil = 0
                end

                if installed and panel and panel:IsShown() then
                    associationVisible = false
                else
                    associationVisible = IsLoadoutsVisible(journal)
                end
                RefreshAssociationRows()
            else
                associationVisible = false
                HideRowButtons()
            end
        end)
    end)
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
    associationVisible = false
    HideRowButtons()
    M.Refresh()
end

local function DeselectOurTab(showAssociation)
    if ourTab and PanelTemplates_DeselectTab then
        pcall(PanelTemplates_DeselectTab, ourTab)
    end
    if panel then panel:Hide() end
    associationVisible = showAssociation ~= false
    if associationVisible then pcall(RefreshAssociationRows) else HideRowButtons() end
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
    EnsureAssociationScanner()

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

    -- Their tab numbering differs between client revisions. Never assume
    -- Tab1 is Loadouts: inspect the clicked tab after the stock handler runs.
    stockTabs = {}
    for i = 1, theirTabCount do
        local t = _G["ProjectEbonholdEchoJournalTab" .. i]
        if t then
            stockTabs[#stockTabs + 1] = t
            if t.HookScript then
                t:HookScript("OnClick", function()
                    pcall(function()
                        DeselectOurTab(false)
                        associationVisible = IsLoadoutsVisible(journal)
                        if associationVisible then RefreshAssociationRows() else HideRowButtons() end
                    end)
                end)
            end
        end
    end
    -- Some client builds use bottom navigation buttons that are not named
    -- ProjectEbonholdEchoJournalTabN. The scanner determines visibility from
    -- actual loadout cards, so opening/rebuilding the journal remains safe.
    if journal.HookScript then
        journal:HookScript("OnShow", function()
            pcall(function()
                DeselectOurTab(false)
                associationVisible = IsLoadoutsVisible(journal)
            end)
        end)
        journal:HookScript("OnHide", function() associationVisible = false; HideRowButtons() end)
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
        if installed then DeselectOurTab(true) end
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

function M.OpenBuilds()
    EnsureAssociationScanner()
    local pe = _G["ProjectEbonhold"]
    local ej = pe and pe.EchoJournal
    if ej and type(ej.Show) == "function" then
        local ok = pcall(function() ej.Show() end)
        if not ok then pcall(ej.Show, ej) end
    elseif ej and type(ej.Toggle) == "function" then
        local ok = pcall(function() ej.Toggle() end)
        if not ok then pcall(ej.Toggle, ej) end
    end

    -- The stock journal and its bottom tabs are created asynchronously.
    -- The independent scanner above retries the real visible Loadouts button
    -- until the loadout cards exist; this works even if the Optimizer tab could
    -- not be installed on this Project Ebonhold UI revision.
    pendingOpenLoadoutsUntil = (GetTime and GetTime() or 0) + 6
    pcall(function()
        if not installed and pcall(Install) then installed = true end
        local journal = _G["ProjectEbonholdEchoJournal"]
        if installed then DeselectOurTab(false) end
        if journal then ClickLoadoutsTab(journal) end
    end)
end

function M.DebugSnapshot()
    local journal = _G["ProjectEbonholdEchoJournal"]
    local A = Nexus and Nexus.GameAdapter
    local slots = A and A.Slots and A.Slots()
    local visible = journal and IsLoadoutsVisible(journal) or false
    local tab = journal and FindLoadoutsTab(journal) or nil
    local tabText = tab and NormalizedText(tab) or "none"
    local lines = {}
    lines[#lines + 1] = "journal=" .. tostring(journal ~= nil) .. " shown=" .. tostring(journal and journal:IsShown() or false)
    lines[#lines + 1] = "loadoutsVisible=" .. tostring(visible) .. " tab=" .. tostring(tabText)
    lines[#lines + 1] = "associationPanel=" .. tostring(associationPanel ~= nil)
        .. " shown=" .. tostring(associationPanel and associationPanel:IsShown() or false)
    if slots then
        lines[#lines + 1] = "activeSlot=" .. tostring(slots.activeSlot) .. " maxSlots=" .. tostring(slots.maxSlots)
        for i = 1, tonumber(slots.maxSlots or 5) do
            local r = slots.bySlot and slots.bySlot[i]
            lines[#lines + 1] = "slot" .. i .. " echoes=" .. tostring(r and r.echoes and #r.echoes or 0) .. " linked=" .. tostring(A.GetLoadoutWishlistSlot and A.GetLoadoutWishlistSlot(i) or "none")
        end
    else
        lines[#lines + 1] = "slots=nil"
    end
    return lines
end

-- Attach to the live journal (or arm the lazy Show/Toggle hooks and
-- attach on first open). Safe to call repeatedly; never errors.
function M.TryInstall(dataProvider)
    local ok = pcall(function()
        if type(dataProvider) == "function" then
            provider = dataProvider
        end
        EnsureAssociationScanner()
        EnsureLifecycleHooks()
        if not installed and pcall(Install) then
            installed = true
        end
    end)
    if not ok then return false end
    return installed and true or false
end
