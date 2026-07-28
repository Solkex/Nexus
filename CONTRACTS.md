# Nexus — internal module contracts (v1.0.0)

Binding interface spec for all modules. Authored from `WISHLIST_REALIZER_BUILD_PROMPT.md`
+ `WISHLIST_REALIZER_SPEC_ADDENDUM.md` + `WISHLIST_REALIZER_DESIGN.md` (the addendum wins
conflicts). Every `logic/*` and `data/*` file: plain Lua 5.1, NO WoW API, NO
SavedVariables, NO `ProjectEbonhold.*` — loadable under bare LuaJIT. All cross-module
data is plain tables produced by `core/GameAdapter.lua` (the only IO module).

Global namespace: `Nexus` (each file: `Nexus = Nexus or {};
local M = {}; Nexus.<Name> = M`). Version: `Nexus.VERSION = "1.0.0"`
set in Main; .toc `## Version: 1.0.0` kept in lockstep.

Lua 5.1 rules: no `goto`, no `#` on non-sequences, `unpack` global, sort pairs for
deterministic output, forward-declare every closure-captured local BEFORE the closure,
`math.floor(x + 0.5)` before `%d` formats.

## Shared data shapes (produced by GameAdapter; logic treats all as read-only)

```lua
catalog = {
  rows = { [spellId] = { spellId=n, name=s, maxStack=n, classMask=n, minLevel=n,
                         quality=n, groupId=n, requiredSpell=n } }, -- validated echo rows only
  familyOf   = { [spellId] = familyKey },  -- "g<groupId>" when >1 row shares groupId, else "s<spellId>"
  familyMembers = { [familyKey] = { spellId, ... } },       -- sorted ascending
  familyName = { [familyKey] = s },                          -- display
  levers = { [requiredSpell] = { lever=requiredSpell, conformant=bool,
                                 members={spellId,...}, tomeName=s|nil } },
  playerMask = n,   -- corrected class mask (PerkClassMasks.DRUID is a client bug; adapter derives)
}

wishlist = nil | {           -- nil => advisor-only mode
  name = s,
  entries  = { { spellId=n, quality=n, stacks=n, family=s } , ... },  -- stacks >= 1
  byFamily = { [familyKey] = { targetStacks=n, wishedQuality=n, spellId=n } },
}

owned = {                    -- granted ∪ locked ∪ adapter-recorded picks
  bySpell  = { [spellId] = count },
  byFamily = { [familyKey] = count },
  synced = bool,             -- false => engine must not auto-act at level > 1
}

board = nil | {              -- nil => no board (wait)
  cards = { { spellId=n, quality=n, family=s, isFrozen=b, isCarried=b,
              isGuaranteed=b, justFrozen=b } , ... },  -- 1..3 entries
  guaranteedIndex = n|nil,   -- found by scanning isGuaranteed; nil is VALID (4-card trim)
  signature = s,
}

charges = { banish=n, freeze=n, reroll=n, trustworthy=bool }  -- min(client, ledger), >=0

slots = nil | {              -- nil => SS 540 not arrived
  bySlot = { [slot] = { slot=n, name=s, verified=b, verifiedFieldPresent=b,
                        suspectParse=b,   -- echoes empty though entriesStr wasn't
                        echoes = { { spellId=n, stacks=n, locked=b, family=s }, ... } } }, -- SPARSE; pairs() only
  activeSlot = n,            -- 0 = none
}

flags = { DISABLE_SUPPRESSES_GUARANTEE = true|false,  -- true (user-confirmed) unless runtime-demoted
          REROLL_HOLDS_GUARANTEED = true|false|nil }  -- nil = conservative

plan = Strategy.Compile output (below).
queue = Ratchet.PredictQueue output (below).
```

## logic/Model.lua — `Nexus.Model`

Fork from EchoOptimizer/logic/Model.lua VERBATIM: `NormName`, `StripRaritySuffix`,
`CanonicalKey`, `BuildDistribution(entries,nBins,floor)`, `EmaxK(dist,k)`,
`EmaxGivenK(dist,c,k)`, `WithoutKey(dist,key)`. New functions:

