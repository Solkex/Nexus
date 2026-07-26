-- Nexus: ui/QuickStart.lua
-- First-launch welcome screen. Shows once per account.
-- Adapts content based on whether a wishlist is already configured.

Nexus = Nexus or {}
local M = {}
Nexus.QuickStart = M

local frame

local function EnsureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "NexusQuickStart", UIParent)
    frame:SetSize(480, 410)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    frame:Hide()

    pcall(function()
        frame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff7fd5ffNexus|r")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", 0, -34)
    subtitle:SetTextColor(0.6, 0.6, 0.6)
    subtitle:SetText("Echo build automation  ·  Community Builds  ·  DPS Leaderboard")

    -- Divider
    local div = frame:CreateTexture(nil, "ARTWORK")
    div:SetSize(420, 1)
    div:SetPoint("TOP", 0, -50)
    pcall(function() div:SetTexture(0.3, 0.3, 0.3, 0.6) end)

    -- Body text
    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", 22, -62)
    body:SetSize(436, 280)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    frame.body = body

    -- Bottom buttons — Leaderboard is front and center
    local leaderboard = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    leaderboard:SetSize(124, 24)
    leaderboard:SetPoint("BOTTOMLEFT", 18, 16)
    leaderboard:SetText("Leaderboard")
    leaderboard:SetScript("OnClick", function()
        NexusDB.hasSeenQuickStart = true
        frame:Hide()
        if Nexus.Leaderboard then Nexus.Leaderboard.Show() end
    end)
    leaderboard:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Nexus Leaderboard", 1, 1, 1)
        GameTooltip:AddLine("See the highest DPS recorded for every exact Echo loadout.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Separate rankings for Training Dummy and Lich King.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    leaderboard:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local builds = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    builds:SetSize(124, 24)
    builds:SetPoint("LEFT", leaderboard, "RIGHT", 6, 0)
    builds:SetText("Nexus Builds")
    builds:SetScript("OnClick", function()
        NexusDB.hasSeenQuickStart = true
        frame:Hide()
        if Nexus.CommunityBuilds then Nexus.CommunityBuilds.Show() end
    end)
    builds:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Community Builds", 1, 1, 1)
        GameTooltip:AddLine("Browse and copy exact Echo loadouts from other players.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    builds:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local wishlists = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    wishlists:SetSize(90, 24)
    wishlists:SetPoint("LEFT", builds, "RIGHT", 6, 0)
    wishlists:SetText("Wishlists")
    wishlists:SetScript("OnClick", function()
        NexusDB.hasSeenQuickStart = true
        frame:Hide()
        if Nexus.WishlistEditor then Nexus.WishlistEditor.Show() end
    end)

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(70, 24)
    close:SetPoint("BOTTOMRIGHT", -18, 16)
    close:SetText("Got it")
    close:SetScript("OnClick", function()
        NexusDB.hasSeenQuickStart = true
        frame:Hide()
    end)

    return frame
end

function M.ShowIfFirstTime(hasWishlist)
    if NexusDB.hasSeenQuickStart then return end
    EnsureFrame()

    local lines
    if not hasWishlist then
        lines = {
            "Nexus automates your Echo board using the game's built-in",
            "Echo Wishlist feature. Set a target build, and it handles",
            "every board decision for you — taking, freezing, banishing,",
            "and rerolling toward that build every run.",
            " ",
            "|cffffd200How to get started:|r",
            "  → Open |cff7fd5ffNexus Builds|r to browse the community leaderboard",
            "    and copy a proven build as your active wishlist.",
            "  → Or open |cff7fd5ffWishlists|r to create your own from scratch.",
            " ",
            "|cffffd200How saving works:|r",
            "After every run, Nexus checks if your new Echo loadout is",
            "better than your saved snapshot. If it is, it overwrites the",
            "active slot automatically. Most runs should be improvements.",
            "If a run ends with no new wishlist Echoes — bad RNG happens —",
            "the HUD will say so. Nothing is broken, the run just missed.",
        }
    else
        lines = {
            "You have an active wishlist — Nexus is ready.",
            " ",
            "|cffffd200How it works:|r",
            "Nexus uses your Echo Wishlist as the target build. Every",
            "time an Echo board opens, it picks the best option toward",
            "that build. Enable |cff4dff80Auto|r on the HUD and it acts for you.",
            " ",
            "|cffffd200Saving:|r After each run, Nexus compares your new Echo loadout",
            "against your saved snapshot. If the new run added wished Echoes",
            "or reduced filler, it overwrites the slot automatically.",
            "If it didn't improve — bad RNG happens — the HUD shows",
            "|cff888888'Working toward X — not an improvement yet'|r so you know",
            "the run finished but the save was correctly skipped.",
            " ",
            "|cffffd200Leaderboard:|r Finish a valid Dummy or Lich King pull. If it is",
            "your character's best result, Nexus snapshots the exact Echo set",
            "and creates an editable record build automatically. Open that build",
            "to rename it or add a description — no manual post is required.",
            " ",
            "|cffffd200Recommendation questions:|r A filler pick is often intentional.",
            "Nexus may take temporary junk that will be replaced later while it",
            "protects rarer wanted Echoes. Hover the recommendation or open",
            "|cff7fd5ff/ nexus logs|r before reporting a mismatch; the explanation shows",
            "whether it was filler strategy, an equivalent junk action, or a real conflict.",
        }
    end
    frame.body:SetText(table.concat(lines, "\n"))
    frame:Show()
end
