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
    local incCov, incFill = EchoFamilySets(incumbentEchoes, wished, catalog)
    local candCov, candFill = {}, {}
    for fam, n in pairs(candidateOwned.byFamily) do
        if Pos(n) then
            if wished[fam] then candCov[fam] = true else candFill[fam] = true end
        end
    end

    local lost = {}
    for fam in pairs(incCov) do
        if not candCov[fam] then lost[fam] = true end
    end
    if next(lost) then
        return false, "coverage lost: "
            .. table.concat(SortedNames(lost, catalog), ", ")
    end
    -- Coverage is a hard set-veto (checked above): a wished family is never
    -- lost. Filler cannot use set-subset -- every board forces a take, so
    -- each run draws a DIFFERENT junk set and subset never holds. Instead
    -- save iff the spec's potential Phi = coverage - RHO*fillerCount
    -- STRICTLY rises: one covered wishlist echo is worth up to 1/RHO new
    -- filler families. Coverage is bounded, so at full coverage only
    -- filler-reducing saves pass -> convergence to A = W (spec section 5.7).
    local RHO = 0.25
    local candFillN, incFillN = 0, 0
    for _ in pairs(candFill) do candFillN = candFillN + 1 end
    for _ in pairs(incFill) do incFillN = incFillN + 1 end
    local covGain = 0
    for fam in pairs(candCov) do
        if not incCov[fam] then covGain = covGain + 1 end
    end
    local fillerDelta = candFillN - incFillN          -- >0 = more filler
    local dPhi = covGain - RHO * fillerDelta
    if dPhi <= 0 then
        return false, string.format("no net gain (coverage +%d, filler %+d)",
            covGain, fillerDelta)
    end
    return true, string.format("coverage +%d, filler %+d", covGain, fillerDelta)
end

------------------------------------------------------------------------
-- Slot scoring / selection over GENUINELY-verified rows only.
------------------------------------------------------------------------

function M.ScoreSlot(slotEchoes, plan, catalog)
    local wished = (type(plan) == "table" and plan.wishedFamilies) or {}
    local cov, fill = EchoFamilySets(slotEchoes, wished, catalog)
    local nc, nf = 0, 0
    for _ in pairs(cov) do nc = nc + 1 end
    for _ in pairs(fill) do nf = nf + 1 end
    return nc - 0.25 * nf
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
