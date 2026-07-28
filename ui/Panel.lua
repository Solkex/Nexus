-- Nexus: ui/Panel.lua v2.13
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
local setupText, setupHint, setupGetStartedBtn, setupImportBtn
local autoBtn, buildsBtn, leaderboardBtn, menuBtn, versionText, worldStatusBox, worldStatusText, worldStatusAsh, worldStatusGain, worldStatusHit, bestDpsText, bestDpsHit
local showPerformance = false

local function SafeText(v) return v ~= nil and tostring(v) or "" end

local function FrameLevelOf(widget)
    local getter = widget and widget.GetFrameLevel
    if type(getter) == "function" then
        local ok, value = pcall(getter, widget)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return 0
end

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

local function CloseOtherNexusWindows(exceptName)
    local names = {
        "NexusCommunityBuildsFrame", "NexusLeaderboardFrame", "NexusEditorFrame",
        "NexusLogViewer", "NexusQuickStart", "NexusChangelogPopup",
        "ProjectEbonholdEchoJournal",
    }
    for i = 1, #names do
        local f = _G[names[i]]
        if names[i] ~= exceptName and f and f.Hide then pcall(f.Hide, f) end
    end
    if _G.DropDownList1 and _G.DropDownList1.Hide then pcall(_G.DropDownList1.Hide, _G.DropDownList1) end
    if _G.DropDownList2 and _G.DropDownList2.Hide then pcall(_G.DropDownList2.Hide, _G.DropDownList2) end
end

function M.CloseOtherWindows(exceptName)
    CloseOtherNexusWindows(exceptName)
end

