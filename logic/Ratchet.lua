-- Nexus: logic/Ratchet.lua
-- Outer convergence: predicted guaranteed queue, domination-guarded
-- overwrite, slot scoring, runs estimate. PURE -- no WoW API, no
-- ProjectEbonhold, no SavedVariables; loads under bare LuaJIT.
--
-- Queue subtraction remains FAMILY-granular (addendum B2), matching the
-- server guarantee contract. Wishlist progress and save scoring are stricter:
-- multi-quality families count only the requested quality-qualified copies.
-- The predicted queue is planning/UI-only -- coverage decisions never read it.

Nexus = Nexus or {}
local M = {}
Nexus.Ratchet = M

local function Pos(n)
    return type(n) == "number" and n > 0
end

-- Family key for an entry: the adapter-stamped field first, then the
-- catalog, then a synthetic per-spellId key (unknown rows stay visible
-- in planning output rather than silently vanishing).
local function FamOf(entry, catalog)
    if type(entry) ~= "table" then return nil end
    if entry.family ~= nil then return entry.family end
    local spellId = entry.spellId
    if spellId == nil then return nil end
    local byId = catalog and catalog.familyOf
    return (byId and byId[spellId]) or ("s" .. tostring(spellId))
end

local function FamName(catalog, fam)
    local names = catalog and catalog.familyName
    return (names and names[fam]) or tostring(fam)
end

-- Distinct coverage/filler family sets of a slot-echoes array.
local function EchoFamilySets(echoes, wished, catalog)
    local cov, fill = {}, {}
    if type(echoes) == "table" then
        for i = 1, #echoes do
            local fam = FamOf(echoes[i], catalog)
            if fam ~= nil then
                if wished[fam] then cov[fam] = true else fill[fam] = true end
            end
        end
    end
    return cov, fill
end

local function OwnedFromEchoes(echoes, catalog)
    local owned = { byFamily = {}, bySpell = {} }
    for i = 1, #(echoes or {}) do
        local entry = echoes[i]
        local family = FamOf(entry, catalog)
        local spellId = type(entry) == "table" and tonumber(entry.spellId) or nil
        local count = type(entry) == "table"
            and (tonumber(entry.stacks or entry.count) or 1) or 0
        if family ~= nil and count > 0 then
            owned.byFamily[family] =
                (tonumber(owned.byFamily[family]) or 0) + count
        end
        if spellId and count > 0 then
            owned.bySpell[spellId] =
                (tonumber(owned.bySpell[spellId]) or 0) + count
        end
    end
    return owned
end

local function TargetProgress(plan, catalog, family, owned)
    local model = Nexus.Model
    if type(model) == "table" and type(model.TargetProgress) == "function" then
        return model.TargetProgress(plan, catalog, family, owned)
    end
    local target = type(plan) == "table"
        and type(plan.targets) == "table" and plan.targets[family] or nil
    local want = type(target) == "table"
        and tonumber(target.targetStacks) or 1
    if want < 1 then want = 1 end
    local byFamily = type(owned) == "table" and owned.byFamily or nil
    local have = tonumber(byFamily and byFamily[family]) or 0
    return math.min(have, want), want
end

