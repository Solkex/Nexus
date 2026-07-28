-- Nexus: ui/Leaderboard.lua
-- Dedicated, dense DPS leaderboard. The board is intentionally separate
-- from the community build browser so ranking and build discovery remain
-- clear, focused workflows.

Nexus = Nexus or {}
local M = {}
Nexus.Leaderboard = M

local frame, listChild, listScroll, detail, searchBox, classBtn, classMenu
local dummyBtn, lkBtn, syncBtn, statusText
local category = "dummy"
local selectedKey = nil
local rowPool, activeRows = {}, {}
local Adapter

local ROW_H = 34
local CLASS_COLOR = {
    DEATHKNIGHT={0.77,0.12,0.23}, DRUID={1.00,0.49,0.04}, HUNTER={0.67,0.83,0.45},
    MAGE={0.25,0.78,0.92}, PALADIN={0.96,0.55,0.73}, PRIEST={1,1,1},
    ROGUE={1,0.96,0.41}, SHAMAN={0,0.44,0.87}, WARLOCK={0.53,0.53,0.93}, WARRIOR={0.78,0.61,0.43},
}
local CLASS_LABEL = {
    DEATHKNIGHT="Death Knight", DRUID="Druid", HUNTER="Hunter", MAGE="Mage", PALADIN="Paladin",
    PRIEST="Priest", ROGUE="Rogue", SHAMAN="Shaman", WARLOCK="Warlock", WARRIOR="Warrior",
}
local CLASS_ICON = {
    DEATHKNIGHT="Interface\\Icons\\Spell_DeathKnight_IceboundFortitude",
    DRUID="Interface\\Icons\\Spell_Nature_NaturesBlessing", HUNTER="Interface\\Icons\\Ability_Hunter_BeastCall",
    MAGE="Interface\\Icons\\Spell_Frost_Frostbolt02", PALADIN="Interface\\Icons\\Spell_Holy_HolyBolt",
    PRIEST="Interface\\Icons\\Spell_Holy_PowerInfusion", ROGUE="Interface\\Icons\\Ability_BackStab",
    SHAMAN="Interface\\Icons\\Spell_Nature_Lightning", WARLOCK="Interface\\Icons\\Spell_Shadow_ShadowBolt",
    WARRIOR="Interface\\Icons\\Ability_Warrior_Charge",
}
local CLASS_ORDER = {"ALL","DEATHKNIGHT","DRUID","HUNTER","MAGE","PALADIN","PRIEST","ROGUE","SHAMAN","WARLOCK","WARRIOR"}
local classFilter = "ALL"

local function SpellIcon(id)
    local ok, _, _, icon = pcall(GetSpellInfo, tonumber(id))
    return ok and icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function DpsText(v)
    v = tonumber(v) or 0
    if v >= 1000000 then return string.format("%.2fM", v / 1000000) end
    if v >= 1000 then return string.format("%dk", math.floor(v / 1000)) end
    return tostring(math.floor(v))
end

local function DurationText(v)
    v = tonumber(v) or 0
    if v <= 0 then return "—" end
    local m = math.floor(v / 60)
    local s = math.floor(v % 60)
    return string.format("%d:%02d", m, s)
end

local function Rows()
    local D = Nexus.DpsCapture
    if not (D and D.GetDpsBoard) then return {} end
    local ok, rows = pcall(D.GetDpsBoard, category)
    if not ok or type(rows) ~= "table" then return {} end
    local query = searchBox and tostring(searchBox:GetText() or ""):lower() or ""
    local out = {}
    for _, row in ipairs(rows) do
        local build = row.build or {}
        local class = tostring(build.class or "UNKNOWN"):upper()
        local classOk = classFilter == "ALL" or class == classFilter
        local searchOk = query == ""
            or tostring(row.player or ""):lower():find(query,1,true)
            or tostring(build.title or ""):lower():find(query,1,true)
            or tostring(build.author or ""):lower():find(query,1,true)
        if classOk and searchOk then out[#out+1] = row end
    end
    return out
end

local function SetBackdrop(f, alpha)
    pcall(function()
        f:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=16,edgeSize=10,insets={left=3,right=3,top=3,bottom=3}})
        f:SetBackdropColor(0.035,0.035,0.05,alpha or 0.94)
        f:SetBackdropBorderColor(0.24,0.24,0.3,0.9)
    end)
end

