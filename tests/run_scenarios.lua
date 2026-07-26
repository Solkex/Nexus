-- Live-play scenario suite: encodes the 2026-07-24 session's four
-- screenshots plus edge cases, against the real logic files.
dofile("logic/Model.lua")
dofile("logic/Policy.lua")
local Model, Policy = Nexus.Model, Nexus.Policy

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then failures = failures + 1 print("FAIL: " .. msg) end
end

-- Catalog: AP = multi-quality stat family g70 (gray 301/green 302/blue 303);
-- DS = stacking x9; the rest single-quality wished; Pain Drive filler.
local rows = {
    -- stat families are STACKABLE in the live catalog even when the wishlist
    -- wants one copy -- the v1.3.0 quality-gate bug hid behind maxStack==1
    [301] = { spellId=301, name="Armor Penetration", maxStack=5, quality=0, groupId=70 },
    [302] = { spellId=302, name="Armor Penetration", maxStack=5, quality=1, groupId=70 },
    [303] = { spellId=303, name="Armor Penetration", maxStack=5, quality=2, groupId=70 },
    [311] = { spellId=311, name="Iron Constitution", maxStack=5, quality=0, groupId=71 },
    [312] = { spellId=312, name="Iron Constitution", maxStack=5, quality=2, groupId=71 },
    [400] = { spellId=400, name="Double Strike", maxStack=9, quality=1, groupId=0 },
    [500] = { spellId=500, name="Blood Frenzy", maxStack=1, quality=2, groupId=0 },
    [510] = { spellId=510, name="Essence Tap", maxStack=1, quality=2, groupId=0 },
    [520] = { spellId=520, name="Ruthless Exploiter", maxStack=1, quality=2, groupId=0 },
    [530] = { spellId=530, name="Polarity Shift", maxStack=1, quality=3, groupId=0 },
    [600] = { spellId=600, name="Pain Drive", maxStack=1, quality=1, groupId=0 },
    [610] = { spellId=610, name="Sludge Ward", maxStack=1, quality=1, groupId=0 },
}
local catalog = {
    rows = rows,
    familyOf = { [301]="g70",[302]="g70",[303]="g70",[311]="g71",[312]="g71",
        [400]="s400",[500]="s500",[510]="s510",[520]="s520",[530]="s530",
        [600]="s600",[610]="s610" },
    familyMembers = { g70={301,302,303}, g71={311,312}, s400={400}, s500={500},
        s510={510}, s520={520}, s530={530}, s600={600}, s610={610} },
    familyName = {},
}
local plan = {
    wishedFamilies = { g70=true, g71=true, s400=true, s500=true, s510=true,
        s520=true, s530=true },
    targets = {
        g70  = { targetStacks=1, wishedQuality=2, spellId=303 },
        g71  = { targetStacks=1, wishedQuality=2, spellId=312 },
        s400 = { targetStacks=9, wishedQuality=1, spellId=400 },
        s500 = { targetStacks=1, wishedQuality=2, spellId=500 },
        s510 = { targetStacks=1, wishedQuality=2, spellId=510 },
        s520 = { targetStacks=1, wishedQuality=2, spellId=520 },
        s530 = { targetStacks=1, wishedQuality=3, spellId=530 },
    },
}
local params = { coverage=100, qualityBonus=2, anchorUnlock=150, diversity=5,
    duplicate=-5, filler=-15, qualityMiss=-20, deferFactor=0.35,
    rerollCost=8, rerollHoldThreshold=25 }

local function St(cards, gi, owned, queueFams, opts)
    opts = opts or {}
    local entries = {}
    for i = 1, #(queueFams or {}) do
        entries[i] = { spellId = 0, family = queueFams[i], wanted = true }
    end
    return {
        board = { cards = cards, guaranteedIndex = gi },
        owned = { synced = true, bySpell = (owned and owned.bySpell) or {},
                  byFamily = (owned and owned.byFamily) or {} },
        charges = opts.charges or { banish=5, reroll=5, freeze=5, trustworthy=true },
        plan = plan, queue = { entries = entries }, flags = {}, level = 30,
        catalog = catalog, canFreeze = (opts.canFreeze ~= false), params = params,
    }
end