local function EnsureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "NexusPanel", UIParent)
    frame:SetSize(300, 210)
    frame:SetClampedToScreen(true)
    NexusDB = NexusDB or {}
    if tonumber(NexusDB.panelX) and tonumber(NexusDB.panelY) then
        frame:SetPoint("CENTER", UIParent, "CENTER", NexusDB.panelX, NexusDB.panelY)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if x and y and ux and uy then
            NexusDB.panelX, NexusDB.panelY = math.floor(x - ux + 0.5), math.floor(y - uy + 0.5)
        end
    end)
    frame:Hide()

    buildHeaderText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buildHeaderText:SetPoint("TOP", 0, -8)
    buildHeaderText:SetSize(274, 17)
    buildHeaderText:SetJustifyH("CENTER")
    buildHeaderText:SetTextColor(0.45, 0.84, 1)

    switchBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    switchBtn:SetSize(90, 19)
    switchBtn:SetPoint("TOPLEFT", 10, -26)
    switchBtn:SetText("Swap Build")
    switchBtn:SetScript("OnClick", function()
        CloseOtherNexusWindows()
        if Nexus.JournalTab and Nexus.JournalTab.OpenBuilds then
            Nexus.JournalTab.OpenBuilds()
        else
            local pe = _G["ProjectEbonhold"]
            if pe and pe.EchoJournal and pe.EchoJournal.Show then
                pcall(pe.EchoJournal.Show, pe.EchoJournal)
            end
        end
    end)
    switchBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Swap Build", 1, 1, 1)
        GameTooltip:AddLine("Open Loadouts. Select a saved build normally, then assign the wishlist Nexus should progress for it.", 0.75, 0.75, 0.75, true)
        GameTooltip:Show()
    end)
    switchBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Clickable compact replacement for Project Ebonhold's difficulty / Soul
    -- Ash HUD. In-progress builds use a slim header treatment. Completed builds
    -- expand this into the primary status card so the familiar server metrics
    -- remain the most visible information.
    worldStatusBox = CreateFrame("Frame", nil, frame)
    worldStatusBox:SetFrameLevel(FrameLevelOf(frame) + 3)
    pcall(function()
        worldStatusBox:SetBackdrop({
            bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=16, edgeSize=10,
            insets={left=2,right=2,top=2,bottom=2},
        })
        worldStatusBox:SetBackdropColor(0.018, 0.035, 0.045, 0.96)
        worldStatusBox:SetBackdropBorderColor(0.16, 0.34, 0.40, 0.9)
    end)

    worldStatusText = worldStatusBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    worldStatusText:SetJustifyH("LEFT")
    worldStatusText:SetText("")

    worldStatusAsh = worldStatusBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    worldStatusAsh:SetJustifyH("LEFT")
    worldStatusAsh:SetText("")

    worldStatusGain = worldStatusBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    worldStatusGain:SetJustifyH("RIGHT")
    worldStatusGain:SetText("")

    worldStatusHit = CreateFrame("Button", nil, worldStatusBox)
    worldStatusHit:SetAllPoints(worldStatusBox)
    worldStatusHit:SetFrameLevel(FrameLevelOf(worldStatusBox) + 5)
    worldStatusHit:RegisterForClicks("LeftButtonUp")
    local statusHighlight = worldStatusHit:CreateTexture(nil, "HIGHLIGHT")
    statusHighlight:SetAllPoints()
    pcall(function() statusHighlight:SetTexture(1, 1, 1, 0.06) end)
    worldStatusHit:SetScript("OnClick", function()
        if Nexus.ServerStatus and Nexus.ServerStatus.OpenHardcoreMenu then
            Nexus.ServerStatus.OpenHardcoreMenu()
        end
    end)
    worldStatusHit:SetScript("OnEnter", function(self)
        local ss = Nexus.ServerStatus and Nexus.ServerStatus.GetSummary and Nexus.ServerStatus.GetSummary() or {}
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(ss.tier or ss.mode or "Difficulty", 1, 0.25, 0.25)
        if ss.ash then GameTooltip:AddLine("Soul Ash: " .. tostring(ss.ash):gsub(",",""), 1, 1, 1) end
        if ss.gain then GameTooltip:AddLine("Soul Ash Multiplier: " .. tostring(ss.gain), 0.2, 1, 0.2) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to open the Hardcore difficulty panel.", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    worldStatusHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    worldStatusBox:Hide()

    rollArea = CreateFrame("Frame", nil, frame)
    rollArea:SetPoint("TOPLEFT", 10, -52)
    rollArea:SetSize(280, 104)

    statusText = rollArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", 2, -1)
    statusText:SetSize(276, 14)
    statusText:SetJustifyH("LEFT")

    for i = 1, 3 do
        local fs = rollArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 2, -19 - (i - 1) * 14)
        fs:SetSize(276, 13)
        fs:SetJustifyH("LEFT")
        cardTexts[i] = fs
    end

    recText = rollArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recText:SetPoint("TOPLEFT", 2, -64)
    recText:SetSize(276, 30)
    recText:SetJustifyH("LEFT")
    recText:SetJustifyV("TOP")
    recText:SetTextColor(1, 0.82, 0)

    rollDivider = rollArea:CreateTexture(nil, "ARTWORK")
    rollDivider:SetSize(278, 1)
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
    needText:SetSize(136, 52)
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
                -- Split "Echo Name ×N (Quality:×N ...)" into label and detail
                local label, detail = name:match("^(.-)%s+(%b())$")
                if label and detail then
                    GameTooltip:AddLine("  • " .. label, 0.9, 0.9, 0.9)
                    -- Strip outer parens and show quality breakdown indented
                    local inner = detail:sub(2, -2)
                    GameTooltip:AddLine("      " .. inner, 0.7, 0.7, 0.7)
                else
                    GameTooltip:AddLine("  • " .. name, 0.9, 0.9, 0.9)
                end
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
    shedText:SetSize(136, 46)
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
    setupHint:SetSize(272, 34)
    setupHint:SetJustifyH("CENTER")
    setupHint:SetJustifyV("TOP")

    -- "Get Started" button shown when no wishlist is configured.
    -- Direct path to Community Builds since most new players want to
    -- browse a proven build before creating their own from scratch.
    setupGetStartedBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    setupGetStartedBtn:SetSize(126, 24)
    setupGetStartedBtn:SetText("Browse Builds")
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

    setupImportBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    setupImportBtn:SetSize(126, 24)
    setupImportBtn:SetText("Import / Create")
    setupImportBtn:SetScript("OnClick", function()
        CloseOtherNexusWindows()
        if Nexus.WishlistEditor then Nexus.WishlistEditor.Show() end
    end)
    setupImportBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Import or create a wishlist", 1, 1, 1)
        GameTooltip:AddLine("Paste a wishlist string or build one directly in Nexus.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    setupImportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    leaderboardBtn:SetSize(104, 22)
    leaderboardBtn:SetPoint("LEFT", autoBtn, "RIGHT", 5, 0)
    leaderboardBtn:SetText("Leaderboard")
    leaderboardBtn:SetScript("OnClick", function()
        CloseOtherNexusWindows()
        if Nexus.Leaderboard then Nexus.Leaderboard.Show() end
    end)
    leaderboardBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Leaderboard", 1, 1, 1)
        GameTooltip:AddLine("Compare personal and global records for exact Echo builds.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    leaderboardBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    menuBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    menuBtn:SetSize(82, 22)
    menuBtn:SetPoint("LEFT", leaderboardBtn, "RIGHT", 5, 0)
    menuBtn:SetText("More")
    menuBtn:SetScript("OnClick", function(self)
        if type(EasyMenu) ~= "function" then return end
        NexusDB = NexusDB or {}
        local items = {
            {
                text = showPerformance and "Hide Performance" or "Show Performance",
                notCheckable = true,
                func = function()
                    showPerformance = not showPerformance
                    NexusDB.uiShowPerformance = showPerformance
                    if M.Refresh then M.Refresh() end
                end,
            },

            {
                text = "Wishlist Editor",
                notCheckable = true,
                func = function() CloseOtherNexusWindows(); if Nexus.WishlistEditor then Nexus.WishlistEditor.Show() end end,
            },
            {
                text = (Nexus.ServerStatus and Nexus.ServerStatus.IsUsingNexusHud and Nexus.ServerStatus.IsUsingNexusHud())
                    and "Use Server Difficulty / Soul Ash HUD" or "Use Nexus Difficulty / Soul Ash HUD",
                notCheckable = true,
                disabled = not (Nexus.ServerStatus and Nexus.ServerStatus.IsDetected and Nexus.ServerStatus.IsDetected()),
                func = function()
                    if Nexus.ServerStatus then
                        Nexus.ServerStatus.SetMode(Nexus.ServerStatus.IsUsingNexusHud() and "server" or "nexus")
                    end
                end,
            },
            {
                text = "Reset Panel Position",
                notCheckable = true,
                func = function()
                    NexusDB.panelX, NexusDB.panelY = nil, nil
                    frame:ClearAllPoints()
                    frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
                end,
            },
            {
                text = "Hide Nexus Panel",
                notCheckable = true,
                func = function() M.Hide() end,
            },
        }
        M._moreMenu = M._moreMenu or CreateFrame("Frame", "NexusPanelMoreMenu", UIParent, "UIDropDownMenuTemplate")
        EasyMenu(items, M._moreMenu, self, 0, 0, "MENU")
    end)
    menuBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("More", 1, 1, 1)
        GameTooltip:AddLine("Performance display, builds, wishlists, Soul Ash HUD, and panel controls.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    menuBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    bestDpsText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bestDpsText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 33)
    bestDpsText:SetSize(280, 14)
    bestDpsText:SetJustifyH("CENTER")
    bestDpsText:SetText("|cff888888Best DPS: hit a training dummy to record|r")
    bestDpsHit = HitFrame(frame, bestDpsText)
    bestDpsHit:SetScript("OnEnter", function(self)
        local info = Nexus.DpsCapture and Nexus.DpsCapture.GetPlayerInfo and Nexus.DpsCapture.GetPlayerInfo(UnitName("player"))
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Character Best DPS", 1, 1, 1)
        if info then
            GameTooltip:AddLine(FmtDps(info.dps) .. " DPS · " .. (info.category == "lk" and "Lich King" or "Training Dummy"), 0.35, 1, 0.45)
            if info.title then GameTooltip:AddLine(info.title, 0.65, 0.85, 1) end
        else
            GameTooltip:AddLine("No recorded DPS yet.", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Fight a training dummy for at least 10 seconds to establish your first record.", 0.9, 0.9, 0.9, true)
        end
        GameTooltip:Show()
    end)
    bestDpsHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    versionText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionText:Hide() -- version remains in /nexus and tooltips; avoids bottom-row overlap

    NexusDB = NexusDB or {}
    showPerformance = NexusDB.uiShowPerformance == true

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
        GameTooltip:AddLine("|cff7fd5ffNexus|r  |cff888888" .. SafeText(Nexus.VERSION) .. "|r")
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
        local left, width = 154, 134
        SetPoint(performanceLabel, "TOPLEFT", frame, "TOPLEFT", left, topY)
        performanceLabel:SetSize(width, 13)
        performanceLabel:SetJustifyH("LEFT")
        SetPoint(setLabelText, "TOPLEFT", frame, "TOPLEFT", left, topY - 15)
        setLabelText:SetSize(width, 13)
        setLabelText:SetJustifyH("LEFT")

        local labelW, valueW = 78, 56
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

local function LayoutServerStatus(completed)
    worldStatusBox:ClearAllPoints()
    worldStatusText:ClearAllPoints()
    worldStatusAsh:ClearAllPoints()
    worldStatusGain:ClearAllPoints()

    if completed then
        worldStatusBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -33)
        worldStatusBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -33)
        worldStatusBox:SetHeight(44)

        worldStatusText:SetPoint("TOPLEFT", worldStatusBox, "TOPLEFT", 9, -5)
        worldStatusText:SetSize(155, 17)
        worldStatusText:SetJustifyH("LEFT")

        worldStatusAsh:SetPoint("BOTTOMLEFT", worldStatusBox, "BOTTOMLEFT", 9, 5)
        worldStatusAsh:SetSize(180, 17)
        worldStatusAsh:SetJustifyH("LEFT")

        worldStatusGain:SetPoint("BOTTOMRIGHT", worldStatusBox, "BOTTOMRIGHT", -9, 6)
        worldStatusGain:SetSize(66, 13)
        worldStatusGain:SetJustifyH("RIGHT")
    else
        worldStatusBox:SetPoint("TOPLEFT", switchBtn, "TOPRIGHT", 5, 3)
        worldStatusBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -23)
        worldStatusBox:SetHeight(22)

        worldStatusText:SetPoint("LEFT", worldStatusBox, "LEFT", 6, 0)
        worldStatusText:SetSize(48, 16)
        worldStatusText:SetJustifyH("LEFT")

        worldStatusAsh:SetPoint("LEFT", worldStatusText, "RIGHT", 3, 0)
        worldStatusAsh:SetPoint("RIGHT", worldStatusGain, "LEFT", -3, 0)
        worldStatusAsh:SetHeight(16)
        worldStatusAsh:SetJustifyH("LEFT")

        worldStatusGain:SetPoint("RIGHT", worldStatusBox, "RIGHT", -6, 0)
        worldStatusGain:SetSize(54, 14)
        worldStatusGain:SetJustifyH("RIGHT")
    end
end

function M.Render(model)
    if type(model) ~= "table" then return end
    M._lastModel = model
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

    buildHeaderText:SetText(name and ("|cff7fd5ff" .. ShortName(name, 28) .. "|r" .. (pr.isCommunityPreview and " |cff888888[Preview]|r" or "")) or "|cff7fd5ffNexus|r")
    switchBtn:SetText("Swap Build")

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
    SetVisible(setupGetStartedBtn, noBuild); SetVisible(setupImportBtn, noBuild)
    SetVisible(completeBadge, complete and not noBuild); SetVisible(completeSubtext, complete and not noBuild)
    ShowCoreProgress(not noBuild and not complete)
    ShowPerformance(not noBuild and showPerformance)

    local contentTop = activeRoll and -166 or -58

    if not complete then
        switchBtn:ClearAllPoints()
        switchBtn:SetPoint("TOPLEFT", 10, -26)
        switchBtn:SetSize(90, 19)
    end

    if noBuild then
        SetVisible(dummyGlobalValue, false)
        SetVisible(lkGlobalValue, false)
        frame:SetHeight(activeRoll and 332 or 218)
        SetPoint(setupText, "TOP", frame, "TOP", 0, contentTop - 18)
        setupText:SetText("Set up your build")
        SetPoint(setupHint, "TOP", frame, "TOP", 0, contentTop - 48)
        setupHint:SetText("Use your finished build, import a wishlist, or copy a proven community build.")
        setupGetStartedBtn:ClearAllPoints()
        setupGetStartedBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, contentTop - 94)
        setupImportBtn:ClearAllPoints()
        setupImportBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, contentTop - 94)
    elseif complete then
        -- Once a build is complete, progress text stops being the purpose of the
        -- HUD. The panel becomes a compact replacement for the stock difficulty /
        -- Soul Ash tracker, with Nexus navigation and the player's best DPS.
        frame:SetHeight(showPerformance and (activeRoll and 382 or 274) or (activeRoll and 236 or 146))
        SetVisible(completeBadge, false)
        SetVisible(completeSubtext, false)
        switchBtn:ClearAllPoints()
        switchBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -7)
        switchBtn:SetSize(82, 19)
        if showPerformance then PositionPerformance(activeRoll and -214 or -106, true) end
        SetVisible(setLabelText, false)
        SetVisible(lkPersonalLabel, true)
        SetVisible(dummyGlobalValue, true)
        SetVisible(lkGlobalValue, true)
    else
        SetVisible(dummyGlobalValue, false)
        SetVisible(lkGlobalValue, false)
        SetVisible(setLabelText, true)
        frame:SetHeight(showPerformance and (activeRoll and 388 or 280) or (activeRoll and 328 or 222))
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
            needText:SetWidth(136)
        end

        SetPoint(needText, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 58)
        local needLines = {}
        local shown = math.min(#missingNamesCache, 2)
        for i = 1, shown do
            -- Strip " (Poor:×N Common:×N ...)" from HUD label — quality
            -- breakdown is in the tooltip on mouseover instead.
            needLines[#needLines + 1] = missingNamesCache[i]:gsub("%s+%b()", "")
        end
        if #missingNamesCache > shown then needLines[#needLines + 1] = "+" .. (#missingNamesCache - shown) .. " more" end
        needText:SetText(#needLines > 0 and table.concat(needLines, "\n") or "|cff888888No remaining demand|r")

        if showPerformance then
            SetPoint(shedLabel, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 108)
            SetPoint(shedText, "TOPLEFT", frame, "TOPLEFT", 12, contentTop - 124)
            shedText:SetWidth(136)
        else
            SetPoint(shedLabel, "TOPLEFT", frame, "TOPLEFT", 154, contentTop - 42)
            SetPoint(shedText, "TOPLEFT", frame, "TOPLEFT", 154, contentTop - 58)
            shedText:SetWidth(134)
        end
        local shedLines = {}
        local shedShown = math.min(#shedNamesCache, 2)
        for i = 1, shedShown do shedLines[#shedLines + 1] = shedNamesCache[i] end
        if #shedNamesCache > shedShown then shedLines[#shedLines + 1] = "+" .. (#shedNamesCache - shedShown) .. " more" end
        shedText:SetText(#shedLines > 0 and table.concat(shedLines, "\n") or "|cff888888None|r")

        if showPerformance then PositionPerformance(contentTop, false) end
        SetVisible(lkPersonalLabel, false)
    end

    if not noBuild then RenderPerformance(pr, complete) end

    local usingNexusStatus = Nexus.ServerStatus and Nexus.ServerStatus.IsUsingNexusHud and Nexus.ServerStatus.IsUsingNexusHud()
    local ss = usingNexusStatus and Nexus.ServerStatus.GetSummary and Nexus.ServerStatus.GetSummary() or nil
    LayoutServerStatus(complete and not noBuild)
    if ss and (ss.tier or ss.mode or ss.ash or ss.gain) then
        local difficulty = ss.tier or ss.mode or "Difficulty"
        -- Parse and format the ash number for compact display
        local function FmtAsh(raw)
            if not raw then return "—" end
            local stripped = tostring(raw):gsub(",", "")
            local n = tonumber(stripped)
            if not n then return tostring(raw) end
            if n >= 1000000 then
                local m = n / 1000000
                local ms = string.format("%.1f", m); return (ms:match("%.0$") and ms:gsub("%.0$","") or ms) .. "M"
            elseif n >= 1000 then
                local k = n / 1000
                local ks = string.format("%.1f", k); return (ks:match("%.0$") and ks:gsub("%.0$","") or ks) .. "k"
            end
            return tostring(math.floor(n))
        end
        local ashFmt = FmtAsh(ss.ash)
        -- Tooltip keeps full unformatted value
        local ashFull = ss.ash and tostring(ss.ash):gsub(",","") or "—"
        worldStatusText:SetText("|cffff6b5f" .. difficulty .. "|r")
        worldStatusAsh:SetText((complete and "|cff8ec9d6Soul Ash  |r" or "|cffb8b8b8Ash |r") .. "|cffffffff" .. ashFmt .. "|r")
        worldStatusGain:SetText(ss.gain and ("|cff35e635" .. ss.gain .. "|r") or "")
        worldStatusBox:Show()
    else
        worldStatusText:SetText("")
        worldStatusAsh:SetText("")
        worldStatusGain:SetText("")
        worldStatusBox:Hide()
    end

    -- Character best is always visible in every HUD state, independent of
    -- whether the wishlist is incomplete, complete, or not configured yet.
    local playerInfo = Nexus.DpsCapture and Nexus.DpsCapture.GetPlayerInfo and Nexus.DpsCapture.GetPlayerInfo(UnitName("player"))
    if playerInfo and tonumber(playerInfo.dps) then
        local encounter = playerInfo.category == "lk" and "Lich King" or "Dummy"
        bestDpsText:SetText("|cffb8b8b8Best DPS:|r  |cff4dff80" .. FmtDps(playerInfo.dps) .. "|r  |cff888888" .. encounter .. "|r")
    else
        bestDpsText:SetText("|cff888888Best DPS: hit a training dummy to record|r")
    end
    bestDpsText:ClearAllPoints()
    if complete and not noBuild and not activeRoll and not showPerformance then
        bestDpsText:SetPoint("TOP", frame, "TOP", 0, -84)
    else
        bestDpsText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 33)
    end
    bestDpsText:Show()
    bestDpsHit:Show()
    autoBtn:SetText(AutoLabel(model.auto))
    if not userHidden then frame:Show() end
end

function M.Refresh() if M._lastModel then M.Render(M._lastModel) end end
function M.Show() userHidden = false; EnsureFrame():Show() end
function M.Hide() if frame then frame:Hide() end; userHidden = true end
function M.IsShown() return frame and frame:IsShown() or false end

return M
