-- Nexus: ui/Panel.lua v2.12
-- Adaptive main HUD. The panel changes shape for setup, active progress,
-- completed builds, and live Echo rolls instead of showing every section
-- at all times.

Nexus = Nexus or {}
local M = {}
Nexus.Panel = M

local frame, minimapBtn, callbacks
local userHidden = false
local missingNamesCache, shedNamesCache, unknownTomesCache = {}, {}, {}

local buildHeaderText, switchBtn, wishlistMenu
local rollArea, statusText, cardTexts, recText, rollDivider = nil, nil, {}, nil, nil
local progressLabel, progressValue, needLabel, needText, needHit
local tomesLabel, tomesValue, tomesHit
local shedLabel, shedText, shedHit
local performanceLabel, setLabelText
local dummyLabel, dummyValue, dummyGlobal, dummyGlobalValue, dummyHit
local lkLabel, lkPersonalLabel, lkValue, lkGlobal, lkGlobalValue, lkHit
local completeBadge, completeSubtext
local setupText, setupHint, setupGetStartedBtn
local autoBtn, buildsBtn, leaderboardBtn, versionText

local function SafeText(v) return v ~= nil and tostring(v) or "" end

local function ShortName(v, maxChars)
    local s = SafeText(v)
    maxChars = maxChars or 30
    if #s <= maxChars then return s end
    return s:sub(1, math.max(1, maxChars - 3)) .. "..."
end

local function AutoLabel(auto)
    if auto == nil then return "Auto: --" end
    if auto then return "|cff2ee62eAuto: ON|r" end
    return "|cffe63c3cAuto: OFF|r"
end

local function FmtDps(dps)
    dps = tonumber(dps)
    if not dps or dps <= 0 then return "—" end
    if dps >= 1000000 then return string.format("%.2fM", dps / 1000000) end
    if dps >= 1000 then return string.format("%dk", math.floor(dps / 1000)) end
    return tostring(math.floor(dps))
end

local function HitFrame(parent, fs)
    local hit = CreateFrame("Frame", nil, parent)
    hit:SetAllPoints(fs)
    hit:EnableMouse(true)
    return hit
end

local function SetVisible(widget, shown)
    if not widget then return end
    if shown then widget:Show() else widget:Hide() end
end

local function SetPoint(widget, point, relative, relativePoint, x, y)
    widget:ClearAllPoints()
    widget:SetPoint(point, relative or frame, relativePoint or point, x or 0, y or 0)
end

