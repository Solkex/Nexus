-- Nexus: core/Main.lua
-- Bootstrap + the decision loop. Wires adapter reads -> pure logic ->
-- adapter actions. Owns the OnUpdate cadence, the lifecycle FSM
-- (LOAD / ARM@L1 / RUN / SAVE@L80), auto-pick pacing, the runtime
-- self-checks (flag demotions), and the slash commands.
-- SCOPING RULE: every closure-captured local is declared here, before
-- any closure that reads it.

Nexus = Nexus or {}
Nexus.VERSION = "1.0"

local Model, Policy, Ratchet, Strategy, Store, Adapter
local Readout, Panel, JournalTab, DefaultProfile
local initialized = false
local autoEnabled = true          -- session-level master switch (panel button / slash)
local sniffPaused = false         -- see /wr sniff
local quickStartChecked = false   -- one-time-per-session guard for the quick-start check
local pollAccum = 0
local POLL = 0.2

-- Lag / addon interference detection
-- If the OnUpdate frame time jumps significantly above the poll cadence,
-- another addon is probably blocking the main thread. We report in chat
-- once per minute at most, so it's informative but not spammy.
local lagWarnedAt    = -math.huge
local LAG_THRESHOLD  = 1.5    -- seconds; a single frame stall this long is suspicious
local LAG_WARN_COOLDOWN = 60  -- seconds between chat warnings

-- ARM state
local armAttempts, armedConfirmed, armPendingSince = 0, false, nil
local armTargetSlot = nil
local boardsSinceArm = 0
local leversDoneThisVisit = {}
local lastLeverSendAt = 0

-- RUN state
local lastDecidedSig, lastDecision, decidedAt = nil, nil, nil
local lastLoggedSig = nil        -- decision-log dedupe per board
local lastBoardForRerollWatch = nil
local frozeThisBoard = nil       -- board signature we already spent a freeze on
local externalPauseUntil = 0

-- SAVE state
local savedThisVisit = false
local slotsRefreshAt = nil
local saveVerifySlot, saveVerifyAt, seedVerify = nil, nil, nil
local lastLevelSeen = nil
local demotionsClearedThisSession = false

local statusLine = "loading"
local EH  -- event frame

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fd5ffNexus:|r " .. tostring(msg))
end

local function SetStatus(s)
    if s ~= statusLine then statusLine = s end
end

local function EffectiveFlags()
    local flags = {}
    for k, v in pairs(DefaultProfile.defaultFlags or {}) do flags[k] = v end
    local st = Store.State()
    for k in pairs(st.flagDemotions or {}) do flags[k] = false end
    return flags
end

local function DemoteFlag(name, reason)
    local st = Store.State()
    st.flagDemotions = st.flagDemotions or {}
    if not st.flagDemotions[name] then
        st.flagDemotions[name] = reason
        Print("|cffff6060flag demoted:|r " .. name .. " -- " .. reason)
    end
end

------------------------------------------------------------------------
-- One FSM step (the whole loop; called from OnUpdate at POLL cadence)
------------------------------------------------------------------------

local function ActiveSlotRow(slots)
    if not slots or slots.activeSlot == 0 then return nil end
    local s = slots.bySlot[slots.activeSlot]
    if s and s.verified and s.verifiedFieldPresent and not s.suspectParse then
        return s
    end
    return nil
end

local function AutoAllowed()
    if not autoEnabled then return false, "manual mode" end
    if GetTime() < externalPauseUntil then return false, "user acting" end
    if Adapter.RivalDetected() then return false, "EchoOptimizer loaded -- disable it" end
    if Adapter.AutoAcceptOn() then return false, "client auto-accept re-enabled" end
    return true
end