-- UC1: Blood Frenzy (single-q wished, pending) / Iron Constitution BLUE
-- (multi-q stat at wished quality) / Pain Drive filler guaranteed.
-- Expect: take Iron Constitution; Blood Frenzy deferred.
do
    local cards = {
        { spellId=500, family="s500", quality=2 },
        { spellId=312, family="g71", quality=2 },
        { spellId=600, family="s600", quality=1, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {"s500","s520","s530"}))
    check(a.type=="take" and a.spellId==312, "UC1 takes the blue stat catch (got "..a.type.." "..tostring(a.spellId)..")")
    check(a.annotations[1]=="returns later", "UC1 Blood Frenzy annotated 'returns later' (got "..tostring(a.annotations[1])..")")
end

-- UC2: Essence Tap (pending) / Double Strike 0-of-9 / Ruthless guaranteed
-- wanted. Tick 1: freeze (bank) Double Strike. Tick 2 (canFreeze=false,
-- DS justFrozen): take guaranteed Ruthless.
do
    local cards = {
        { spellId=510, family="s510", quality=2 },
        { spellId=400, family="s400", quality=1 },
        { spellId=520, family="s520", quality=2, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {"s510","s400","s530"}))
    check(a.type=="freeze" and a.index==2, "UC2 tick1 banks Double Strike (got "..a.type.." idx "..tostring(a.index)..")")
    local cards2 = {
        { spellId=510, family="s510", quality=2 },
        { spellId=400, family="s400", quality=1, justFrozen=true },
        { spellId=520, family="s520", quality=2, isGuaranteed=true },
    }
    local a2 = Policy.Decide(St(cards2, 3, nil, {"s510","s400","s530"}, {canFreeze=false}))
    check(a2.type=="take" and a2.spellId==520, "UC2 tick2 takes guaranteed Ruthless (got "..a2.type.." "..tostring(a2.spellId)..")")
end

-- UC3: Polarity Shift epic (pending, deferred) / Double Strike CARRIED
-- (owned 1/9, banked) / Armor Pen GRAY guaranteed (below wished blue).
-- Expect: take the banked Double Strike.
do
    local cards = {
        { spellId=530, family="s530", quality=3 },
        { spellId=400, family="s400", quality=1, isCarried=true },
        { spellId=301, family="g70", quality=0, isGuaranteed=true },
    }
    local owned = { bySpell={ [400]=1 }, byFamily={ s400=1 } }
    local a = Policy.Decide(St(cards, 3, owned, {"s530","s510"}))
    check(a.type=="take" and a.spellId==400, "UC3 takes banked Double Strike over gray stat + deferred epic (got "..a.type.." "..tostring(a.spellId)..")")
    check(a.annotations[3]=="low quality", "UC3 gray Armor Pen annotated 'low quality' (got "..tostring(a.annotations[3])..")")
    check(a.annotations[2]=="banked", "UC3 carried DS annotated 'banked'")
end

-- Gray stat guaranteed + two fillers, no charges: gray stat must NOT be
-- taken (locking the family is worse than one filler).
do
    local cards = {
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1 },
        { spellId=311, family="g71", quality=0, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {}, {charges={banish=0,reroll=0,freeze=0,trustworthy=true}}))
    check(a.type=="take" and a.spellId~=311, "gray stat never taken over plain filler (got "..tostring(a.spellId)..")")
end

-- Blue stat guaranteed at wished quality: take it.
do
    local cards = {
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1 },
        { spellId=312, family="g71", quality=2, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {}))
    check(a.type=="take" and a.spellId==312, "blue stat guaranteed taken (got "..tostring(a.spellId)..")")
end

-- Deferred wished card vs pure filler board: still take the deferred card
-- (discounted, not discarded).
do
    local cards = {
        { spellId=530, family="s530", quality=3 },
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {"s530"}, {charges={banish=0,reroll=0,freeze=0,trustworthy=true}}))
    check(a.type=="take" and a.spellId==530, "deferred card still beats filler (got "..tostring(a.spellId)..")")
end

