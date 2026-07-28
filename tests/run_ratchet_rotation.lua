-- Equal-progress wishlist rotations must advance the active snapshot without
-- allowing a true wishlist regression or a dirtier filler trade.
Nexus = {}
dofile("logic/Ratchet.lua")

local Ratchet = Nexus.Ratchet
local catalog = {
    familyOf = {
        [100] = "saved",
        [200] = "new",
        [300] = "filler",
    },
    familyName = {
        saved = "Saved Target",
        new = "New Target",
        filler = "Filler",
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

print("ratchet wishlist rotation scenarios OK")
