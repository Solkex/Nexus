-- Nexus: logic/Model.lua
-- Pure math layer: name normalization (forked verbatim from the
-- EchoOptimizer sibling), the ordinal wishlist value function Delta,
-- the free-slot support enumerator, and the discretized draw
-- distribution with its order-statistic helpers.
-- No WoW API calls, no SavedVariables access; runs under plain Lua 5.1.

Nexus = Nexus or {}
local Model = {}
Nexus.Model = Model

------------------------------------------------------------------------
-- Names (verbatim fork: EchoOptimizer/logic/Model.lua)
------------------------------------------------------------------------

-- Server comment keys use curly apostrophes; hand-written config uses
-- straight ones. Both must compare equal.
function Model.NormName(name)
    name = tostring(name or "")
    -- Some ProjectEbonhold database comments append invisible
    -- control-byte discriminators to otherwise identical player-facing
    -- names (documented behavior of the server database). Cut at the
    -- first control byte so config names match what the game sends.
    local cut = name:find("[%c\127]")
    if cut then name = name:sub(1, cut - 1) end
    name = name:gsub("\226\128\153", "'") -- U+2019 -> '
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    return name
end

-- Some recorded keys carry an " - <rarity>" suffix (observed in live data:
-- "Mana Regeneration - uncommon"). Strip it so all quality variants of an
-- echo share one canonical key.
local RARITY_WORDS = { "common", "uncommon", "rare", "epic", "legendary" }

