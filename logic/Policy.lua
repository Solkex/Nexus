-- Nexus: logic/Policy.lua
-- Pure per-board decision engine, v2 quality- and guarantee-aware greedy.
-- Board model: 2 free slots + at most 1 guaranteed (flag-3) card; select
-- is mandatory; freeze does NOT consume the board (freeze fires, then the
-- take happens on the next tick of the same board), which makes banking a
-- stacking-wishlist card nearly free. Policy PROPOSES; the adapter
-- re-checks and may drop. Never targets a guaranteed/frozen/carried/
-- justFrozen card with banish/reroll. No WoW API calls; plain Lua 5.1.
--
-- The three live-play rules this version encodes (2026-07-24 session):
--  A. QUALITY GATE -- a below-wished-quality copy of a single-stack,
--     multi-quality family (the stat echoes) scores qualityMiss (< filler):
--     taking it locks the family at the wrong quality AND poisons the
--     saved loadout. The wished quality per family comes from the
--     wishlist itself (plan.targets[fam].wishedQuality) -- no hardcoded
--     stat list.
--  B. DEFER -- a free-slot wished card whose guarantee is still pending
--     (family present in the predicted queue) will come back on its own;
--     its take-value is discounted by deferFactor so a one-shot pick
--     (guaranteed head, banked stack copy, at-quality stat catch) never
--     loses to it. An at-or-above-wished-quality catch of a multi-quality
--     family is NEVER deferred: the guarantee is level-gated and may only
--     serve the low-quality variant, so the free-slot catch is the real
--     opportunity.
--  C. BANK -- a free-slot copy of a wished STACKING family below its
--     stack target is frozen whenever it isn't this board's own pick
--     (the guarantee only ever serves a family's first copy; stacks
--     2..N are free-slot RNG only). A frozen/carried wanted card keeps
--     full value and is taken the first board the guaranteed head is
--     junk or wrong-quality.

Nexus = Nexus or {}
local Policy = {}
Nexus.Policy = Policy

local NEG_INF = -math.huge

-- Resolved at call time, never at file load (load order is not ours).
local Model

local function GetModel()
    Model = Model or Nexus.Model
    return Model
end

local function OwnedFam(owned, fam)
    if fam == nil or type(owned) ~= "table" then return 0 end
    local byFamily = owned.byFamily
    return (type(byFamily) == "table" and tonumber(byFamily[fam])) or 0
end

local function Wished(plan, fam)
    return fam ~= nil and type(plan.wishedFamilies) == "table"
        and plan.wishedFamilies[fam] and true or false
end

local function WishedQuality(plan, fam)
    local t = type(plan.targets) == "table" and plan.targets[fam] or nil
    return (type(t) == "table" and tonumber(t.wishedQuality)) or 0
end

-- Base annotation: guaranteed > wanted > duplicate > filler > junk.
-- Decide overlays "banked" / "returns later" / "low quality" after the
-- effective-value pass.
local function Annotation(card, delta, plan, owned)
    if card.isGuaranteed then return "guaranteed" end
    local fam = card.family
    local wished = Wished(plan, fam)
    if wished and delta > 0 then return "wanted" end
    local have = OwnedFam(owned, fam)
    local cap = 1
    if wished and type(plan.targets) == "table" and plan.targets[fam] ~= nil then
        cap = plan.targets[fam].targetStacks or 1
    end
    if have > 0 and have >= cap then return "duplicate" end
    if not wished then return "filler" end
    return "junk"
end

