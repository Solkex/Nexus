-- Nexus: logic/Ratchet.lua
-- Outer convergence: predicted guaranteed queue, domination-guarded
-- overwrite, slot scoring, runs estimate. PURE -- no WoW API, no
-- ProjectEbonhold, no SavedVariables; loads under bare LuaJIT.
--
-- Identity is FAMILY-granular throughout (addendum B2): any quality
-- variant of a wished family counts as coverage/filler. The predicted
-- queue is planning/UI-only -- coverage decisions never read it.

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
                out.entries[#out.entries + 1] = {
                    spellId = spellId,
                    family = fam,
                    wanted = not not wished[fam],
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
    local targets = (type(plan) == "table" and plan.targets) or {}

    -- Count the saved loadout exactly as the server serialized it. Duplicate
    -- entries and entries carrying a stacks/count field all contribute.
    local incStacksByFam = {}
    local incFill, candFill = {}, {}
    for _, e in ipairs(incumbentEchoes) do
        local fam = FamOf(e, catalog)
        if fam then
            local n = tonumber(e.stacks or e.count) or 1
            if wished[fam] then
                incStacksByFam[fam] = (incStacksByFam[fam] or 0) + n
            elseif Pos(n) then
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
        local target = targets[fam]
        local cap = (type(target) == "table" and tonumber(target.targetStacks)) or 1
        if cap < 1 then cap = 1 end
        local before = math.min(tonumber(incStacksByFam[fam]) or 0, cap)
        local after = math.min(tonumber(candidateOwned.byFamily[fam]) or 0, cap)
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
    local targets = (type(plan) == "table" and plan.targets) or {}
    local cov, fill = EchoFamilySets(slotEchoes, wished, catalog)
    local nc, nf = 0, 0
    for _ in pairs(cov) do nc = nc + 1 end
    for _ in pairs(fill) do nf = nf + 1 end

    -- Stack bonus: for each wished stacking family, add fractional credit
    -- proportional to stacks present vs the target.  This ensures BestSlot
    -- prefers a slot with 14×Rend over one with 1×Rend when the wishlist
    -- calls for 67×Rend.  Weight < 1 so a stack bonus never outweighs a
    -- genuinely new echo family.
    local stackBonus = 0
    if type(slotEchoes) == "table" then
        local stacksByFam = {}
        for _, e in ipairs(slotEchoes) do
            local fam = FamOf(e, catalog)
            if fam and wished[fam] then
                stacksByFam[fam] = (stacksByFam[fam] or 0)
                    + (tonumber(e.stacks or e.count) or 1)
            end
        end
        for fam, count in pairs(stacksByFam) do
            local t = targets[fam]
            local target = (type(t) == "table" and tonumber(t.targetStacks)) or 1
            if target > 1 then
                stackBonus = stackBonus + 0.9 * math.min(count, target) / target
            end
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

function M.RunsEstimate(plan, owned, queue, support)
    local wished = type(plan) == "table" and plan.wishedFamilies or nil
    if not wished or not next(wished) then
        return { text = "no wishlist target - advisor mode", unknown = true }
    end
    local byFamily = (type(owned) == "table" and owned.byFamily) or {}
    local pending = 0
    for fam in pairs(wished) do
        if not Pos(byFamily[fam]) then pending = pending + 1 end
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
