-- Equal-progress wishlist rotations must advance the active snapshot without
-- allowing a true wishlist regression or a dirtier filler trade.
Nexus = {}
dofile("logic/Model.lua")
dofile("logic/Ratchet.lua")

local Ratchet = Nexus.Ratchet
local catalog = {
    familyOf = {
        [100] = "saved",
        [200] = "new",
        [300] = "filler",
        [400] = "quality",
        [401] = "quality",
    },
    familyName = {
        saved = "Saved Target",
        new = "New Target",
        filler = "Filler",
        quality = "Quality Target",
    },
    rows = {
        [400] = { spellId=400, quality=0, maxStack=10 },
        [401] = { spellId=401, quality=2, maxStack=10 },
    },
    familyMembers = {
        quality={400,401},
    },
}
local plan = {
    wishedFamilies = { saved=true, new=true },
    targets = {
        saved={ targetStacks=1 },
        new={ targetStacks=1 },
    },
}
local incumbent = {
    { spellId=100, family="saved", stacks=1 },
}

local ok, reason = Ratchet.Dominates({
    byFamily={ new=1 },
}, incumbent, plan, catalog)
assert(ok and reason:find("wishlist rotation", 1, true),
    "a clean one-for-one wishlist rotation must save")

ok = Ratchet.Dominates({
    byFamily={ new=1, filler=1 },
}, incumbent, plan, catalog)
assert(not ok,
    "an equal-progress wishlist rotation must not save when it adds filler")

ok = Ratchet.Dominates({
    byFamily={},
}, incumbent, plan, catalog)
assert(not ok,
    "a true wishlist-progress regression must never save")

ok = Ratchet.Dominates({
    byFamily={ saved=1 },
}, incumbent, plan, catalog)
assert(not ok,
    "an unchanged wishlist snapshot must not save")

local stackPlan = {
    wishedFamilies = { new=true },
    targets = { new={ targetStacks=5 } },
}
local oneStack = Ratchet.ScoreSlot({
    { spellId=200, family="new", stacks=1 },
}, stackPlan, catalog)
local fourStacks = Ratchet.ScoreSlot({
    { spellId=200, family="new", stacks=4 },
}, stackPlan, catalog)
assert(fourStacks > oneStack,
    "slot scoring must prefer greater progress toward a requested stack target")

local qualityPlan = {
    wishedFamilies = { quality=true },
    targets = {
        quality={ targetStacks=1, wishedQuality=2, spellId=401 },
    },
}
ok = Ratchet.Dominates({
    byFamily={ quality=1 },
    bySpell={ [400]=1 },
}, {}, qualityPlan, catalog)
assert(not ok,
    "below-target quality must not count as saveable wishlist progress")

ok = Ratchet.Dominates({
    byFamily={ quality=1 },
    bySpell={ [400]=1 },
}, {
    { spellId=300, family="filler", stacks=1 },
}, qualityPlan, catalog)
assert(not ok,
    "below-target quality must not masquerade as cleaner filler")

ok = Ratchet.Dominates({
    byFamily={ quality=1 },
    bySpell={ [401]=1 },
}, {}, qualityPlan, catalog)
assert(ok,
    "quality-qualified target progress must pass the save gate")

local emptyScore = Ratchet.ScoreSlot({}, qualityPlan, catalog)
local lowQualityScore = Ratchet.ScoreSlot({
    { spellId=400, family="quality", stacks=1 },
}, qualityPlan, catalog)
local qualifiedScore = Ratchet.ScoreSlot({
    { spellId=401, family="quality", stacks=1 },
}, qualityPlan, catalog)
assert(lowQualityScore < emptyScore and qualifiedScore > emptyScore,
    "slot scoring must penalize an unqualified wished-family variant")

local qualityQueue = Ratchet.PredictQueue({
    { spellId=400, family="quality", quality=0, stacks=1 },
    { spellId=401, family="quality", quality=2, stacks=1 },
}, {
    byFamily={}, bySpell={},
}, qualityPlan, {}, {}, catalog)
assert(qualityQueue.entries[1].wanted == false
        and qualityQueue.entries[2].wanted == true,
    "predicted guarantees must expose quality-qualified wanted state")

local lowEstimate = Ratchet.RunsEstimate(qualityPlan, {
    byFamily={ quality=1 },
    bySpell={ [400]=1 },
}, qualityQueue, nil, catalog)
local highEstimate = Ratchet.RunsEstimate(qualityPlan, {
    byFamily={ quality=1 },
    bySpell={ [401]=1 },
}, qualityQueue, nil, catalog)
assert(lowEstimate.text:find("~1 wishlist echo", 1, true)
        and highEstimate.text:find("wishlist complete", 1, true),
    "runs estimate must use quality-qualified completion")

local tierPlan = {
    wishedFamilies = { quality=true },
    targets = {
        quality={
            targetStacks=2, wishedQuality=0, spellId=400,
            qualityTiers={
                { q=0, n=1, spellId=400 },
                { q=2, n=1, spellId=401 },
            },
        },
    },
}
local tierIncumbent = {
    { spellId=400, family="quality", stacks=1 },
}
ok = Ratchet.Dominates({
    byFamily={ quality=2 },
    bySpell={ [400]=2 },
}, tierIncumbent, tierPlan, catalog)
assert(not ok,
    "surplus low-tier copies must not satisfy a higher-tier quota")

ok = Ratchet.Dominates({
    byFamily={ quality=2 },
    bySpell={ [400]=1, [401]=1 },
}, tierIncumbent, tierPlan, catalog)
assert(ok,
    "an exact newly completed quality tier must count as progress")

print("ratchet wishlist rotation scenarios OK")
