-- Nexus: logic/Relay.lua
-- Pure two-slot snapshot relay policy.
--
-- Confirmed server contract (Project Ebonhold Player Guide, 2026-07-28):
--   * only an active Snapshot supplies guaranteed Echoes;
--   * an active Snapshot cannot be overwritten;
--   * Designed Builds do not supply guarantees.
--
-- Therefore convergence must alternate between two numbered Snapshot slots:
-- run from active A, save an improvement into inactive B, arm B at level 1,
-- then use inactive A for the next improvement. This module only chooses safe
-- relay actions; core/Main.lua owns server IO and confirmation.

Nexus = Nexus or {}
local Relay = {}
Nexus.Relay = Relay

local function Populated(row)
    return type(row) == "table"
        and type(row.echoes) == "table"
        and #row.echoes > 0
end

local function Verified(row)
    return Populated(row)
        and row.verified == true
        and row.verifiedFieldPresent == true
        and not row.suspectParse
end

local function SameKey(a, b)
    return a ~= nil and b ~= nil and tostring(a) == tostring(b)
end

local function SnapshotMatches(row, expected)
    if not Verified(row) or type(expected) ~= "table"
        or type(expected.bySpell) ~= "table" then
        return false
    end
    local actual = {}
    for i = 1, #row.echoes do
        local entry = row.echoes[i]
        local spellId = type(entry) == "table" and tonumber(entry.spellId) or nil
        if spellId == nil then return false end
        local count = tonumber(entry.stacks or entry.count) or 1
        if count < 1 or count ~= math.floor(count) then return false end
        actual[tostring(spellId)] =
            (actual[tostring(spellId)] or 0) + count
    end
    for spellId, count in pairs(expected.bySpell) do
        if (tonumber(actual[tostring(spellId)]) or 0)
            ~= (tonumber(count) or 0) then
            return false
        end
    end
    for spellId, count in pairs(actual) do
        if (tonumber(expected.bySpell[tostring(spellId)])
            or tonumber(expected.bySpell[tonumber(spellId)]) or 0)
            ~= (tonumber(count) or 0) then
            return false
        end
    end
    return true
end

local function SlotLimit(slots, unlocked)
    local maxSlots = type(slots) == "table" and tonumber(slots.maxSlots) or 0
    unlocked = tonumber(unlocked) or 0
    if maxSlots < 0 then maxSlots = 0 end
    if unlocked < 0 then unlocked = 0 end
    return math.floor(math.min(maxSlots, unlocked))
end

-- Select an INACTIVE destination for an improved run.
--
-- state = {
--   slots, activeSlot, unlockedSlots, preferredSlot,
--   associations = { [loadoutSlot] = stableWishlistKey },
--   wishlistKey, candidateOwned, plan, catalog
-- }
--
-- Safety order:
--   1. Reuse the persisted relay peer when it is empty or a dominated
--      Snapshot for the same wishlist.
--   2. Use an empty unlocked slot (never overwrite unrelated player data).
--   3. Reuse the weakest dominated inactive Snapshot associated with the
--      same wishlist.
-- The active slot and any unrelated/stronger Snapshot are never selected.
function Relay.SelectSaveTarget(state)
    if type(state) ~= "table" or type(state.slots) ~= "table"
        or type(state.slots.bySlot) ~= "table" then
        return nil, "snapshot slots unavailable"
    end
    local active = tonumber(state.activeSlot or state.slots.activeSlot)
    local key = state.wishlistKey
    if not active or key == nil then
        return nil, "active snapshot or wishlist identity unavailable"
    end
    local limit = SlotLimit(state.slots, state.unlockedSlots)
    if limit < 1 then return nil, "no unlocked snapshot slot" end

    local associations = type(state.associations) == "table"
        and state.associations or {}
    local ratchet = Nexus.Ratchet
    if type(ratchet) ~= "table"
        or type(ratchet.Dominates) ~= "function"
        or type(ratchet.ScoreSlot) ~= "function" then
        return nil, "ratchet unavailable"
    end

    local function Eligible(slot)
        slot = tonumber(slot)
        if not slot or slot ~= math.floor(slot) or slot < 1
            or slot > limit or slot == active then
            return false
        end
        local row = state.slots.bySlot[slot]
        if row == nil then return true, "empty" end
        if not Verified(row) or not SameKey(associations[slot], key) then
            return false
        end
        local ok = ratchet.Dominates(
            state.candidateOwned, row.echoes, state.plan, state.catalog)
        return ok and true or false, ok and "same-wishlist" or nil
    end

    local preferred = tonumber(state.preferredSlot)
    if preferred then
        local ok = Eligible(preferred)
        if ok then return preferred, "preferred relay slot" end
    end

    for slot = 1, limit do
        if slot ~= active and state.slots.bySlot[slot] == nil then
            return slot, "empty relay slot"
        end
    end

    local best, bestScore
    for slot = 1, limit do
        local ok, kind = Eligible(slot)
        if ok and kind == "same-wishlist" then
            local row = state.slots.bySlot[slot]
            local score = ratchet.ScoreSlot(
                row.echoes, state.plan, state.catalog)
            if bestScore == nil or score < bestScore
                or (score == bestScore and slot < best) then
                best, bestScore = slot, score
            end
        end
    end
    if best then return best, "weaker same-wishlist relay slot" end
    return nil, "a second empty or weaker same-wishlist Snapshot slot is required"
end

-- Decide how to handle a confirmed relay save on the next level-1 visit.
--
-- Returns:
--   "activate"  -> target is safe to arm
--   "confirmed" -> target is already active; clear pending state
--   "wait"      -> slot data is temporarily incomplete
--   "cancel"    -> user/server state diverged; do not switch builds
function Relay.ArmDecision(state)
    if type(state) ~= "table" or type(state.pending) ~= "table" then
        return "none", "no relay pending"
    end
    local slots = state.slots
    if type(slots) ~= "table" or type(slots.bySlot) ~= "table" then
        return "wait", "waiting for snapshot slots"
    end

    local pending = state.pending
    local source = tonumber(pending.sourceSlot)
    local target = tonumber(pending.targetSlot)
    local active = tonumber(slots.activeSlot)
    local key = pending.wishlistKey
    if not source or not target or key == nil or source == target
        or type(pending.snapshot) ~= "table" then
        return "cancel", "invalid relay state"
    end

    local targetRow = slots.bySlot[target]
    if targetRow == nil then
        return "cancel", "saved relay Snapshot is missing"
    end
    if not Verified(targetRow) then
        return "wait", "waiting for verified relay Snapshot"
    end
    if not SnapshotMatches(targetRow, pending.snapshot) then
        return "cancel", "relay Snapshot contents changed"
    end

    local associations = type(state.associations) == "table"
        and state.associations or {}
    if not SameKey(associations[target], key) then
        return "cancel", "relay Snapshot wishlist association changed"
    end
    if active == target then return "confirmed", "relay Snapshot is active" end
    if active ~= source then
        return "cancel", "active Snapshot changed outside the relay"
    end
    if not SameKey(associations[source], key) then
        return "cancel", "source Snapshot wishlist association changed"
    end
    return "activate", "arm improved relay Snapshot"
end

return Relay