local function AddDpsTooltip(widget, title, personal, global)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        if personal then
            GameTooltip:AddLine("Your best: " .. FmtDps(personal.dps), 0.35, 1, 0.45)
            if personal.duration then GameTooltip:AddLine("Duration: " .. tostring(personal.duration) .. "s", 0.75, 0.75, 0.75) end
        else
            GameTooltip:AddLine("No personal record for this exact loadout.", 0.65, 0.65, 0.65, true)
        end
        if global then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Global best: " .. FmtDps(global.dps), 1, 0.82, 0)
            GameTooltip:AddLine("Held by " .. tostring(global.player or "Unknown"), 0.8, 0.8, 0.8)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Records only match identical Echo IDs and stack quantities.", 0.45, 0.75, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function EnsureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "NexusPanel", UIParent)
    frame:SetSize(340, 240)
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:Hide()

    buildHeaderText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buildHeaderText:SetPoint("TOP", 0, -8)
    buildHeaderText:SetSize(314, 17)
    buildHeaderText:SetJustifyH("CENTER")
    buildHeaderText:SetTextColor(0.45, 0.84, 1)

    switchBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    switchBtn:SetSize(72, 19)
    switchBtn:SetPoint("TOP", 0, -26)
    switchBtn:SetText("Switch")
    local function HideWishlistMenu()
        if wishlistMenu then wishlistMenu:Hide() end
    end

    local function OpenEditorFor(candidate)
        local A = Nexus and Nexus.GameAdapter
        if candidate and A and A.Activate then pcall(A.Activate, candidate.slot) end
        HideWishlistMenu()
        if Nexus.WishlistEditor then
            if Nexus.WishlistEditor.OpenForCandidate then
                Nexus.WishlistEditor.OpenForCandidate(candidate)
            else
                Nexus.WishlistEditor.Show()
            end
        end
    end

    local function EnsureWishlistMenu()
        if wishlistMenu then return wishlistMenu end
        local menu = CreateFrame("Frame", "NexusWishlistMenu", frame)
        menu:SetFrameStrata("DIALOG")
        menu:SetFrameLevel(frame:GetFrameLevel() + 20)
        menu:SetWidth(260)
        menu:Hide()
        pcall(function()
            menu:SetBackdrop({
                bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
                tile=true, tileSize=16, edgeSize=12,
                insets={left=3,right=3,top=3,bottom=3},
            })
            menu:SetBackdropColor(0.025, 0.025, 0.04, 0.98)
            menu:SetBackdropBorderColor(0.35, 0.35, 0.45, 1)
        end)
        menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        menu.title:SetPoint("TOPLEFT", 12, -10)
        menu.title:SetText("Select Wishlist")
        menu.close = CreateFrame("Button", nil, menu, "UIPanelCloseButton")
        menu.close:SetPoint("TOPRIGHT", 4, 4)
        menu.rows = {}
        menu.actions = {}
        wishlistMenu = menu
        return menu
    end

    local function AddMenuButton(menu, index, text, width, onClick)
        local btn = menu.actions[index]
        if not btn then
            btn = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
            menu.actions[index] = btn
        end
        btn:SetSize(width, 21)
        btn:SetText(text)
        btn:SetScript("OnClick", onClick)
        btn:Show()
        return btn
    end

    local function RefreshWishlistMenu()
        local menu = EnsureWishlistMenu()
        local A = Nexus and Nexus.GameAdapter
        local candidates = A and A.GetWishlistCandidates and A.GetWishlistCandidates() or {}
        local y = -34
        for i = 1, math.max(#candidates, #menu.rows) do
            local row = menu.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, menu)
                row:SetSize(236, 24)
                row.pick = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.pick:SetPoint("LEFT", 0, 0)
                row.pick:SetSize(198, 22)
                row.settings = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.settings:SetPoint("LEFT", row.pick, "RIGHT", 4, 0)
                row.settings:SetSize(34, 22)
                row.settings:SetText("...")
                menu.rows[i] = row
            end
            local c = candidates[i]
            if c then
                local candidate = c
                row:SetPoint("TOPLEFT", 12, y)
                local label = ShortName(candidate.name ~= "" and candidate.name or "Unnamed wishlist", 25)
                if candidate.active then label = "|cff4dff80> |r" .. label end
                label = label .. " |cff888888(" .. tostring(candidate.count or 0) .. ")|r"
                row.pick:SetText(label)
                row.pick:SetScript("OnClick", function()
                    if A and A.Activate then pcall(A.Activate, candidate.slot) end
                    HideWishlistMenu()
                end)
                row.settings:SetScript("OnClick", function() OpenEditorFor(candidate) end)
                row.settings:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine("Wishlist settings", 1, 1, 1)
                    GameTooltip:AddLine("Activate this wishlist and open its editor.", 0.75, 0.75, 0.75, true)
                    GameTooltip:Show()
                end)
                row.settings:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row:Show()
                y = y - 26
            else
                row:Hide()
            end
        end
        if #candidates == 0 then
            menu.empty = menu.empty or menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            menu.empty:ClearAllPoints(); menu.empty:SetPoint("TOPLEFT", 14, y)
            menu.empty:SetText("No wishlist created yet.")
            menu.empty:Show(); y = y - 25
        elseif menu.empty then menu.empty:Hide() end

        local create = AddMenuButton(menu, 1, "+ New / Import", 112, function()
            HideWishlistMenu()
            if Nexus.WishlistEditor then
                if Nexus.WishlistEditor.NewWishlist then
                    Nexus.WishlistEditor.NewWishlist()
                else
                    Nexus.WishlistEditor.Show()
                end
            end
        end)
        create:ClearAllPoints(); create:SetPoint("TOPLEFT", 12, y - 3)
        local overlay = Nexus.WishlistOverlay
        local overlayShown = overlay and overlay.IsShown and overlay.IsShown()
        local toggle = AddMenuButton(menu, 2, overlayShown and "Hide Screen List" or "Show Screen List", 112, function()
            if Nexus.WishlistOverlay then Nexus.WishlistOverlay.Toggle() end
            RefreshWishlistMenu()
        end)
        toggle:ClearAllPoints(); toggle:SetPoint("LEFT", create, "RIGHT", 6, 0)
        y = y - 26
        local display = AddMenuButton(menu, 3, "On-Screen List Settings", 230, function()
            HideWishlistMenu()
            if Nexus.WishlistEditor and Nexus.WishlistEditor.ToggleDisplayPopup then
                Nexus.WishlistEditor.ToggleDisplayPopup()
            end
        end)
        display:ClearAllPoints(); display:SetPoint("TOPLEFT", 12, y - 2)
        y = y - 31
        menu:SetHeight(-y + 8)
    end

    switchBtn:SetScript("OnClick", function()
        local menu = EnsureWishlistMenu()
        if menu:IsShown() then menu:Hide(); return end
        RefreshWishlistMenu()
        menu:ClearAllPoints()
        menu:SetPoint("TOP", switchBtn, "BOTTOM", 0, -3)
        menu:Show()
    end)
    switchBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Wishlist menu", 1, 1, 1)
        GameTooltip:AddLine("Select, create, edit, or configure your on-screen wishlist.", 0.75, 0.75, 0.75, true)
        GameTooltip:Show()
    end)
    switchBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rollArea = CreateFrame("Frame", nil, frame)
    rollArea:SetPoint("TOPLEFT", 10, -52)
    rollArea:SetSize(320, 104)

    statusText = rollArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", 2, -1)
    statusText:SetSize(316, 14)
    statusText:SetJustifyH("LEFT")

    for i = 1, 3 do
        local fs = rollArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 2, -19 - (i - 1) * 14)
        fs:SetSize(316, 13)
        fs:SetJustifyH("LEFT")
        cardTexts[i] = fs
    end

    recText = rollArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recText:SetPoint("TOPLEFT", 2, -64)
    recText:SetSize(316, 30)
    recText:SetJustifyH("LEFT")
    recText:SetJustifyV("TOP")
    recText:SetTextColor(1, 0.82, 0)

    rollDivider = rollArea:CreateTexture(nil, "ARTWORK")
    rollDivider:SetSize(318, 1)
    rollDivider:SetPoint("BOTTOMLEFT", 1, 0)
    pcall(function() rollDivider:SetTexture(0.3, 0.3, 0.3, 0.65) end)

    progressLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    progressLabel:SetText("PROGRESS")
    progressValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    progressValue:SetTextColor(1, 0.5, 0.2)

    needLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    needLabel:SetText("STILL NEEDED")

    tomesLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tomesLabel:SetText("TOMES NEEDED")
    tomesLabel:SetJustifyH("RIGHT")
    tomesValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tomesValue:SetJustifyH("RIGHT")
    tomesValue:SetTextColor(1, 0.4, 0.4)
    tomesHit = CreateFrame("Frame", nil, frame)
    tomesHit:EnableMouse(true)
    tomesHit:SetScript("OnEnter", function(self)
        if #unknownTomesCache == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Tomes Needed", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("These Echoes are on your wishlist but CANNOT appear", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("in your rolls yet because you have not learned their", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("corresponding Unlearn Tome.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("This is NOT an addon error. The addon is correct.", 0.6, 1, 0.6, true)
        GameTooltip:AddLine("Obtain and use the Unlearn Tome for each Echo below", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("to unlock it. They drop from world content and vendors.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Echoes blocked by missing tomes:", 1, 0.8, 0.4)
        for i, name in ipairs(unknownTomesCache) do
            GameTooltip:AddLine("  • " .. name, 1, 0.45, 0.45)
            if i >= 25 then
                if #unknownTomesCache > i then
                    GameTooltip:AddLine("  +" .. (#unknownTomesCache - i) .. " more", 0.7, 0.7, 0.7)
                end
                break
            end
        end
        GameTooltip:Show()
    end)
    tomesHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    needText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    needText:SetSize(158, 52)
    needText:SetJustifyH("LEFT")
    needText:SetJustifyV("TOP")
    needText:SetTextColor(1, 0.5, 0.2)
    needHit = HitFrame(frame, needText)
    needHit:SetScript("OnEnter", function(self)
        if #missingNamesCache == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Still needed this run", 1, 1, 1)
        GameTooltip:AddLine("These wishlist Echoes have not been obtained yet.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("When your wishlist Echoes are not on the board,", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine("the addon picks filler. Filler is intentional —", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine("it will be replaced in a future run once your", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine("wished Echoes become available to roll.", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine(" ")
        if #missingNamesCache > 0 then
            GameTooltip:AddLine("Missing Echoes:", 1, 0.65, 0.25)
            for i, name in ipairs(missingNamesCache) do
                GameTooltip:AddLine("  • " .. name, 0.9, 0.9, 0.9)
                if i >= 25 then
                    if #missingNamesCache > 25 then
                        GameTooltip:AddLine("  +" .. (#missingNamesCache - 25) .. " more", 0.6, 0.6, 0.6)
                    end
                    break
                end
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to open Wishlist Editor", 0.4, 0.8, 1)
        GameTooltip:Show()
    end)
    needHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    needHit:SetScript("OnMouseUp", function() if Nexus.WishlistEditor then Nexus.WishlistEditor.Show() end end)

    shedLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    shedLabel:SetText("TO SHED")
    shedText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shedText:SetSize(158, 46)
    shedText:SetJustifyH("LEFT")
    shedText:SetJustifyV("TOP")
    shedText:SetTextColor(0.72, 0.52, 1)
    shedHit = HitFrame(frame, shedText)
    shedHit:SetScript("OnEnter", function(self)
        if #shedNamesCache == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Echoes to shed", 1, 1, 1)
        GameTooltip:AddLine("These Echoes are in your current loadout but are", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("NOT on your wishlist. They are filler that the", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("addon will replace as wished Echoes become available.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Locked Echoes (pinned in your build slot) are", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine("never listed here, even if off-wishlist.", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine(" ")
        for i, name in ipairs(shedNamesCache) do
            GameTooltip:AddLine("  • " .. name, 0.75, 0.6, 1)
            if i >= 25 then
                if #shedNamesCache > 25 then
                    GameTooltip:AddLine("  +" .. (#shedNamesCache - 25) .. " more", 0.6, 0.6, 0.6)
                end
                break
            end
        end
        GameTooltip:Show()
    end)
    shedHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    performanceLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    performanceLabel:SetText("PERFORMANCE")
    setLabelText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    setLabelText:SetSize(164, 14)
    setLabelText:SetJustifyH("LEFT")

    dummyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dummyLabel:SetText("Dummy Best")
    dummyValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dummyValue:SetJustifyH("RIGHT")
    dummyGlobal = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dummyGlobal:SetJustifyH("LEFT")
    dummyGlobalValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dummyGlobalValue:SetJustifyH("RIGHT")

    lkLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lkLabel:SetText("Lich King Best")
    lkPersonalLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lkPersonalLabel:SetText("Your Best")
    lkPersonalLabel:SetJustifyH("LEFT")
    lkValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lkValue:SetJustifyH("RIGHT")
    lkGlobal = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lkGlobal:SetJustifyH("LEFT")
    lkGlobalValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lkGlobalValue:SetJustifyH("RIGHT")

    dummyHit = CreateFrame("Frame", nil, frame)
    dummyHit:EnableMouse(true)
    lkHit = CreateFrame("Frame", nil, frame)
    lkHit:EnableMouse(true)

    completeBadge = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    completeBadge:SetTextColor(0.35, 1, 0.45)
    completeBadge:SetJustifyH("CENTER")
    completeSubtext = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    completeSubtext:SetJustifyH("CENTER")
    completeSubtext:SetTextColor(0.72, 0.72, 0.72)

    setupText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setupText:SetJustifyH("CENTER")
    setupText:SetTextColor(0.45, 0.84, 1)
    setupHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setupHint:SetSize(312, 34)
    setupHint:SetJustifyH("CENTER")
    setupHint:SetJustifyV("TOP")

    -- "Get Started" button shown when no wishlist is configured.
    -- Direct path to Community Builds since most new players want to
    -- browse a proven build before creating their own from scratch.
    setupGetStartedBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    setupGetStartedBtn:SetSize(160, 26)
    setupGetStartedBtn:SetText("Browse Nexus Builds")
    setupGetStartedBtn:SetScript("OnClick", function()
        if Nexus.CommunityBuilds then
            Nexus.CommunityBuilds.Show()
        end
    end)
    setupGetStartedBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Get started quickly", 1, 1, 1)
        GameTooltip:AddLine("Browse builds shared by other players.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("Copy any build to set it as your wishlist.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    setupGetStartedBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    autoBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    autoBtn:SetSize(78, 22)
    autoBtn:SetPoint("BOTTOMLEFT", 8, 7)
    autoBtn:SetText(AutoLabel(nil))
    autoBtn:SetScript("OnClick", function()
        if callbacks and type(callbacks.ToggleAuto) == "function" then
            local ok, state = pcall(callbacks.ToggleAuto)
            if ok and state ~= nil then autoBtn:SetText(AutoLabel(state and true or false)) end
        end
    end)
    autoBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Auto Mode", 1, 1, 1)
        GameTooltip:AddLine("When ON: automatically picks Echoes, banishes, and rerolls", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("based on your wishlist. The addon plays the board for you.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Filler picks are correct behavior.", 0.6, 1, 0.6, true)
        GameTooltip:AddLine("When your wished Echoes aren't on the board, the addon", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine("takes the least-harmful filler to fill your slots.", 0.75, 0.75, 0.75, true)
        GameTooltip:AddLine("It will be replaced in a future run.", 0.75, 0.75, 0.75, true)
        GameTooltip:Show()
    end)
    autoBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    leaderboardBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    leaderboardBtn:SetSize(90, 22)
    leaderboardBtn:SetPoint("LEFT", autoBtn, "RIGHT", 4, 0)
    leaderboardBtn:SetText("Leaderboard")
    leaderboardBtn:SetScript("OnClick", function() if Nexus.Leaderboard then Nexus.Leaderboard.Show() end end)
    leaderboardBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Nexus Leaderboard", 1, 1, 1)
        GameTooltip:AddLine("See the highest DPS recorded for each exact Echo loadout.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("Separate rankings for Training Dummy and Lich King.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    leaderboardBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    buildsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    buildsBtn:SetSize(106, 22)
    buildsBtn:SetPoint("LEFT", leaderboardBtn, "RIGHT", 4, 0)
    buildsBtn:SetText("Nexus Builds")
    buildsBtn:SetScript("OnClick", function() if Nexus.CommunityBuilds then Nexus.CommunityBuilds.Show() end end)
    buildsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Community Builds", 1, 1, 1)
        GameTooltip:AddLine("Browse, share, and copy exact Echo loadouts from other players.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("Syncs automatically over the local player mesh.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    buildsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    versionText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionText:SetPoint("BOTTOMRIGHT", -8, 10)
    versionText:SetJustifyH("RIGHT")

    pcall(function()
        frame:SetBackdrop({
            bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=16, edgeSize=12,
            insets={left=3,right=3,top=3,bottom=3},
        })
        frame:SetBackdropColor(0.035, 0.035, 0.05, 0.94)
        frame:SetBackdropBorderColor(0.28, 0.28, 0.34, 0.9)
    end)

    return frame
end

local function EnsureMinimapButton()
    if minimapBtn then return minimapBtn end
    NexusDB = NexusDB or {}
    NexusDB.minimapAngle = NexusDB.minimapAngle or 220

    local btn = CreateFrame("Button", "NexusMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20); icon:SetPoint("CENTER"); icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    pcall(function()
        local border = btn:CreateTexture(nil, "OVERLAY")
        border:SetSize(54,54); border:SetPoint("TOPLEFT",-3,3); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    end)

    local function Reposition()
        local angle = math.rad(NexusDB.minimapAngle or 220)
        local r = 80
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(angle), r * math.sin(angle))
    end
    Reposition()

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            NexusDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            Reposition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" and Nexus.WishlistEditor then Nexus.WishlistEditor.Show() else M.Toggle() end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff7fd5ffNexus|r")
        GameTooltip:AddLine("Echo build automation · Community Builds · DPS Leaderboard", 0.6,0.8,1,true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: HUD  |  Right-click: Wishlists  |  Drag to reposition", 0.7,0.7,0.7,true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapBtn = btn
    return btn
end

local function PositionPerformance(topY, completed)
    if completed then
        -- Compact centered record table, modeled after the original HUD.
        -- Encounter headings anchor each pair and every value gets its own
        -- column, so matching personal/global numbers remain unambiguous.
        local left, width = 60, 220
        local labelW, valueW = 128, 92

        SetPoint(performanceLabel, "TOP", frame, "TOP", 0, topY)
        performanceLabel:SetSize(width, 13)
        performanceLabel:SetJustifyH("CENTER")

        SetPoint(dummyLabel, "TOPLEFT", frame, "TOPLEFT", left, topY - 21)
        dummyLabel:SetSize(labelW, 14); dummyLabel:SetJustifyH("LEFT")
        SetPoint(dummyValue, "TOPLEFT", frame, "TOPLEFT", left + labelW, topY - 21)
        dummyValue:SetSize(valueW, 14); dummyValue:SetJustifyH("RIGHT")
        SetPoint(dummyGlobal, "TOPLEFT", frame, "TOPLEFT", left, topY - 41)
        dummyGlobal:SetSize(labelW, 14); dummyGlobal:SetJustifyH("LEFT")
        SetPoint(dummyGlobalValue, "TOPLEFT", frame, "TOPLEFT", left + labelW, topY - 41)
        dummyGlobalValue:SetSize(valueW, 14); dummyGlobalValue:SetJustifyH("RIGHT")

        SetPoint(lkPersonalLabel, "TOP", frame, "TOP", 0, topY - 70)
        lkPersonalLabel:SetSize(width, 13); lkPersonalLabel:SetJustifyH("CENTER")
        SetPoint(lkLabel, "TOPLEFT", frame, "TOPLEFT", left, topY - 91)
        lkLabel:SetSize(labelW, 14); lkLabel:SetJustifyH("LEFT")
        SetPoint(lkValue, "TOPLEFT", frame, "TOPLEFT", left + labelW, topY - 91)
        lkValue:SetSize(valueW, 14); lkValue:SetJustifyH("RIGHT")
        SetPoint(lkGlobal, "TOPLEFT", frame, "TOPLEFT", left, topY - 111)
        lkGlobal:SetSize(labelW, 14); lkGlobal:SetJustifyH("LEFT")
        SetPoint(lkGlobalValue, "TOPLEFT", frame, "TOPLEFT", left + labelW, topY - 111)
        lkGlobalValue:SetSize(valueW, 14); lkGlobalValue:SetJustifyH("RIGHT")
    else
        local left, width = 174, 154
        SetPoint(performanceLabel, "TOPLEFT", frame, "TOPLEFT", left, topY)
        performanceLabel:SetSize(width, 13)
        performanceLabel:SetJustifyH("LEFT")
        SetPoint(setLabelText, "TOPLEFT", frame, "TOPLEFT", left, topY - 15)
        setLabelText:SetSize(width, 13)
        setLabelText:SetJustifyH("LEFT")

        local labelW, valueW = 92, 62
        SetPoint(dummyLabel, "TOPLEFT", frame, "TOPLEFT", left, topY - 38)
        dummyLabel:SetSize(labelW, 14); dummyLabel:SetJustifyH("LEFT")
        SetPoint(dummyValue, "TOPLEFT", frame, "TOPLEFT", left + labelW, topY - 38)
        dummyValue:SetSize(valueW, 14); dummyValue:SetJustifyH("RIGHT")
        SetPoint(dummyGlobal, "TOPLEFT", frame, "TOPLEFT", left, topY - 57)
        dummyGlobal:SetSize(width, 14); dummyGlobal:SetJustifyH("RIGHT")

        SetPoint(lkLabel, "TOPLEFT", frame, "TOPLEFT", left, topY - 80)
        lkLabel:SetSize(labelW, 14); lkLabel:SetJustifyH("LEFT")
        SetPoint(lkValue, "TOPLEFT", frame, "TOPLEFT", left + labelW, topY - 80)
        lkValue:SetSize(valueW, 14); lkValue:SetJustifyH("RIGHT")
        SetPoint(lkGlobal, "TOPLEFT", frame, "TOPLEFT", left, topY - 99)
        lkGlobal:SetSize(width, 14); lkGlobal:SetJustifyH("RIGHT")
    end

    dummyHit:ClearAllPoints()
    dummyHit:SetPoint("TOPLEFT", dummyLabel, "TOPLEFT", 0, 2)
    dummyHit:SetPoint("BOTTOMRIGHT", completed and dummyGlobalValue or dummyGlobal, "BOTTOMRIGHT", 0, -2)
    lkHit:ClearAllPoints()
    lkHit:SetPoint("TOPLEFT", completed and lkPersonalLabel or lkLabel, "TOPLEFT", 0, 2)
    lkHit:SetPoint("BOTTOMRIGHT", completed and lkGlobalValue or lkGlobal, "BOTTOMRIGHT", 0, -2)
end

local function RenderPerformance(pr, completed)
    local D = Nexus.DpsCapture
    local echoes = pr.dpsEchoes
    local myDummy, myLK, topDummy, topLK
    if D and type(echoes) == "table" then
        myDummy = D.GetPersonalBestForEchoes and D.GetPersonalBestForEchoes(echoes, "dummy") or nil
        myLK = D.GetPersonalBestForEchoes and D.GetPersonalBestForEchoes(echoes, "lk") or nil
        local dRows = D.GetLeaderboardForEchoes and D.GetLeaderboardForEchoes(echoes, "dummy") or {}
        local lRows = D.GetLeaderboardForEchoes and D.GetLeaderboardForEchoes(echoes, "lk") or {}
        topDummy, topLK = dRows and dRows[1], lRows and lRows[1]
    end

    local count = tonumber(pr.total) or 0
    if completed then
        performanceLabel:SetText("TRAINING DUMMY")
        setLabelText:SetText("")
        dummyLabel:SetText("Your Best")
        dummyGlobal:SetText("Global Best")
        lkPersonalLabel:SetText("LICH KING")
        lkLabel:SetText("Your Best")
        lkGlobal:SetText("Global Best")
    else
        performanceLabel:SetText("PERFORMANCE")
        setLabelText:SetText("Target build · " .. count .. " Echoes")
        dummyLabel:SetText("Your Dummy")
        lkLabel:SetText("Your Lich King")
    end
    dummyValue:SetText(myDummy and ("|cff4dff80" .. FmtDps(myDummy.dps) .. "|r") or "|cff777777—|r")
    lkValue:SetText(myLK and ("|cff4dff80" .. FmtDps(myLK.dps) .. "|r") or "|cff777777—|r")
    if completed then
        dummyGlobalValue:SetText(topDummy and ("|cffffd200" .. FmtDps(topDummy.dps) .. "|r") or "|cff777777—|r")
        lkGlobalValue:SetText(topLK and ("|cffffd200" .. FmtDps(topLK.dps) .. "|r") or "|cff777777—|r")
    else
        dummyGlobal:SetText(topDummy and ("Global  |cffffd200" .. FmtDps(topDummy.dps) .. "|r") or "Global  —")
        lkGlobal:SetText(topLK and ("Global  |cffffd200" .. FmtDps(topLK.dps) .. "|r") or "Global  —")
    end

    AddDpsTooltip(dummyHit, "Training Dummy", myDummy, topDummy)
    AddDpsTooltip(lkHit, "Lich King", myLK, topLK)
end

local function ShowCoreProgress(show)
    SetVisible(progressLabel, show); SetVisible(progressValue, show)
    SetVisible(needLabel, show); SetVisible(needText, show); SetVisible(needHit, show)
    local showTomes = show and #unknownTomesCache > 0
    SetVisible(tomesLabel, showTomes); SetVisible(tomesValue, showTomes); SetVisible(tomesHit, showTomes)
    SetVisible(shedLabel, show); SetVisible(shedText, show); SetVisible(shedHit, show)
end

local function ShowPerformance(show)
    SetVisible(performanceLabel, show); SetVisible(setLabelText, show)
    SetVisible(dummyLabel, show); SetVisible(dummyValue, show); SetVisible(dummyGlobal, show); SetVisible(dummyGlobalValue, show); SetVisible(dummyHit, show)
    SetVisible(lkLabel, show); SetVisible(lkPersonalLabel, show); SetVisible(lkValue, show); SetVisible(lkGlobal, show); SetVisible(lkGlobalValue, show); SetVisible(lkHit, show)
end

function M.Init(cb)
    if cb ~= nil then callbacks = cb end
    pcall(EnsureMinimapButton)
end

function M.SetAuto(auto)
    if autoBtn then autoBtn:SetText(AutoLabel(auto and true or false)) end
end

function M.Toggle()
    local f = EnsureFrame()
    if f:IsShown() then f:Hide(); userHidden = true else f:Show(); userHidden = false end
end

function M.Render(model)
    if type(model) ~= "table" then return end
    EnsureFrame()

    local pr = type(model.progress) == "table" and model.progress or {}
    local name = pr.wishlistName
    local total = tonumber(pr.total) or 0
    local owned = tonumber(pr.owned) or 0
    local complete = total > 0 and owned >= total
    local cards = type(model.cards) == "table" and model.cards or {}
    local recommendation = SafeText(model.recommendation)
    local activeRoll = #cards > 0 or recommendation ~= ""
    local noBuild = total <= 0 or not name

    buildHeaderText:SetText(name and ("|cff7fd5ff" .. ShortName(name, 34) .. "|r" .. (pr.isCommunityPreview and " |cff888888[Preview]|r" or "")) or "|cff7fd5ffNexus|r")
    switchBtn:SetText(noBuild and "Choose" or "Switch")

    SetVisible(rollArea, activeRoll)
    if activeRoll then
        local activeSlot = tonumber(pr.activeSlot) or 0
        statusText:SetText(activeSlot > 0 and ("|cff4dff80●|r Roll recommendations active — Slot " .. activeSlot) or "|cff888888○ Roll recommendation preview|r")
        for i = 1, 3 do
            local c = cards[i]
            cardTexts[i]:SetText(type(c) == "table" and SafeText(c.text) or "")
        end
        recText:SetText(recommendation)
    end

    missingNamesCache = type(pr.missing) == "table" and pr.missing or {}
    shedNamesCache = type(pr.shed) == "table" and pr.shed or {}
    unknownTomesCache = type(pr.unknownTomes) == "table" and pr.unknownTomes or {}

    SetVisible(setupText, noBuild); SetVisible(setupHint, noBuild)
    SetVisible(setupGetStartedBtn, noBuild)
    SetVisible(completeBadge, complete and not noBuild); SetVisible(completeSubtext, complete and not noBuild)
    ShowCoreProgress(not noBuild and not complete)
    ShowPerformance(not noBuild)

    local contentTop = activeRoll and -166 or -58

    if noBuild then
        SetVisible(dummyGlobalValue, false)
        SetVisible(lkGlobalValue, false)
        frame:SetHeight(activeRoll and 258 or 172)
        SetPoint(setupText, "TOP", frame, "TOP", 0, contentTop - 18)
        setupText:SetText("Choose a build to track")
        SetPoint(setupHint, "TOP", frame, "TOP", 0, contentTop - 48)
        setupHint:SetText("Nexus tracks your progress, automates your Echo board, and records DPS for your exact loadout.")
        SetPoint(setupGetStartedBtn, "TOP", frame, "TOP", 0, contentTop - 100)
        setupGetStartedBtn:SetPoint("CENTER", frame, "CENTER", 0, contentTop > -58 and -80 or -60)
    elseif complete then
        frame:SetHeight(activeRoll and 348 or 242)
        SetPoint(completeBadge, "TOP", frame, "TOP", 0, contentTop)
        completeBadge:SetSize(320, 14)
        completeBadge:SetJustifyH("CENTER")
        completeBadge:SetText("WISHLIST COMPLETE  |cffb8b8b8·  " .. owned .. " / " .. total .. "|r")
        SetVisible(completeSubtext, false)
        PositionPerformance(contentTop - 25, true)
        SetVisible(setLabelText, false)
        SetVisible(lkPersonalLabel, true)
        SetVisible(dummyGlobalValue, true)
        SetVisible(lkGlobalValue, true)
    else
        SetVisible(dummyGlobalValue, false)
        SetVisible(lkGlobalValue, false)
        SetVisible(setLabelText, true)
        frame:SetHeight(activeRoll and 346 or 240)
        SetPoint(progressLabel, "TOPLEFT", frame, "TOPLEFT", 12, contentTop)
        SetPoint(progressValue, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 17)
        progressValue:SetText(string.format("%d / %d complete", owned, total))

        SetPoint(needLabel, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 42)
        needLabel:SetText("STILL NEEDED")

        if #unknownTomesCache > 0 then
            SetPoint(tomesLabel, "TOPLEFT", frame, "TOPLEFT", 104, contentTop - 42)
            tomesLabel:SetSize(64, 12)
            tomesLabel:SetJustifyH("LEFT")
            SetPoint(tomesValue, "TOPLEFT", frame, "TOPLEFT", 104, contentTop - 56)
            tomesValue:SetSize(64, 14)
            tomesValue:SetJustifyH("LEFT")
            tomesValue:SetText(tostring(#unknownTomesCache))
            tomesLabel:SetTextColor(0.85, 0.7, 0.55)
            tomesValue:SetTextColor(1, 0.4, 0.4)
            tomesHit:ClearAllPoints()
            tomesHit:SetPoint("TOPLEFT", tomesLabel, "TOPLEFT", -2, 2)
            tomesHit:SetPoint("BOTTOMRIGHT", tomesValue, "BOTTOMRIGHT", 2, -2)
            tomesHit:Show()
            needText:SetWidth(88)
        else
            tomesLabel:Hide()
            tomesValue:Hide()
            tomesHit:Hide()
            needText:SetWidth(156)
        end

        SetPoint(needText, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 58)
        local needLines = {}
        local shown = math.min(#missingNamesCache, 2)
        for i = 1, shown do needLines[#needLines + 1] = missingNamesCache[i] end
        if #missingNamesCache > shown then needLines[#needLines + 1] = "+" .. (#missingNamesCache - shown) .. " more" end
        needText:SetText(#needLines > 0 and table.concat(needLines, "\n") or "|cff888888No remaining demand|r")

        SetPoint(shedLabel, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 108)
        SetPoint(shedText, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 124)
        local shedLines = {}
        local shedShown = math.min(#shedNamesCache, 2)
        for i = 1, shedShown do shedLines[#shedLines + 1] = shedNamesCache[i] end
        if #shedNamesCache > shedShown then shedLines[#shedLines + 1] = "+" .. (#shedNamesCache - shedShown) .. " more" end
        shedText:SetText(#shedLines > 0 and table.concat(shedLines, "\n") or "|cff888888None|r")

        PositionPerformance(contentTop, false)
        SetVisible(lkPersonalLabel, false)
    end

    if not noBuild then RenderPerformance(pr, complete) end
    autoBtn:SetText(AutoLabel(model.auto))
    versionText:SetText(SafeText(model.version))
    if not userHidden then frame:Show() end
end

function M.Show() userHidden = false; EnsureFrame():Show() end
function M.Hide() if frame then frame:Hide() end; userHidden = true end
function M.IsShown() return frame and frame:IsShown() or false end

return M