-- Wishlist progress for this run: how many wished FAMILIES are owned, and
-- how many total, family-granular (same identity rule as everything else
-- -- addendum B2). Pure; malformed plan/owned degrades to 0/0.
-- This run's progress toward the wishlist's total STACK target (the
-- "79" number) -- not a family-boolean count. A family sitting at 1 of
-- 9 needed copies contributes only 1 toward the total, not a full
-- credit; "missing" lists anything not yet at its FULL target, whether
-- that's zero copies or a partial stack still short.
local function WishlistProgress(plan, owned, catalog)
    local stackTotal, stackCount, missing = 0, 0, {}
    if type(plan) ~= "table" or type(plan.wishedFamilies) ~= "table" then
        return 0, 0, missing
    end
    local targets = type(plan.targets) == "table" and plan.targets or {}
    local byFamily = (type(owned) == "table" and owned.byFamily) or {}
    for fam in pairs(plan.wishedFamilies) do
        local target = targets[fam]
        local want = (type(target) == "table" and tonumber(target.targetStacks)) or 1
        stackTotal = stackTotal + want
        local have = byFamily[fam] or 0
        stackCount = stackCount + math.min(have, want)
        if have < want then
            local nm = catalog and catalog.familyName and catalog.familyName[fam]
            local remain = want - have
            missing[#missing + 1] = tostring(nm or fam) .. (remain > 1 and (" ×" .. remain) or "")
        end
    end
    table.sort(missing)
    return stackCount, stackTotal, missing
end

-- How many wished families the ACTIVE loadout snapshot already covers,
-- and the NAMES of the ones it's still missing -- the cross-run
-- convergence number (loadout -> ideal build), distinct from
-- WishlistProgress which is this run's owned set. Returns count, missing
-- (sorted name array); count is nil when there's no active snapshot to
-- measure against (never confused with "converged").
-- Convergence of the ACTIVE loadout snapshot toward the ideal wishlist,
-- using the SAME two units the game's own Echo Journal uses ("68
-- echo(es), 79/79 stacks"): distinct wished FAMILIES present at all
-- (familyCount/familyTotal), and total STACKS actually banked toward
-- each family's target, capped per family so extra copies past target
-- don't inflate it (stackCount/stackTotal). Family count alone
-- overstates progress -- a family sitting at 1 of 9 needed copies reads
-- as "covered" there but is nowhere near done; stackCount is the honest
-- number. Also returns the missing family NAMES (families with zero
-- copies) and the LOCKED echo names (server build-slot locks -- distinct
-- from the wishlist's own "locked" concept, these are echoes pinned in
-- the saved snapshot itself).
local function LoadoutCoverage(activeRow, plan, catalog)
    if type(activeRow) ~= "table" or type(activeRow.echoes) ~= "table"
        or type(plan) ~= "table" or type(plan.wishedFamilies) ~= "table" then
        return {}, nil, {}
    end
    local targets = type(plan.targets) == "table" and plan.targets or {}
    local famStacks = {}
    local locked = {}
    for i = 1, #activeRow.echoes do
        local e = activeRow.echoes[i]
        local fam = e and e.family
        if fam and plan.wishedFamilies[fam] then
            famStacks[fam] = (famStacks[fam] or 0) + (tonumber(e.stacks) or 1)
            if e.locked then
                local row = catalog and catalog.rows and catalog.rows[e.spellId]
                locked[#locked + 1] = (row and row.name) or ("spell " .. tostring(e.spellId))
            end
        end
    end
    local stackTotal, stackCount = 0, 0
    local missing = {}
    for fam in pairs(plan.wishedFamilies) do
        local target = targets[fam]
        local want = (type(target) == "table" and tonumber(target.targetStacks)) or 1
        stackTotal = stackTotal + want
        local have = famStacks[fam] or 0
        stackCount = stackCount + math.min(have, want)
        if have < want then
            local nm = catalog and catalog.familyName and catalog.familyName[fam]
            missing[#missing + 1] = nm or fam
        end
    end
    table.sort(missing)
    table.sort(locked)
    return missing, { stackCount = stackCount, stackTotal = stackTotal }, locked
end

-- Builds the one progress table every render site feeds to the panel:
-- this run's gains, the active loadout's convergence toward the ideal
-- wishlist, and the loadout's specific missing echoes (what "close to
-- ideal" actually means, not just a percentage).
local function BuildProgress(plan, owned, slots, catalog, wishlistOverride, previewBuildId)
    local runStacks, wishTotal, wishlistMissing = WishlistProgress(plan, owned, catalog)
    local loadoutMissing, loadoutStacks, locked =
        LoadoutCoverage(ActiveSlotRow(slots), plan, catalog)
    local wl = wishlistOverride or Adapter.Wishlist()

    -- Build a set of families that are LOCKED in the active slot -- the
    -- player intentionally placed these and they should never appear as
    -- "to shed" even if they aren't on the wishlist.
    local lockedByFamily = {}
    if Adapter.LockedOwned then
        local lockedOwned = Adapter.LockedOwned()
        if lockedOwned and type(lockedOwned.byFamily) == "table" then
            lockedByFamily = lockedOwned.byFamily
        end
    end
    local activeRow = ActiveSlotRow(slots)
    if type(activeRow) == "table" and type(activeRow.echoes) == "table" then
        for _, e in ipairs(activeRow.echoes) do
            if e.locked and e.family then
                lockedByFamily[e.family] = (lockedByFamily[e.family] or 0)
                    + (tonumber(e.stacks) or 1)
            end
        end
    end

    -- Shed echoes: families currently owned but NOT on the wishlist AND
    -- NOT locked by the player. Locked echoes are intentionally placed
    -- and will always be on the build -- never list them as "shed".
    local shed = {}
    if type(plan) == "table" and type(plan.wishedFamilies) == "table"
        and type(owned) == "table" and owned.byFamily then
        for fam, count in pairs(owned.byFamily) do
            local removable = math.max(0, (tonumber(count) or 0)
                - (tonumber(lockedByFamily[fam]) or 0))
            if removable > 0 and not plan.wishedFamilies[fam] then
                local nm = catalog and catalog.familyName and catalog.familyName[fam]
                shed[#shed + 1] = tostring(nm or fam)
                    .. (removable > 1 and (" ×" .. removable) or "")
            end
        end
        table.sort(shed)
    end

    -- Find the WR Build that matches the WISHLIST (not the exact owned
    -- set). This is what the player is working toward, so the panel
    -- shows DPS numbers even when the run isn't complete yet.
    local matchedBuildId = nil
    local D = Nexus.DpsCapture
    if D and D.FindMatchingBuildPublic and wl then
        -- Try wishlist-based match first (works mid-run)
        matchedBuildId = D.FindMatchingBuildPublic(wl)
    end

    local wishlistEchoes = wl and (wl.echoes or wl.entries) or nil
    local unknownTomes = Adapter.UnknownTomesForEchoes and Adapter.UnknownTomesForEchoes(wishlistEchoes) or {}
    return { owned = runStacks, total = wishTotal, missing = wishlistMissing, unknownTomes = unknownTomes,
        loadoutMissing = loadoutMissing, loadoutStacks = loadoutStacks, locked = locked, shed = shed,
        wishlistName = wl and ((wl.name ~= "" and wl.name) or "(unnamed)") or nil,
        activeSlot = activeRow and tonumber(activeRow.slot) or 0,
        matchedBuildId = matchedBuildId, previewBuildId = previewBuildId,
        dpsEchoes = wishlistEchoes,
        isCommunityPreview = previewBuildId and true or false }
end


local function BuildPanelProgress(activePlan, owned, slots, catalog)
    local C = Nexus.CommunityBuilds
    local build = C and C.GetSelectedBuildForPanel and C.GetSelectedBuildForPanel()
    if build and type(build.echoes) == "table" and #build.echoes > 0 then
        local wl = { name = build.title or "Community Build", entries = build.echoes }
        local previewPlan = Strategy.Compile(catalog, wl, Store.Settings())
        return BuildProgress(previewPlan, owned, slots, catalog, wl, build.id)
    end
    return BuildProgress(activePlan, owned, slots, catalog)
end

-- Renders the panel with just status + progress, no board cards. Used at
-- every point in Step() where StepRun isn't running this tick (level 1,
-- level 80 with no board, or catalog not yet loaded) -- otherwise the
-- panel only ever refreshes while an echo board is live and freezes
-- showing stale leveling-era content the rest of the time, which breaks
-- both "check status at level 80" and "alt-tab between characters".
-- All args may be nil; WishlistProgress/LoadoutCoverage are null-safe.
local function RenderIdlePanel(plan, owned, slots, catalog)
    local settings = Store.Settings()
    local okAuto = AutoAllowed()
    Panel.Render({
        status = statusLine,
        cards = {},
        recommendation = "",
        progress = BuildPanelProgress(plan, owned, slots, catalog),
        level = Adapter.Level(),
        auto = okAuto and settings.autoPick,
        version = Nexus.VERSION,
    })
end

local function StepArm(level, plan, owned, slots, disabledLevers)
    local settings = Store.Settings()
    -- (a) activate best verified snapshot. Advisor mode (no wishlist) is
    -- read-only: never auto-arm a snapshot the user didn't ask for
    -- (BestSlot would pick an arbitrary least-filler slot).
    if settings.autoActivate and slots and not plan.advisorOnly then
        local best = Ratchet.BestSlot(slots, plan, Adapter.Catalog())
        -- SS-541 failures (combat/dead/...) are consumed invisibly by the
        -- client: retry the SAME target on a 5s timer until SS-542 moves
        -- activeSlot, bounded at 3 attempts
        local retryDue = armTargetSlot == best and armPendingSince
            and (GetTime() - armPendingSince) > 5
        if best and best ~= slots.activeSlot and armAttempts < 3
            and (armTargetSlot ~= best or retryDue) then
            local ok = Adapter.Activate(best)
            if ok then
                armAttempts = armAttempts + 1
                armTargetSlot = best
                armPendingSince = GetTime()
                armedConfirmed, boardsSinceArm = false, 0
                SetStatus("activating snapshot slot " .. best
                    .. (armAttempts > 1 and (" (attempt " .. armAttempts .. ")") or ""))
            end
        elseif best and best ~= slots.activeSlot and armAttempts >= 3 then
            SetStatus("activation not confirmed after 3 tries -- in combat/dead? activate manually")
        elseif not best and not ActiveSlotRow(slots) then
            SetStatus("Seeding run -- no verified snapshot to arm")
        end
    end
    -- (b) disable off-wishlist conformant tome levers (one send per 0.5s)
    if settings.autoDisable and plan and not plan.advisorOnly
        and Adapter.DiscoverySynced()
        and (GetTime() - lastLeverSendAt) > 0.5 then
        local optOut = settings.leverOptOut or {}
        for _, lever in ipairs(plan.leverPlan.disable) do
            if not optOut[lever] and not disabledLevers[lever]
                and not leversDoneThisVisit[lever] then
                if not Adapter.LeverHasKnownMember(lever) then
                    -- unknown tome: its echo isn't in your pool, so there is
                    -- nothing to disable. Skip (marking done so we never
                    -- retry it -- this was the "no confirmation" spam).
                    leversDoneThisVisit[lever] = true
                else
                    local ok = Adapter.ToggleLever(lever, true)
                    if ok then
                        leversDoneThisVisit[lever] = true
                        lastLeverSendAt = GetTime()
                        SetStatus("disabling off-wishlist tome lever " .. lever)
                        break
                    end
                end
            end
        end
        -- (c) RE-ENABLE any confirmed-disabled lever the wishlist now
        -- needs (a wishlist switch after earlier disables would otherwise
        -- silently make convergence impossible)
        if (GetTime() - lastLeverSendAt) > 0.5 then
            for _, lever in ipairs(plan.leverPlan.keep) do
                if disabledLevers[lever] == "confirmed" then
                    local ok = Adapter.ToggleLever(lever, false)
                    if ok then
                        lastLeverSendAt = GetTime()
                        SetStatus("re-enabling wishlist tome lever " .. lever)
                        break
                    end
                end
            end
        end
    end
    RenderIdlePanel(plan, owned, slots, Adapter.Catalog())
end

local function WatchRerollHold(board)
    -- reroll-hold observation: if our last action was a reroll and the
    -- previous board carried a guaranteed card, a changed flag-3 identity
    -- kills the tactic permanently (conservative).
    if lastDecision and lastDecision.type == "reroll" and lastBoardForRerollWatch then
        local prevG, curG = nil, nil
        local pb = lastBoardForRerollWatch
        if pb.guaranteedIndex then prevG = pb.cards[pb.guaranteedIndex].spellId end
        if board.guaranteedIndex then curG = board.cards[board.guaranteedIndex].spellId end
        if prevG and prevG ~= curG then
            local st = Store.State()
            st.rerollHoldViolations = (st.rerollHoldViolations or 0) + 1
            DemoteFlag("REROLL_HOLDS_GUARANTEED", "guaranteed head changed across a reroll")
        end
        lastBoardForRerollWatch = nil
    end
end

local function SelfCheckDisable(board, disabledLevers, catalog)
    -- user-confirmed DISABLE_SUPPRESSES_GUARANTEE=true: if a disabled
    -- lever's echo ever shows up flag-3 anyway, demote for the session.
    if not board.guaranteedIndex then return end
    local g = board.cards[board.guaranteedIndex]
    local row = catalog and catalog.rows[g.spellId]
    if not (row and row.requiredSpell ~= 0) then return end
    -- only a server-CONFIRMED disable proves anything; a pending one may
    -- simply not have been processed before this board was rolled
    if disabledLevers[row.requiredSpell] ~= "confirmed" then return end
    -- and only a CONFORMANT lever we actually disabled: the garbage
    -- requiredSpell=9 cohort (38 unrelated echoes) is never disabled by us,
    -- so a member appearing guaranteed after the user hand-disables one
    -- cohort sibling in the journal is NOT evidence against suppression.
    local lever = catalog.levers and catalog.levers[row.requiredSpell]
    if not (lever and lever.conformant) then return end
    DemoteFlag("DISABLE_SUPPRESSES_GUARANTEE",
        "disabled tome echo " .. tostring(g.spellId) .. " appeared guaranteed")
end

local function StepRun(level, plan, slots, owned, flags, disabledLevers)
    local settings = Store.Settings()
    local catalog = Adapter.Catalog()
    local board = Adapter.Board()
    if not board then
        SetStatus("waiting for board")
        Panel.Render({ status = statusLine, cards = {}, recommendation = "",
            progress = BuildProgress(plan, owned, slots, catalog),
            auto = AutoAllowed() and settings.autoPick,
            version = Nexus.VERSION })
        return
    end

    if armTargetSlot and not armedConfirmed then
        boardsSinceArm = boardsSinceArm + 1
        if board.guaranteedIndex then
            armedConfirmed = true
            SetStatus("armed (guaranteed queue live)")
        elseif boardsSinceArm >= 3 then
            SetStatus("Activate did not guarantee -- treating as unarmed")
        end
    end

    WatchRerollHold(board)
    SelfCheckDisable(board, disabledLevers, catalog)

    local activeRow = ActiveSlotRow(slots)
    local queue = Ratchet.PredictQueue(activeRow and activeRow.echoes or {},
        owned, plan, flags, disabledLevers, catalog)
    local charges = Adapter.Charges()
    local state = {
        board = board, owned = owned, charges = charges, plan = plan,
        queue = queue, flags = flags, level = level, catalog = catalog,
        horizon = Adapter.Horizon(),
        canFreeze = (level < 80) and (frozeThisBoard ~= board.signature),
        support = Model.Support(catalog, owned, level, disabledLevers, plan, DefaultProfile.params),
        params = DefaultProfile.params,
    }
    local action = Policy.Decide(state)

    -- ------------------------------------------------------------------
    -- Decision log (manual-training data). One entry per fresh board:
    -- everything needed to replay the decision offline, plus whatever
    -- the USER manually clicked on that board. Lives in SavedVariables
    -- (NexusDB.decisionLog) -- persists on /reload or logout.
    -- ------------------------------------------------------------------
    do
        NexusDB.decisionLog = NexusDB.decisionLog or {}
        local log = NexusDB.decisionLog
        -- Attach any pending user action to the PREVIOUS entry BEFORE
        -- creating this tick's new one. See file header note above.
        local ua = Adapter.ConsumeUserAction and Adapter.ConsumeUserAction()
        if ua and #log > 0 then
            local e = log[#log]
            e.user = e.user or {}
            e.user[#e.user + 1] = { kind = ua.kind, arg = ua.arg }
        end
        if lastLoggedSig ~= board.signature then
            lastLoggedSig = board.signature
            local entry = {
                t = date and date("%H:%M:%S") or "",
                level = level,
                sig = board.signature,
                gIndex = board.guaranteedIndex,
                charges = { b = charges.banish, r = charges.reroll,
                            f = charges.freeze, ok = charges.trustworthy },
                proposal = { type = action.type, spellId = action.spellId,
                             index = action.index, reason = action.reason,
                             steps = action.steps },
                cards = {},
                pending = (function()
                    local out = {}
                    for _, qe in ipairs(queue.entries or {}) do
                        if type(qe) == "table" and qe.family then
                            out[#out + 1] = tostring(qe.family)
                                .. (qe.wanted and "*" or "")
                        end
                    end
                    return table.concat(out, ",")
                end)(),
            }
            for i = 1, #board.cards do
                local c = board.cards[i]
                local row = catalog.rows[c.spellId]
                local fam = c.family
                entry.cards[i] = {
                    id = c.spellId,
                    name = row and row.name or ("spell " .. tostring(c.spellId)),
                    fam = tostring(fam),
                    cardQ = c.quality,
                    catQ = row and row.quality,
                    maxStack = row and row.maxStack,
                    g = c.isGuaranteed or nil,
                    frozen = (c.isFrozen or c.isCarried or c.justFrozen) or nil,
                    wished = (plan.wishedFamilies and fam
                        and plan.wishedFamilies[fam]) and true or false,
                    wishQ = Model.EffectiveWishedQuality
                        and Model.EffectiveWishedQuality(plan, catalog, fam) or nil,
                    owned = (owned and owned.byFamily and fam
                        and owned.byFamily[fam]) or 0,
                    delta = action.deltas and action.deltas[i],
                    ann = action.annotations and action.annotations[i],
                }
            end
            log[#log + 1] = entry
            while #log > 500 do table.remove(log, 1) end
        end
    end

    -- render (bridge display names onto the copies -- Readout is id-blind)
    local cardLines = {}
    for i = 1, #board.cards do
        local card = board.cards[i]
        local row = catalog.rows[card.spellId]
        card.name = row and row.name or nil
        cardLines[#cardLines + 1] = {
            text = Readout.CardLine(card,
                action.annotations and action.annotations[i],
                action.deltas and action.deltas[i]),
            highlight = (action.type == "take"
                and board.cards[i].spellId == action.spellId),
        }
    end
    local okAuto, autoWhy = AutoAllowed()
    local recommendation = action.reason or action.type or ""
    if type(action.steps) == "table" and #action.steps > 0 then
        local lines = {}
        for si, step in ipairs(action.steps) do
            local row = step.spellId and catalog.rows[step.spellId]
            local label = step.type == "freeze" and "Freeze"
                or step.type == "take" and "Take"
                or tostring(step.type)
            lines[#lines + 1] = string.format("%d. %s %s",
                si, label, row and row.name or ("spell " .. tostring(step.spellId or "?")))
        end
        recommendation = table.concat(lines, "\n")
    end
    Panel.Render({
        status = statusLine,
        cards = cardLines,
        progress = BuildPanelProgress(plan, owned, slots, catalog),
        level = level,
        recommendation = recommendation,
        auto = okAuto and settings.autoPick,
        version = Nexus.VERSION,
    })

    -- pacing: decide, show intent, act after a short beat
    if action.type == "wait" then
        SetStatus(action.reason == "advisor"
            and "No wishlist set -- advisor only" or ("waiting: " .. tostring(action.reason)))
        return
    end
    SetStatus("L" .. level .. " -- " .. (action.reason or action.type))
    if not (okAuto and settings.autoPick) then
        if not okAuto then SetStatus("auto paused: " .. autoWhy) end
        return
    end
    if lastDecidedSig ~= board.signature then
        lastDecidedSig, lastDecision, decidedAt = board.signature, action, GetTime()
        return -- show the intent one beat before acting
    end
    if (GetTime() - (decidedAt or 0)) < 0.4 then return end
    if Adapter.InFlight() then return end

    if action.type == "take" then
        Adapter.Take(action.spellId)
    elseif action.type == "banish" and settings.autoBanish then
        -- Policy indexes cards 1-based; the client (and adapter) are 0-based
        local ok, err = Adapter.Banish(action.index - 1)
        if ok then
            SetStatus(string.format("|cffff6666Banished|r echo #%d", action.index))
        end
    elseif action.type == "freeze" then
        -- one freeze per board; the follow-up banish/reroll happens on a
        -- later tick once this resolves
        local ok = Adapter.Freeze(action.index - 1)
        if ok then
            frozeThisBoard = board.signature
            SetStatus(string.format("|cff66aaff Froze|r echo #%d -- waiting for board to update",
                action.index))
        else
            frozeThisBoard = board.signature   -- refused: do not retry this board
        end
    elseif action.type == "reroll" then
        lastBoardForRerollWatch = board
        Adapter.Reroll()
    end
end

local function StepSave(level, plan, slots, owned)
    RenderIdlePanel(plan, owned, slots, Adapter.Catalog())
    local settings = Store.Settings()
    if not settings.autoSave or savedThisVisit then return end
    if plan.advisorOnly then
        -- with no wishlist every family is "filler": Dominates would bless
        -- any smaller build and shrink the snapshot -- never save
        SetStatus("No wishlist set -- not saving")
        return
    end
    if not slots then SetStatus("waiting for slot data"); return end
    if not owned.synced then SetStatus("waiting for owned-state sync"); return end
    local catalog = Adapter.Catalog()
    local incumbent = ActiveSlotRow(slots)
    if incumbent then
        local ok, detail = Ratchet.Dominates(owned, incumbent.echoes, plan, catalog)
        if ok then
            local saved = Adapter.Save(incumbent.slot, incumbent.name)
            if saved then
                -- send != success: SS-541 FAIL (combat/dead) is consumed
                -- invisibly. Block re-save, but only CONFIRM after a fresh
                -- SS-540 shows the slot now holds the improved build.
                savedThisVisit = true
                saveVerifySlot, saveVerifyAt, seedVerify =
                    incumbent.slot, GetTime(), false
                slotsRefreshAt = GetTime() + 3.5
                SetStatus("Run saved to slot " .. incumbent.slot .. " — loadout updated")
            end
        else
            local wl = Adapter.Wishlist()
            local wlName = wl and ((wl.name ~= "" and wl.name) or "your build") or "your build"
            -- Translate the raw Ratchet detail into something readable
            local readableDetail
            if tostring(detail):find("no net gain") then
                readableDetail = "no new wishlist Echoes this run — bad RNG, not a bug"
            elseif tostring(detail):find("coverage lost") then
                readableDetail = "this run lost a wishlist Echo vs your saved snapshot"
            else
                readableDetail = tostring(detail)
            end
            SetStatus(string.format(
                "Working toward '%s' — run complete, no improvement (%s)",
                wlName, readableDetail))
            NexusDB.lastSaveRefusal = {
                t = date and date("%H:%M:%S") or "",
                level = level, detail = tostring(detail),
                incumbentSlot = incumbent.slot,
            }
        end
    else
        -- Seeding: only create a new snapshot if the player has NO echo
        -- data in any slot at all. If they have existing slots with echoes,
        -- the problem is activation (wrong slot is active), not seeding.
        -- Seeding into an empty slot when slots with data exist was causing
        -- the "must manually overwrite your loadout after first run" bug.
        local hasAnyData = false
        for _, slotData in pairs(slots.bySlot) do
            if slotData and slotData.echoes and #slotData.echoes > 0 then
                hasAnyData = true; break
            end
        end
        if hasAnyData then
            SetStatus("Activate a slot to let Nexus track your run")
        else
            -- Truly fresh install: seed into the first unlocked empty slot
            local unlocked = Adapter.UnlockedSlots()
            local target = nil
            for slot = 1, math.min(slots.maxSlots, unlocked) do
                if slots.bySlot[slot] == nil then target = slot; break end
            end
            if target then
                local saved = Adapter.Save(target, "Nexus")
                if saved then
                    savedThisVisit = true
                    saveVerifySlot, saveVerifyAt, seedVerify = target, GetTime(), true
                    slotsRefreshAt = GetTime() + 3.5
                    SetStatus("seed save sent to slot " .. target .. " -- confirming")
                end
            else
                SetStatus("no free unlocked snapshot slot -- save manually to seed")
            end
        end
    end
end

local function Step()
    local level = Adapter.Level()
    if lastLevelSeen ~= level then
        if level == 1 then
            leversDoneThisVisit = {}
            armAttempts, armTargetSlot = 0, nil
            armedConfirmed, boardsSinceArm = false, 0
            saveVerifySlot, seedVerify = nil, nil
            Adapter.RunBoundaryReset()   -- void the dead run's picks/trust
        end
        if level ~= 80 then savedThisVisit = false end
        lastLevelSeen = level
    end
    if Adapter.ExternalActionSeen() then
        externalPauseUntil = GetTime() + 3
    end

    local catalog = Adapter.Catalog()
    if not catalog then
        SetStatus("waiting for ProjectEbonhold")
        RenderIdlePanel(nil, nil, nil, nil)
        return
    end
    local wishlist = Adapter.Wishlist()
    if not quickStartChecked then
        quickStartChecked = true
        if Nexus.QuickStart then
            Nexus.QuickStart.ShowIfFirstTime(wishlist ~= nil)
        end
    end
    local plan = Strategy.Compile(catalog, wishlist, Store.Settings())
    local slots = Adapter.Slots()
    local owned = Adapter.Owned()
    local flags = EffectiveFlags()
    local disabledLevers = Adapter.DisabledLevers()

    -- once per session, clear stale flag demotions (they are session-
    -- scoped per addendum C; a real one re-arms on the first evidence)
    if not demotionsClearedThisSession and Adapter.Ready() then
        Store.State().flagDemotions = {}
        demotionsClearedThisSession = true
    end

    -- post-save verification: refresh the slot cache (a save does NOT
    -- update GetServerBuildSlots; only a fresh CS 340 does)
    if slotsRefreshAt and GetTime() >= slotsRefreshAt then
        if Adapter.RequestSlots() then slotsRefreshAt = nil end
    end

    -- confirm a sent save against the refreshed slot content: only latch
    -- "saved" once the fresh SS-540 proves the build landed; a silent
    -- SS-541 FAIL (combat/dead at 80) clears savedThisVisit so it retries.
    if saveVerifySlot and not slotsRefreshAt then
        local row = slots and slots.bySlot[saveVerifySlot]
        local confirmed
        if seedVerify then
            confirmed = row ~= nil                 -- the empty slot is now populated
        else
            confirmed = row ~= nil
                and not Ratchet.Dominates(owned, row.echoes, plan, catalog)
        end
        if confirmed then
            SetStatus("snapshot confirmed saved to slot " .. saveVerifySlot)
            Print("snapshot saved to slot " .. saveVerifySlot)
            saveVerifySlot, seedVerify = nil, nil
        elseif GetTime() - (saveVerifyAt or 0) > 8 then
            savedThisVisit = false                 -- unconfirmed -> allow a retry
            saveVerifySlot, seedVerify = nil, nil
            SetStatus("save not confirmed (in combat/dead?) -- will retry")
        end
    end

    if level == 1 then
        StepArm(level, plan, owned, slots, disabledLevers)
        if plan.advisorOnly then
            SetStatus("No wishlist set -- advisor only")
        end
    elseif level >= 2 and level < 80 then
        StepRun(level, plan, slots, owned, flags, disabledLevers)
    elseif level == 80 then
        -- the FINAL board arrives at 80: spend it before judging the save,
        -- or the snapshot captures the build with one roll unspent
        if Adapter.Board() then
            StepRun(level, plan, slots, owned, flags, disabledLevers)
        else
            StepSave(level, plan, slots, owned)
        end
    end
end

------------------------------------------------------------------------
-- Journal tab data provider
------------------------------------------------------------------------

local function JournalData()
    local catalog = Adapter.Catalog()
    local wishlist = Adapter.Wishlist()
    local plan = Strategy.Compile(catalog, wishlist, Store.Settings())
    local owned = Adapter.Owned()
    local slots = Adapter.Slots()
    local flags = EffectiveFlags()
    local disabledLevers = Adapter.DisabledLevers()
    local sections = {}

    if not wishlist then
        local note = Adapter.WishlistNote and Adapter.WishlistNote()
        sections[#sections + 1] = { title = "Target", lines = {
            "No wishlist set -- advisor only.",
            note or "Design a build with 'New Wishlist' (the Echo Wishlist section).",
        } }
    else
        local ownedN, pending, filler = 0, {}, {}
        for fam in pairs(plan.wishedFamilies) do
            if (owned.byFamily[fam] or 0) > 0 then ownedN = ownedN + 1
            else pending[#pending + 1] = catalog.familyName[fam] or fam end
        end
        local activeRow = ActiveSlotRow(slots)   -- genuinely-verified only
        if activeRow then
            local seen = {}
            for _, e in ipairs(activeRow.echoes) do
                if not plan.wishedFamilies[e.family] and not seen[e.family] then
                    seen[e.family] = true
                    filler[#filler + 1] = catalog.familyName[e.family] or e.family
                end
            end
        end
        table.sort(pending); table.sort(filler)
        local famN = 0
        for _ in pairs(plan.wishedFamilies) do famN = famN + 1 end
        local srcTag = (wishlist.source == "designed" and " (Echo Wishlist build)")
            or (wishlist.source == "active" and " (active loadout)") or ""
        local lines = {
            string.format("Wishlist '%s'%s: %d families -- %d owned, %d pending, %d filler in snapshot",
                wishlist.name, srcTag, famN, ownedN, #pending, #filler),
        }
        sections[#sections + 1] = { title = "Target", lines = lines }
        sections[#sections + 1] = { title = "Pending (" .. #pending .. ")", lines = pending }
        local fillerLines = {}
        for _, f in ipairs(filler) do
            fillerLines[#fillerLines + 1] = f .. (flags.DISABLE_SUPPRESSES_GUARANTEE
                and "  (shed via disable or skip)" or "  (will shed next run)")
        end
        sections[#sections + 1] = { title = "Lingering filler", lines = fillerLines }
    end

    local leverLines = {}
    for _, lever in ipairs(plan.leverPlan.disable) do
        leverLines[#leverLines + 1] = string.format("lever %d: disable%s", lever,
            disabledLevers[lever] and " (done)" or "")
    end
    for _, lever in ipairs(plan.leverPlan.skippedNonConformant) do
        leverLines[#leverLines + 1] = string.format("lever %d: skipped (non-conformant data)", lever)
    end
    sections[#sections + 1] = { title = "Tome levers", lines = leverLines }
    local est = "no estimate (advisor mode)"
    if wishlist then
        local activeRow = ActiveSlotRow(slots)
        local queue = Ratchet.PredictQueue(activeRow and activeRow.echoes or {},
            owned, plan, flags, disabledLevers, catalog)
        local e = Ratchet.RunsEstimate(plan, owned, queue, nil)
        est = (e and e.text) or "estimate unavailable"
    end
    sections[#sections + 1] = { title = "Notes", lines = {
        "Targets the ACTIVE loadout (journal 'Play with...'), not designed slots.",
        est,
    } }
    return { sections = sections, version = Nexus.VERSION }
end

------------------------------------------------------------------------
-- Init + events + slash
------------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- Log viewer data providers (/wr log). Pure text assembly; the viewer
-- renders whatever these return, one tab each.
-- ---------------------------------------------------------------------

local function FamLabel(catalog, fam)
    local nm = catalog and catalog.familyName and catalog.familyName[fam]
    return nm and (tostring(fam) .. " '" .. tostring(nm) .. "'") or tostring(fam)
end

-- ---------------------------------------------------------------------
-- TEMPORARY: PerkService API sniffer (/wr sniff)
-- ---------------------------------------------------------------------
-- Purely observational -- never calls anything, only logs what the
-- game's OWN Echo Journal UI invokes on PerkService while the person
-- manually edits their wishlist. This is how we find the real
-- add/remove-echo function for a DESIGNED build slot without guessing
-- and risking a destructive call against a real, curated wishlist.
-- Remove once the real function is identified and wired in properly.
local sniffLog, sniffInstalled = {}, false
-- Recursively dumps a table's contents (bounded depth/breadth so a huge
-- catalog table can't hang the client or spam the log) instead of just
-- tostring()'ing its memory address. This is exactly the gap that hid
-- UploadServerBuildSlot's actual echo-data shape in the first capture
-- (2026-07-24) -- we saw "table: 210720A8" instead of what was in it.
local function SerializeArg(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return tostring(v) end
    if depth >= 3 then return "{...}" end
    local parts = {}
    local n = 0
    -- array part first, in order
    for i, item in ipairs(v) do
        parts[#parts + 1] = SerializeArg(item, depth + 1)
        n = n + 1
        if n >= 20 then parts[#parts + 1] = "...(truncated)"; break end
    end
    -- then any non-array (hash) keys
    if n < 20 then
        for k, val in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                parts[#parts + 1] = tostring(k) .. "=" .. SerializeArg(val, depth + 1)
                n = n + 1
                if n >= 20 then parts[#parts + 1] = "...(truncated)"; break end
            end
        end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- hooksecurefunc fires AFTER the original call with the original's
-- ARGUMENTS, never its return value -- structurally can't see what a
-- getter like GetSharedEchoLoadouts() actually hands back. For a small
-- whitelist of "interesting" read functions, fully wrap (call through +
-- log the result) instead, so we can see the real data shape rather than
-- guessing at it before building UI around an assumption.
local RETURN_LOGGED_FUNCTIONS = {
    GetSharedEchoLoadouts = true,
    GetActiveEchoLoadout = true,
    GetEchoLoadouts = true,
}

local function InstallSniffer()
    if sniffInstalled then return end
    local svc = ProjectEbonhold and ProjectEbonhold.PerkService
    if not svc then return end
    for name, fn in pairs(svc) do
        if type(fn) == "function" then
            if RETURN_LOGGED_FUNCTIONS[name] then
                svc[name] = function(...)
                    local results = { pcall(fn, ...) }
                    local argParts = {}
                    for i = 1, select("#", ...) do
                        local ok, str = pcall(SerializeArg, select(i, ...))
                        argParts[#argParts + 1] = ok and str or "<unserializable>"
                    end
                    local retParts = {}
                    for i = 2, #results do
                        local ok, str = pcall(SerializeArg, results[i])
                        retParts[#retParts + 1] = ok and str or "<unserializable>"
                    end
                    sniffLog[#sniffLog + 1] = string.format("%s(%s) -> %s", name,
                        table.concat(argParts, ", "), table.concat(retParts, ", "))
                    if #sniffLog > 200 then table.remove(sniffLog, 1) end
                    if results[1] then
                        return unpack(results, 2)
                    end
                end
            else
                hooksecurefunc(svc, name, function(...)
                    local parts = {}
                    for i = 1, select("#", ...) do
                        local ok, str = pcall(SerializeArg, select(i, ...))
                        parts[#parts + 1] = ok and str or "<unserializable>"
                    end
                    sniffLog[#sniffLog + 1] = string.format("%s(%s)", name,
                        table.concat(parts, ", "))
                    if #sniffLog > 200 then table.remove(sniffLog, 1) end
                end)
            end
        end
    end
    sniffInstalled = true
end

local function LogText_Sniffer()
    local out = { string.format("PERKSERVICE SNIFFER -- %d calls captured", #sniffLog),
        "(purely observational -- run /wr sniff, then click in the Echo",
        " Journal's wishlist designer, then reopen this tab / hit Refresh)", "" }
    for i = 1, #sniffLog do
        out[#out + 1] = sniffLog[i]
    end
    if #sniffLog == 0 then
        out[#out + 1] = "(no calls captured yet)"
    end
    return table.concat(out, "\n")
end

local function LogText_Boards()
    local log = NexusDB and NexusDB.decisionLog or {}
    local out = { string.format("DECISION LOG -- %d boards (v%s)",
        #log, Nexus.VERSION), "" }
    for i = 1, #log do
        local e = log[i]
        out[#out + 1] = string.format("== #%d [%s] L%s  charges B:%s R:%s F:%s%s",
            i, tostring(e.t), tostring(e.level),
            tostring(e.charges and e.charges.b),
            tostring(e.charges and e.charges.r),
            tostring(e.charges and e.charges.f),
            (e.charges and e.charges.ok == false) and " (untrusted)" or "")
        for ci = 1, #(e.cards or {}) do
            local c = e.cards[ci]
            out[#out + 1] = string.format(
                "  %d%s %s id=%s fam=%s q=%s/cat:%s wishQ=%s max=%s own=%s d=%s %s%s",
                ci, c.g and "[G]" or "", tostring(c.name), tostring(c.id),
                tostring(c.fam), tostring(c.cardQ), tostring(c.catQ),
                tostring(c.wishQ), tostring(c.maxStack), tostring(c.owned),
                tostring(c.delta), tostring(c.ann),
                (c.wished and "" or " OFF-WISHLIST"))
            if c.frozen then out[#out] = out[#out] .. " FROZEN" end
        end
        out[#out + 1] = string.format("  proposal: %s %s (%s)",
            tostring(e.proposal and e.proposal.type),
            tostring(e.proposal and (e.proposal.spellId or e.proposal.index or "")),
            tostring(e.proposal and e.proposal.reason))
        if e.user then
            for _, u in ipairs(e.user) do
                out[#out + 1] = string.format("  USER: %s(%s)",
                    tostring(u.kind), tostring(u.arg))
            end
        end
        if e.pending and e.pending ~= "" then
            out[#out + 1] = "  pending guarantee: " .. e.pending
        end
        out[#out + 1] = ""
    end
    return table.concat(out, "\n")
end

-- A user action "matches" the proposal when it is the same verb aimed at
-- the same thing; anything else is a training mismatch worth reading.
local function UserMatchesProposal(u, p)
    if not (u and p) then return false end
    local k, a = tostring(u.kind), tonumber(u.arg)
    if k == "SelectPerk" then
        return p.type == "take" and a ~= nil and a == tonumber(p.spellId)
    elseif k == "BanishPerk" then
        return p.type == "banish" and a ~= nil and (a + 1) == tonumber(p.index)
    elseif k == "FreezePerk" then
        return p.type == "freeze" and a ~= nil and (a + 1) == tonumber(p.index)
    elseif k == "RequestReroll" then
        return p.type == "reroll"
    end
    return false
end

local function LogText_Mismatch()
    local log = NexusDB and NexusDB.decisionLog or {}
    local out = { "MISMATCHES -- boards where your manual play differed", "" }
    local nMis = 0
    for i = 1, #log do
        local e = log[i]
        if e.user then
            local anyMismatch = false
            for _, u in ipairs(e.user) do
                if not UserMatchesProposal(u, e.proposal) then anyMismatch = true end
            end
            if anyMismatch then
                nMis = nMis + 1
                out[#out + 1] = string.format("== board #%d [%s] L%s",
                    i, tostring(e.t), tostring(e.level))
                for ci = 1, #(e.cards or {}) do
                    local c = e.cards[ci]
                    out[#out + 1] = string.format(
                        "  %d%s %s id=%s fam=%s q=%s wishQ=%s own=%s d=%s %s%s",
                        ci, c.g and "[G]" or "", tostring(c.name), tostring(c.id),
                        tostring(c.fam), tostring(c.cardQ), tostring(c.wishQ),
                        tostring(c.owned), tostring(c.delta), tostring(c.ann),
                        (c.wished and "" or " OFF-WISHLIST"))
                end
                out[#out + 1] = string.format("  addon: %s %s (%s)",
                    tostring(e.proposal and e.proposal.type),
                    tostring(e.proposal and (e.proposal.spellId or e.proposal.index or "")),
                    tostring(e.proposal and e.proposal.reason))
                for _, u in ipairs(e.user) do
                    out[#out + 1] = string.format("  you:   %s(%s)",
                        tostring(u.kind), tostring(u.arg))
                end
                out[#out + 1] = ""
            end
        end
    end
    if nMis == 0 then out[#out + 1] = "(none recorded yet)" end
    return table.concat(out, "\n")
end

local function LogText_Wishlist()
    local catalog = Adapter.Catalog()
    local wl = Adapter.Wishlist()
    local out = {}
    if not wl then
        return "no wishlist resolved" ..
            (Adapter.WishlistNote and (" -- " .. tostring(Adapter.WishlistNote())) or "")
    end
    local plan = Strategy.Compile(catalog, wl, Store.Settings())
    local owned = Adapter.Owned()
    out[#out + 1] = string.format("WISHLIST '%s' source=%s -- %d entries",
        tostring(wl.name), tostring(wl.source), #wl.entries)
    local nFam = 0
    for _ in pairs(plan.wishedFamilies or {}) do nFam = nFam + 1 end
    out[#out + 1] = string.format("plan.wishedFamilies: %d families", nFam)
    out[#out + 1] = ""
    local orphans = {}
    for _, e in ipairs(wl.entries) do
        local row = catalog and catalog.rows[e.spellId]
        local fam = e.family
        local members = catalog and catalog.familyMembers
            and catalog.familyMembers[fam] or {}
        local mq = {}
        for _, mid in ipairs(members) do
            local mr = catalog.rows[mid]
            mq[#mq + 1] = tostring(mid) .. ":q" .. tostring(mr and mr.quality)
        end
        local inPlan = plan.wishedFamilies and plan.wishedFamilies[fam] and true or false
        local effQ = Model.EffectiveWishedQuality
            and Model.EffectiveWishedQuality(plan, catalog, fam) or "?"
        out[#out + 1] = string.format(
            "%s id=%s q=%s stacks=%s fam=%s effWishQ=%s own=%s%s",
            tostring(row and row.name or ("spell " .. tostring(e.spellId))),
            tostring(e.spellId), tostring(e.quality), tostring(e.stacks),
            FamLabel(catalog, fam), tostring(effQ),
            tostring(owned.byFamily and owned.byFamily[fam] or 0),
            inPlan and "" or "  <-- NOT IN PLAN")
        out[#out + 1] = "    variants: " .. (next(mq) and table.concat(mq, ", ")
            or "(sole variant)")
        if not inPlan then orphans[#orphans + 1] = tostring(row and row.name or e.spellId) end
    end
    out[#out + 1] = ""
    if #orphans > 0 then
        out[#out + 1] = "!! ENTRIES MISSING FROM PLAN (this is the ST/AB bug surface):"
        out[#out + 1] = "   " .. table.concat(orphans, ", ")
    else
        out[#out + 1] = "all wishlist entries resolved into the plan"
    end
    return table.concat(out, "\n")
end

local function LogText_State()
    local catalog = Adapter.Catalog()
    local wl = Adapter.Wishlist()
    local plan = wl and Strategy.Compile(catalog, wl, Store.Settings())
        or { advisorOnly = true }
    local slots = Adapter.Slots()
    local owned = Adapter.Owned()
    local charges = Adapter.Charges()
    local out = {}
    out[#out + 1] = string.format("v%s  level=%s  auto=%s",
        Nexus.VERSION, tostring(Adapter.Level()),
        tostring(autoEnabled))
    out[#out + 1] = string.format("charges B:%s R:%s F:%s trustworthy=%s",
        tostring(charges.banish), tostring(charges.reroll),
        tostring(charges.freeze), tostring(charges.trustworthy))
    for k, v in pairs(EffectiveFlags()) do
        out[#out + 1] = "flag " .. tostring(k) .. " = " .. tostring(v)
    end
    local s = Store.Settings()
    out[#out + 1] = string.format(
        "settings: autoPick=%s autoActivate=%s autoBanish=%s autoSave=%s autoDisable=%s",
        tostring(s.autoPick), tostring(s.autoActivate), tostring(s.autoBanish),
        tostring(s.autoSave), tostring(s.autoDisable))
    out[#out + 1] = ""
    local refusal = NexusDB and NexusDB.lastSaveRefusal
    if refusal then
        out[#out + 1] = string.format(
            "LAST SAVE REFUSAL [%s] L%s slot %s: %s",
            tostring(refusal.t), tostring(refusal.level),
            tostring(refusal.incumbentSlot), tostring(refusal.detail))
        out[#out + 1] = "  (\"coverage lost: X\" = a wished family X the active loadout"
        out[#out + 1] = "   already has is missing from this run. \"no net gain\" = coverage"
        out[#out + 1] = "   held even but this run picked up more off-wishlist filler than"
        out[#out + 1] = "   the active loadout carries -- not a coverage regression.)"
        out[#out + 1] = ""
    end
    if slots then
        out[#out + 1] = "SLOTS (activeSlot=" .. tostring(slots.activeSlot) .. "):"
        local ids = {}
        for id in pairs(slots.bySlot or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local row = slots.bySlot[id]
            out[#out + 1] = string.format("  slot %s '%s' verified=%s echoes=%d%s",
                tostring(id), tostring(row.name), tostring(row.verified),
                #(row.echoes or {}), row.suspectParse and " SUSPECT" or "")
            if id == slots.activeSlot then
                for _, e in ipairs(row.echoes or {}) do
                    out[#out + 1] = string.format(
                        "      id=%s fam=%s q=%s stacks=%s%s wished=%s",
                        tostring(e.spellId), tostring(e.family), tostring(e.quality),
                        tostring(e.stacks), e.locked and " locked" or "",
                        tostring(plan.wishedFamilies
                            and plan.wishedFamilies[e.family] or false))
                end
            end
        end
    else
        out[#out + 1] = "SLOTS: not loaded"
    end
    out[#out + 1] = ""
    out[#out + 1] = "OWNED byFamily:"
    local fams = {}
    for fam in pairs(owned.byFamily or {}) do fams[#fams + 1] = fam end
    table.sort(fams, function(a, b) return tostring(a) < tostring(b) end)
    for _, fam in ipairs(fams) do
        out[#out + 1] = string.format("  %s x%s", FamLabel(catalog, fam),
            tostring(owned.byFamily[fam]))
    end
    out[#out + 1] = string.format("owned synced=%s", tostring(owned.synced))
    return table.concat(out, "\n")
end

local function LogText_Sync()
    local s = Nexus.Sync
    if not s then return "sync module not loaded" end
    local out = {}
    local function Add(fmt, ...)
        local ok, line = pcall(string.format, fmt, ...)
        out[#out + 1] = ok and line or tostring(fmt)
    end

    Add("SYNC DIAGNOSTICS -- Nexus v%s", tostring(Nexus.VERSION))
    Add("")
    Add("-- connection --")
    Add("channel name   : %s", s.ChannelName())
    Add("connected      : %s", tostring(s.IsConnected()))
    Add("channel index  : %s", tostring(s.ChannelIndex()))
    Add("my name        : %s", tostring((UnitName and UnitName("player")) or "?"))
    Add("receiving now  : %s (%.0fs left)", tostring(s.IsReceiving()), s.ReceiveTimeLeft())
    Add("last sync new  : %d build(s)", s.LastSyncNewCount())
    Add("")

    local st = s.Stats()
    Add("-- counters --")
    Add("messages sent          : %d", st.sent or 0)
    Add("builds stored (new)    : %d", (st.received or 0) - (st.updated or 0))
    Add("builds updated         : %d", st.updated or 0)
    Add("skipped (peer up2date) : %d", st.skippedUpToDate or 0)
    Add("duplicates skipped     : %d", st.duplicatesSkipped or 0)
    Add("malformed rejected     : %d", st.malformedRejected or 0)
    Add("ignored (no sync open) : %d", st.ignoredOutsideWindow or 0)
    Add("oversize dropped       : %d", st.oversizeDropped or 0)
    Add("deleted (tombstoned)   : %d", s.TombstoneCount and s.TombstoneCount() or 0)
    Add("")

    Add("-- builds in my library --")
    local mine, theirs = 0, 0
    for _, b in pairs((NexusDB and NexusDB.communityBuilds) or {}) do
        if b.isMine then
            mine = mine + 1
            Add("  [MINE]  %-28s %2d echoes  stamp=%s",
                tostring(b.title), #(b.echoes or {}),
                tostring(b.lastModified or b.postedAt))
        else
            theirs = theirs + 1
            Add("  [THEIRS] %-27s %2d echoes  by %s",
                tostring(b.title), #(b.echoes or {}), tostring(b.author))
        end
    end
    if mine + theirs == 0 then Add("  (none)") end
    Add("  total: %d mine, %d from others", mine, theirs)
    Add("")

    Add("-- event log (newest last) --")
    local log = s.EventLog()
    if #log == 0 then
        Add("  (empty -- no sync activity yet this session)")
        Add("  If you pressed Sync Now and this is still empty, the addon")
        Add("  is not seeing ANY traffic on the channel.")
    else
        local t0 = log[1].t or 0
        for i = 1, #log do
            local e = log[i]
            Add("  [%7.2fs] %-5s %s", (e.t or 0) - t0, e.cat or "?", e.text or "")
        end
    end
    return table.concat(out, "\n")
end

local function LogViewerProvider(tabKey)
    if tabKey == "boards" then return LogText_Boards() end
    if tabKey == "mismatch" then return LogText_Mismatch() end
    if tabKey == "wishlist" then return LogText_Wishlist() end
    if tabKey == "state" then return LogText_State() end
    if tabKey == "sync" then return LogText_Sync() end
    if tabKey == "dps" then
        local D = Nexus.DpsCapture
        return D and D.GetDebugLog and D.GetDebugLog() or "DPS module unavailable"
    end
    if tabKey == "sniffer" then return LogText_Sniffer() end
    return "unknown tab: " .. tostring(tabKey)
end

-- Immediate repaint hook used when a DPS result is committed. This avoids
-- waiting for the normal poll interval and guarantees the panel reads the
-- newly saved exact-set best from SavedVariables.
function Nexus.RefreshPanel()
    if not initialized or not Adapter.Ready() then return false end
    local ok, err = pcall(Step)
    if not ok then Nexus.lastError = err; return false end
    return true
end

local function Init()
    if initialized then return end
    Model = Nexus.Model
    Policy = Nexus.Policy
    Ratchet = Nexus.Ratchet
    Strategy = Nexus.Strategy
    Store = Nexus.Store
    Adapter = Nexus.GameAdapter
    Readout = Nexus.Readout
    Panel = Nexus.Panel
    JournalTab = Nexus.JournalTab
    DefaultProfile = Nexus.DefaultProfile
    if not (Model and Policy and Ratchet and Strategy and Store
        and Adapter and Readout and Panel and DefaultProfile) then
        return -- missing module: stay uninitialized, retry next event
    end
    Store.Init()
    Adapter.Init({ OnStatus = Print }, Store)
    if Nexus.LogViewer and Nexus.LogViewer.Init then
        Nexus.LogViewer.Init(LogViewerProvider)
    end
    if Nexus.WishlistEditor and Nexus.WishlistEditor.Init then
        Nexus.WishlistEditor.Init(Adapter, Model)
    end
    if Nexus.WishlistOverlay and Nexus.WishlistOverlay.Init then
        Nexus.WishlistOverlay.Init(Adapter, Model)
        if NexusDB.overlayShown then
            Nexus.WishlistOverlay.Show()
        end
    end
    if Nexus.CommunityBuilds and Nexus.CommunityBuilds.Init then
        Nexus.CommunityBuilds.Init(Adapter, Model)
    end
    if Nexus.Leaderboard and Nexus.Leaderboard.Init then
        Nexus.Leaderboard.Init(Adapter, Model)
    end
    if Nexus.Nameplate and Nexus.Nameplate.Init then
        Nexus.Nameplate.Init()
    end
    Panel.Init({ ToggleAuto = function()
        autoEnabled = not autoEnabled
        Print("auto " .. (autoEnabled and "ON" or "OFF"))
        return autoEnabled   -- Panel uses this to repaint the button NOW
    end })
    initialized = true
    Print("v" .. Nexus.VERSION .. " -- type /nexus for commands.")
    if Adapter.RivalDetected() then
        Print("|cffff6060EchoOptimizer detected -- it replaces the board hook. Disable it; the Realizer replaces it.|r")
    end
end

EH = CreateFrame("Frame")
EH:RegisterEvent("ADDON_LOADED")
EH:RegisterEvent("PLAYER_ENTERING_WORLD")
EH:RegisterEvent("PLAYER_LEVEL_UP")
EH:RegisterEvent("CHAT_MSG_CHANNEL")
EH:RegisterEvent("PLAYER_REGEN_DISABLED")
EH:RegisterEvent("PLAYER_REGEN_ENABLED")
EH:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4,
                                 arg5, arg6, arg7, arg8, arg9)
    if event == "ADDON_LOADED" and arg1 == "Nexus" then
        Init()
    elseif event == "PLAYER_ENTERING_WORLD" then
        Init()
        if initialized then
            Adapter.OnEvent(event)
            if Store.Settings().autoPick then Adapter.SetSoloPicker() end
            Adapter.RequestSlots()
            if JournalTab then JournalTab.TryInstall(JournalData) end
            if Nexus.Sync and Nexus.Codec then
                Nexus.Sync.Init(Nexus.Codec, Adapter)
            end
            if Nexus.DpsCapture then
                Nexus.DpsCapture.Init(Adapter, Nexus.Sync)
            end
        end
    elseif event == "PLAYER_LEVEL_UP" then
        if initialized then Adapter.OnEvent(event) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if initialized and Nexus.DpsCapture then
            pcall(Nexus.DpsCapture.OnCombatStart)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if initialized and Nexus.DpsCapture then
            pcall(Nexus.DpsCapture.OnCombatEnd)
        end
    elseif event == "CHAT_MSG_CHANNEL" then
        -- 3.3.5 CHAT_MSG_CHANNEL: arg1=text, arg2=sender, arg3=language,
        -- arg4=channel name WITH its number prefix ("5. wrbuildssync"),
        -- arg8=channel number, arg9=bare channel name.
        --
        -- Comparing the bare name against arg4 alone never matched (live
        -- bug 2026-07-24: nothing was ever received, and peers never saw
        -- each other's sync requests either). Accept either form.
        if initialized and Nexus.Sync then
            local want = Nexus.Sync.ChannelName()
            local bare = type(arg9) == "string" and arg9:lower() or nil
            local numbered = nil
            if type(arg4) == "string" then
                numbered = (arg4:lower():gsub("^%s*%d+%.%s*", ""))
            end
            if bare == want or numbered == want then
                local ok, err = pcall(Nexus.Sync.HandleIncoming, arg1, arg2)
                if not ok then
                    Nexus.lastError = err
                    Nexus.Sync.LogEvent("RX", "handler ERROR: %s", tostring(err))
                end
            elseif type(arg1) == "string" and arg1:find("^WLR") then
                -- Our protocol seen on a channel we didn't match -- the
                -- single most useful clue if filtering ever breaks again.
                Nexus.Sync.LogEvent("RX",
                    "MISMATCH arg4=%q arg9=%q (wanted %q)",
                    tostring(arg4), tostring(arg9), want)
            end
        end
    end
end)
EH:SetScript("OnUpdate", function(_, elapsed)
    -- Detect addon interference: a frame time well above our poll cadence
    -- indicates another addon is blocking the main thread. Report once per
    -- minute so the player knows to investigate (/framerate, /fstack).
    if elapsed and elapsed > LAG_THRESHOLD then
        local now = GetTime and GetTime() or 0
        if now - lagWarnedAt > LAG_WARN_COOLDOWN then
            lagWarnedAt = now
            print(string.format(
                "|cffff9040Nexus:|r frame stall detected (%.1fs). " ..
                "Another addon may be interfering. Try |cffffd200/fstack|r to identify it " ..
                "or disable other addons one by one.",
                elapsed))
        end
    end
    if not initialized then return end
    -- OnUpdate fires during the login loading screen (ADDON_LOADED before
    -- PLAYER_ENTERING_WORLD). Running the loop then would call
    -- GetActiveEchoLoadout / UnitClass before the player is known and
    -- poison the client's session char-key + class mask (addendum B5).
    if not Adapter.Ready() then return end
    if Nexus.Sync then
        pcall(Nexus.Sync.OnUpdate, elapsed)
    end
    if Nexus.DpsCapture then
        pcall(Nexus.DpsCapture.OnUpdate, elapsed)
    end
    if sniffPaused then
        pollAccum = pollAccum + (elapsed or 0)
        if pollAccum < POLL then return end
        pollAccum = 0
        SetStatus("|cffff6060sniffer active -- polling paused (/nexus sniffdump to resume)|r")
        if Panel and Panel.Render then
            Panel.Render({ status = statusLine, cards = {}, recommendation = "",
                progress = nil, auto = autoEnabled, version = Nexus.VERSION })
        end
        return
    end
    pollAccum = pollAccum + (elapsed or 0)
    if pollAccum < POLL then return end
    pollAccum = 0
    local okPoll, errPoll = pcall(Adapter.Poll)
    if not okPoll then Nexus.lastError = errPoll end
    local ok, err = pcall(Step)
    if not ok then
        SetStatus("error (see /nexus err)")
        Nexus.lastError = err
    end
end)

SLASH_NEXUS1 = "/nexus"
SLASH_NEXUS2 = "/nx"
SLASH_NEXUS3 = "/wr"   -- legacy alias kept for muscle memory
SlashCmdList["NEXUS"] = function(msg)
    if not initialized then Print("not initialized yet") return end
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local settings = Store.Settings()
    if msg == "auto" then
        autoEnabled = not autoEnabled
        Print("auto " .. (autoEnabled and "ON" or "OFF"))
        if Panel.SetAuto then Panel.SetAuto(autoEnabled) end
    elseif msg == "panel" then
        Panel.Toggle()
    elseif msg == "restore" then
        Print(Adapter.RestoreAutoAccept() and "client auto-accept restored"
            or "nothing to restore")
    elseif msg == "flags" then
        for k, v in pairs(EffectiveFlags()) do
            Print(k .. " = " .. tostring(v))
        end
        local st = Store.State()
        for k, why in pairs(st.flagDemotions or {}) do
            Print("demoted " .. k .. ": " .. tostring(why))
        end
    elseif msg == "status" then
        if sniffPaused then
            Print("|cffff6060NOTE: sniffer is active -- background polling is PAUSED.|r")
            Print("Run /nexus sniffdump when done to resume normal operation.")
        end
        local catalog = Adapter.Catalog()
        local wl = Adapter.Wishlist()
        local slots = Adapter.Slots()
        local owned = Adapter.Owned()
        Print("v" .. Nexus.VERSION .. " -- level " .. Adapter.Level()
            .. ", auto " .. (autoEnabled and "ON" or "OFF"))
        -- Target (wishlist)
        if wl then
            local src = (wl.source == "designed" and "Echo Wishlist build")
                or (wl.source == "active" and "active loadout") or "wishlist"
            Print(string.format("TARGET: |cff7fff7f'%s'|r (your %s) -- %d echoes",
                (wl.name ~= "" and wl.name) or "(unnamed)", src, #wl.entries))
        else
            local note = Adapter.WishlistNote and Adapter.WishlistNote()
            Print("TARGET: none -- advisor only" .. (note and ("  (" .. note .. ")") or ""))
        end
        -- Loadout / snapshot data (the guarantee source)
        if not slots then
            Print("LOADOUTS: slot data not loaded yet (waiting on the server).")
        else
            local nsnap, ndesign = 0, 0
            for _, s in pairs(slots.bySlot) do
                if type(s.echoes) == "table" and #s.echoes > 0 then
                    if s.verified then nsnap = nsnap + 1 else ndesign = ndesign + 1 end
                end
            end
            local act = slots.activeSlot
            if act ~= 0 and slots.bySlot[act] then
                local s = slots.bySlot[act]
                Print(string.format("ACTIVE slot %d '%s': %s, %d echoes", act,
                    (s.name ~= "" and s.name) or "?",
                    s.verified and "snapshot (arms the guarantee)"
                        or "designed build (highlight only -- not a guarantee)",
                    #s.echoes))
            else
                Print("ACTIVE: no build activated right now.")
            end
            Print(string.format("READABLE: %d loadout snapshot(s), %d designed wishlist build(s)",
                nsnap, ndesign))
            if wl and Ratchet and Ratchet.BestSlot then
                local plan = Strategy.Compile(catalog, wl, Store.Settings())
                local best = Ratchet.BestSlot(slots, plan, catalog)
                Print(best and ("Would arm snapshot slot " .. best .. " at level 1.")
                    or "No verified snapshot to arm -- first run seeds one.")
            end
        end
        Print(string.format("OWNED this run: %d echoes (%s).", owned.distinct or 0,
            owned.synced and "synced" or "not synced yet"))
    elseif msg == "wishlist" or msg == "check" then
        local wl = Adapter.Wishlist()
        if not wl then
            local note = Adapter.WishlistNote and Adapter.WishlistNote()
            if note then
                Print(note)
            else
                Print("no wishlist detected -- running as advisor only.")
                Print("Design one in the Echo Journal: 'New Wishlist' (the 'Echo Wishlist'")
                Print("section), pick its echoes, and save it. The addon reads that build.")
            end
        else
            local cat = Adapter.Catalog()
            local src = (wl.source == "designed" and "your Echo Wishlist build")
                or (wl.source == "active" and "your active loadout")
                or "your wishlist"
            local famset = {}
            for _, e in ipairs(wl.entries) do famset[e.family] = true end
            local nfam = 0
            for _ in pairs(famset) do nfam = nfam + 1 end
            Print(string.format("reading |cff7fff7f'%s'|r (from %s) -- %d echoes, %d families",
                (wl.name ~= "" and wl.name) or "(unnamed)", src, #wl.entries, nfam))
            local names = {}
            for _, e in ipairs(wl.entries) do
                local row = cat and cat.rows[e.spellId]
                names[#names + 1] = (row and row.name or ("spell " .. e.spellId))
                    .. (e.stacks > 1 and (" x" .. e.stacks) or "")
            end
            table.sort(names)
            Print("  " .. table.concat(names, ", "))
        end
    elseif msg == "progress" or msg == "missing" then
        local catalog = Adapter.Catalog()
        local wl = Adapter.Wishlist()
        local owned = Adapter.Owned()
        if not wl then
            Print("no wishlist set -- advisor only, nothing to track.")
        else
            local plan = Strategy.Compile(catalog, wl, Store.Settings())
            local haveN, totalN, missing = WishlistProgress(plan, owned, catalog)
            local pct = (totalN > 0) and math.floor(haveN / totalN * 100 + 0.5) or 0
            Print(string.format("this run: |cff7fff7f%d/%d|r echoes (%d%%) -- %d still short",
                haveN, totalN, pct, #missing))
            if msg == "missing" and #missing > 0 then
                Print("  " .. table.concat(missing, ", "))
            end
        end
    elseif msg == "editor" then
        if Nexus.WishlistEditor then
            Nexus.WishlistEditor.Toggle()
        else
            Print("wishlist editor unavailable")
        end
    elseif msg == "syncdebug" then
        if Nexus.LogViewer then
            Nexus.LogViewer.Show("sync")
        else
            Print("log viewer unavailable")
        end
    elseif msg == "nameplate" then
        local NP = Nexus.Nameplate
        if NP then
            Print("Nameplate: active. Mouse over another player to see their Nexus rank.")
            Print("The tag appears only for players with data in your local leaderboard.")
        else
            Print("Nameplate module not loaded.")
        end
    elseif msg == "dps" then
        -- Always-on: this just shows the current capture status
        local D = Nexus.DpsCapture
        if not D then Print("DPS capture module not loaded"); return end
        if D.IsDetailsAvailable() then
            Print("|cff4dff80DPS capture is active.|r")
            Print("Fight the Lich King or hit a training dummy to record your best.")
        else
            Print("|cffff9040Details! damage meter is not installed.|r")
            Print("Install Details! to enable DPS tracking on your builds.")
        end
        if Nexus.lastDpsNote then
            Print("Last session: " .. Nexus.lastDpsNote)
        end
        local wl = Adapter.Wishlist()
        if wl and D.GetEchoKey then
            Print("Selected wishlist key: " .. tostring(D.GetEchoKey(wl.entries)))
        end
        if D.GetCurrentEchoKey then
            Print("Current tracked Echo key: " .. tostring(D.GetCurrentEchoKey()))
        end
        Print("Open /nexus log and select DPS for the full capture trace.")
    elseif msg == "sync" then
        if Nexus.Sync then
            local ok, err = Nexus.Sync.RequestSync()
            if ok then
                Print("asking other players for their builds -- results appear in /nexus builds")
            else
                Print(tostring(err))
            end
        else
            Print("sync unavailable")
        end
    elseif msg == "builds" then
        if Nexus.CommunityBuilds then
            Nexus.CommunityBuilds.Toggle()
        else
            Print("Nexus Builds unavailable")
        end
    elseif msg == "leaderboard" or msg == "ranks" then
        if Nexus.Leaderboard then
            Nexus.Leaderboard.Toggle()
        else
            Print("Nexus Leaderboard unavailable")
        end
    elseif msg == "sniff" then
        InstallSniffer()
        sniffPaused = true
        Print("PerkService sniffer active -- Nexus's own background")
        Print("polling is PAUSED so the log stays clean. Now go do ONE thing in")
        Print("the real UI (add/remove an echo in the wishlist designer, OR")
        Print("browse Community Loadouts and import one), then /nexus sniffdump.")
    elseif msg == "sniffdump" then
        sniffPaused = false
        if Nexus.LogViewer then
            Nexus.LogViewer.Show("sniffer")
        else
            Print("log viewer unavailable")
        end
    elseif msg == "log" or msg == "logs" then
        if Nexus.LogViewer then
            Nexus.LogViewer.Toggle()
        else
            Print("log viewer unavailable")
        end
    elseif msg == "logclear" then
        if NexusDB then NexusDB.decisionLog = {} end
        Print("decision log cleared")
    elseif msg == "err" then
        Print(tostring(Nexus.lastError))
    elseif msg == "undemote" then
        local st = Store.State()
        st.flagDemotions = {}
        Print("flag demotions cleared (they re-arm on fresh evidence)")
    elseif msg == "overlay" then
        if Nexus.WishlistOverlay then
            Nexus.WishlistOverlay.Toggle()
        else
            Print("overlay unavailable")
        end
    elseif msg:match("^anchor") then
        local arg = msg:match("^anchor%s+(%S+)")
        if arg == "off" or arg == nil then
            settings.anchorSpellId = nil
            Print("anchor cleared")
        else
            settings.anchorSpellId = tonumber(arg)
            Print("anchor set to " .. tostring(settings.anchorSpellId))
        end
    else
        Print("v" .. Nexus.VERSION .. " -- " .. statusLine)
        Print("|cffffd200Nexus v" .. Nexus.VERSION .. "|r  --  /nexus (or /nx, /wr)")
        Print("|cffffd200Setup:|r  builds  |  leaderboard  |  editor  |  sync  |  overlay")
        Print("|cffffd200Run:|r    auto  |  panel  |  status  |  wishlist  |  progress")
        Print("|cffffd200Data:|r   log  |  dps  |  nameplate  |  logclear")
        Print("|cffffd200Fixes:|r  flags  |  undemote  |  anchor <id|off>  |  restore  |  err")
        Print("|cffffd200Dev:|r    sniff  |  sniffdump")
    end
end
