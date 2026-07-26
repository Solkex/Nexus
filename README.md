# Nexus

## Download Nexus

### [Download Nexus.zip](https://github.com/Solkex/Nexus/releases/latest/download/Nexus.zip)

This is the player-ready Nexus 1.0 addon.

> **Do not use GitHub's “Code → Download ZIP” button to install the addon.** That download contains the repository source and will not have the intended player package layout. Use the **Download Nexus.zip** link above.

## Installation

1. Download [Nexus.zip](https://github.com/Solkex/Nexus/releases/latest/download/Nexus.zip).
2. Open the ZIP and extract the `Nexus` folder.
3. Put that folder inside Ebonhold's `Interface\AddOns` folder.
4. Confirm the installed file exists at `...\Interface\AddOns\Nexus\Nexus.toc`.
5. Start Ebonhold or type `/reload` if the game is already running.

Example addon folder:

```text
F:\Ebonhold\Ebonhold\Interface\AddOns
```

The finished installation should look like:

```text
F:\Ebonhold\Ebonhold\Interface\AddOns\Nexus\Nexus.toc
```

If your archive tool shows another surrounding folder, extract the inner `Nexus` folder—the folder that directly contains `Nexus.toc`.

## About Nexus

Nexus provides Echo build automation, community builds, and DPS leaderboards for Project Ebonhold.

It helps you choose and complete an Echo build, share builds with other players, and compare exact loadouts using verified DPS records.

## Getting Started

1. Install Nexus and Details!.
   - Details! is required for DPS tracking and leaderboard records.
   - Disabling other addons that automate or modify Echo choices is recommended.
2. Log in or type `/reload`.
   - The Nexus HUD should appear automatically.
   - If it does not, left-click the Nexus minimap button.
3. Pick a build.
   - Import an in-game loadout.
   - Create your own wishlist.
   - Or open **Community Builds**, filter by class, and copy a build.
4. Press **Switch** on the Nexus HUD and select the wishlist you want to use.
5. Choose your roll mode.
   - Leave **Auto ON** for full supported automation.
   - Turn **Auto OFF** to roll manually while still seeing Nexus recommendations and explanations.

## What Nexus Does

### Echo Board Automation

When an Echo board opens, Nexus recommends what to take, freeze, banish, or reroll based on your selected wishlist.

- **Auto ON:** Nexus handles supported Echo choices for you.
- **Auto OFF:** You make the choices manually while Nexus shows its recommendation and explains the logic.

Nexus accounts for guaranteed Echoes, freeze and banish sequencing, quality requirements, stack quantities, and temporary filler.

### Wishlist Progress

The HUD shows:

- Echoes you still need
- Extra Echoes you should eventually shed
- Unlearned tomes preventing wishlist Echoes from appearing
- Your best Dummy and Lich King DPS for the selected loadout
- The current global best for that same exact loadout

### Community Builds

Browse builds shared by other Nexus users, filter by class, read descriptions, preview Echoes, and copy an exact build into your own wishlist.

Builds and updates sync through online Nexus users with safeguards to prevent lag when you press **Sync now**. Nexus also performs a safe, throttled sync after login.

### DPS Leaderboards

With Details! enabled, Nexus records valid Training Dummy and Lich King sessions lasting at least 30 seconds.

Each record is tied to the exact Echo IDs and stack quantities used during the pull. When you set a new personal record, Nexus can automatically create or update the build for that character.

Mouse over another Nexus user to see that they use Nexus and, when applicable, their leaderboard rank.

## Why Nexus Sometimes Takes Filler

When none of your target Echoes are available, Nexus may take the least harmful temporary filler.

This is intentional. The filler holds the slot until a wanted Echo appears and replaces it later. A strange-looking choice does not always mean the recommendation is wrong; Nexus may be planning around future replacements or protecting a harder-to-find Echo.

The HUD's **STILL NEEDED** section shows what is missing and will replace filler on following runs…204530 tokens truncated…K_ROWS), #list))
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