-- No double-bank: DS carried + a second DS copy free -> no freeze proposed
-- for the second copy.
do
    local cards = {
        { spellId=400, family="s400", quality=1, isCarried=true },
        { spellId=400, family="s400", quality=1 },
        { spellId=520, family="s520", quality=2, isGuaranteed=true },
    }
    local owned = { bySpell={ [400]=1 }, byFamily={ s400=1 } }
    local a = Policy.Decide(St(cards, 3, owned, {"s510"}))
    check(a.type~="freeze", "no second freeze on an already-banked family (got "..a.type..")")
end

-- Scarce stack IS the board's own pick (rest junk): take it, don't freeze.
do
    local cards = {
        { spellId=400, family="s400", quality=1 },
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1, isGuaranteed=true },
    }
    local owned = { bySpell={ [400]=3 }, byFamily={ s400=3 } }
    local a = Policy.Decide(St(cards, 3, owned, {}))
    check(a.type=="take" and a.spellId==400, "scarce stack that IS the pick is taken, not frozen (got "..a.type.." "..tostring(a.spellId)..")")
end


-- LIVE 2026-07-24 board 1: Arcane Bombardment (pending loadout echo) /
-- Desperate Escape (filler) / gray Iron Constitution guaranteed.
-- v1.3.0 wrongly said "tight horizon: take guaranteed" on the gray stat.
-- With charges available the correct move is reroll (board holds nothing
-- one-shot); the gray stat must never be the pick.
do
    rows[700] = { spellId=700, name="Arcane Bombardment", maxStack=1, quality=1, groupId=0 }
    rows[710] = { spellId=710, name="Desperate Escape", maxStack=1, quality=1, groupId=0 }
    catalog.familyOf[700] = "s700"; catalog.familyOf[710] = "s710"
    catalog.familyMembers.s700 = {700}; catalog.familyMembers.s710 = {710}
    plan.wishedFamilies.s700 = true
    plan.targets.s700 = { targetStacks=1, wishedQuality=1, spellId=700 }
    local cards = {
        { spellId=700, family="s700", quality=1 },
        { spellId=710, family="s710", quality=1 },
        { spellId=311, family="g71", quality=0, isGuaranteed=true },
    }
    -- generous support: plenty of uncovered wishlist left, so a reroll EV
    -- comfortably clears the discounted board
    -- mediocre support (late-run-ish mix: mostly filler/duplicate, a
    -- thin slice of real wishlist value) -- NOT enough upside to justify
    -- passing on a perfectly good deferred pick already in hand
    local support = {}
    for i = 1, 30 do support[i] = { spellId = 9000+i, family="sx"..i, quality=0, value=-15 } end
    for i = 31, 40 do support[i] = { spellId = 9000+i, family="sx"..i, quality=2, value=100 } end
    local st = St(cards, 3, nil, {"s700","s530","s510"})
    st.support = support
    st.horizon = 70
    local a = Policy.Decide(st)
    check(a.type ~= "take" or a.spellId ~= 311,
        "LIVE1 gray stat guaranteed is never the pick (got "..a.type.." "..tostring(a.spellId)..")")
    -- Updated 2026-07-24: five repeated live L64 boards showed the correct
    -- move is taking a good deferred pick directly, not rerolling away a
    -- fine board on the hope of something marginally better. The original
    -- "must reroll" expectation here predated the maxStack quality-gate
    -- fix and was reacting to gray IC wrongly scoring +100 wanted, not a
    -- real preference for rerolling over a good deferred pick.
    check(a.type == "take" and a.spellId == 700,
        "LIVE1 takes the good deferred pick over a mediocre reroll (got "..a.type.." "..tostring(a.spellId)..")")
    check(a.annotations[3] == "low quality",
        "LIVE1 gray stat annotated low quality (got "..tostring(a.annotations[3])..")")
end