local function ReleaseRows()
    for _, r in ipairs(activeRows) do r:Hide(); r:ClearAllPoints(); rowPool[#rowPool+1] = r end
    activeRows = {}
end

local function SelectRow(row)
    selectedKey = row and (tostring(row.fingerprint or "") .. ":" .. tostring(row.player or "")) or nil
    M.Refresh()
    if row and row.buildId and (not row.echoes or #row.echoes == 0) and Nexus.Sync and Nexus.Sync.RequestLoadout then
        Nexus.Sync.RequestLoadout(row.buildId)
    end
end

local function GetRow(parent)
    local r = table.remove(rowPool)
    if r then r:SetParent(parent); r:Show(); return r end
    r = CreateFrame("Button",nil,parent)
    r:SetHeight(ROW_H); r:EnableMouse(true)
    SetBackdrop(r,0.82)
    r.rank = r:CreateFontString(nil,"OVERLAY","GameFontNormal")
    r.rank:SetPoint("LEFT",8,0); r.rank:SetSize(34,14); r.rank:SetJustifyH("CENTER")
    r.icon = r:CreateTexture(nil,"ARTWORK"); r.icon:SetSize(22,22); r.icon:SetPoint("LEFT",48,0)
    r.player = r:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    r.player:SetPoint("LEFT",82,0); r.player:SetSize(188,14); r.player:SetJustifyH("LEFT")
    r.build = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    r.build:SetPoint("LEFT",276,0); r.build:SetSize(180,14); r.build:SetJustifyH("LEFT")
    r.dps = r:CreateFontString(nil,"OVERLAY","GameFontNormal")
    r.dps:SetPoint("RIGHT",-12,0); r.dps:SetSize(100,14); r.dps:SetJustifyH("RIGHT")
    r.sel = r:CreateTexture(nil,"BACKGROUND"); r.sel:SetAllPoints(r); r.sel:SetTexture(0.8,0.6,0.1,0.16); r.sel:Hide()
    r:SetScript("OnEnter",function(self) pcall(function() self:SetBackdropColor(0.10,0.10,0.16,0.95) end) end)
    r:SetScript("OnLeave",function(self) pcall(function() self:SetBackdropColor(0.035,0.035,0.05,0.82) end) end)
    r:SetScript("OnClick",function(self) SelectRow(self.data) end)
    return r
end

local function EnsureDetail(parent)
    if detail then return end
    detail = CreateFrame("Frame",nil,parent); detail:SetSize(345,530); detail:SetPoint("TOPRIGHT",-18,-86); SetBackdrop(detail,0.9)
    detail.title = detail:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    detail.title:SetPoint("TOPLEFT",14,-14); detail.title:SetSize(315,22); detail.title:SetJustifyH("LEFT")
    detail.owner = detail:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    detail.owner:SetPoint("TOPLEFT",14,-40); detail.owner:SetSize(315,16); detail.owner:SetJustifyH("LEFT")
    detail.record = detail:CreateFontString(nil,"OVERLAY","GameFontNormal")
    detail.record:SetPoint("TOPLEFT",14,-64); detail.record:SetSize(315,34); detail.record:SetJustifyH("LEFT"); detail.record:SetJustifyV("TOP")
    detail.desc = detail:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    detail.desc:SetPoint("TOPLEFT",14,-105); detail.desc:SetSize(315,58); detail.desc:SetJustifyH("LEFT"); detail.desc:SetJustifyV("TOP")

    -- Locked perks section (up to 6 permanent echoes, shown above rolled echoes)
    detail.lockedTitle = detail:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    detail.lockedTitle:SetPoint("TOPLEFT",14,-170); detail.lockedTitle:SetText("LOCKED ECHOES")
    detail.lockedIcons = {}
    for i = 1, 6 do
        local b = CreateFrame("Button",nil,detail); b:SetSize(34,34)
        b:SetPoint("TOPLEFT", 14 + (i-1)*38, -184)
        b.icon = b:CreateTexture(nil,"ARTWORK"); b.icon:SetAllPoints(b)
        b.border = b:CreateTexture(nil,"OVERLAY")
        b.border:SetAllPoints(b)
        pcall(function() b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border") end)
        b:SetScript("OnEnter", function(self)
            if self.tip then
                GameTooltip:SetOwner(self,"ANCHOR_TOP")
                GameTooltip:SetSpellByID(self.tip)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:Hide(); detail.lockedIcons[i] = b
    end

    detail.echoTitle = detail:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    detail.echoTitle:SetPoint("TOPLEFT",14,-234); detail.echoTitle:SetText("EXACT LOADOUT")
    detail.icons = {}
    for i=1,80 do
        local b = CreateFrame("Button",nil,detail); b:SetSize(23,23)
        local col=(i-1)%10; local row=math.floor((i-1)/10)
        b:SetPoint("TOPLEFT",14+col*30,-252-row*27)
        b.icon=b:CreateTexture(nil,"ARTWORK"); b.icon:SetAllPoints(b)
        b.count=b:CreateFontString(nil,"OVERLAY","NumberFontNormalSmall"); b.count:SetPoint("BOTTOMRIGHT",1,-1)
        b:Hide(); detail.icons[i]=b
    end
    detail.more = detail:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    detail.more:SetPoint("TOPLEFT",14,-474); detail.more:SetSize(315,18); detail.more:SetJustifyH("LEFT")
    detail.copy = CreateFrame("Button",nil,detail,"UIPanelButtonTemplate")
    detail.copy:SetSize(138,24); detail.copy:SetPoint("BOTTOMLEFT",14,14); detail.copy:SetText("Copy Exact Build")
    detail.copy:SetScript("OnClick",function()
        if not detail.row or not detail.row.buildId then return end
        local C=Nexus.CommunityBuilds
        if C then C.Select(detail.row.buildId); C.LockInSelected() end
    end)
    detail.open = CreateFrame("Button",nil,detail,"UIPanelButtonTemplate")
    detail.open:SetSize(138,24); detail.open:SetPoint("LEFT",detail.copy,"RIGHT",8,0); detail.open:SetText("Open Build")
    detail.open:SetScript("OnClick",function()
        if detail.row and detail.row.buildId and Nexus.CommunityBuilds then
            M.Hide(); Nexus.CommunityBuilds.ShowBuild(detail.row.buildId)
        end
    end)
    detail.empty = detail:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    detail.empty:SetPoint("CENTER",0,15); detail.empty:SetSize(280,60); detail.empty:SetJustifyH("CENTER")
    detail.empty:SetText("Select a leaderboard entry to inspect its exact build and copy the loadout.")
end

local function RenderDetail(row)
    if not detail then return end
    detail.row = row
    if not row then
        detail.title:Hide(); detail.owner:Hide(); detail.record:Hide(); detail.desc:Hide()
        detail.echoTitle:Hide(); detail.more:Hide(); detail.copy:Hide(); detail.open:Hide()
        detail.lockedTitle:Hide()
        for _, b in ipairs(detail.lockedIcons) do b:Hide() end
        for _, b in ipairs(detail.icons) do b:Hide() end
        detail.empty:Show(); return
    end
    detail.empty:Hide(); detail.title:Show(); detail.owner:Show(); detail.record:Show()
    detail.desc:Show(); detail.echoTitle:Show(); detail.more:Show(); detail.copy:Show(); detail.open:Show()

    -- Locked perks row
    local locked = row.lockedEchoes or {}
    if #locked > 0 then
        detail.lockedTitle:Show()
        for i, btn in ipairs(detail.lockedIcons) do
            local e = locked[i]
            if e then
                btn.icon:SetTexture(SpellIcon(e.spellId or e.id))
                btn.tip = tonumber(e.spellId or e.id)
                btn:Show()
            else
                btn:Hide()
            end
        end
    else
        detail.lockedTitle:Hide()
        for _, btn in ipairs(detail.lockedIcons) do btn:Hide() end
    end

    local b=row.build or {}; local c=CLASS_COLOR[tostring(b.class or ""):upper()] or {1,1,1}
    detail.title:SetText(b.title or "Record Loadout"); detail.title:SetTextColor(c[1],c[2],c[3])
    detail.owner:SetText("by "..tostring(b.author or row.player or "?"))
    detail.record:SetText(string.format("|cff4dff80%s DPS|r  •  %s  •  Lv%d",DpsText(row.dps),DurationText(row.duration),tonumber(row.level) or 0))
    detail.desc:SetText((b.description and b.description~="") and b.description or "No build description provided.")
    local echoes=row.echoes or b.echoes or {}; local shown=math.min(#echoes,#detail.icons)
    for i, btn in ipairs(detail.icons) do
        local e=echoes[i]
        if i<=shown and e then btn.icon:SetTexture(SpellIcon(e.spellId or e.id)); local n=tonumber(e.stacks or e.count) or 1; btn.count:SetText(n>1 and n or ""); btn:Show() else btn:Hide() end
    end
    do
        local totalSlots = 0
        for _, e in ipairs(echoes) do totalSlots = totalSlots + (tonumber(e.stacks or e.count) or 1) end
        if #echoes == 0 then
            detail.more:SetText("Exact loadout is still completing its background sync.")
        elseif #echoes > shown then
            detail.more:SetText("+" .. (#echoes-shown) .. " more  ·  " .. totalSlots .. " Echo slots total")
        else
            detail.more:SetText(tostring(totalSlots) .. " Echo slots")
        end
    end
    if #echoes > 0 then detail.copy:Enable() else detail.copy:Disable() end
end

local function EnsureFrame()
    if frame then return frame end
    frame=CreateFrame("Frame","NexusLeaderboardFrame",UIParent)
    frame:SetClampedToScreen(true)
    UISpecialFrames = UISpecialFrames or {}
    table.insert(UISpecialFrames, "NexusLeaderboardFrame"); frame:SetSize(980,570); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG"); frame:SetFrameLevel(55)
    frame:EnableMouse(true); frame:SetMovable(true); frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart",function(self) self:StartMoving() end); frame:SetScript("OnDragStop",function(self) self:StopMovingOrSizing() end); frame:Hide()
    pcall(function() frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}}) end)
    local title=frame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge"); title:SetPoint("TOP",0,-14); title:SetText("Nexus Leaderboard")
    local close=CreateFrame("Button",nil,frame,"UIPanelCloseButton"); close:SetPoint("TOPRIGHT",-6,-6)
    local builds=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate"); builds:SetSize(88,22); builds:SetPoint("TOPLEFT",18,-42); builds:SetText("Builds"); builds:SetScript("OnClick",function() M.Hide(); if Nexus.CommunityBuilds then Nexus.CommunityBuilds.Show() end end)
    local board=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate"); board:SetSize(102,22); board:SetPoint("LEFT",builds,"RIGHT",4,0); board:SetText("|cffffd200Leaderboard|r")
    searchBox=CreateFrame("EditBox","NexusLeaderboardSearch",frame,"InputBoxTemplate"); searchBox:SetSize(180,22); searchBox:SetPoint("LEFT",board,"RIGHT",14,0); searchBox:SetAutoFocus(false); searchBox:SetScript("OnTextChanged",function() M.Refresh() end)
    local ph=frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); ph:SetPoint("LEFT",searchBox,"LEFT",6,0); ph:SetText("Search player or build...")
    searchBox:SetScript("OnEditFocusGained",function() ph:Hide() end); searchBox:SetScript("OnEditFocusLost",function(self) if self:GetText()=="" then ph:Show() end end)
    classBtn=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate"); classBtn:SetSize(125,22); classBtn:SetPoint("LEFT",searchBox,"RIGHT",8,0); classBtn:SetText("All Classes (v)")
    classMenu=CreateFrame("Frame",nil,UIParent); classMenu:SetFrameStrata("TOOLTIP"); classMenu:SetSize(145,#CLASS_ORDER*20+8); classMenu:EnableMouse(true); classMenu:Hide(); SetBackdrop(classMenu,0.98)
    for i,k in ipairs(CLASS_ORDER) do local rb=CreateFrame("Button",nil,classMenu); rb:SetSize(135,20); rb:SetPoint("TOPLEFT",5,-4-(i-1)*20); local t=rb:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); t:SetPoint("LEFT",5,0); t:SetText(k=="ALL" and "All Classes" or CLASS_LABEL[k] or k); rb:SetScript("OnClick",function() classFilter=k; classMenu:Hide(); M.Refresh() end) end
    classBtn:SetScript("OnClick",function(self) if classMenu:IsShown() then classMenu:Hide() else classMenu:ClearAllPoints(); classMenu:SetPoint("TOPLEFT",self,"BOTTOMLEFT",0,-2); classMenu:Show() end end)
    dummyBtn=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate"); dummyBtn:SetSize(110,22); dummyBtn:SetPoint("TOPLEFT",18,-72); dummyBtn:SetScript("OnClick",function() category="dummy"; selectedKey=nil; M.Refresh() end)
    lkBtn=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate"); lkBtn:SetSize(110,22); lkBtn:SetPoint("LEFT",dummyBtn,"RIGHT",4,0); lkBtn:SetScript("OnClick",function() category="lk"; selectedKey=nil; M.Refresh() end)
    syncBtn=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate"); syncBtn:SetSize(90,22); syncBtn:SetPoint("TOPRIGHT",-18,-42); syncBtn:SetText("Sync Now"); syncBtn:SetScript("OnClick",function() if Nexus.Sync then Nexus.Sync.RequestSync() end end)
    statusText=frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); statusText:SetPoint("LEFT",lkBtn,"RIGHT",12,0); statusText:SetSize(330,14); statusText:SetJustifyH("LEFT")
    local head=CreateFrame("Frame",nil,frame); head:SetSize(575,22); head:SetPoint("TOPLEFT",18,-102); SetBackdrop(head,0.75)
    local labels={{"#",8,34,"CENTER"},{"",48,24,"CENTER"},{"CHARACTER",82,188,"LEFT"},{"LOADOUT",276,180,"LEFT"},{"DPS",463,100,"RIGHT"}}
    for _,x in ipairs(labels) do local t=head:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); t:SetPoint("LEFT",x[2],0); t:SetSize(x[3],14); t:SetJustifyH(x[4]); t:SetText(x[1]) end
    local clip=CreateFrame("Frame",nil,frame); clip:SetPoint("TOPLEFT",18,-126); clip:SetSize(575,426); pcall(function() clip:SetClipsChildren(true) end)
    listScroll=CreateFrame("ScrollFrame",nil,clip); listScroll:SetAllPoints(clip); listScroll:EnableMouseWheel(true)
    listChild=CreateFrame("Frame",nil,listScroll); listChild:SetWidth(575); listChild:SetHeight(1); listScroll:SetScrollChild(listChild)
    listScroll:SetScript("OnMouseWheel",function(self,d) local v=self:GetVerticalScroll() or 0; local max=math.max(0,(listChild:GetHeight() or 0)-426); self:SetVerticalScroll(math.max(0,math.min(max,v-d*ROW_H*4))) end)
    EnsureDetail(frame)
    frame:SetScript("OnUpdate",function(self,elapsed) self._tick=(self._tick or 0)+elapsed; if self._tick>1 then self._tick=0; M.Refresh() end end)
    return frame
end

function M.Refresh()
    if not frame or not frame:IsShown() then return end
    dummyBtn:SetText(category=="dummy" and "|cffffd200Training Dummy|r" or "Training Dummy")
    lkBtn:SetText(category=="lk" and "|cffffd200Lich King|r" or "Lich King")
    classBtn:SetText((classFilter=="ALL" and "All Classes" or CLASS_LABEL[classFilter] or classFilter).." (v)")
    local S=Nexus.Sync
    if S and S.IsReceiving and S.IsReceiving() then statusText:SetText("|cff4dff80Syncing leaderboard...|r") else statusText:SetText("|cff888888Each character's best exact loadout|r") end
    ReleaseRows(); local rows=Rows(); local selected=nil
    for i,row in ipairs(rows) do
        local r=GetRow(listChild); r:SetWidth(575); r:ClearAllPoints(); r:SetPoint("TOPLEFT",0,-(i-1)*(ROW_H+2)); r.data=row
        local class=tostring((row.build or {}).class or "UNKNOWN"):upper(); local c=CLASS_COLOR[class] or {0.8,0.8,0.8}
        r.rank:SetText(i<=3 and "|cffffd200"..i.."|r" or tostring(i)); r.icon:SetTexture(CLASS_ICON[class] or "Interface\\Icons\\INV_Misc_QuestionMark")
        r.player:SetText(tostring(row.player or "?")); r.player:SetTextColor(c[1],c[2],c[3])
        r.build:SetText(tostring((row.build or {}).title or "Record Loadout"))
        r.dps:SetText("|cff4dff80"..DpsText(row.dps).."|r")
        local key=tostring(row.fingerprint or "")..":"..tostring(row.player or ""); if key==selectedKey then r.sel:Show(); selected=row else r.sel:Hide() end
        activeRows[#activeRows+1]=r
    end
    listChild:SetHeight(math.max(1,#rows*(ROW_H+2)))
    if #rows==0 then RenderDetail(nil); detail.empty:SetText("No "..(category=="dummy" and "Training Dummy" or "Lich King").." records are known yet.\n\nLeaderboard data syncs on login; Sync Now checks again.")
    else
        if not selected and selectedKey then selectedKey=nil end
        RenderDetail(selected)
    end
end

function M.Init(adapter) Adapter=adapter end
function M.Show(mode) EnsureFrame(); if Nexus.Panel and Nexus.Panel.CloseOtherWindows then Nexus.Panel.CloseOtherWindows("NexusLeaderboardFrame") end; if mode=="lk" or mode=="dummy" then category=mode end; frame:Show(); M.Refresh() end
function M.Hide() if frame then frame:Hide() end end
function M.Toggle(mode) EnsureFrame(); if frame:IsShown() then frame:Hide() else M.Show(mode) end end
function M.SetCategory(mode) if mode=="lk" then category="lk" else category="dummy" end; selectedKey=nil; M.Refresh() end
function M.IsShown() return frame and frame:IsShown() or false end

