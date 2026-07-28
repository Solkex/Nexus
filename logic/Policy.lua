-- Nexus: logic/Policy.lua
-- Pure deterministic board policy. During leveling, safe off-wishlist
-- Banishes are front-loaded after any exposed wanted side Echo is protected. A
-- wanted side card is still frozen first when the client reports a trustworthy
-- Freeze; the guaranteed card is selected only after that asynchronous
-- resolution. Guarantees outside the wishlist are never drained: side choices
-- are searched and one is selected instead.
-- Rerolls stay in the normal post-queue search phase. On a trustworthy
-- final-selection horizon, a held wanted Echo becomes the fallback while safe
-- search actions look for another wanted side Echo. If Freeze cannot be
-- trusted or was refused, the side card is taken as loss prevention.
-- No WoW APIs or SavedVariables; Lua 5.1 only.

Nexus = Nexus or {}
local Policy = {}
Nexus.Policy = Policy

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

local function WishedQuality(model, plan, catalog, fam)
    if type(model.EffectiveWishedQuality) == "function" then
        return tonumber(model.EffectiveWishedQuality(plan, catalog, fam)) or 0
    end
    local target = type(plan.targets) == "table" and plan.targets[fam] or nil
    return (type(target) == "table" and tonumber(target.wishedQuality)) or 0
end

local function IsFrozen(card)
    return card.isFrozen or card.isCarried or card.justFrozen
end

local function IsWanted(model, card, delta, plan, owned, catalog)
    if not (delta and delta > 0 and Wished(plan, card.family)) then return false end
    -- Model.Delta applies the quality gate. A below-required-quality variant
    -- therefore cannot become wanted merely because its family is wished.
    if type(model.FamilyMultiQuality) == "function"
        and model.FamilyMultiQuality(catalog, card.family)
        and (tonumber(card.quality) or 0)
            < WishedQuality(model, plan, catalog, card.family) then
        return false
    end
    return true
end

local function IsOneShot(model, card, plan, owned, catalog)
    return OwnedFam(owned, card.family) <= 0
        and type(model.FamilyMultiQuality) == "function"
        and model.FamilyMultiQuality(catalog, card.family)
        and (tonumber(card.quality) or 0)
            >= WishedQuality(model, plan, catalog, card.family)
end

local function WantedTier(model, card, plan, owned, catalog)
    if type(model.StackWishBelowTarget) == "function"
        and model.StackWishBelowTarget(plan, owned, card.family) then
        return 1
    end
    if IsOneShot(model, card, plan, owned, catalog) then return 2 end
    return 3
end

local function BetterWanted(model, cards, deltas, plan, owned, catalog,
    candidate, incumbent)
    if incumbent == nil then return true end
    local ct = WantedTier(model, cards[candidate], plan, owned, catalog)
    local it = WantedTier(model, cards[incumbent], plan, owned, catalog)
    if ct ~= it then return ct < it end
    if deltas[candidate] ~= deltas[incumbent] then
        return deltas[candidate] > deltas[incumbent]
    end
    return candidate < incumbent
end

local function QueueCanDeliverWanted(model, state, card, plan, catalog)
    local queue = type(state.queue) == "table" and state.queue.entries or nil
    if type(queue) ~= "table" or card.family == nil then return false end

    local multiQuality = type(model.FamilyMultiQuality) == "function"
        and model.FamilyMultiQuality(catalog, card.family)
    local requiredQuality = WishedQuality(model, plan, catalog, card.family)
    local rows = type(catalog) == "table" and catalog.rows or nil
    for i = 1, #queue do
        local entry = queue[i]
        if type(entry) == "table" and entry.wanted == true
            and entry.family == card.family then
            if not multiQuality then return true end
            local row = type(rows) == "table"
                and rows[tonumber(entry.spellId)] or nil
            local quality = (type(row) == "table" and tonumber(row.quality))
                or tonumber(entry.quality)
            if quality and quality >= requiredQuality then return true end
        end
    end
    return false
end