-- LIVE 2026-07-24 board 2 (post-manual-rerolls): Battle Momentum uncommon
-- (pending loadout echo, its family peak quality) / gray Strength Training
-- / gray Iron Constitution guaranteed. No reroll EV support -> the
-- deferred Battle Momentum is the correct pick; never a gray stat.
do
    rows[720] = { spellId=720, name="Battle Momentum", maxStack=1, quality=1, groupId=0 }
    rows[731] = { spellId=731, name="Strength Training", maxStack=5, quality=0, groupId=72 }
    rows[732] = { spellId=732, name="Strength Training", maxStack=5, quality=2, groupId=72 }
    catalog.familyOf[720] = "s720"; catalog.familyOf[731] = "g72"; catalog.familyOf[732] = "g72"
    catalog.familyMembers.s720 = {720}; catalog.familyMembers.g72 = {731, 732}
    plan.wishedFamilies.s720 = true; plan.wishedFamilies.g72 = true
    plan.targets.s720 = { targetStacks=1, wishedQuality=1, spellId=720 }
    plan.targets.g72 = { targetStacks=1, wishedQuality=2, spellId=732 }
    local cards = {
        { spellId=720, family="s720", quality=1 },
        { spellId=731, family="g72", quality=0 },
        { spellId=311, family="g71", quality=0, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {"s720","s530"},
        {charges={banish=5,reroll=0,freeze=5,trustworthy=true}}))
    check(a.type=="take" and a.spellId==720,
        "LIVE2 takes Battle Momentum over two gray stats (got "..a.type.." "..tostring(a.spellId)..")")
end

-- Gray top-up regression: wished 3x blue stat, own 1 blue -> a gray copy
-- of the same family is gated, never a "top-up".
do
    plan.targets.g71 = { targetStacks=3, wishedQuality=2, spellId=312 }
    local cards = {
        { spellId=311, family="g71", quality=0 },
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1, isGuaranteed=true },
    }
    local owned = { bySpell={ [312]=1 }, byFamily={ g71=1 } }
    local a = Policy.Decide(St(cards, 3, owned, {},
        {charges={banish=0,reroll=0,freeze=0,trustworthy=true}}))
    check(a.spellId ~= 311, "gray never tops up a blue stack (got "..tostring(a.spellId)..")")
    plan.targets.g71 = { targetStacks=1, wishedQuality=2, spellId=312 }
end