function Model.StripRaritySuffix(name)
    name = tostring(name or "")
    local lower = name:lower()
    for i = 1, #RARITY_WORDS do
        local w = RARITY_WORDS[i]
        if lower:find(" %- " .. w .. "$") then
            return (name:sub(1, #name - (#w + 3)))
        end
    end
    return name
end

function Model.CanonicalKey(raw)
    return Model.NormName(Model.StripRaritySuffix(raw))
end

------------------------------------------------------------------------
-- Class-mask test (no bit library in logic files)
------------------------------------------------------------------------

-- True iff bitwise AND of the two masks is non-zero, via modular
-- arithmetic (Lua 5.1 has no bit ops without a library).
function Model.MaskMatch(a, b)
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    if a <= 0 or b <= 0 then return false end
    a = math.floor(a)
    b = math.floor(b)
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then return true end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return false
end

------------------------------------------------------------------------
-- Marginal value Delta (ordinal, calibration-free)
------------------------------------------------------------------------

-- Mirror of data/DefaultProfile.params: keeps Delta functional when a
-- caller omits params. Keep in lockstep with DefaultProfile.
local DEFAULT_PARAMS = {
    coverage = 100,
    qualityBonus = 2,
    anchorUnlock = 150,
    diversity = 5,
    duplicate = -5,
    filler = -15,
    qualityMiss = -20,
    deferFactor = 0.35,
    rerollPacingBase = 6,
    deferRerollFloor = 4,
}

local function Param(params, key)
    local v = params and tonumber(params[key])
    if v ~= nil then return v end
    return DEFAULT_PARAMS[key]
end

-- Marginal value of taking one copy of spellId given the plan and the
-- owned state. Coverage/duplicate/filler are decided at FAMILY
-- granularity (any quality variant of a wished family covers it);
-- exhaustion inputs stay per-spellId. Pure; returns a single number,
-- 0 on malformed input.
function Model.Delta(plan, owned, spellId, catalog, params)
    plan = type(plan) == "table" and plan or {}
    owned = type(owned) == "table" and owned or {}
    if type(catalog) ~= "table" then return 0 end
    local rows = type(catalog.rows) == "table" and catalog.rows or {}
    local row = rows[spellId]
    if type(row) ~= "table" then return 0 end

    local family = type(catalog.familyOf) == "table"
        and catalog.familyOf[spellId] or nil
    if family == nil then family = "s" .. tostring(spellId) end

    local bySpell = type(owned.bySpell) == "table" and owned.bySpell or {}
    local byFamily = type(owned.byFamily) == "table" and owned.byFamily or {}
    local ownedFam = tonumber(byFamily[family]) or 0
    local ownedSpell = tonumber(bySpell[spellId]) or 0
    local maxStack = tonumber(row.maxStack) or 1
    if maxStack < 1 then maxStack = 1 end

    -- Duplicate: family full at maxStack, this exact spellId exhausted,
    -- or any owned maxStack==1 family member (one owned quality variant
    -- of a unique echo exhausts the whole family for value purposes,
    -- even though pool removal stays per-spellId).
    local isDuplicate = (ownedFam >= maxStack and ownedFam > 0)
        or ownedSpell >= maxStack
    if not isDuplicate then
        local members = type(catalog.familyMembers) == "table"
            and catalog.familyMembers[family] or nil
        for i = 1, #(members or {}) do
            local m = (members or {})[i]
            local mr = rows[m]
            if type(mr) == "table" and (tonumber(mr.maxStack) or 1) == 1
                and (tonumber(bySpell[m]) or 0) > 0 then
                isDuplicate = true
                break
            end
        end
    end
    if isDuplicate then return Param(params, "duplicate") end

    local wishedFamilies = type(plan.wishedFamilies) == "table"
        and plan.wishedFamilies or {}
    local targets = type(plan.targets) == "table" and plan.targets or {}

    local v
    if wishedFamilies[family] then
        if ownedFam <= 0 then
            local quality = tonumber(row.quality) or 0
            -- Quality gate (multi-quality families -- the stat echoes):
            -- quality variants are DISTINCT spellIds in one family, and
            -- taking a below-wished-quality copy covers the family at the
            -- wrong quality for the run AND poisons the saved loadout
            -- (next run's guarantee re-serves the low copy). Worse than
            -- filler -- filler is merely useless, this actively damages
            -- the end build. Applies REGARDLESS of maxStack: stat echoes
            -- are stackable in the server catalog even when the wishlist
            -- wants a single copy (live 2026-07-24: a gray guaranteed
            -- Iron Constitution scored full coverage because the old gate
            -- required maxStack == 1).
            local wishedQuality = Model.EffectiveWishedQuality(plan, catalog, family, 0, bySpell)
            if quality < wishedQuality
                and Model.FamilyMultiQuality(catalog, family) then
                return Param(params, "qualityMiss")
            end
            v = Param(params, "coverage")
                + Param(params, "qualityBonus") * quality
        else
            local target = targets[family]
            local targetStacks = type(target) == "table"
                and tonumber(target.targetStacks) or nil
            targetStacks = targetStacks or 1
            if ownedFam < targetStacks then
                local wishedQuality = Model.EffectiveWishedQuality(plan, catalog, family, ownedFam, bySpell)
                local quality = tonumber(row.quality) or 0
                if quality < wishedQuality
                    and Model.FamilyMultiQuality(catalog, family) then
                    return Param(params, "qualityMiss")
                end
                v = Param(params, "coverage")
                    * ((targetStacks - ownedFam) / targetStacks)
            else
                v = 0 -- covered at target; extra copies are neutral
            end
        end
    else
        v = Param(params, "filler")
    end

    -- Anchor terms only ever attach to a NEW family (the anchor's own
    -- family uncovered -> unlock bonus; anchor already owned -> every
    -- new family earns the diversity bonus, filler included).
    local anchor = plan.anchorSpellId
    if anchor ~= nil and ownedFam <= 0 then
        if spellId == anchor then
            v = v + Param(params, "anchorUnlock")
        end
        local anchorFam = type(catalog.familyOf) == "table"
            and catalog.familyOf[anchor] or nil
        local anchorOwned = (tonumber(bySpell[anchor]) or 0) > 0
            or (anchorFam ~= nil and (tonumber(byFamily[anchorFam]) or 0) > 0)
        if anchorOwned then
            v = v + Param(params, "diversity")
        end
    end
    return v
end

------------------------------------------------------------------------
-- Scarcity: has this family's guaranteed-slot supply already run dry?
------------------------------------------------------------------------

-- True when the family exists in more than one quality variant (distinct
-- spellIds sharing the group). These are the families where WHICH copy
-- you take matters -- the stat echoes among them.
function Model.FamilyMultiQuality(catalog, family)
    if type(catalog) ~= "table" or family == nil then return false end
    local members = type(catalog.familyMembers) == "table"
        and catalog.familyMembers[family] or nil
    if type(members) ~= "table" or #members < 2 then return false end
    local rows = type(catalog.rows) == "table" and catalog.rows or {}
    local seen = nil
    for i = 1, #members do
        local r = rows[members[i]]
        local q = r and tonumber(r.quality) or nil
        if q ~= nil then
            if seen == nil then seen = q
            elseif q ~= seen then return true end
        end
    end
    return false
end

-- Highest quality any variant of this family exists at in the catalog.
function Model.FamilyPeakQuality(catalog, family)
    if type(catalog) ~= "table" or family == nil then return 0 end
    local members = type(catalog.familyMembers) == "table"
        and catalog.familyMembers[family] or nil
    local rows = type(catalog.rows) == "table" and catalog.rows or {}
    local peak = 0
    for i = 1, #(members or {}) do
        local r = rows[(members or {})[i]]
        local q = r and tonumber(r.quality) or nil
        if q and q > peak then peak = q end
    end
    return peak
end

-- The quality a multi-quality wished family should be CHASED at: the
-- family's peak. Compensates for two live-server realities (2026-07-24):
-- the designed-build wire can lose the clicked variant's quality, and the
-- level-bracket bug can serve a below-peak variant as the guaranteed --
-- "we want the blue of each stat if possible" means the target is what's
-- POSSIBLE, not what a lossy wire happened to store. The stored
-- wishedQuality still acts as a floor for single-variant data.
function Model.EffectiveWishedQuality(plan, catalog, family, ownedFamCount, ownedBySpell)
    local stored = 0
    local targets = type(plan) == "table" and plan.targets or nil
    local t = targets and targets[family]
    if type(t) == "table" then stored = tonumber(t.wishedQuality) or 0 end

    -- Multi-tier wishlist (e.g. Quick Hands Common×5, Uncommon×50, Rare×20):
    -- the player explicitly wants copies at EVERY listed quality tier.
    -- Return the lowest quality on the wishlist so the gate accepts anything
    -- at or above that level — a Common Quick Hands is not a quality miss
    -- when Common is explicitly on the wishlist.
    if type(t) == "table" and type(t.qualityTiers) == "table"
        and #t.qualityTiers > 1 then
        return stored  -- stored = wishedQuality = lowest tier quality
    end

    -- Single-tier wishlist: escalate to catalog peak for multi-quality
    -- families so the model always chases the best available copy.
    -- (e.g. wishlist has Rare Iron Constitution → reject Common copies)
    if Model.FamilyMultiQuality(catalog, family) then
        local peak = Model.FamilyPeakQuality(catalog, family)
        if peak > stored then return peak end
    end
    return stored
end

-- A wished STACKING family still short of its wishlist stack target
-- (own 0..target-1 of a want-9 echo). The guarantee only ever serves the
-- FIRST copy of a family; every further stack is free-slot RNG, so a
-- free-slot appearance of one of these is always worth banking with a
-- freeze when it isn't this board's pick. Pure; false on malformed input.
function Model.StackWishBelowTarget(plan, owned, family)
    if family == nil then return false end
    local wishedFamilies = type(plan) == "table" and plan.wishedFamilies or nil
    if not (wishedFamilies and wishedFamilies[family]) then return false end
    local targets = type(plan) == "table" and plan.targets or nil
    local target = targets and targets[family]
    local targetStacks = (type(target) == "table" and tonumber(target.targetStacks)) or 1
    if targetStacks <= 1 then return false end
    local byFamily = type(owned) == "table" and owned.byFamily or nil
    local ownedFam = tonumber(byFamily and byFamily[family]) or 0
    return ownedFam < targetStacks
end

-- Ratchet.PredictQueue drops a family from the guaranteed queue the
-- instant ANY copy is owned (family-aware subtraction, addendum B2) --
-- regardless of how far short of the wishlist's targetStacks it still
-- sits. So a partially-stacked wished family (own 3, want 9) will NOT
-- come back around on slot 3; every further copy is free-slot RNG only.
-- A family that is wished but still fully unowned is NOT scarce by this
-- definition -- it's still guarantee-eligible and needs no protecting.
-- Pure; false on malformed input.
function Model.Scarce(plan, owned, family)
    if family == nil then return false end
    local wishedFamilies = type(plan) == "table" and plan.wishedFamilies or nil
    if not (wishedFamilies and wishedFamilies[family]) then return false end
    local byFamily = type(owned) == "table" and owned.byFamily or nil
    local ownedFam = tonumber(byFamily and byFamily[family]) or 0
    if ownedFam <= 0 then return false end
    local targets = type(plan) == "table" and plan.targets or nil
    local target = targets and targets[family]
    local targetStacks = (type(target) == "table" and tonumber(target.targetStacks)) or 1
    return ownedFam < targetStacks
end

------------------------------------------------------------------------
-- Free-slot support
------------------------------------------------------------------------

-- Catalog rows still drawable in the two free slots: class-legal,
-- level-eligible, lever not disabled, not exhausted. Exhaustion here is
-- strictly per-spellId (an owned sibling quality does NOT remove this
-- row from the pool -- it only turns its Delta into a duplicate score).
-- params is optional; Delta defaults apply when omitted.
-- Deterministic output order (ascending spellId).
function Model.Support(catalog, owned, level, disabledLevers, plan, params)
    local out = {}
    if type(catalog) ~= "table" or type(catalog.rows) ~= "table" then
        return out
    end
    owned = type(owned) == "table" and owned or {}
    local bySpell = type(owned.bySpell) == "table" and owned.bySpell or {}
    level = tonumber(level) or 0
    disabledLevers = type(disabledLevers) == "table" and disabledLevers or {}
    local levers = type(catalog.levers) == "table" and catalog.levers or {}
    local familyOf = type(catalog.familyOf) == "table"
        and catalog.familyOf or {}
    local playerMask = tonumber(catalog.playerMask) or 0

    local ids = {}
    for id, row in pairs(catalog.rows) do
        if type(row) == "table" then ids[#ids + 1] = id end
    end
    table.sort(ids)

    for i = 1, #ids do
        local id = ids[i]
        local row = catalog.rows[id]
        local ok = Model.MaskMatch(row.classMask, playerMask)
            and (tonumber(row.minLevel) or 0) <= level
        if ok then
            local lever = tonumber(row.requiredSpell) or 0
            if lever ~= 0 and levers[lever] ~= nil
                and disabledLevers[lever] then
                ok = false
            end
        end
        if ok then
            local maxStack = tonumber(row.maxStack) or 1
            if (tonumber(bySpell[id]) or 0) >= maxStack then ok = false end
        end
        if ok then
            local family = familyOf[id]
            if family == nil then family = "s" .. tostring(id) end
            out[#out + 1] = {
                spellId = id,
                family = family,
                quality = tonumber(row.quality) or 0,
                value = Model.Delta(plan, owned, id, catalog, params),
            }
        end
    end
    return out
end

------------------------------------------------------------------------
-- Draw distribution (quantile-binned) and order statistics
-- (verbatim fork: EchoOptimizer/logic/Model.lua)
------------------------------------------------------------------------

-- entries: array of { key = normName, prob = p, value = v }, probs sum to 1.
-- Values are floored at `floor` (default 0) for the distribution only:
-- a junk card on screen contributes ~nothing to "best offer", it is never
-- force-picked at its negative utility. Live decisions use true values.
function Model.BuildDistribution(entries, nBins, floor)
    nBins = nBins or 16
    floor = floor or 0

    local list = {}
    for i = 1, #entries do
        local e = entries[i]
        if e.prob and e.prob > 0 then
            list[#list + 1] = {
                key = e.key, prob = e.prob,
                value = e.value > floor and e.value or floor,
            }
        end
    end
    table.sort(list, function(a, b) return a.value < b.value end)

    local x, p = {}, {}
    local target = 1 / nBins
    local accP, accPV = 0, 0
    for i = 1, #list do
        local e = list[i]
        accP = accP + e.prob
        accPV = accPV + e.prob * e.value
        local isLast = (i == #list)
        local nextDiffers = isLast or (list[i + 1].value > e.value)
        -- Close the bin at the quantile boundary, but never split a tie
        -- group across bins (keeps bin values exact for degenerate pools).
        if (accP >= target and nextDiffers) or isLast then
            x[#x + 1] = accPV / accP
            p[#p + 1] = accP
            accP, accPV = 0, 0
        end
    end

    local F = {}
    local c = 0
    for i = 1, #x do
        c = c + p[i]
        F[i] = c
    end
    if #F > 0 then F[#F] = 1 end -- guard fp drift

    local E1 = 0
    for i = 1, #x do E1 = E1 + x[i] * p[i] end

    return {
        x = x, p = p, F = F, n = #x,
        E1 = E1,
        rawEntries = entries,
        nBins = nBins, floor = floor,
    }
end

-- E[ best of k draws ]
function Model.EmaxK(dist, k)
    local ev = 0
    local Fprev = 0
    for i = 1, dist.n do
        local Fi = dist.F[i]
        ev = ev + dist.x[i] * (Fi ^ k - Fprev ^ k)
        Fprev = Fi
    end
    return ev
end

-- E[ max(c, best of k draws) ] for an arbitrary known value c.
function Model.EmaxGivenK(dist, c, k)
    local ev = 0
    local Fc = 0
    local Fprev = 0
    for i = 1, dist.n do
        local Fi = dist.F[i]
        if dist.x[i] <= c then
            Fc = Fi
        else
            ev = ev + dist.x[i] * (Fi ^ k - Fprev ^ k)
        end
        Fprev = Fi
    end
    return ev + c * (Fc ^ k)
end

-- Distribution with one echo removed from the pool (banish preview).
function Model.WithoutKey(dist, nk)
    local kept, removed = {}, 0
    for i = 1, #dist.rawEntries do
        local e = dist.rawEntries[i]
        if e.key == nk then
            removed = removed + (e.prob or 0)
        else
            kept[#kept + 1] = e
        end
    end
    if removed <= 0 or removed >= 1 then return dist end
    local scale = 1 / (1 - removed)
    local rescaled = {}
    for i = 1, #kept do
        rescaled[i] = { key = kept[i].key, prob = kept[i].prob * scale, value = kept[i].value }
    end
    return Model.BuildDistribution(rescaled, dist.nBins, dist.floor)
end

------------------------------------------------------------------------
-- Free-slot distribution
------------------------------------------------------------------------

-- Uniform draw belief over the support (theta unmeasured: no quality
-- mix, no counts -- addendum C/M4). Keyed by spellId so WithoutKey
-- matches the per-spellId banish granularity. nil on empty support;
-- callers treat a nil distribution as E = 0.
function Model.FreeDist(support)
    if type(support) ~= "table" or #support == 0 then return nil end
    local n = #support
    local entries = {}
    for i = 1, n do
        local s = support[i]
        entries[i] = {
            key = s.spellId,
            prob = 1 / n,
            value = tonumber(s.value) or 0,
        }
    end
    return Model.BuildDistribution(entries)
end
