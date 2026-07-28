-- Offline regression coverage for the two-Snapshot guarantee relay.
-- Run from the Nexus addon root with Lua 5.1/LuaJIT:
--   luajit tests/run_relay.lua

Nexus = {}
dofile("logic/Model.lua")
dofile("logic/Ratchet.lua")
dofile("logic/Relay.lua")

local Relay = Nexus.Relay
local passed = 0

local function Eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
    passed = passed + 1
end

local catalog = {
    rows = {
        [1] = { spellId=1, name="One", maxStack=1, quality=1 },
        [2] = { spellId=2, name="Two", maxStack=1, quality=1 },
        [3] = { spellId=3, name="Three", maxStack=1, quality=1 },
        [9] = { spellId=9, name="Filler", maxStack=1, quality=1 },
        [10] = { spellId=10, name="One Variant", maxStack=1, quality=1 },
    },
    familyOf = {
        [1]="s1", [2]="s2", [3]="s3", [9]="s9", [10]="s1",
    },
    familyMembers = {
        s1={1,10}, s2={2}, s3={3}, s9={9},
    },
    familyName = {
        s1="One", s2="Two", s3="Three", s9="Filler",
    },
}

local plan = {
    wishedFamilies = { s1=true, s2=true, s3=true },
    targets = {
        s1={targetStacks=1}, s2={targetStacks=1}, s3={targetStacks=1},
    },
}

local function Echoes(...)
    local ids = {...}
    local out = {}
    for i = 1, #ids do
        local id = ids[i]
        out[i] = { spellId=id, family=catalog.familyOf[id], stacks=1 }
    end
    return out
end

local function Row(...)
    return {
        verified=true, verifiedFieldPresent=true, suspectParse=false,
        echoes=Echoes(...),
    }
end

local candidate = {
    byFamily = { s1=1, s2=1 },
    bySpell = { [1]=1, [2]=1 },
}

local function Select(fields)
    fields = fields or {}
    fields.catalog = catalog
    fields.plan = plan
    fields.candidateOwned = candidate
    fields.wishlistKey = fields.wishlistKey or "wish-A"
    fields.unlockedSlots = fields.unlockedSlots or 3
    fields.associations = fields.associations or { [1]="wish-A" }
    return Relay.SelectSaveTarget(fields)
end

do
    local slot = Select({
        activeSlot=1,
        slots={activeSlot=1, maxSlots=3, bySlot={ [1]=Row(1) }},
    })
    Eq(slot, 2, "empty inactive slot starts the relay")
end

do
    local slot = Select({
        activeSlot=1,
        unlockedSlots=1,
        slots={activeSlot=1, maxSlots=3, bySlot={ [1]=Row(1) }},
    })
    Eq(slot, nil, "active Snapshot is never overwritten when it is the only unlocked slot")
end

do
    local slot = Select({
        activeSlot=2,
        preferredSlot=1,
        associations={ [1]="wish-A", [2]="wish-A" },
        slots={activeSlot=2, maxSlots=3, bySlot={
            [1]=Row(1), [2]=Row(1),
        }},
    })
    Eq(slot, 1, "persisted relay peer is reused before another empty slot")
end

do
    local slot = Select({
        activeSlot=1,
        preferredSlot=2,
        associations={ [1]="wish-A", [2]="wish-A" },
        slots={activeSlot=1, maxSlots=3, bySlot={
            [1]=Row(1), [2]=Row(1, 2, 3),
        }},
    })
    Eq(slot, 3, "stronger relay peer is preserved when an empty slot exists")
end

do
    local slot = Select({
        activeSlot=1,
        associations={ [1]="wish-A", [2]="wish-B", [3]="wish-C" },
        slots={activeSlot=1, maxSlots=3, bySlot={
            [1]=Row(1), [2]=Row(1), [3]=Row(1),
        }},
    })
    Eq(slot, nil, "unrelated Snapshots are never overwritten")
end

do
    local slot = Select({
        activeSlot=1,
        associations={ [1]="wish-A", [2]="wish-A", [3]="wish-B" },
        slots={activeSlot=1, maxSlots=3, bySlot={
            [1]=Row(1), [2]=Row(1), [3]=Row(1),
        }},
    })
    Eq(slot, 2, "weaker same-wishlist Snapshot is a safe fallback relay")
end

do
    local unverified = Row(1)
    unverified.verified = false
    local slot = Select({
        activeSlot=1,
        unlockedSlots=2,
        associations={ [1]="wish-A", [2]="wish-A" },
        slots={activeSlot=1, maxSlots=2, bySlot={
            [1]=Row(1), [2]=unverified,
        }},
    })
    Eq(slot, nil, "unverified Snapshot is never overwritten")
end

local armSlots = {
    activeSlot=1, maxSlots=3,
    bySlot={ [1]=Row(1), [2]=Row(1, 2) },
}
local pending = {
    sourceSlot=1, targetSlot=2, wishlistKey="wish-A", wishlistSlot=7,
    snapshot={
        byFamily={ s1=1, s2=1 },
        bySpell={ [1]=1, [2]=1 },
    },
}

do
    local action = Relay.ArmDecision({
        pending=pending, slots=armSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "activate", "verified same-wishlist relay target is armed")
end

do
    armSlots.activeSlot = 2
    local action = Relay.ArmDecision({
        pending=pending, slots=armSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "confirmed", "server-confirmed relay activation clears pending")
end

do
    armSlots.activeSlot = 3
    local action = Relay.ArmDecision({
        pending=pending, slots=armSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "cancel", "manual switch outside the relay is respected")
end

do
    armSlots.activeSlot = 1
    local action = Relay.ArmDecision({
        pending=pending, slots=armSlots,
        associations={ [1]="wish-A", [2]="wish-B" },
    })
    Eq(action, "cancel", "changed target association blocks automatic activation")
end

do
    local unverifiedSlots = {
        activeSlot=1, maxSlots=3,
        bySlot={ [1]=Row(1), [2]=Row(1, 2) },
    }
    unverifiedSlots.bySlot[2].verifiedFieldPresent = false
    local action = Relay.ArmDecision({
        pending=pending, slots=unverifiedSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "wait", "automatic activation waits for verified slot data")
end

do
    local changedSlots = {
        activeSlot=1, maxSlots=3,
        bySlot={ [1]=Row(1), [2]=Row(1, 3) },
    }
    local action = Relay.ArmDecision({
        pending=pending, slots=changedSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "cancel", "changed relay Snapshot contents block automatic activation")
end

do
    local changedVariantSlots = {
        activeSlot=1, maxSlots=3,
        bySlot={ [1]=Row(1), [2]=Row(10, 2) },
    }
    local action = Relay.ArmDecision({
        pending=pending, slots=changedVariantSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "cancel",
        "same-family replacement cannot bypass exact relay verification")
end

do
    local invalidCountSlots = {
        activeSlot=1, maxSlots=3,
        bySlot={ [1]=Row(1), [2]=Row(1, 2) },
    }
    invalidCountSlots.bySlot[2].echoes[1].stacks = 0
    local action = Relay.ArmDecision({
        pending=pending, slots=invalidCountSlots,
        associations={ [1]="wish-A", [2]="wish-A" },
    })
    Eq(action, "cancel",
        "non-positive stack data cannot satisfy exact relay verification")
end

io.write(string.format("relay tests passed: %d\n", passed))