-- LIVE 2026-07-24 board S1: deferred Epic + two quality-gated grays,
-- Banish 0 and rerolls nearly spent -> TAKE the deferred epic (the last
-- rerolls are reserved for junk boards), but with rerolls plentiful the
-- reroll is still correct.
do
    local cards = {
        { spellId=530, family="s530", quality=3 },
        { spellId=311, family="g71", quality=0 },
        { spellId=301, family="g70", quality=0, isGuaranteed=true },
    }
    -- mediocre fixture: nearly-spent rerolls must never fire regardless
    local mediocre = {}
    for i = 1, 30 do mediocre[i] = { spellId = 9500+i, family="sy"..i, quality=0, value=-15 } end
    for i = 31, 40 do mediocre[i] = { spellId = 9500+i, family="sy"..i, quality=2, value=100 } end
    local low = St(cards, 3, nil, {"s530"},
        {charges={banish=0,reroll=3,freeze=8,trustworthy=true}})
    low.support = mediocre
    local a = Policy.Decide(low)
    check(a.type=="take" and a.spellId==530,
        "SCARCE takes the deferred epic when rerolls are nearly spent (got "..a.type.." "..tostring(a.spellId)..")")
    -- rich fixture: genuine upside (a strong majority of entries clearly
    -- above the deferred card's true value) -- reroll should still be
    -- able to fire when it truly clears EV and charges are plentiful
    local rich = {}
    for i = 1, 8 do rich[i] = { spellId = 9600+i, family="sy2"..i, quality=0, value=-15 } end
    for i = 9, 40 do rich[i] = { spellId = 9600+i, family="sy2"..i, quality=3, value=160 } end
    local high = St(cards, 3, nil, {"s530"},
        {charges={banish=0,reroll=17,freeze=8,trustworthy=true}})
    high.support = rich
    local b = Policy.Decide(high)
    check(b.type=="reroll",
        "SCARCE still rerolls the same board when redraw EV genuinely clears the true value (got "..b.type..")")
end

-- LIVE 2026-07-24 board S2: Nature's Reprisal (wanted) + Rare Vitality
-- (precious quality catch) + filler guaranteed. Tick 1 banks Vitality
-- with a freeze; tick 2 takes Nature's Reprisal.
do
    rows[740] = { spellId=740, name="Nature's Reprisal", maxStack=1, quality=2, groupId=0 }
    rows[751] = { spellId=751, name="Vitality", maxStack=5, quality=0, groupId=73 }
    rows[752] = { spellId=752, name="Vitality", maxStack=5, quality=2, groupId=73 }
    rows[760] = { spellId=760, name="Earthen Stability", maxStack=1, quality=1, groupId=0 }
    catalog.familyOf[740]="s740"; catalog.familyOf[751]="g73"; catalog.familyOf[752]="g73"
    catalog.familyOf[760]="s760"
    catalog.familyMembers.s740={740}; catalog.familyMembers.g73={751,752}
    catalog.familyMembers.s760={760}
    plan.wishedFamilies.s740 = true; plan.wishedFamilies.g73 = true
    plan.targets.s740 = { targetStacks=1, wishedQuality=2, spellId=740 }
    plan.targets.g73 = { targetStacks=1, wishedQuality=2, spellId=752 }
    local cards = {
        { spellId=740, family="s740", quality=2 },
        { spellId=752, family="g73", quality=2 },
        { spellId=760, family="s760", quality=1, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {"g73"}))
    check(a.type=="freeze" and a.index==2,
        "LIVE-S2 tick1 banks the Rare Vitality quality catch (got "..a.type.." idx "..tostring(a.index)..")")
    local cards2 = {
        { spellId=740, family="s740", quality=2 },
        { spellId=752, family="g73", quality=2, justFrozen=true },
        { spellId=760, family="s760", quality=1, isGuaranteed=true },
    }
    local a2 = Policy.Decide(St(cards2, 3, nil, {"g73"}, {canFreeze=false}))
    check(a2.type=="take" and a2.spellId==740,
        "LIVE-S2 tick2 takes Nature's Reprisal (got "..a2.type.." "..tostring(a2.spellId)..")")
end

-- Lossy-wire compensation: the wishlist stored wishedQuality=0 for a
-- multi-quality family (designed wire dropped the clicked quality) -- the
-- gray variant must STILL be gated, because the effective target is the
-- family's peak quality.
do
    plan.targets.g70 = { targetStacks=1, wishedQuality=0, spellId=301 }
    local cards = {
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1 },
        { spellId=301, family="g70", quality=0, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {},
        {charges={banish=0,reroll=0,freeze=0,trustworthy=true}}))
    check(a.spellId ~= 301,
        "peak-quality target survives a lossy wishlist wire (got "..tostring(a.spellId)..")")
    plan.targets.g70 = { targetStacks=1, wishedQuality=2, spellId=303 }
end


-- LIVE 2026-07-24 board #8: filler + gray wished Agility Boost + gray
-- guaranteed Strength Training. Banish must target the OFF-WISHLIST
-- filler, never the wished-but-gated AB (banishing a family removes
-- ALL its quality variants from the pool, confirmed by the user).
do
    rows[810] = { spellId=810, name="Corrosive Breath", maxStack=1, quality=1, groupId=0 }
    catalog.familyOf[810] = "s810"; catalog.familyMembers.s810 = {810}
    local cards = {
        { spellId=810, family="s810", quality=1 },
        { spellId=311, family="g71", quality=1 },   -- gray-ish IC reused as "AB" stand-in
        { spellId=301, family="g70", quality=0, isGuaranteed=true },
    }
    local a = Policy.Decide(St(cards, 3, nil, {},
        {charges={banish=5,reroll=0,freeze=0,trustworthy=true}}))
    check(a.type=="banish" and a.index==1,
        "LIVE-B8 banish targets off-wishlist filler, never wished-gated (got "..a.type.." idx "..tostring(a.index)..")")
end