-- state = { board, owned, charges, plan, queue, flags, level, horizon,
--           support, params, canFreeze [, catalog] }
-- Returns { type = "take"|"freeze"|"reroll"|"banish"|"wait", spellId=?,
--   index=?, reason = s, annotations = { [cardIndex] = s },
--   deltas = { [cardIndex] = n } }
-- Pure: same input, same output; malformed input degrades to "wait".
function Policy.Decide(state)
    local annotations = {}
    if type(state) ~= "table" then
        return { type = "wait", reason = "no board", annotations = annotations }
    end
    local Model = GetModel()
    if not Model or type(Model.Delta) ~= "function" then
        return { type = "wait", reason = "model unavailable", annotations = annotations }
    end

    local board = state.board
    local rawCards = type(board) == "table" and board.cards or nil
    if type(rawCards) ~= "table" or #rawCards == 0 then
        return { type = "wait", reason = "no board", annotations = annotations }
    end

    local owned = state.owned
    local plan = state.plan or { advisorOnly = true }
    local params = state.params or {}
    local charges = state.charges or {}
    local flags = state.flags or {}
    local level = tonumber(state.level)
    local catalog = state.catalog

    local cards = {}
    for i = 1, #rawCards do
        local c = rawCards[i]
        cards[i] = type(c) == "table" and c or {}
    end
    local n = #cards

    -- Guaranteed card first (annotation + defer logic both need it).
    local gIndex = board.guaranteedIndex
    if gIndex and not cards[gIndex] then gIndex = nil end
    if not gIndex then
        for i = 1, n do
            if cards[i].isGuaranteed then gIndex = i break end
        end
    end

    -- Families with a pending guarantee (the predicted queue).
    local pendingFam = {}
    do
        local entries = state.queue and state.queue.entries or nil
        if type(entries) == "table" then
            for i = 1, #entries do
                local e = entries[i]
                if type(e) == "table" and e.family ~= nil then
                    pendingFam[e.family] = true
                end
            end
        end
    end

    -- Deltas, effective take-values, annotations. Effective value is what
    -- the take comparison uses; raw delta is what the UI shows.
    local ownedSafe = owned or {}
    local deltas, eff = {}, {}
    local precious = {}   -- [i]=true: one-shot quality catch (see loop)
    local deferFactor = tonumber(params.deferFactor) or 0.35
    local bankedWantedOnBoard = false
    for i = 1, n do
        local card = cards[i]
        local d = Model.Delta(plan, ownedSafe, card.spellId, catalog, params)
        d = tonumber(d) or 0
        deltas[i] = d
        annotations[i] = Annotation(card, d, plan, ownedSafe)
        eff[i] = d

        local fam = card.family
        local frozenish = card.isFrozen or card.isCarried or card.justFrozen
        -- Precious catch: an at/above-wished-quality roll of a
        -- multi-quality wished, uncovered family. One-shot regardless of
        -- the guarantee queue -- the level-gated guarantee may only ever
        -- serve the low variant, so THIS roll is the opportunity.
        if not frozenish and d > 0 and Wished(plan, fam)
            and OwnedFam(ownedSafe, fam) <= 0
            and type(Model.FamilyMultiQuality) == "function"
            and Model.FamilyMultiQuality(catalog, fam)
            and (tonumber(card.quality) or 0)
                >= Model.EffectiveWishedQuality(plan, catalog, fam) then
            precious[i] = true
        end
        if frozenish and d > 0 then
            -- Banked: already secured with a freeze; full value. A
            -- justFrozen card cannot be selected this same board (client
            -- refuses) -- excluded from take below, but still banked.
            annotations[i] = "banked"
            bankedWantedOnBoard = true
        elseif i ~= gIndex and not frozenish and d > 0
            and Wished(plan, fam) and OwnedFam(ownedSafe, fam) <= 0
            and pendingFam[fam] then
            -- Pending guarantee: it comes back. Unless this roll is a
            -- precious catch (above) -- then never defer.
            if not precious[i] then
                eff[i] = d * deferFactor
                annotations[i] = "returns later"
            end
        elseif Wished(plan, fam) and d < 0
            and annotations[i] ~= "duplicate" then
            -- Negative delta on a non-duplicate wished family = the
            -- quality gate fired (Model.Delta rule A), whether on the
            -- first copy or a stack top-up.
            annotations[i] = "low quality"
        end
    end

    -- Wait states (annotated boards still returned so the UI renders).
    if (owned == nil or owned.synced == false) and level and level > 1 then
        return { type = "wait", reason = "unsynced",
            annotations = annotations, deltas = deltas }
    end
    if plan.advisorOnly then
        return { type = "wait", reason = "advisor",
            annotations = annotations, deltas = deltas }
    end

    local gDelta = gIndex and deltas[gIndex] or nil
    local gWanted = false
    if gIndex and gDelta and gDelta > 0 then
        gWanted = Wished(plan, cards[gIndex].family)
    end
    -- The quality gate makes a wrong-quality guaranteed head score
    -- negative, so gWanted is false for it and every "Taking guaranteed echo"
    -- path below is naturally skipped -- exactly the gray-Armor-Pen case.

    -- Presumptive take: best effective value among selectable cards
    -- (justFrozen excluded -- the client refuses same-board select of a
    -- just-frozen card). Ties go to the guaranteed head (one-shot).
    local takeIdx, takeEff = nil, NEG_INF
    for i = 1, n do
        if not cards[i].justFrozen then
            if eff[i] > takeEff
                or (eff[i] == takeEff and i == gIndex) then
                takeIdx, takeEff = i, eff[i]
            end
        end
    end
    if gIndex and gWanted and not cards[gIndex].justFrozen
        and eff[gIndex] >= takeEff then
        takeIdx, takeEff = gIndex, eff[gIndex]
    end

    -- BANK (rule C): freeze a free-slot card that is either (a) a copy of
    -- a wished stacking family below its stack target (the guarantee only
    -- ever serves a family's first copy; stacks 2..N are free-slot RNG
    -- only) or (b) a PRECIOUS quality catch (an at/above-wished-quality
    -- roll of a multi-quality wished family -- live 2026-07-24: a Rare
    -- Vitality that lost the take tie-break to Nature's Reprisal must be
    -- frozen, not lost, since the guarantee may only re-serve the gray
    -- variant). Fires whenever the card isn't this board's own pick.
    -- Runs BEFORE the tight-horizon check below: a precious catch that
    -- isn't yet in the predicted queue (e.g. a family just added to the
    -- wishlist this session) gets no other protection, and tight horizon
    -- would otherwise take the guaranteed and let it slip -- live
    -- 2026-07-24, a blue Strength Training lost to a tight-horizon
    -- guaranteed until manually frozen instead. Freeze doesn't consume
    -- the board: Main fires the freeze, marks the board, and this
    -- function runs again with canFreeze=false to place the take (the
    -- guaranteed, tight horizon or not, is still taken on that next
    -- tick). One per board; never a card already frozen/carried; never
    -- when a copy of the same family is already banked on this board.
    if (charges.freeze or 0) > 0 and charges.trustworthy ~= false
        and state.canFreeze ~= false then
        local function FindBankable(wantStack)
            for i = 1, n do
                local c = cards[i]
                local isStack = deltas[i] > 0
                    and type(Model.StackWishBelowTarget) == "function"
                    and Model.StackWishBelowTarget(plan, ownedSafe, c.family)
                local bankable = wantStack and isStack
                    or (not wantStack and precious[i] and not isStack)
                local protectBeforeGuaranteed = gIndex and gWanted
                    and i ~= gIndex and deltas[i] > 0 and Wished(plan, c.family)
                if i ~= gIndex and (i ~= takeIdx or protectBeforeGuaranteed) and bankable
                    and not (c.isFrozen or c.isCarried or c.justFrozen) then
                    local famAlreadyBanked = false
                    for j = 1, n do
                        local o = cards[j]
                        if j ~= i and o.family == c.family
                            and (o.isFrozen or o.isCarried or o.justFrozen) then
                            famAlreadyBanked = true
                        end
                    end
                    if not famAlreadyBanked then return i end
                end
            end
            return nil
        end
        -- Pass 1: a stacking-family copy (Double Strike, needing many
        -- more) always wins the single freeze over a precious catch.
        -- Pass 2: no stack candidate -- bank the precious catch instead.
        local bankIdx = FindBankable(true) or FindBankable(false)
        if bankIdx then
            local isStack = type(Model.StackWishBelowTarget) == "function"
                and Model.StackWishBelowTarget(plan, ownedSafe, cards[bankIdx].family)
            local followIdx = gIndex and gWanted and gIndex or takeIdx
            local steps = {
                { type = "freeze", index = bankIdx, spellId = cards[bankIdx].spellId },
            }
            if followIdx and followIdx ~= bankIdx then
                steps[#steps + 1] = {
                    type = "take", index = followIdx, spellId = cards[followIdx].spellId,
                }
            end
            return { type = "freeze", index = bankIdx,
                spellId = cards[bankIdx].spellId,
                reason = isStack and "bank stack copy (take follows)"
                    or "bank wanted Echo (take follows)",
                steps = steps,
                annotations = annotations, deltas = deltas }
        end
    end

    -- Tight regime: pending wanted guarantees fill the whole horizon;
    -- never divert a pick from the queue. Unknown horizon = abundant.
    local horizon = tonumber(state.horizon)
    if horizon and gIndex and gWanted then
        local wantedInQueue = 0
        local entries = state.queue and state.queue.entries or nil
        if type(entries) == "table" then
            for i = 1, #entries do
                local e = entries[i]
                if type(e) == "table" and e.wanted then
                    wantedInQueue = wantedInQueue + 1
                end
            end
        end
        if wantedInQueue >= horizon then
            return { type = "take", spellId = cards[gIndex].spellId, index = gIndex,
                reason = "tight horizon: take guaranteed",
                annotations = annotations, deltas = deltas }
        end
    end

    -- Reroll EV test, shared by two call sites: (1) before settling for a
    -- board whose best option is merely DEFERRED (a deferred card returns
    -- guaranteed by definition, so rerolling it away loses nothing), and
    -- (2) the classic junk-board chain. Conservative on missing params.
    -- Charge scarcity (live 2026-07-24, board with Banish 0): the cost
    -- escalates as remaining rerolls thin -- an abundant reroll is cheap,
    -- the last few are precious and reserved for genuinely junk boards.
    local function TryReroll(bestCurrent, reason, deferredOnly)
        local remaining = tonumber(charges.reroll) or 0
        if remaining <= 0 or charges.trustworthy == false
            or bankedWantedOnBoard then
            return nil
        end
        -- Dodging a POSITIVE deferred pick is a luxury: only with a
        -- comfortable reserve. Junk boards may spend down to the last.
        if deferredOnly
            and remaining < (tonumber(params.deferRerollFloor) or 4) then
            return nil
        end
        local holdOk = (gIndex == nil)
            or (flags.REROLL_HOLDS_GUARANTEED == true)
            or ((gDelta or NEG_INF) < (tonumber(params.rerollHoldThreshold) or NEG_INF))
        if not holdOk then return nil end
        if type(Model.FreeDist) ~= "function"
            or type(Model.EmaxGivenK) ~= "function" then
            return nil
        end
        local dist = Model.FreeDist(state.support)
        local cost = tonumber(params.rerollCost)
        if not (dist and cost) then return nil end
        local pacing = (tonumber(params.rerollPacingBase) or 6) / remaining
        if pacing < 1 then pacing = 1 end
        if Model.EmaxGivenK(dist, bestCurrent, 2) - cost * pacing > bestCurrent then
            return { type = "reroll", reason = reason,
                annotations = annotations, deltas = deltas }
        end
        return nil
    end

    -- Take the best free/banked card when it strictly beats the
    -- guaranteed head's value (deferred cards compete at their
    -- discounted value, so a pending-guarantee catch no longer diverts
    -- the pick from a one-shot).
    local gBar = (gIndex and eff[gIndex]) or NEG_INF
    if takeIdx and takeIdx ~= gIndex and takeEff > 0 and takeEff > gBar then
        if annotations[takeIdx] == "returns later" then
            -- Nothing one-shot on this board: the pick would only be a
            -- deferred card. Taking it now costs nothing (it's not a
            -- scarce resource), so a reroll only makes sense if it beats
            -- the card's TRUE value -- not its discounted take-comparison
            -- value (that discount exists only so a genuine one-shot can
            -- outrank a deferred pick above; reusing it here made reroll
            -- clear an artificially low bar and fire on boards that were
            -- already fine -- live 2026-07-24, five repeated L64 boards).
            local rr = TryReroll(deltas[takeIdx], "Rerolling — only deferred echoes on board", true)
            if rr then return rr end
        end
        return { type = "take", spellId = cards[takeIdx].spellId, index = takeIdx,
            reason = (annotations[takeIdx] == "banked") and "Taking held stack copy"
                or "Taking best available echo",
            annotations = annotations, deltas = deltas }
    end

    -- Else the guaranteed head, when present and wanted (at quality --
    -- the gate already zeroed the wrong-quality case out of gWanted).
    if gIndex and gWanted then
        return { type = "take", spellId = cards[gIndex].spellId, index = gIndex,
            reason = "take guaranteed",
            annotations = annotations, deltas = deltas }
    end

    -- Junk-board chain: banish, else reroll, else least-harmful take.

    -- Banish only on a genuinely junk board (no selectable card with a
    -- positive effective value): the redraw of the removed worst card is
    -- the improvement. Never a guaranteed/frozen/carried/justFrozen
    -- target, and NEVER a wished family regardless of its quality-gate
    -- status -- confirmed live 2026-07-24: banishing removes the entire
    -- family from the draw pool, including quality variants that haven't
    -- even appeared yet. A gray Strength Training scores worse than
    -- filler (qualityMiss < filler) but banishing it would permanently
    -- forfeit the blue variant for the run. Only a genuinely off-wishlist
    -- card is ever a safe banish target.
    local allFreeJunk = true
    for i = 1, n do
        if i ~= gIndex and eff[i] > 0 then allFreeJunk = false end
    end
    if allFreeJunk and (charges.banish or 0) > 0
        and not charges.banishSpentThisPush
        and charges.trustworthy ~= false then
        local worst, worstDelta = nil, 0
        for i = 1, n do
            local c = cards[i]
            if i ~= gIndex
                and not (c.isGuaranteed or c.isFrozen or c.isCarried or c.justFrozen)
                and not Wished(plan, c.family)
                and deltas[i] < worstDelta then
                worst, worstDelta = i, deltas[i]
            end
        end
        if worst then
            return { type = "banish", index = worst, spellId = cards[worst].spellId,
                reason = "junk board: banish worst",
                annotations = annotations, deltas = deltas }
        end
    end

    -- Reroll on a junk board (same shared gate as above) -- EXCEPT at
    -- level 80: there's no future board within this run left to conserve
    -- a reroll charge for, so per the "this can only ever be neutral or
    -- better" logic, spend one unconditionally rather than force a
    -- worthless duplicate/filler take.
    do
        local bestCurrent = NEG_INF
        for i = 1, n do
            if eff[i] > bestCurrent then bestCurrent = eff[i] end
        end
        if level and level >= 80 and bestCurrent <= 0
            and (charges.reroll or 0) > 0 and charges.trustworthy ~= false
            and not bankedWantedOnBoard then
            return { type = "reroll", reason = "endgame: nothing to lose, spend the charge",
                annotations = annotations, deltas = deltas }
        end
        local rr = TryReroll(bestCurrent, "Rerolling — redraw expected to improve board")
        if rr then return rr end
    end

    -- Least-harmful mandatory select. Structurally NEVER take a duplicate
    -- while any non-duplicate card exists (a new distinct echo, even
    -- filler, at least advances an Adaptive-Power-style distinct count),
    -- and never a justFrozen card while any other exists (the client
    -- refuses it this board). Among the eligible: max effective value;
    -- ties prefer non-filler, then lower quality, then lower index.
    local anyNonDup, anySelectable = false, false
    for i = 1, n do
        if annotations[i] ~= "duplicate" then anyNonDup = true end
        if not cards[i].justFrozen then anySelectable = true end
    end
    local pick = nil
    for i = 1, n do
        local eligible = ((not anyNonDup) or (annotations[i] ~= "duplicate"))
            and ((not anySelectable) or (not cards[i].justFrozen))
        if eligible then
            if pick == nil then
                pick = i
            else
                local better = false
                if eff[i] > eff[pick] then
                    better = true
                elseif eff[i] == eff[pick] then
                    local iFiller = annotations[i] == "filler"
                    local pFiller = annotations[pick] == "filler"
                    if pFiller and not iFiller then
                        better = true
                    elseif iFiller == pFiller
                        and (cards[i].quality or 0) < (cards[pick].quality or 0) then
                        better = true
                    end
                end
                if better then pick = i end
            end
        end
    end
    pick = pick or 1
    return { type = "take", spellId = cards[pick].spellId, index = pick,
        reason = (annotations[pick] == "duplicate") and "Forced take — all echoes already owned"
            or "Taking filler — will be replaced in a later run",
        annotations = annotations, deltas = deltas }
end
