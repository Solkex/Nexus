-- Nexus: ui/WishlistEditor.lua
-- The wishlist BUILDER window -- browse the full echo catalog, see at a
-- glance which ones you own/need/have the tome for, and build your
-- target list right here instead of in the Echo Journal.
--
-- Modeled closely on the EchoWishlist addon's two-panel layout (left:
-- browsable catalog with status labels; right: your current picks with
-- per-item stack steppers), rebuilt against OUR OWN live data sources
-- (Adapter.Catalog/Owned/Wishlist) instead of a separate reverse-
-- engineered catalog scan.
--
-- STATUS (2026-07-24): fully live for BROWSING -- search, filters,
-- pagination, and the Owned/Locked/Tome/Base status labels are all real
-- data. Clicking a row DOES add/remove/adjust it in a local, in-memory
-- pending list -- but that pending list is NOT YET sent anywhere. The
-- "Apply to Server" button at the bottom is deliberately disabled with
-- an explanatory tooltip until /nexus sniff identifies the real write
-- function for a designed build slot. Wiring it up then is a matter of
-- replacing ApplyPending()'s body -- everything else here is ready.

Nexus = Nexus or {}
local M = {}
Nexus.WishlistEditor = M

local MAX_ROWS = 14
local PICK_ROWS = 14
local ROW_HEIGHT = 22

local QUALITY_COLORS = {
    [0] = { 1, 1, 1 },          -- Common
    [1] = { 0.12, 1, 0.12 },    -- Uncommon
    [2] = { 0.2, 0.6, 1 },      -- Rare
    [3] = { 0.72, 0.36, 0.98 }, -- Epic
    [4] = { 1, 0.65, 0 },       -- Legendary
}

-- Closure-captured widgets.
local frame, rows, pickRows
local searchBox, classCheck, applyBtn, footerText, pickFooterText
local trackingText, candidateButtons
local displayPopup, displayCheck, displayLockBtn
local Adapter, Model   -- injected via Init so this file has no direct
                        -- dependency on module load order

-- Local, in-memory pending wishlist. Keyed by spellId:
--   pending[spellId] = { spellId, quality, stacks }
-- Seeded from the currently-read real wishlist on first open so the UI
-- starts from somewhere sane. NOT auto-saved anywhere yet.
local pending = {}
local pendingSeeded = false

local scrollOffset, pickOffset = 0, 0

------------------------------------------------------------------------
-- Data helpers
------------------------------------------------------------------------

local function IsKnownSpell(spellId)
    spellId = tonumber(spellId)
    if not spellId or spellId <= 0 then return false end
    if type(IsSpellKnown) == "function" then
        local ok, known = pcall(IsSpellKnown, spellId)
        if ok and known then return true end
    end
    if type(IsPlayerSpell) == "function" then
        local ok, known = pcall(IsPlayerSpell, spellId)
        if ok and known then return true end
    end
    return false
end