local function SortedNames(set, catalog)
    local list = {}
    for fam in pairs(set) do
        list[#list + 1] = FamName(catalog, fam)
    end
    table.sort(list)
    return list
end

------------------------------------------------------------------------
-- Predicted guaranteed queue: activeEchoes in given (loadout-index)
-- order, minus family-owned entries, minus disabled-lever members when
-- the (user-confirmed, runtime-demotable) suppression flag holds.
------------------------------------------------------------------------

function M.PredictQueue(activeEchoes, owned, plan, flags, disabledLevers, catalog)
    local out = { entries = {} }
    if type(activeEchoes) ~= "table" then return out end
    local byFamily = (type(owned) == "table" and owned.byFamily) or {}
    local wished = (type(plan) == "table" and plan.wishedFamilies) or {}
    local suppress = type(flags) == "table"
        and flags.DISABLE_SUPPRESSES_GUARANTEE == true
    local rows = catalog and catalog.rows
    local levers = catalog and catalog.levers
    for i = 1, #activeEchoes do
        local e = activeEchoes[i]
        local spellId = type(e) == "table" and e.spellId or nil
        if spellId ~= nil then
            local fam = FamOf(e, catalog)
            local skip = Pos(byFamily[fam])
            if not skip and suppress and rows and levers
                and type(disabledLevers) == "table" then
                local row = rows[spellId]
                local lever = row and row.requiredSpell
                if lever and lever ~= 0 and levers[lever]
                    and disabledLevers[lever] then
                    skip = true
                end
            end
            if not skip then
                local wanted = not not wished[fam]
                local model = Nexus.Model
                local row = rows and rows[spellId]
                local quality = type(row) == "table"
                    and tonumber(row.quality) or tonumber(e.quality)
                if wanted and type(model) == "table"
                    and type(model.QualityOfferNeeded) == "function"
                    and quality ~= nil then
                    wanted = model.QualityOfferNeeded(
                        plan, catalog, fam, quality, owned)
                end
                out.entries[#out.entries + 1] = {
                    spellId = spellId,
                    family = fam,
                    quality = quality,
                    wanted = wanted,
                }
            end
        end
    end
    return out
end

------------------------------------------------------------------------
-- Domination guard: the candidate build may overwrite the incumbent
-- snapshot only when it is at least as good on BOTH axes and strictly
-- better on one. An unreadable input never dominates (brick guard).
------------------------------------------------------------------------

function M.Dominates(candidateOwned, incumbentEchoes, plan, catalog)
    if type(candidateOwned) ~= "table"
        or type(candidateOwned.byFamily) ~= "table" then
        return false, "candidate owned state unreadable"
    end
    if type(incumbentEchoes) ~= "table" then
        return false, "incumbent echoes unreadable"
    end

    local wished = (type(plan) == "table" and plan.wishedFamilies) or {}
    -- Count the saved loadout exactly as the server serialized it. Duplicate
    -- entries and entries carrying a stacks/count field all contribute.
    local incumbentOwned = OwnedFromEchoes(incumbentEchoes, catalog)
    local incFill, candFill = {}, {}
    for _, e in ipairs(incumbentEchoes) do
        local fam = FamOf(e, catalog)
        if fam then
            local n = tonumber(e.stacks or e.count) or 1
            if not wished[fam] and Pos(n) then
                incFill[fam] = true
            end
        end
    end
    for fam, n in pairs(candidateOwned.byFamily) do
        if Pos(n) and not wished[fam] then candFill[fam] = true end
    end

    -- The save gate is intentionally aggregate. A progressing loadout is a
    -- workbench toward the whole wishlist, not a promise that every individual
    -- wished family can only move upward on every run. This allows a run that
    -- trades one less-useful/overrepresented Echo for a missing wished Echo to
    -- become the new active snapshot.
    --
    -- Each family's contribution is capped at its requested target, so excess
    -- copies cannot hide a regression elsewhere or inflate progress forever.
    local incumbentProgress, candidateProgress = 0, 0
    local gainedStacks, lostStacks = 0, 0
    for fam in pairs(wished) do
        local before = TargetProgress(
            plan, catalog, fam, incumbentOwned)
        local after = TargetProgress(
            plan, catalog, fam, candidateOwned)
        -- A wished-family copy that supplies zero qualified progress is still
        -- filler. Otherwise a below-target variant could replace an ordinary
        -- filler, look "cleaner", and incorrectly pass the save gate.
        if before <= 0
            and (tonumber(incumbentOwned.byFamily[fam]) or 0) > 0 then
            incFill[fam] = true
        end
        if after <= 0
            and (tonumber(candidateOwned.byFamily[fam]) or 0) > 0 then
            candFill[fam] = true
        end
        incumbentProgress = incumbentProgress + before
        candidateProgress = candidateProgress + after
        local d = after - before
        if d > 0 then gainedStacks = gainedStacks + d
        elseif d < 0 then lostStacks = lostStacks + (-d) end
    end

    local progressGain = candidateProgress - incumbentProgress
    local candFillN, incFillN = 0, 0
    for _ in pairs(candFill) do candFillN = candFillN + 1 end
    for _ in pairs(incFill) do incFillN = incFillN + 1 end
    local fillerDelta = candFillN - incFillN

    -- Any net movement toward the requested wishlist saves, regardless of
    -- which exact wished family supplied that progress or how much filler was
    -- carried during the run.
    if progressGain > 0 then
        return true, string.format(
            "wishlist progress +%d (gained %d, shed %d wished stacks, filler %+d)",
            progressGain, gainedStacks, lostStacks, fillerDelta)
    end

    -- A clean one-for-one wishlist rotation is also progress: the active
    -- snapshot learns the newly acquired family, and the next run can search
    -- for the family that rotated out. This is generic wishlist movement, not
    -- a name-specific priority. Never accept the rotation if it adds filler.
    if progressGain == 0 and gainedStacks > 0 and lostStacks > 0
        and fillerDelta <= 0 then
        return true, string.format(
            "wishlist rotation (gained %d, shed %d wished stacks, filler %+d)",
            gainedStacks, lostStacks, fillerDelta)
    end

    -- At equal wishlist progress, a strictly cleaner snapshot is still useful.
    if progressGain == 0 and fillerDelta < 0 then
        return true, string.format(
            "wishlist progress unchanged; filler -%d", -fillerDelta)
    end

    if progressGain < 0 then
        return false, string.format(
            "wishlist progress regressed %d (gained %d, shed %d wished stacks)",
            -progressGain, gainedStacks, lostStacks)
    end

    return false, string.format(
        "no net gain (wishlist +0, filler %+d)", fillerDelta)
end

------------------------------------------------------------------------
-- Slot scoring / selection over GENUINELY-verified rows only.
------------------------------------------------------------------------

function M.ScoreSlot(slotEchoes, plan, catalog)
    local wished  = (type(plan) == "table" and plan.wishedFamilies) or {}
    local _, fill = EchoFamilySets(slotEchoes, wished, catalog)
    local owned = OwnedFromEchoes(slotEchoes, catalog)
    local nc, nf = 0, 0
    for _ in pairs(fill) do nf = nf + 1 end

    -- Stack bonus: for each wished stacking family, add fractional credit
    -- proportional to stacks present vs the target.  This ensures BestSlot
    -- prefers a slot with 14×Rend over one with 1×Rend when the wishlist
    -- calls for 67×Rend.  Weight < 1 so a stack bonus never outweighs a
    -- genuinely new echo family.
    local stackBonus = 0
    for family in pairs(wished) do
        local have, want = TargetProgress(plan, catalog, family, owned)
        if have > 0 then nc = nc + 1 end
        if have <= 0
            and (tonumber(owned.byFamily[family]) or 0) > 0 then
            nf = nf + 1
        end
        if want > 1 then
            stackBonus = stackBonus + 0.9 * math.min(have, want) / want
        end
    end

    return nc + stackBonus - 0.25 * nf
end

-- bySlot is SPARSE (designed builds live above maxSlots): pairs only,
-- never ipairs/#. Ties break toward the lowest slot id.
function M.BestSlot(slots, plan, catalog)
    if type(slots) ~= "table" or type(slots.bySlot) ~= "table" then
        return nil
    end
    local ids = {}
    for id, row in pairs(slots.bySlot) do
        if type(id) == "number" and type(row) == "table"
            and row.verified and row.verifiedFieldPresent
            and not row.suspectParse then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    local best, bestScore
    for i = 1, #ids do
        local score = M.ScoreSlot(slots.bySlot[ids[i]].echoes, plan, catalog)
        if bestScore == nil or score > bestScore then
            best, bestScore = ids[i], score
        end
    end
    return best
end

------------------------------------------------------------------------
-- Runs estimate. The free-slot draw rate (theta) is unmeasured in v1
-- (measurement M4 open), so `support` cannot honestly yield a run
-- count: unknown stays true and the text reports only what is known.
------------------------------------------------------------------------

function M.RunsEstimate(plan, owned, queue, support, catalog)
    local wished = type(plan) == "table" and plan.wishedFamilies or nil
    if not wished or not next(wished) then
        return { text = "no wishlist target - advisor mode", unknown = true }
    end
    local pending = 0
    for fam in pairs(wished) do
        local have, want = TargetProgress(plan, catalog, fam, owned)
        if have < want then pending = pending + 1 end
    end
    local queued, seen = 0, {}
    local entries = type(queue) == "table" and queue.entries or nil
    if type(entries) == "table" then
        for i = 1, #entries do
            local e = entries[i]
            local fam = type(e) == "table" and e.family or nil
            if fam ~= nil and e.wanted and not seen[fam] then
                seen[fam] = true
                queued = queued + 1
            end
        end
    end
    local text
    if pending == 0 then
        text = "wishlist complete - 0 wanted echoes pending"
    else
        text = string.format(
            "~%d wishlist echo%s pending, %d in guaranteed queue (rate unmeasured)",
            pending, pending == 1 and "" or "es", queued)
    end
    return { text = text, unknown = true }
end

return M