- `Model.Support(catalog, owned, level, disabledLevers, plan)` → array of
  `{ spellId, family, quality, value }` — free-slot draw support: row passes iff
  `bit-and(classMask, playerMask) ~= 0` (implement via arithmetic, no bit lib in logic:
  `Model.MaskMatch(mask, playerMask)` using modular arithmetic), `minLevel <= level`,
  its lever (if any, `requiredSpell~=0` and lever exists) is not in `disabledLevers`
  (set keyed by lever id), and not exhausted (`owned.bySpell[spellId] or 0) < maxStack`
  — plus for maxStack==1 rows any owned FAMILY member exhausts the whole family's other
  qualities for coverage purposes but NOT pool presence (pool removal is per-spellId).
  `value` = `Model.Delta(...)` for that spellId.
- `Model.Delta(plan, owned, spellId, catalog, params)` → number. Ordinal scale
  (`params` from data/DefaultProfile): uncovered wished family → `params.coverage`
  (+ `params.qualityBonus * quality`); wished stackable below targetStacks →
  `params.coverage * (remaining/target)` decreasing; anchor spellId itself uncovered →
  `params.anchorUnlock`; unique new family while anchor owned → `+params.diversity`;
  duplicate of an owned maxStack==1 family → `params.duplicate` (≈0/negative);
  off-wishlist non-duplicate → `params.filler` (negative). Pure function, no state.
- `Model.FreeDist(support)` → `BuildDistribution` over support with UNIFORM probs
  (θ unmeasured); nil-safe on empty support (return nil → callers treat E as 0).

## logic/Strategy.lua — `Nexus.Strategy`

- `Strategy.Compile(catalog, wishlist, settings)` → plan:
  ```lua
  plan = {
    targets = wishlist and wishlist.byFamily or {},
    wishedFamilies = { [familyKey]=true },
    anchorSpellId = settings.anchorSpellId (nil unless the row exists in catalog & on wishlist),
    leverPlan = {
      disable = { leverId, ... },  -- conformant AND every member's family off-wishlist
      keep    = { leverId, ... },  -- has a wishlist-family member
      skippedNonConformant = { leverId, ... },  -- NEVER toggled (e.g. requiredSpell=9)
    },
    advisorOnly = (wishlist == nil),
  }
  ```
  Lever conformance comes from `catalog.levers[l].conformant` (adapter computes via the
  name-exact "Tome of <member name>" rule); Strategy only partitions. Deterministic
  ordering (sort lever ids ascending).

## logic/Ratchet.lua — `Nexus.Ratchet`

- `Ratchet.PredictQueue(activeEchoes, owned, plan, flags, disabledLevers, catalog)` →
  `{ entries = { { spellId, family, wanted=bool }, ... } }` in given order, skipping
  entries whose FAMILY is owned (family-aware subtraction, addendum §B2), and — iff
  `flags.DISABLE_SUPPRESSES_GUARANTEE` — skipping members of disabled levers.
  Prediction is planning/UI-only; never coverage.
- `Ratchet.Dominates(candidateOwned, incumbentEchoes, plan, catalog)` → `ok, detail` —
  compare target-capped wishlist stacks and distinct off-wishlist filler families.
  Save a net wishlist gain, a filler reduction at equal wishlist progress, or a
  one-for-one wishlist rotation that adds no filler. Reject unchanged snapshots
  and net wishlist regressions. `incumbentEchoes` = slot echoes array.
- `Ratchet.ScoreSlot(slotEchoes, plan, catalog)` → number (wished families covered −
  `0.25 ×` off-wishlist families) and `Ratchet.BestSlot(slots, plan, catalog)` →
  `slot|nil` over genuinely-verified rows only (`verified and verifiedFieldPresent and
  not suspectParse`), sparse-safe (pairs).
- `Ratchet.RunsEstimate(plan, owned, queue, support)` → `{ text = s, unknown = bool }` —
  with θ unmeasured return `unknown=true` and text like "~N wishlist echoes pending
  (rate unmeasured)"; never fabricate a number labeled as fact.

## logic/Policy.lua — `Nexus.Policy`

- `Policy.Decide(state)` where `state = { board, owned, charges, plan, queue, flags,
  level, horizon, support, params, searchRefused, allowBanish }`
  → action:
  `{ type = "take"|"freeze"|"reroll"|"banish"|"wait", spellId=?, index=?,
  reason = s, endgame=? }`
  plus `annotations = { [cardIndex] = "wanted"|"guaranteed"|"duplicate"|"filler"|"junk" }`.
  Rules:
  1. Compute `Model.Delta` for each card. Guaranteed card =
     `board.guaranteedIndex` or a card's `isGuaranteed` flag; array position has
     no meaning.
  2. Below level 80, protect an exposed wanted side Echo first, then spend one
     safe off-wishlist Banish per fresh run-data push before normal queue
     handling. A frozen/carried wanted side permits early Banish while the
     guarantee remains; without a guarantee, wanted cards keep take priority.
  3. While a guaranteed card exists, freeze the best scarce wanted side Echo,
     re-evaluate after asynchronous resolution, then drain guaranteed cards.
     A queue-deliverable single-stack target is annotated `returns later` and
     is not frozen. An unavailable or refused Freeze takes the wanted side Echo
     as loss prevention. At level 80, Freeze additionally requires a numeric
     horizon above one. This drain rule applies only to wishlist guarantees.
     An off-wishlist guarantee is never selected: take a visible missing
     wishlist side not already promised by the remaining queue, otherwise use
     safe side Banishes then Rerolls, and finally take the least-harmful side if
     search is exhausted.
  4. When no guaranteed card exists, take a frozen/carried wanted Echo first,
     then any visible wanted Echo. With nothing wanted, use one safe Banish per
     fresh run-data push, then Reroll, then make the deterministic least-harmful
     mandatory selection.
  5. Final-selection exception requires both level 80 and a numeric
     `horizon == 1`. Lower-level `horizon == 1` only ends the current pending
     batch and must keep normal queue behavior. Level 80 alone is not a final
     signal. On the true final selection, a visible wanted side Echo is taken
     immediately. Otherwise, when a frozen wanted Echo or guaranteed card
     protects the final choice and another wishlist target remains missing,
     use a safe off-wishlist Banish before consuming that fallback. Reroll may
     continue from a frozen wanted fallback, a non-wanted guaranteed fallback,
     or a wanted guaranteed fallback only when
     `REROLL_HOLDS_GUARANTEED == true`. Exhausted search takes the frozen Echo
     when present; otherwise normal guaranteed draining resumes.
  6. Final comparison is fully wishlist-driven: stacking deficit,
     quality-qualified one-shot, normal delta, then stable card index. No Echo
     name receives a special final-selection priority.
  7. Never Banish a wished-family, guaranteed, frozen, carried, or just-frozen
     card. A Reroll reason may describe the guaranteed card as held only when
     `flags.REROLL_HOLDS_GUARANTEED == true`.
  8. `searchRefused` records synchronous final-search refusals for the current
     board signature; Policy skips refused actions and consumes the protected
     frozen/guaranteed fallback.
  9. `board == nil` or `owned.synced == false` (with level>1) →
     `{type="wait", reason}`.
  Pure function; same input → same output.

## data/DefaultProfile.lua — `Nexus.DefaultProfile`

Pure table: `params` (coverage=100, qualityBonus=2, anchorUnlock=150, diversity=5,
duplicate=-5, filler=-15, rerollCost=8, rerollHoldThreshold=25), `defaultSettings`
(autoPick=true, autoActivate=true, autoDisable=true, autoSave=true, autoBanish=true,
anchorSpellId=nil, leverOptOut={}), `defaultFlags` (DISABLE_SUPPRESSES_GUARANTEE=true
-- user-confirmed 2026-07-23, runtime-demotable; REROLL_HOLDS_GUARANTEED=nil).

## core/Store.lua — `Nexus.Store` (SavedVariables: `NexusDB`)

`Store.Init()` (wholesale-replace on version change, sibling pattern), `Store.Settings()`,
`Store.State()` (per-char keyed subtable: tomeTogglePending per lever w/ timestamps,
priorAutoAccept, flagDemotions, recordedPicks for the current session). Char key from
`UnitName("player")` guarded — if unavailable, defer (never latch "Unknown").

## core/GameAdapter.lua — `Nexus.GameAdapter` (sole IO; my file)

Exposes to Main: `Init(callbacks)`, `Catalog()`, `Board()`, `Charges()`, `Owned()`,
`Wishlist()`, `Slots()`, `DisabledLevers()`, `DiscoverySynced()`, `Level()`, `Horizon()`,
`InFlight()`, `Take(spellId)`, `Banish(index)`, `Reroll()`,
`ToggleLever(leverId, wantDisabled)`, `Activate(slot)`, `Save(slot, name)`,
`SetSoloPicker()`, `RestoreAutoAccept()`, `RivalDetected()`, `RequestSlots()`,
`RequestGranted()`. All per design doc §4 (deep copies, ledger, gate v2 latch-polling,
run-boundary, self-check demotion hook).

## ui/*

- `ui/Readout.lua` — `Nexus.Readout`: pure-ish formatting: `Readout.Status(model)`,
  `Readout.CardLine(card, annotation, delta)`, `Readout.QueueLines(queue, n)`. No IO.
- `ui/Panel.lua` — `Nexus.Panel`: movable frame `NexusPanel`:
  status line, up to 3 card lines + recommendation, AUTO ON/OFF button (calls
  `callbacks.ToggleAuto()`), version string. `Panel.Init(callbacks)`, `Panel.Render(model)`.
  model = { status, cards={ {text, highlight} }, recommendation, auto, version }.
- `ui/JournalTab.lua` — `Nexus.JournalTab`: lazy install by hooking
  `ProjectEbonhold.EchoJournal.Show/Toggle` via hooksecurefunc (journal frames DO NOT
  exist at login), `PanelTemplates`-based 4th tab "Optimizer", soft-fail contract
  (pcall everything; failure = no tab, no error). Content (text lines are fine for v1):
  wishlist decomposition counts + names (owned/pending/filler), lever list with
  per-lever state, runs estimate, terminology note ("targets the ACTIVE loadout —
  set via 'Play with' in Loadouts"), VERSION. `JournalTab.TryInstall(dataProvider)`,
  re-asserted on journal Show. UI files may read `ProjectEbonholdEchoJournal` frames
  (presentation-layer exception, documented) but NEVER PerkService — all data through
  the provider callback.

## Post-review amendments (binding, from the pre-deploy adversarial pass)

- **Index bases:** `Policy` `action.index` is **1-based** into `board.cards`;
  `GameAdapter.Banish(index0)` takes the client's **0-based** perk index. `Main`
  converts at the seam (`action.index - 1`).
- `board` additionally carries `idSignature` (spellIds only, comma-joined) — the
  in-flight select resolution compares idSignatures like-for-like (the flag-suffixed
  `signature` would misread a failed select as success).
- **`Ratchet.Dominates` filler axis is COUNT-based**, not set-subset: every board
  forces a take, so per-run filler sets always differ. Wishlist progress is the
  sum of target-capped stacks. A clean equal-progress wishlist rotation saves so
  the next run can search for the family rotated out; rotations that add filler
  do not save. Advisor mode (no wishlist) NEVER saves.
- `Store` per-char `tomeTogglePending[lever] = { t = sentAt, want = bool }` (legacy
  bare-number entries read as `want=true`); `priorAutoAccept` survives version bumps.
- `GameAdapter.DisabledLevers()` values are `"confirmed"` (server mirror) or
  `"pending"` (our unconfirmed request) — both truthy for pool math; only
  `"confirmed"` may drive the DISABLE_SUPPRESSES_GUARANTEE self-check demotion.
- Per-latch watchdog: a client `pending*` latch stuck >10s is declared dead for the
  session (per-action, mirroring the client's own failure mode), excluded from the
  whole-loop gate, its charges zeroed, status surfaced; recovers if the latch clears.
- Run boundary (`A.RunBoundaryReset`, called on every arrival at level 1): recorded
  picks void; owned-sync trust suspended until the client-reported owned set CHANGES
  from its at-reset snapshot (dead-run ghost protection).
- Level 80 with a live board runs every pending board FIRST; save only after
  `Adapter.Board()` clears. `Adapter.Horizon()`, not level, identifies the final
  remaining selection. After any save, the slot cache is re-requested (~3.5s)
  for verification.
- Decision-log board records include `horizon`; final-selection proposals set
  `proposal.endgame=true` and carry a reason naming the selected Banish, Reroll,
  higher-priority side Echo, or frozen fallback path.
- Seeding saves only into an empty slot within `GetServerUnlockedSlots()`.
- `Panel.Toggle()` exists. `/wr undemote` clears flag demotions.

## tests (mine)

`tests/harness.lua` (stub extensions per design §10) + `tests/run_integration.lua`
(scenario asserts). Run: `luajit tests/run_integration.lua` from the addon root; exits
non-zero on failure. A red suite blocks deploy.