local function FreezeWorthy(model, state, card, plan, owned, catalog)
    -- Guaranteed injection only supplies the family's first copy. Extra
    -- stacks remain side-card RNG and are always worth protecting.
    if type(model.StackWishBelowTarget) == "function"
        and model.StackWishBelowTarget(plan, owned, card.family) then
        return true
    end
    -- A single-stack card that the remaining queue will deliver at a useful
    -- quality is not scarce. Save Freeze for a non-returning family or for a
    -- superior-quality catch when the queued variant is below target.
    return not QueueCanDeliverWanted(model, state, card, plan, catalog)
end

local function Annotation(card, delta, wanted, plan, owned)
    if card.isGuaranteed then return "guaranteed" end
    if wanted then return IsFrozen(card) and "banked" or "wanted" end
    local fam = card.family
    local have = OwnedFam(owned, fam)
    local target = type(plan.targets) == "table" and plan.targets[fam] or nil
    local cap = (type(target) == "table" and tonumber(target.targetStacks)) or 1
    if have > 0 and have >= cap then return "duplicate" end
    if Wished(plan, fam) and delta < 0 then return "low quality" end
    if not Wished(plan, fam) then return "filler" end
    return "junk"
end

local function Take(cards, annotations, deltas, index, reason)
    return {
        type = "take", index = index, spellId = cards[index].spellId,
        reason = reason, annotations = annotations, deltas = deltas,
    }
end

local function Endgame(action)
    action.endgame = true
    return action
end

local function SafeBanishCandidate(cards, deltas, plan, gIndex)
    local worst, worstDelta = nil, nil
    for i = 1, #cards do
        local card = cards[i]
        if i ~= gIndex
            and not (card.isGuaranteed or card.isFrozen or card.isCarried
                or card.justFrozen)
            and not Wished(plan, card.family)
            and (worst == nil or deltas[i] < worstDelta
                or (deltas[i] == worstDelta and i < worst)) then
            worst, worstDelta = i, deltas[i]
        end
    end
    return worst
end

local function LeastHarmfulSide(cards, annotations, deltas, gIndex)
    local anyNonDuplicate = false
    for i = 1, #cards do
        if i ~= gIndex and not cards[i].isGuaranteed
            and not cards[i].justFrozen
            and annotations[i] ~= "duplicate" then
            anyNonDuplicate = true
            break
        end
    end

    local pick = nil
    for i = 1, #cards do
        local eligible = i ~= gIndex and not cards[i].isGuaranteed
            and not cards[i].justFrozen
            and ((not anyNonDuplicate) or annotations[i] ~= "duplicate")
        if eligible and (pick == nil
            or deltas[i] > deltas[pick]
            or (deltas[i] == deltas[pick]
                and annotations[pick] == "filler"
                and annotations[i] ~= "filler")
            or (deltas[i] == deltas[pick]
                and (annotations[i] == "filler")
                    == (annotations[pick] == "filler")
                and (tonumber(cards[i].quality) or 0)
                    < (tonumber(cards[pick].quality) or 0))) then
            pick = i
        end
    end
    return pick
end

-- True when selecting fallbackCard would still leave at least one requested
-- wishlist stack missing. This prevents the final-search exception from
-- wasting charges when the protected card itself completes the wishlist.
local function MissingAfterFallback(plan, owned, fallbackCard, catalog)
    local wished = type(plan) == "table" and plan.wishedFamilies or {}
    local targets = type(plan) == "table" and plan.targets or {}
    local byFamily = type(owned) == "table" and owned.byFamily or {}
    local fallbackFamily = type(fallbackCard) == "table"
        and (fallbackCard.family
            or (type(catalog) == "table"
                and type(catalog.familyOf) == "table"
                and catalog.familyOf[tonumber(fallbackCard.spellId)]))
        or nil

    for family in pairs(wished) do
        local target = targets[family]
        local want = type(target) == "table"
            and tonumber(target.targetStacks) or 1
        if want < 1 then want = 1 end
        local have = tonumber(byFamily[family]) or 0
        if fallbackFamily == family then have = have + 1 end
        if have < want then return true end
    end
    return false
end

