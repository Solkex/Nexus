-- Regression: a guarantee from a wished family is still unusable when the
-- exact offered quality is below the wishlist target.
dofile("logic/Model.lua")
dofile("logic/Policy.lua")

local rows = {
    [210] = {
        spellId=210, name="Quality Target", quality=0, maxStack=10,
    },
    [211] = {
        spellId=211, name="Quality Target", quality=2, maxStack=10,
    },
    [400] = {
        spellId=400, name="Filler A", quality=1, maxStack=1,
    },
    [401] = {
        spellId=401, name="Filler B", quality=1, maxStack=1,
    },
}
local catalog = {
    rows=rows,
    familyOf={
        [210]="quality", [211]="quality",
        [400]="fillerA", [401]="fillerB",
    },
    familyMembers={
        quality={210,211}, fillerA={400}, fillerB={401},
    },
}
local plan = {
    advisorOnly=false,
    wishedFamilies={ quality=true },
    targets={
        quality={ targetStacks=1, wishedQuality=2, spellId=211 },
    },
}

local function card(spellId, guaranteed)
    return {
        spellId=spellId,
        family=catalog.familyOf[spellId],
        quality=rows[spellId].quality,
        isGuaranteed=guaranteed or nil,
    }
end

local function decide(charges)
    return Nexus.Policy.Decide({
        board={
            cards={ card(400), card(210, true), card(401) },
            guaranteedIndex=2,
        },
        owned={ synced=true, bySpell={}, byFamily={} },
        charges=charges,
        plan=plan,
        queue={ entries={} },
        catalog=catalog,
        level=20,
    })
end

local forced = decide({
    freeze=0, banish=0, reroll=0, trustworthy=true,
})
assert(forced.type == "take" and forced.index ~= 2
        and forced.spellId ~= 210,
    "below-target-quality guaranteed Echo must be rejected")

local searched = decide({
    freeze=0, banish=1, reroll=0, trustworthy=true,
})
assert(searched.type == "banish"
        and searched.index ~= 2
        and searched.spellId ~= 210,
    "search may Banish filler but never the wished quality family")

local tieredPlan = {
    advisorOnly=false,
    wishedFamilies={ quality=true },
    targets={
        quality={
            targetStacks=2, wishedQuality=0, spellId=210,
            qualityTiers={
                { q=0, n=1, spellId=210 },
                { q=2, n=1, spellId=211 },
            },
        },
    },
}
local tiered = Nexus.Policy.Decide({
    board={
        cards={ card(400), card(210, true), card(401) },
        guaranteedIndex=2,
    },
    owned={ synced=true, bySpell={}, byFamily={} },
    charges={ freeze=0, banish=0, reroll=0, trustworthy=true },
    plan=tieredPlan,
    queue={ entries={} },
    catalog=catalog,
    level=20,
})
assert(tiered.type == "take" and tiered.index == 2,
    "an explicitly requested lower quality tier must remain a usable guarantee")

local tierOwned = {
    synced=true,
    bySpell={ [210]=1 },
    byFamily={ quality=1 },
}
local surplusLowTier = Nexus.Policy.Decide({
    board={
        cards={ card(400), card(210, true), card(401) },
        guaranteedIndex=2,
    },
    owned=tierOwned,
    charges={ freeze=0, banish=0, reroll=0, trustworthy=true },
    plan=tieredPlan,
    queue={ entries={} },
    catalog=catalog,
    level=20,
})
assert(surplusLowTier.type == "take" and surplusLowTier.index ~= 2,
    "a filled low-quality tier must not absorb a higher-quality tier quota")

local neededHighTier = Nexus.Policy.Decide({
    board={
        cards={ card(400), card(211, true), card(401) },
        guaranteedIndex=2,
    },
    owned=tierOwned,
    charges={ freeze=0, banish=0, reroll=0, trustworthy=true },
    plan=tieredPlan,
    queue={ entries={} },
    catalog=catalog,
    level=20,
})
assert(neededHighTier.type == "take" and neededHighTier.index == 2,
    "the remaining exact quality tier must stay guarantee-eligible")

print("wrong-quality guarantee regression OK")
