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
}

local frame, editBox, scroll, tabButtons, statusFS, exportButton
local exportRunner, exportJob, exportGeneration = nil, nil, 0
local provider, clearProvider
local activeTab = "state"
local repaintPending = false
local MAX_TEXT_CHARS = 60000
local MAX_EXPORT_CHARS = 70000

local function Repaint()
    repaintPending = false
    if not (frame and editBox and frame:IsShown()) then return end
    local text = "no data provider"
    if type(provider) == "function" then
        local ok, result = pcall(provider, activeTab)
        text = ok and tostring(result or "") or ("provider error: " .. tostring(result))
    end
    local originalLen = #text
    local limit = activeTab == "support_export" and MAX_EXPORT_CHARS or MAX_TEXT_CHARS
    if originalLen > limit then
        text = "EXPORT TOO LARGE FOR A SAFE SINGLE COPY (" .. originalLen .. " chars).\n"
            .. "Press Clear Log after saving the current export, then collect a fresh run.\n"
            .. "No partial/truncated export is shown because that would be misleading."
    end
    editBox:SetText(text)
    editBox:SetCursorPosition(0)
    if statusFS then
        local suffix = originalLen > limit and " (safe-limit exceeded)" or ""
        if activeTab == "support_export" then
            statusFS:SetText(string.format("%d chars%s -- full retained decision + mismatch log", originalLen, suffix))
        else
            statusFS:SetText(string.format("%d chars%s -- Select All, Ctrl-C", originalLen, suffix))
        end
    end
    for _, b in ipairs(tabButtons or {}) do
        if b.tabKey == activeTab then b:LockHighlight() else b:UnlockHighlight() end
    end
    if activeTab == "support_export" and editBox then
        editBox:SetFocus()
        editBox:HighlightText()
    end
end

local function ScheduleRepaint()
    if repaintPending then return end
    repaintPending = true
    local waiter = CreateFrame("Frame")
    local elapsed = 0
    waiter:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + (tonumber(dt) or 0)
        if elapsed < 0.05 then return end
        self:SetScript("OnUpdate", nil)
        Repaint()
    end)
end

local function StopExport()
    exportGeneration = exportGeneration + 1
    exportJob = nil
    if exportRunner then
        exportRunner:SetScript("OnUpdate", nil)
        exportRunner:Hide()
    end
end

local function FinishExport(text)
    exportJob = nil
    if exportRunner then exportRunner:SetScript("OnUpdate", nil); exportRunner:Hide() end
    text = tostring(text or "")
    local n = #text
    if n > MAX_EXPORT_CHARS then
        editBox:SetText("FULL EXPORT IS TOO LARGE FOR A SAFE SINGLE COPY (" .. n .. " chars).\n\nClear the diagnostic log, reproduce the problem once, then export again. Nexus did not render a partial log because partial data can produce a false diagnosis.")
        statusFS:SetText(n .. " chars -- safe single-copy limit exceeded")
        return
    end
    editBox:SetText(text)
    editBox:SetCursorPosition(0)
    editBox:SetFocus()
    editBox:HighlightText()
    statusFS:SetText(n .. " chars -- complete log selected; Ctrl-C")
end