-- state = { board, owned, charges, plan, queue, flags, level, horizon,
--           support, params, canFreeze, searchRefused
--           [, allowBanish, catalog] }
-- Returns { type="take"|"freeze"|"banish"|"reroll"|"wait", index=?,
-- spellId=?, reason=s, annotations={}, deltas={}, steps=? }.
function Policy.Decide(state)
    local annotations = {}
    if type(state) ~= "table" then
        return { type = "wait", reason = "no board", annotations = annotations }
    end
    local model = GetModel()
    if not model or type(model.Delta) ~= "function" then
        return { type = "wait", reason = "model unavailable", annotations = annotations }
    end

    local board = state.board
    local rawCards = type(board) == "table" and board.cards or nil
    if type(rawCards) ~= "table" or #rawCards == 0 then
        return { type = "wait", reason = "no board", annotations = annotations }
    end

    local cards = {}
    for i = 1, #rawCards do
        cards[i] = type(rawCards[i]) == "table" and rawCards[i] or {}
    end
    local plan = state.plan or { advisorOnly = true }
    local owned = state.owned or {}
    local catalog = state.catalog
    local params = state.params or {}
    local charges = state.charges or {}
    local level = tonumber(state.level)

    local gIndex = tonumber(board.guaranteedIndex)
    if gIndex and (gIndex ~= math.floor(gIndex) or not cards[gIndex]) then gIndex = nil end
    if not gIndex then
        for i = 1, #cards do
            if cards[i].isGuaranteed then gIndex = i break end
        end
    end

    local deltas, wanted = {}, {}
    for i = 1, #cards do
        local delta = tonumber(model.Delta(
            plan, owned, cards[i].spellId, catalog, params)) or 0
        deltas[i] = delta
        wanted[i] = IsWanted(model, cards[i], delta, plan, owned, catalog)
        annotations[i] = Annotation(cards[i], delta, wanted[i], plan, owned)
    end

    -- Never make an irreversible automatic choice from a missing or stale
    -- owned snapshot. GameAdapter settles a genuinely empty new run after
    -- its bounded startup window.
    if (state.owned == nil or state.owned.synced == false)
        and level and level > 1 then
        return {
            type = "wait",
            reason = "owned state is not synchronized",
            annotations = annotations,
            deltas = deltas,
        }
    end
    if plan.advisorOnly then
        return {
            type = "wait", reason = "advisor",
            annotations = annotations, deltas = deltas,
        }
    end

    -- The client reports horizon == 1 at the end of each pending-roll batch,
    -- including ordinary leveling batches. It is a final RUN selection only
    -- at level 80. This branch intentionally sits before both queue phases so
    -- it survives a Banish/Reroll that changes or removes the guaranteed card.
    local finalSelection = (tonumber(state.level) or 0) >= 80
        and type(state.horizon) == "number"
        and state.horizon == 1
    -- A guarantee is usable only when this exact card is still wanted.
    -- Family membership alone is insufficient for multi-quality families:
    -- a below-target variant is wished by family but Model.Delta/IsWanted
    -- correctly rejects it. Treat that card like any other unusable guarantee
    -- while SafeBanishCandidate continues protecting every wished family.
    local unusableGuarantee = gIndex ~= nil
        and wanted[gIndex] ~= true

    -- An unusable guarantee is not useful merely because it is guaranteed.
    -- During ordinary leveling, search only the side slots and take the best
    -- currently-missing wishlist Echo that is not already promised later by
    -- the queue. Selecting that side rejects the unwanted guarantee.
    -- Final-selection search remains in its dedicated branch below so a frozen
    -- wanted fallback can stay protected.
    if unusableGuarantee and not finalSelection then
        local bestWantedSide, wantedFreezeResolving = nil, false
        for i = 1, #cards do
            if i ~= gIndex and wanted[i] then
                if not FreezeWorthy(
                    model, state, cards[i], plan, owned, catalog) then
                    annotations[i] = "returns later"
                elseif cards[i].justFrozen then
                    wantedFreezeResolving = true
                elseif BetterWanted(model, cards, deltas, plan, owned, catalog,
                    i, bestWantedSide) then
                    bestWantedSide = i
                end
            end
        end
        if bestWantedSide then
            return Take(cards, annotations, deltas, bestWantedSide,
                "Reject off-wishlist guarantee; take missing wishlist side Echo")
        end
        if wantedFreezeResolving then
            return {
                type = "wait",
                reason = "Wanted side Freeze is resolving before rejecting "
                    .. "off-wishlist guarantee",
                annotations = annotations,
                deltas = deltas,
            }
        end

        local refused = type(state.searchRefused) == "table"
            and state.searchRefused or {}
        if state.allowBanish ~= false and not refused.banish
            and (tonumber(charges.banish) or 0) > 0
            and charges.trustworthy == true
            and not charges.banishSpentThisPush then
            local worst = SafeBanishCandidate(cards, deltas, plan, gIndex)
            if worst then
                return {
                    type = "banish",
                    index = worst,
                    spellId = cards[worst].spellId,
                    reason = "Replace off-wishlist guarantee: Banish safe "
                        .. "side to search for a missing wishlist Echo",
                    annotations = annotations,
                    deltas = deltas,
                }
            end
        end
        if not refused.reroll and (tonumber(charges.reroll) or 0) > 0
            and charges.trustworthy == true then
            return {
                type = "reroll",
                reason = "Replace off-wishlist guarantee: Reroll side choices "
                    .. "for a missing wishlist Echo",
                annotations = annotations,
                deltas = deltas,
            }
        end

        local side = LeastHarmfulSide(cards, annotations, deltas, gIndex)
        if side then
            return Take(cards, annotations, deltas, side,
                "Reject off-wishlist guarantee; take least-harmful side")
        end
        return {
            type = "wait",
            reason = "Off-wishlist guarantee has no selectable side",
            annotations = annotations,
            deltas = deltas,
        }
    end

    -- Spend safe Banishes early in the leveling run, including while a
    -- guaranteed queue is active. Never let this pre-empt an unbanked wanted
    -- side Echo: it keeps normal Freeze/loss-prevention priority. A frozen or
    -- carried wanted side makes early Banish safe while the guarantee is still
    -- present. Without a guarantee, all wanted cards keep normal take priority.
    -- Once Banishes are exhausted, Rerolls remain in the ordinary post-queue
    -- search phase below.
    if level and level < 80 then
        local hasWantedSide, hasUnbankedWantedSide = false, false
        for i = 1, #cards do
            if i ~= gIndex and wanted[i] then
                hasWantedSide = true
                if not IsFrozen(cards[i]) then
                    hasUnbankedWantedSide = true
                    break
                end
            end
        end
        local wantedSideBlocksBanish
        if gIndex then
            wantedSideBlocksBanish = hasUnbankedWantedSide
        else
            wantedSideBlocksBanish = hasWantedSide
        end
        local refused = type(state.searchRefused) == "table"
            and state.searchRefused or {}
        if not wantedSideBlocksBanish and state.allowBanish ~= false
            and not refused.banish
            and (tonumber(charges.banish) or 0) > 0
            and charges.trustworthy == true
            and not charges.banishSpentThisPush then
            local worst = SafeBanishCandidate(cards, deltas, plan, gIndex)
            if worst then
                return {
                    type = "banish",
                    index = worst,
                    spellId = cards[worst].spellId,
                    reason = "Early search: Banish safe off-wishlist side "
                        .. "before normal roll sequencing",
                    annotations = annotations,
                    deltas = deltas,
                }
            end
        end
    end

    if finalSelection then
        local bestFrozen, bestVisible = nil, nil
        for i = 1, #cards do
            local card = cards[i]
            if wanted[i] and not card.justFrozen then
                if card.isFrozen or card.isCarried then
                    if BetterWanted(model, cards, deltas, plan, owned, catalog,
                        i, bestFrozen) then
                        bestFrozen = i
                    end
                elseif i ~= gIndex and not card.isGuaranteed
                    and BetterWanted(model, cards, deltas, plan, owned, catalog,
                        i, bestVisible) then
                    bestVisible = i
                end
            end
        end

        if bestVisible and (not bestFrozen
            or BetterWanted(model, cards, deltas, plan, owned, catalog,
                bestVisible, bestFrozen)) then
            return Endgame(Take(cards, annotations, deltas, bestVisible,
                bestFrozen
                    and ("Final selection: better remaining wishlist Echo "
                        .. "replaces frozen target")
                    or "Final selection: take wanted side Echo before search"))
        end

        local protectedIndex = bestFrozen or gIndex
        local protectedWanted = bestFrozen ~= nil
            or (gIndex ~= nil and wanted[gIndex] == true)
        local fallbackCard = protectedWanted and cards[protectedIndex] or nil
        local searchPending = protectedIndex ~= nil
            and MissingAfterFallback(plan, owned, fallbackCard, catalog)
        if searchPending then
            local refused = type(state.searchRefused) == "table"
                and state.searchRefused or {}
            if state.allowBanish ~= false and not refused.banish
                and (tonumber(charges.banish) or 0) > 0
                and charges.trustworthy == true
                and not charges.banishSpentThisPush then
                local worst = SafeBanishCandidate(cards, deltas, plan, gIndex)
                if worst then
                    return Endgame({
                        type = "banish",
                        index = worst,
                        spellId = cards[worst].spellId,
                        reason = "Final selection: safe Banish searches for "
                            .. "another missing wanted Echo",
                        annotations = annotations,
                        deltas = deltas,
                    })
                end
            end

            -- A frozen wanted card is a safe fallback even when Reroll changes
            -- the guaranteed card. Without one, only reroll a wanted
            -- guaranteed card after the hold behavior was explicitly
            -- confirmed. A filler guaranteed card needs no such protection.
            local rerollSafe = bestFrozen ~= nil
                or gIndex == nil
                or wanted[gIndex] ~= true
                or (type(state.flags) == "table"
                    and state.flags.REROLL_HOLDS_GUARANTEED == true)
            if not refused.reroll
                and (tonumber(charges.reroll) or 0) > 0
                and charges.trustworthy == true
                and rerollSafe then
                local reason
                if bestFrozen then
                    reason = "Final selection: Reroll searches while "
                        .. "the frozen wanted Echo remains protected"
                elseif gIndex and wanted[gIndex] then
                    reason = "Final selection: Reroll searches while "
                        .. "the guaranteed wanted Echo is held"
                else
                    reason = "Final selection: Reroll searches past "
                        .. "a non-wanted guaranteed Echo"
                end
                return Endgame({
                    type = "reroll",
                    reason = reason,
                    annotations = annotations,
                    deltas = deltas,
                })
            end
        end

        if bestFrozen then
            local reason = "Final selection: search exhausted or unavailable; "
                .. "take frozen wanted Echo"
            local refused = type(state.searchRefused) == "table"
                and state.searchRefused or {}
            if refused.banish or refused.reroll then
                reason = "Final selection: search action refused; "
                    .. "take frozen wanted Echo"
            end
            return Endgame(Take(
                cards, annotations, deltas, bestFrozen, reason))
        end
    end

    -- Final search above already spent every safe action. If its guarantee is
    -- off-wishlist and no wanted fallback was available, discard it by taking a
    -- side card rather than allowing normal queue draining to select it.
    if finalSelection and unusableGuarantee then
        local side = LeastHarmfulSide(cards, annotations, deltas, gIndex)
        if side then
            return Endgame(Take(cards, annotations, deltas, side,
                "Final selection: reject off-wishlist guarantee"))
        end
        return Endgame({
            type = "wait",
            reason = "Final off-wishlist guarantee has no selectable side",
            annotations = annotations,
            deltas = deltas,
        })
    end

    -- Phase A: drain the guaranteed queue. Board position never identifies
    -- the queue head; only guaranteedIndex/isGuaranteed does.
    if gIndex then
        local bestUnbanked, hasBankedWanted = nil, false
        for i = 1, #cards do
            if i ~= gIndex and wanted[i] then
                if IsFrozen(cards[i]) then
                    hasBankedWanted = true
                elseif FreezeWorthy(model, state, cards[i], plan, owned, catalog) then
                    if BetterWanted(model, cards, deltas, plan, owned, catalog,
                        i, bestUnbanked) then
                        bestUnbanked = i
                    end
                else
                    annotations[i] = "returns later"
                end
            end
        end

        -- One protected side card is enough. Keep the remaining slot open
        -- for later side-card opportunities and advance the queue now.
        if hasBankedWanted then
            return Take(cards, annotations, deltas, gIndex,
                "Take guaranteed; wanted side Echo is safely frozen")
        end

        if bestUnbanked then
            local freezeAvailable = (tonumber(charges.freeze) or 0) > 0
                and charges.trustworthy == true
                and state.canFreeze ~= false
                and not cards[bestUnbanked].isGuaranteed
            if freezeAvailable then
                return {
                    type = "freeze",
                    index = bestUnbanked,
                    spellId = cards[bestUnbanked].spellId,
                    reason = "Freeze wanted side Echo; take guaranteed after it resolves",
                    steps = {
                        { type = "freeze", index = bestUnbanked,
                          spellId = cards[bestUnbanked].spellId },
                        { type = "take", index = gIndex,
                          spellId = cards[gIndex].spellId },
                    },
                    annotations = annotations,
                    deltas = deltas,
                }
            end

            local why
            if (tonumber(charges.freeze) or 0) <= 0 then
                why = "Freeze unavailable"
            elseif charges.trustworthy ~= true then
                why = "Freeze count untrusted"
            else
                why = "Freeze unavailable or refused on this board"
            end
            return Take(cards, annotations, deltas, bestUnbanked,
                why .. ": taking wanted side Echo to prevent its loss")
        end

        return Take(cards, annotations, deltas, gIndex,
            "Drain guaranteed queue")
    end

    -- Phase B: consume the bank first, then any other wanted offer.
    local bestFrozen, bestWanted = nil, nil
    local protectedWanted = false
    for i = 1, #cards do
        if wanted[i] then
            if cards[i].justFrozen then
                protectedWanted = true
            elseif cards[i].isFrozen or cards[i].isCarried then
                if BetterWanted(model, cards, deltas, plan, owned, catalog,
                    i, bestFrozen) then
                    bestFrozen = i
                end
            elseif BetterWanted(model, cards, deltas, plan, owned, catalog,
                i, bestWanted) then
                bestWanted = i
            end
        end
    end
    if bestFrozen then
        return Take(cards, annotations, deltas, bestFrozen,
            "Take frozen wanted Echo before searching")
    end
    if bestWanted then
        return Take(cards, annotations, deltas, bestWanted,
            "Take wanted Echo")
    end

    -- With no wanted card, use at most one safe Banish per fresh run-data
    -- push. A wished family is protected even when this displayed quality is
    -- below target because Banish may remove the entire family.
    if not protectedWanted and (tonumber(charges.banish) or 0) > 0
        and charges.trustworthy == true
        and not charges.banishSpentThisPush then
        local worst = SafeBanishCandidate(cards, deltas, plan, gIndex)
        if worst then
            return {
                type = "banish", index = worst, spellId = cards[worst].spellId,
                reason = "No wanted Echo: banish worst safe off-wishlist card",
                annotations = annotations, deltas = deltas,
            }
        end
    end

    if not protectedWanted and (tonumber(charges.reroll) or 0) > 0
        and charges.trustworthy == true then
        return {
            type = "reroll",
            reason = "No wanted Echo or useful safe Banish: reroll",
            annotations = annotations,
            deltas = deltas,
        }
    end

    -- Least-harmful mandatory selection. Prefer a non-duplicate whenever one
    -- exists, then the largest delta, then non-filler, lower quality, and the
    -- lowest stable card index.
    local anyNonDuplicate, anySelectable = false, false
    for i = 1, #cards do
        if annotations[i] ~= "duplicate" then anyNonDuplicate = true end
        if not cards[i].justFrozen then anySelectable = true end
    end
    local pick = nil
    for i = 1, #cards do
        local eligible = ((not anyNonDuplicate) or annotations[i] ~= "duplicate")
            and ((not anySelectable) or not cards[i].justFrozen)
        if eligible then
            if pick == nil
                or deltas[i] > deltas[pick]
                or (deltas[i] == deltas[pick]
                    and annotations[pick] == "filler"
                    and annotations[i] ~= "filler")
                or (deltas[i] == deltas[pick]
                    and (annotations[i] == "filler") == (annotations[pick] == "filler")
                    and (tonumber(cards[i].quality) or 0)
                        < (tonumber(cards[pick].quality) or 0)) then
                pick = i
            end
        end
    end
    pick = pick or 1
    return Take(cards, annotations, deltas, pick,
        annotations[pick] == "duplicate"
            and "Forced take: every selectable Echo is already owned"
            or "Forced least-harmful selection")
end