-- "base" (no tome needed) | "tome" (needs a tome you know) |
-- "locked" (needs a tome you don't know yet)
local function RollStatus(row, catalog)
    local req = tonumber(row.requiredSpell) or 0
    if req <= 0 then return "base" end
    if IsKnownSpell(req) then return "tome" end
    return "locked"
end

local function SeedPendingFromWishlist()
    if pendingSeeded then return end
    pendingSeeded = true
    local wl = Adapter.Wishlist and Adapter.Wishlist()
    if not wl then return end
    for _, e in ipairs(wl.entries or {}) do
        pending[e.spellId] = { spellId = e.spellId, quality = e.quality,
            stacks = e.stacks or 1 }
    end
end

-- Builds the browsable list: every catalog row usable by the player's
-- class, matching the search text, sorted by name.
local function BuildAvailableList(catalog, owned)
    local out = {}
    local search = (NexusDB.editorSearch or ""):lower()
    local classOnly = NexusDB.editorClassOnly ~= false
    local playerMask = catalog and catalog.playerMask
    for id, row in pairs((catalog and catalog.rows) or {}) do
        local okClass = (not classOnly) or (Model and Model.MaskMatch
            and Model.MaskMatch(row.classMask, playerMask))
        local nm = (row.name or ""):lower()
        if okClass and (search == "" or nm:find(search, 1, true)) then
            out[#out + 1] = row
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return out
end

------------------------------------------------------------------------
-- Actions (pending list only -- see file header)
------------------------------------------------------------------------

local function AddPending(row)
    pending[row.spellId] = pending[row.spellId]
        or { spellId = row.spellId, quality = row.quality, stacks = 1 }
end

local function RemovePending(spellId)
    pending[spellId] = nil
end

local function AdjustStacks(spellId, delta)
    local p = pending[spellId]
    if not p then return end
    p.stacks = math.max(1, (p.stacks or 1) + delta)
end

-- Deliberately unimplemented: the write function isn't identified yet
-- (see /nexus sniff). Wiring this up is the ONLY remaining step once we
-- know it -- everything upstream (the pending list, its shape, the UI)
-- is already exactly what a real Save call would need.
-- Confirmed via /nexus sniff (2026-07-24): UploadServerBuildSlot(slot, name,
-- echoes) with slot=0 is the real write function -- two independent live
-- captures (a community-loadout import, and a raw ImportEchoLoadout
-- string import) both used it. This is destructive (it overwrites
-- whatever's currently in that slot), so it goes through a confirmation
-- popup rather than firing on click.
StaticPopupDialogs = StaticPopupDialogs or {}
local APPLY_FRIENDLY = {
    spacing = "the server is busy with another build operation -- try again in a moment",
    refused = "the server refused the change (are you in a state that allows editing your build?)",
    ["no echoes"] = "there are no echoes in your pending list",
    ["no valid echoes"] = "none of the pending echoes look valid",
}

local applyRetry = nil
local function TryApply(name, echoes, isRetry)
    local ok, err = Adapter.UploadWishlist(0, name, echoes)
    if ok then
        print("|cff4dff80Nexus:|r wishlist uploaded (" .. #echoes .. " echoes).")
        applyRetry = nil
        return true
    end
    if tostring(err) == "spacing" then
        applyRetry = applyRetry or { name = name, echoes = echoes, tries = 0 }
        return false
    end
    print("|cffff6060Nexus:|r couldn't apply: "
        .. (APPLY_FRIENDLY[tostring(err)] or tostring(err)))
    applyRetry = nil
    return false
end

function M._PumpApplyRetry()
    if not applyRetry then return end
    applyRetry.tries = applyRetry.tries + 1
    if applyRetry.tries > 12 then
        print("|cffff6060Nexus:|r couldn't apply: " .. APPLY_FRIENDLY.spacing)
        applyRetry = nil
        return
    end
    TryApply(applyRetry.name, applyRetry.echoes, true)
end

function M.IsApplyPending() return applyRetry ~= nil end

StaticPopupDialogs["WISHLISTREALIZER_APPLY_WISHLIST"] = {
    text = "Overwrite your designed wishlist with these %d echoes?\nThis cannot be undone from here.",
    button1 = "Overwrite",
    button2 = "Cancel",
    OnAccept = function(self, data)
        TryApply(data.name, data.echoes)
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function ApplyPending()
    if not (Adapter and Adapter.UploadWishlist) then
        print("|cffff6060Nexus:|r adapter not ready.")
        return
    end
    local echoes = {}
    for _, p in pairs(pending) do
        echoes[#echoes + 1] = { spellId = p.spellId, quality = p.quality,
            stacks = p.stacks or 1 }
    end
    if #echoes == 0 then
        print("|cffff6060Nexus:|r pending list is empty -- add something first.")
        return
    end
    StaticPopup_Show("WISHLISTREALIZER_APPLY_WISHLIST", #echoes, nil,
        { name = "Nexus", echoes = echoes })
end

local function SpellIcon(spellId)
    if not spellId then return "Interface\\Icons\\INV_Misc_QuestionMark" end
    local ok, _, _, icon = pcall(GetSpellInfo, spellId)
    return (ok and icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

------------------------------------------------------------------------
-- Frame construction
------------------------------------------------------------------------

local function EnsureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "NexusEditorFrame", UIParent)
    frame:SetSize(860, 560)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(50)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local refreshTicker = 0
    local applyTicker = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        applyTicker = applyTicker + (elapsed or 0)
        if applyTicker >= 0.5 then
            applyTicker = 0
            if M._PumpApplyRetry then M._PumpApplyRetry() end
        end
        refreshTicker = refreshTicker + (elapsed or 0)
        if refreshTicker >= 2.0 then
            refreshTicker = 0
            M.Refresh()
        end
    end)
    frame:SetScript("OnHide", function()
        if displayPopup then displayPopup:Hide() end
    end)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Nexus  —  Wishlists")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- Tracking status: shows EXACTLY what the addon currently believes
    -- the active wishlist is, rather than a bare "no wishlist" that reads
    -- as "you have none" when really it can also mean "you have several
    -- and none is marked active" (2026-07-24 -- this was silently
    -- swallowed before; A.GetWishlistCandidates() surfaces it properly).
    trackingText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    trackingText:SetPoint("TOPLEFT", 28, -40)
    trackingText:SetSize(500, 16)
    trackingText:SetJustifyH("LEFT")

    -- Shown only when multiple designed wishlists exist and none is
    -- active -- one button per candidate, click to make it the active one.
    candidateButtons = {}
    for i = 1, 4 do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(115, 20)
        b:SetPoint("TOPLEFT", 28 + ((i - 1) * 121), -58)
        b:Hide()
        candidateButtons[i] = b
    end

    -- Overlay controls, moved to the top-right where they're actually
    -- visible instead of buried at the bottom of a long window.
    local displayBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    displayBtn:SetSize(150, 22)
    displayBtn:SetPoint("TOPRIGHT", -260, -34)
    displayBtn:SetText("Display Settings")
    displayBtn:SetScript("OnClick", function(self) M.ToggleDisplayPopup(self) end)
    displayBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("On-screen wishlist settings", 1, 1, 1)
        GameTooltip:AddLine("Show/hide the always-on-screen list, and lock/unlock", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("it for moving.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    displayBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    searchBox = CreateFrame("EditBox", "NexusEditorSearch", frame,
        "InputBoxTemplate")
    searchBox:SetSize(260, 22)
    searchBox:SetPoint("TOPLEFT", 28, -78)
    searchBox:SetAutoFocus(false)
    searchBox:SetText(NexusDB.editorSearch or "")
    searchBox:SetScript("OnTextChanged", function(self)
        NexusDB.editorSearch = self:GetText() or ""
        scrollOffset = 0
        M.Refresh()
    end)

    classCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    classCheck:SetPoint("LEFT", searchBox, "RIGHT", 24, 0)
    classCheck:SetChecked(NexusDB.editorClassOnly ~= false)
    classCheck.text = classCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classCheck.text:SetPoint("LEFT", classCheck, "RIGHT", -2, 1)
    classCheck.text:SetText("Current class only")
    classCheck:SetScript("OnClick", function(self)
        NexusDB.editorClassOnly = self:GetChecked() and true or false
        scrollOffset = 0
        M.Refresh()
    end)

    -- Opens Nexus Builds directly -- our own working community-sharing
    -- system (core/Sync.lua), not a best-effort guess at the game's own
    -- UI. That guess-based version is retired now that we have a real one.
    local communityBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    communityBtn:SetSize(150, 22)
    communityBtn:SetPoint("TOPRIGHT", -46, -78)
    communityBtn:SetText("Nexus Builds")
    communityBtn:SetScript("OnClick", function()
        if Nexus.CommunityBuilds then
            Nexus.CommunityBuilds.Show()
        else
            print("|cffff6060Nexus:|r Nexus Builds unavailable")
        end
    end)
    communityBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Browse and post shared wishlists", 1, 1, 1)
        GameTooltip:AddLine("Opens Nexus Builds -- see what other players running", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Nexus have posted, or share your own.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    communityBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", 30, -94)
    header:SetText("Left: browse the catalog, click to add. Right: your picks -- click to remove. Scroll either side with your mouse wheel.")

    -- Left: browsable catalog -----------------------------------------
    local leftArea = CreateFrame("Frame", nil, frame)
    leftArea:SetPoint("TOPLEFT", 36, -112)
    leftArea:SetSize(500, MAX_ROWS * ROW_HEIGHT)
    leftArea:EnableMouseWheel(true)
    leftArea:SetScript("OnMouseWheel", function(_, delta)
        scrollOffset = math.max(0, scrollOffset - delta * 3)
        M.Refresh()
    end)

    rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, leftArea)
        row:SetSize(500, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:EnableMouse(true)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta)
            scrollOffset = math.max(0, scrollOffset - delta * 3)
            M.Refresh()
        end)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 0, 0)
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.text:SetSize(330, ROW_HEIGHT)
        row.text:SetJustifyH("LEFT")

        row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.status:SetPoint("RIGHT", row, "RIGHT", -12, 0)
        row.status:SetSize(90, ROW_HEIGHT)
        row.status:SetJustifyH("RIGHT")

        row:SetScript("OnEnter", function(self)
            if not self.data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.data.name, 1, 1, 1)
            GameTooltip:AddLine("Click to add to your pending wishlist", 0.6, 0.9, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.data then AddPending(self.data); M.Refresh() end
        end)

        rows[i] = row
    end

    footerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footerText:SetPoint("BOTTOMLEFT", 36, 24)
    footerText:SetJustifyH("LEFT")

    -- Right: pending picks ----------------------------------------------
    local pickTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOPLEFT", 578, -82)
    pickTitle:SetText("Your Wishlist (pending)")

    local pickArea = CreateFrame("Frame", nil, frame)
    pickArea:SetPoint("TOPLEFT", 578, -104)
    pickArea:SetSize(266, PICK_ROWS * ROW_HEIGHT)
    pickArea:EnableMouseWheel(true)
    pickArea:SetScript("OnMouseWheel", function(_, delta)
        pickOffset = math.max(0, pickOffset - delta * 3)
        M.Refresh()
    end)

    pickRows = {}
    for i = 1, PICK_ROWS do
        local row = CreateFrame("Button", nil, pickArea)
        row:SetSize(266, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:EnableMouse(true)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta)
            pickOffset = math.max(0, pickOffset - delta * 3)
            M.Refresh()
        end)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 0, 0)
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetSize(230, ROW_HEIGHT)
        row.text:SetJustifyH("LEFT")

        row:SetScript("OnEnter", function(self)
            if not self.data then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self.data.name, 1, 1, 1)
            GameTooltip:AddLine("Click to remove from your pending wishlist", 1, 0.6, 0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.data then RemovePending(self.data.spellId); M.Refresh() end
        end)

        pickRows[i] = row
    end

    pickFooterText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pickFooterText:SetPoint("BOTTOMLEFT", 578, 54)
    pickFooterText:SetJustifyH("LEFT")

    -- Apply button: deliberately disabled until the real write function
    -- is known (see file header). Wire ApplyPending() and re-enable this
    -- once /nexus sniff has an answer.
    applyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    applyBtn:SetSize(180, 24)
    applyBtn:SetPoint("BOTTOMLEFT", 578, 24)
    applyBtn:SetText("Apply to Server")
    applyBtn:SetScript("OnClick", ApplyPending)
    applyBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Overwrites your designed wishlist", 1, 0.8, 0.3)
        GameTooltip:AddLine("Uploads your pending list here as your active Echo", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Journal wishlist. You'll get a confirmation first.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    applyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Cosmetic only, deliberately last: every functional widget above
    -- already exists regardless of whether this succeeds (this exact
    -- ordering mistake -- a cosmetic call sitting BEFORE pickRows/
    -- applyBtn -- was why they never got created when SetColorTexture
    -- threw, live 2026-07-24).
    pcall(function()
        local divider = frame:CreateTexture(nil, "ARTWORK")
        divider:SetTexture(0.35, 0.35, 0.35, 0.65)
        divider:SetSize(1, 390)
        divider:SetPoint("TOPLEFT", 560, -104)
    end)

    -- Background -- this was simply never added (not a crash, just an
    -- oversight, 2026-07-24). Separate pcall from the divider above so
    -- either one failing can't take out the other.
    pcall(function()
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end)

    return frame
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------

function M.Refresh()
    if not frame then return end
    SeedPendingFromWishlist()

    local catalog = Adapter and Adapter.Catalog and Adapter.Catalog()
    local owned = Adapter and Adapter.Owned and Adapter.Owned()
    local ownedBySpell = (owned and owned.bySpell) or {}

    -- Tracking status: show EXACTLY what's active, or why nothing is,
    -- rather than a bare "no wishlist" that reads as "you have none"
    -- when it might really mean "you have several, pick one".
    local wl = Adapter and Adapter.Wishlist and Adapter.Wishlist()
    if wl then
        trackingText:SetText(string.format("|cff4dff80Tracking:|r '%s' (%s, %d echoes)",
            (wl.name ~= "" and wl.name) or "(unnamed)", tostring(wl.source), #wl.entries))
        for _, b in ipairs(candidateButtons) do b:Hide() end
    else
        local candidates = (Adapter and Adapter.GetWishlistCandidates
            and Adapter.GetWishlistCandidates()) or {}
        if #candidates > 1 then
            trackingText:SetText(string.format(
                "|cffff9040%d wishlists found, none active|r -- click one to use it:",
                #candidates))
            for i, b in ipairs(candidateButtons) do
                local c = candidates[i]
                if c then
                    b:SetText(string.format("%s (%d)",
                        (c.name ~= "" and c.name) or ("Slot " .. tostring(c.slot)), c.count))
                    b:SetScript("OnClick", function()
                        local ok, err = Adapter.Activate and Adapter.Activate(c.slot)
                        if ok then
                            print("|cff4dff80Nexus:|r activated '" .. tostring(c.name) .. "'.")
                        else
                            print("|cffff6060Nexus:|r couldn't activate right now ("
                                .. tostring(err) .. ") -- this only works at level 1 or 80.")
                        end
                    end)
                    b:Show()
                else
                    b:Hide()
                end
            end
        elseif #candidates == 1 then
            -- Exactly one candidate but not yet flagged active by the
            -- server -- offer to activate it directly.
            trackingText:SetText("|cffff9040Found a wishlist, but it's not active yet|r -- click to use it:")
            candidateButtons[1]:SetText(candidates[1].name ~= "" and candidates[1].name
                or ("Slot " .. tostring(candidates[1].slot)))
            candidateButtons[1]:SetScript("OnClick", function()
                local ok, err = Adapter.Activate and Adapter.Activate(candidates[1].slot)
                if ok then
                    print("|cff4dff80Nexus:|r activated '" .. tostring(candidates[1].name) .. "'.")
                else
                    print("|cffff6060Nexus:|r couldn't activate right now ("
                        .. tostring(err) .. ") -- this only works at level 1 or 80.")
                end
            end)
            candidateButtons[1]:Show()
            for i = 2, #candidateButtons do candidateButtons[i]:Hide() end
        else
            trackingText:SetText("|cff888888No wishlist yet|r -- build one below, or check Nexus Builds.")
            for _, b in ipairs(candidateButtons) do b:Hide() end
        end
    end

    if applyBtn then
        applyBtn:SetText(M.IsApplyPending() and "Applying..." or "Apply to Server")
    end
    if displayCheck and Nexus.WishlistOverlay then
        displayCheck:SetChecked(Nexus.WishlistOverlay.IsShown() == true)
        if displayLockBtn then
            displayLockBtn:SetText(Nexus.WishlistOverlay.IsLocked() and "Unlock to Move" or "Lock Position")
        end
    end

    local available = BuildAvailableList(catalog, owned)
    if scrollOffset >= #available then
        scrollOffset = math.max(0, #available - MAX_ROWS)
    end
    for i, row in ipairs(rows) do
        local data = available[scrollOffset + i]
        row.data = data
        if data then
            row:Show()
            row.icon:SetTexture(SpellIcon(data.spellId))
            local c = QUALITY_COLORS[data.quality] or QUALITY_COLORS[0]
            row.text:SetTextColor(c[1], c[2], c[3])
            row.text:SetText(data.name .. (pending[data.spellId] and "  |cff4dff80(wishlisted)|r" or ""))
            local ownedCount = ownedBySpell[data.spellId] or 0
            local status = RollStatus(data, catalog)
            if ownedCount > 0 then
                row.status:SetText("|cffffd200[X]" .. (ownedCount > 1 and ("x" .. ownedCount) or "") .. "|r")
            elseif status == "locked" then
                row.status:SetText("|cffff4040Locked|r")
            elseif status == "tome" then
                row.status:SetText("|cff72ff72Tome|r")
            else
                row.status:SetText("|cffbbbbbbBase|r")
            end
        else
            row:Hide()
        end
    end
    footerText:SetText(string.format("Available %d-%d / %d",
        math.min(scrollOffset + 1, #available), math.min(#available, scrollOffset + MAX_ROWS),
        #available))

    local list = {}
    for _, p in pairs(pending) do
        local row = catalog and catalog.rows and catalog.rows[p.spellId]
        list[#list + 1] = { spellId = p.spellId, stacks = p.stacks,
            quality = p.quality, name = (row and row.name) or ("spell " .. p.spellId) }
    end
    table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
    if pickOffset >= #list then pickOffset = math.max(0, #list - PICK_ROWS) end
    for i, row in ipairs(pickRows) do
        local data = list[pickOffset + i]
        row.data = data
        if data then
            row:Show()
            row.icon:SetTexture(SpellIcon(data.spellId))
            row.text:SetText(data.name .. ((data.stacks or 1) > 1
                and ("  |cffffd200x" .. data.stacks .. "|r") or ""))
        else
            row:Hide()
        end
    end
    pickFooterText:SetText(string.format("Wishlist %d-%d / %d",
        math.min(pickOffset + 1, #list), math.min(#list, pickOffset + PICK_ROWS), #list))
end

------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Display popup (on-screen wishlist settings) -- small, self-contained,
-- opened from the "Display..." button so the main editor stays uncluttered
------------------------------------------------------------------------

local function EnsureDisplayPopup()
    if displayPopup then return displayPopup end

    -- Always parent this dialog directly to UIParent. Parenting it to the
    -- editor made its visibility and mouse state depend on a much larger
    -- window, which could leave the popup visible but unable to receive
    -- clicks after the editor was hidden.
    local p = CreateFrame("Frame", "NexusDisplayPopup", UIParent)
    p:SetSize(300, 218)
    p:SetFrameStrata("TOOLTIP")
    p:SetFrameLevel(100)
    p:EnableMouse(true)
    if p.SetClampedToScreen then p:SetClampedToScreen(true) end
    p:Hide()

    pcall(function()
        p:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        p:SetBackdropColor(0.04, 0.04, 0.04, 0.98)
    end)

    -- Only the title bar drags the dialog. Making the entire popup a drag
    -- target can steal mouse-down events from checkboxes, sliders and
    -- buttons on older clients.
    local dragBar = CreateFrame("Frame", nil, p)
    dragBar:SetPoint("TOPLEFT", 10, -8)
    dragBar:SetPoint("TOPRIGHT", -34, -8)
    dragBar:SetHeight(30)
    dragBar:SetFrameLevel(p:GetFrameLevel() + 1)
    dragBar:EnableMouse(true)
    dragBar:RegisterForDrag("LeftButton")
    p:SetMovable(true)
    dragBar:SetScript("OnDragStart", function() p:StartMoving() end)
    dragBar:SetScript("OnDragStop", function() p:StopMovingOrSizing() end)

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("On-Screen Wishlist")

    local subtitle = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetSize(245, 28)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Show, position, and resize the wishlist list used while playing.")

    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetFrameLevel(p:GetFrameLevel() + 5)
    close:SetScript("OnClick", function() p:Hide() end)

    displayCheck = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    displayCheck:SetPoint("TOPLEFT", 16, -68)
    displayCheck:SetFrameLevel(p:GetFrameLevel() + 5)
    displayCheck:EnableMouse(true)
    displayCheck:SetChecked(NexusDB.overlayShown == true)
    displayCheck.text = displayCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    displayCheck.text:SetPoint("LEFT", displayCheck, "RIGHT", -2, 1)
    displayCheck.text:SetText("Show on-screen wishlist")
    displayCheck:SetScript("OnClick", function(self)
        if Nexus.WishlistOverlay then
            if self:GetChecked() then
                Nexus.WishlistOverlay.Show()
            else
                Nexus.WishlistOverlay.Hide()
            end
        end
    end)

    local moveLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moveLabel:SetPoint("TOPLEFT", 18, -102)
    moveLabel:SetText("Position")

    displayLockBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    displayLockBtn:SetSize(92, 22)
    displayLockBtn:SetPoint("LEFT", moveLabel, "RIGHT", 16, 0)
    displayLockBtn:SetFrameLevel(p:GetFrameLevel() + 5)
    displayLockBtn:EnableMouse(true)
    displayLockBtn:SetScript("OnClick", function()
        if Nexus.WishlistOverlay then
            Nexus.WishlistOverlay.ToggleLock()
            displayLockBtn:SetText(Nexus.WishlistOverlay.IsLocked()
                and "Unlock to Move" or "Lock Position")
        end
    end)

    local resetBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 22)
    resetBtn:SetPoint("LEFT", displayLockBtn, "RIGHT", 10, 0)
    resetBtn:SetFrameLevel(p:GetFrameLevel() + 5)
    resetBtn:EnableMouse(true)
    resetBtn:SetText("Reset Position")
    resetBtn:SetScript("OnClick", function()
        if Nexus.WishlistOverlay and Nexus.WishlistOverlay.ResetPosition then
            Nexus.WishlistOverlay.ResetPosition()
            displayCheck:SetChecked(true)
        end
    end)

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, -128)
    hint:SetSize(260, 24)
    hint:SetJustifyH("LEFT")
    hint:SetText("Unlock to drag the list. Lock it when placed so the list does not block gameplay clicks.")

    local sizeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sizeLabel:SetPoint("TOPLEFT", 18, -164)
    sizeLabel:SetText("Size")

    local scaleMinus = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    scaleMinus:SetSize(22, 22)
    scaleMinus:SetPoint("LEFT", sizeLabel, "RIGHT", 22, 0)
    scaleMinus:SetFrameLevel(p:GetFrameLevel() + 5)
    scaleMinus:EnableMouse(true)
    scaleMinus:SetText("-")

    local scaleValueText = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleValueText:SetPoint("LEFT", scaleMinus, "RIGHT", 7, 0)
    scaleValueText:SetSize(48, 22)
    scaleValueText:SetJustifyH("CENTER")

    local scalePlus = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    scalePlus:SetSize(22, 22)
    scalePlus:SetPoint("LEFT", scaleValueText, "RIGHT", 7, 0)
    scalePlus:SetFrameLevel(p:GetFrameLevel() + 5)
    scalePlus:EnableMouse(true)
    scalePlus:SetText("+")

    local scaleSlider = CreateFrame("Slider", "NexusScaleSlider", p,
        "OptionsSliderTemplate")
    scaleSlider:SetSize(250, 16)
    scaleSlider:SetPoint("TOPLEFT", 20, -195)
    scaleSlider:SetFrameLevel(p:GetFrameLevel() + 5)
    scaleSlider:EnableMouse(true)
    pcall(function()
        scaleSlider:SetMinMaxValues(0.5, 1.6)
        scaleSlider:SetValueStep(0.02)
    end)

    local updatingDisplay = false
    local function RefreshScaleDisplay()
        if not Nexus.WishlistOverlay then return end
        local v = Nexus.WishlistOverlay.GetScale()
        updatingDisplay = true
        pcall(function() scaleSlider:SetValue(v) end)
        scaleValueText:SetText(string.format("%d%%", math.floor(v * 100 + 0.5)))
        updatingDisplay = false
    end

    scaleSlider:SetScript("OnValueChanged", function(self, value)
        if updatingDisplay then return end
        if Nexus.WishlistOverlay then Nexus.WishlistOverlay.SetScale(value) end
        RefreshScaleDisplay()
    end)
    scaleMinus:SetScript("OnClick", function()
        if Nexus.WishlistOverlay then
            Nexus.WishlistOverlay.SetScale(Nexus.WishlistOverlay.GetScale() - 0.02)
        end
        RefreshScaleDisplay()
    end)
    scalePlus:SetScript("OnClick", function()
        if Nexus.WishlistOverlay then
            Nexus.WishlistOverlay.SetScale(Nexus.WishlistOverlay.GetScale() + 0.02)
        end
        RefreshScaleDisplay()
    end)

    p:SetScript("OnShow", function(self)
        self:SetFrameStrata("TOOLTIP")
        self:SetFrameLevel(100)
        self:EnableMouse(true)
        if displayCheck and Nexus.WishlistOverlay then
            displayCheck:SetChecked(Nexus.WishlistOverlay.IsShown() == true)
            displayLockBtn:SetText(Nexus.WishlistOverlay.IsLocked()
                and "Unlock to Move" or "Lock Position")
        end
        RefreshScaleDisplay()
    end)

    p.RefreshScaleDisplay = RefreshScaleDisplay
    displayPopup = p
    return p
end

function M.ToggleDisplayPopup(anchorTo)
    local p = EnsureDisplayPopup()
    if p:IsShown() then
        p:Hide()
        return
    end
    p:ClearAllPoints()
    if anchorTo and anchorTo.IsVisible and anchorTo:IsVisible() then
        p:SetPoint("TOPRIGHT", anchorTo, "BOTTOMRIGHT", 0, -6)
    else
        p:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    p:Show()
end

function M.Init(adapter, model)
    Adapter, Model = adapter, model
end

-- Debug/test accessor only.
function M.DebugPendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end


function M.OpenForCandidate(candidate)
    pending = {}
    pendingSeeded = true
    if type(candidate) == "table" then
        for _, e in ipairs(candidate.echoes or {}) do
            local id = tonumber(e.spellId)
            if id then
                pending[id] = { spellId = id, quality = tonumber(e.quality) or 0,
                    stacks = math.max(1, tonumber(e.stacks) or 1) }
            end
        end
    end
    EnsureFrame()
    frame:Show()
    M.Refresh()
end

function M.NewWishlist()
    pending = {}
    pendingSeeded = true
    EnsureFrame()
    frame:Show()
    M.Refresh()
end

function M.Show()
    EnsureFrame()
    frame:Show()
    M.Refresh()
end

function M.Toggle()
    EnsureFrame()
    if frame:IsShown() then frame:Hide() else M.Show() end
end