local function StartExport()
    StopExport()
    activeTab = "support_export"
    for _, b in ipairs(tabButtons or {}) do b:UnlockHighlight() end
    editBox:SetText("Preparing full support diagnostic...\n\nNexus is building this over multiple frames so gameplay stays responsive.")
    statusFS:SetText("Preparing export...")
    local factory = Nexus and Nexus.NewSupportExportCoroutine
    if type(factory) ~= "function" then
        editBox:SetText("Support export builder is unavailable.")
        return
    end
    local ok, job = pcall(factory)
    if not ok or type(job) ~= "thread" then
        editBox:SetText("Could not start support export: " .. tostring(job))
        return
    end
    exportJob = job
    exportGeneration = exportGeneration + 1
    local myGeneration = exportGeneration
    if not exportRunner then exportRunner = CreateFrame("Frame") end
    exportRunner:Show()
    local updateElapsed = 0
    exportRunner:SetScript("OnUpdate", function(self, elapsed)
        if myGeneration ~= exportGeneration or not exportJob then self:SetScript("OnUpdate", nil); self:Hide(); return end
        updateElapsed = updateElapsed + (tonumber(elapsed) or 0)
        -- Exactly one small coroutine slice per rendered frame. Each slice
        -- encodes only a handful of boards/audits, keeping frame time bounded
        -- even on low-end clients while combat or sync traffic is active.
        for _ = 1, 1 do
            local okResume, value = coroutine.resume(exportJob)
            if not okResume then
                exportJob = nil
                self:SetScript("OnUpdate", nil); self:Hide()
                editBox:SetText("Support export failed: " .. tostring(value))
                statusFS:SetText("export failed")
                return
            end
            if coroutine.status(exportJob) == "dead" then
                exportJob = nil
                self:SetScript("OnUpdate", nil)
                self:Hide()
                local finalText = value
                local finisher = CreateFrame("Frame")
                local waited = false
                finisher:SetScript("OnUpdate", function(f)
                    if not waited then waited = true; return end
                    f:SetScript("OnUpdate", nil)
                    FinishExport(finalText)
                    finalText = nil
                end)
                return
            end
            if updateElapsed >= 0.12 then
                statusFS:SetText(tostring(value or "Building full support log...") .. " -- you may keep playing")
                updateElapsed = 0
            end
        end
    end)
end

local function EnsureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "NexusLogViewer", UIParent)
    frame:SetClampedToScreen(true)
    UISpecialFrames = UISpecialFrames or {}
    table.insert(UISpecialFrames, "NexusLogViewer")
    frame:SetSize(700, 440)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetFrameStrata("DIALOG")
    frame:SetScript("OnHide", StopExport)
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
            StopExport()
            activeTab = self.tabKey
            ScheduleRepaint()
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
    refresh:SetScript("OnClick", function()
        if activeTab == "support_export" then StartExport() else ScheduleRepaint() end
    end)

    exportButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    exportButton:SetSize(148, 22)
    exportButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 7)
    exportButton:SetText("Copy Support Log")
    exportButton:SetScript("OnClick", StartExport)
    exportButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Copy every retained decision and mismatch")
        GameTooltip:AddLine("Creates one compact support-ready diagnostic and selects it for Ctrl-C. The normal tabs stay shortened to prevent freezes.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    exportButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clearButton:SetSize(86, 22)
    clearButton:SetPoint("RIGHT", exportButton, "LEFT", -6, 0)
    clearButton:SetText("Clear Log")
    clearButton.confirmUntil = 0
    clearButton:SetScript("OnClick", function(self)
        local now = GetTime and GetTime() or 0
        if now > (self.confirmUntil or 0) then
            self.confirmUntil = now + 4
            self:SetText("Confirm Clear")
            return
        end
        self.confirmUntil = 0
        self:SetText("Clear Log")
        if type(clearProvider) == "function" then pcall(clearProvider) end
        activeTab = "state"
        ScheduleRepaint()
    end)
    clearButton:SetScript("OnUpdate", function(self)
        if self.confirmUntil and self.confirmUntil > 0 and (GetTime and GetTime() or 0) > self.confirmUntil then
            self.confirmUntil = 0
            self:SetText("Clear Log")
        end
    end)
    clearButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Clear diagnostic history")
        GameTooltip:AddLine("Press twice to clear retained boards and save/guarantee audit events. This does not change settings, builds, or automation.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    clearButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    scroll = CreateFrame("ScrollFrame", "NexusLogScroll", frame,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -58)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 36)

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

function M.Init(providerFn, clearFn)
    if providerFn ~= nil then provider = providerFn end
    if clearFn ~= nil then clearProvider = clearFn end
end

function M.Show(tabKey)
    EnsureFrame()
    if Nexus.Panel and Nexus.Panel.CloseOtherWindows then Nexus.Panel.CloseOtherWindows("NexusLogViewer") end
    if tabKey then activeTab = tabKey end
    frame:Show()
    if editBox then editBox:SetText("Loading " .. tostring(activeTab) .. " log...") end
    ScheduleRepaint()
end

function M.Toggle(tabKey)
    EnsureFrame()
    if frame:IsShown() then frame:Hide() else M.Show(tabKey) end
end