-- All-three-cards-wished-and-gated board (the Agility/Reactive/Strength
-- board): no valid banish target exists (every card is a wished family)
-- -- must fall through to reroll, never banish a wished card.
do
    rows[820] = { spellId=820, name="Reactive Retaliation", maxStack=1, quality=0, groupId=74 }
    rows[821] = { spellId=821, name="Reactive Retaliation", maxStack=1, quality=2, groupId=74 }
    catalog.familyOf[820]="g74"; catalog.familyOf[821]="g74"
    catalog.familyMembers.g74 = {820,821}
    plan.wishedFamilies.g74 = true
    plan.targets.g74 = { targetStacks=1, wishedQuality=2, spellId=821 }
    local cards = {
        { spellId=311, family="g71", quality=0 },   -- gray IC (wished, gated)
        { spellId=820, family="g74", quality=0 },   -- gray Reactive (wished, gated)
        { spellId=301, family="g70", quality=0, isGuaranteed=true },  -- gray AP (wished, gated)
    }
    local support = {}
    for i = 1, 40 do support[i] = { spellId = 9600 + i, family = "sz"..i, quality = 2, value = 104 } end
    local st = St(cards, 3, nil, {},
        {charges={banish=5,reroll=17,freeze=0,trustworthy=true}})
    st.support = support
    local a = Policy.Decide(st)
    check(a.type=="reroll" or a.type=="wait",
        "ALL-GATED board never banishes a wished family (got "..a.type..")")
    check(a.type ~= "banish", "ALL-GATED board must never propose banish here")
end

-- LIVE 2026-07-24 board #27: a precious quality catch (blue stat, NOT
-- yet in the predicted queue -- just added to the wishlist this
-- session) sits beside a tight-horizon-worthy guaranteed. BANK must
-- freeze the catch FIRST; tight horizon must not steamroll it.
do
    local cards = {
        { spellId=400, family="s400", quality=1, isCarried=true },  -- banked DS
        { spellId=312, family="g71", quality=2 },                   -- fresh blue IC catch
        { spellId=530, family="s530", quality=3, isGuaranteed=true }, -- tight-horizon guaranteed
    }
    local owned = { bySpell={ [400]=1 }, byFamily={ s400=1 } }
    -- tight horizon: queue length equals horizon, forcing the guaranteed
    -- UNLESS the bank step intercepts first
    local st = St(cards, 3, owned, {"s530"})
    st.horizon = 1
    local a = Policy.Decide(st)
    check(a.type=="freeze" and a.index==2,
        "LIVE-B27 banks the fresh blue catch before tight horizon fires (got "..a.type.." idx "..tostring(a.index)..")")
    -- tick 2: catch now justFrozen, tight horizon proceeds to the guaranteed
    local cards2 = {
        { spellId=400, family="s400", quality=1, isCarried=true },
        { spellId=312, family="g71", quality=2, justFrozen=true },
        { spellId=530, family="s530", quality=3, isGuaranteed=true },
    }
    local st2 = St(cards2, 3, owned, {"s530"}, {canFreeze=false})
    st2.horizon = 1
    local a2 = Policy.Decide(st2)
    check(a2.type=="take" and a2.spellId==530,
        "LIVE-B27 tick2 takes the tight-horizon guaranteed (got "..a2.type.." "..tostring(a2.spellId)..")")
end


-- LIVE 2026-07-24 board #41/53/56/57/73 pattern: only-deferred boards at
-- L64, plenty of reroll charges, mediocre support pool (most families
-- already owned this late-run) -- the user consistently took the
-- deferred pick directly. Reroll must compare against the card's TRUE
-- value, not its discounted one, or a mediocre redraw pool clears an
-- artificially low bar.
do
    local cards = {
        { spellId=530, family="s530", quality=3 },   -- deferred, true value 106ish
        { spellId=600, family="s600", quality=1 },    -- filler
        { spellId=610, family="s610", quality=1, isGuaranteed=true }, -- off-wishlist guaranteed
    }
    -- mediocre support: late-run, most families already owned -> low EV
    local support = {}
    for i = 1, 40 do support[i] = { spellId = 9700 + i, family = "sw"..i, quality = 0, value = -10 } end
    local st = St(cards, 3, nil, {"s530"},
        {charges={banish=5,reroll=17,freeze=8,trustworthy=true}})
    st.support = support
    local a = Policy.Decide(st)
    check(a.type=="take" and a.spellId==530,
        "LIVE-L64 takes a good deferred pick over a low-EV reroll (got "..a.type.." "..tostring(a.spellId)..")")
end

-- Same board shape but with a genuinely rich support pool (early run,
-- almost nothing owned) -- reroll should still be able to fire when it
-- truly clears the deferred card's real value.
do
    local cards = {
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1 },
        { spellId=530, family="s530", quality=3, isGuaranteed=false },
    }
    cards[1].family = "s600"; cards[2].family="s610"
    local wishedOnly = {
        { spellId=530, family="s530", quality=3 },
        { spellId=600, family="s600", quality=1 },
        { spellId=610, family="s610", quality=1, isGuaranteed=true },
    }
    local rich = {}
    for i = 1, 40 do rich[i] = { spellId = 9800 + i, family = "sv"..i, quality = 3, value = 150 } end
    local st = St(wishedOnly, 3, nil, {"s530"},
        {charges={banish=5,reroll=17,freeze=8,trustworthy=true}})
    st.support = rich
    local a = Policy.Decide(st)
    check(a.type=="reroll",
        "LIVE-L64 still rerolls when redraw EV genuinely beats the deferred card's true value (got "..a.type..")")
end

-- LIVE 2026-07-24 board #23: Double Strike (stacking, 0/9) AND a
-- precious quality catch both bankable on the same board -- Double
-- Strike must win the single freeze.
do
    local cards = {
        { spellId=312, family="g71", quality=2 },   -- precious catch (blue IC)
        { spellId=400, family="s400", quality=1 },  -- Double Strike, 0/9
        { spellId=510, family="s510", quality=2, isGuaranteed=true }, -- good guaranteed
    }
    local a = Policy.Decide(St(cards, 3, nil, {"s510"}))
    check(a.type=="freeze" and a.index==2,
        "LIVE-B23 banks Double Strike over a single precious catch (got "..a.type.." idx "..tostring(a.index)..")")
end


-- LIVE 2026-07-24: level-80 endgame, ~20 boards where every option was
-- duplicate/filler and rerolls were abundant -- must reroll unconditionally
-- rather than force a "least harmful" take, since there is no future
-- board within this run left to conserve the charge for.
do
    local cards = {
        { spellId=600, family="s600", quality=1 },   -- filler
        { spellId=610, family="s610", quality=1 },   -- filler
        { spellId=610, family="s610", quality=1 },   -- would force "least harmful"
    }
    -- genuinely thin support (nothing left worth finding -- truly
    -- nothing to gain from a redraw): the normal EV gate correctly
    -- fails to clear here, so L64 should settle for the pick, while
    -- L80 overrides and rerolls anyway (no future board to conserve for)
    local thin = {}
    for i = 1, 40 do thin[i] = { spellId = 9900+i, family="sr"..i, quality=0, value=-15 } end
    local st = St(cards, nil, nil, {},
        {charges={banish=0,reroll=15,freeze=0,trustworthy=true}})
    st.support = thin
    st.level = 80
    local a = Policy.Decide(st)
    check(a.type=="reroll" and a.reason=="endgame: nothing to lose, spend the charge",
        "L80-ENDGAME rerolls unconditionally via the endgame override, not the EV gate (got "..a.type.." / "..tostring(a.reason)..")")

    -- same board and same thin pool, but level 64: whatever the pre-
    -- existing (unrelated) EV-gate reroll math decides, it must NOT be
    -- coming from the endgame override -- that override is scoped to
    -- level >= 80 only and must never fire during active leveling.
    local st2 = St(cards, nil, nil, {},
        {charges={banish=0,reroll=15,freeze=0,trustworthy=true}})
    st2.support = thin
    st2.level = 64
    local b = Policy.Decide(st2)
    check(b.reason ~= "endgame: nothing to lose, spend the charge",
        "L64-LEVELING never uses the endgame override (got reason "..tostring(b.reason)..")")
end

-- L80 endgame with a genuinely wanted card on the board: must NOT reroll
-- it away.
do
    local cards = {
        { spellId=600, family="s600", quality=1 },
        { spellId=530, family="s530", quality=3 },  -- wanted, uncovered
        { spellId=610, family="s610", quality=1 },
    }
    local st = St(cards, nil, nil, {},
        {charges={banish=0,reroll=15,freeze=0,trustworthy=true}})
    st.level = 80
    local a = Policy.Decide(st)
    check(a.type=="take" and a.spellId==530,
        "L80-ENDGAME never rerolls away a genuinely wanted card (got "..a.type.." "..tostring(a.spellId)..")")
end

print(string.format("checks=%d failures=%d", checks, failures))
os.exit(failures == 0 and 0 or 1)
