# Changelog

All notable public changes to Nexus are documented here.

## 1.17

### Guarantee convergence

- Rejects a guaranteed Echo when its exact quality is below the wishlist target; the wished family remains protected from Banish.
- Uses final-selection Banish/Reroll search while preserving a frozen or confirmed-held wanted fallback.
- Preserves the latest multi-board level-80 horizon handling and refusal recovery.
- Adds a safe two-Snapshot relay: improvements save only to an inactive empty or weaker same-wishlist Snapshot, then arm on the next level-1 visit after exact verification.
- Adds stable per-Snapshot wishlist associations so the active guarantee source and its intended wishlist cannot drift apart.

### Scoring and safety

- Counts explicit multi-quality wishlist tiers correctly instead of rejecting a lower tier the player requested.
- Scores requested stack progress when choosing between saved Snapshots.
- Never overwrites the active Snapshot, an unrelated Snapshot, an unverified Snapshot, or a stronger same-wishlist Snapshot.
- Keeps protocol-7 DPS identity validation, owner verification, mesh backfill, and peer-presence hardening from the latest public code.

### Interface and diagnostics

- Adds the release HUD, Snapshot association controls, server-status view, bounded support diagnostic export, and one-time 1.17 release notes.
- Defers heavy UI initialization until the player enters the world.

## 1.1

### Added

- Mesh-style peer synchronization for Community Builds and DPS records.
- Lightweight build summaries before full loadout transfer.
- Automatic backfilling of missing exact loadouts.
- Delayed, throttled synchronization after login.
- Peer discovery and presence announcements.
- Sync diagnostics available through `/nexus status`.

### Improved

- Reduced addon-channel traffic with hash buckets, responder claims, pacing, and rolling traffic limits.
- Safer manual **Sync now** behavior with cooldowns, bounded retries, and transfer timeouts.
- Better convergence between online Nexus users without requiring one permanent central host.
- Clearer release download and installation instructions for players unfamiliar with GitHub.
- Repository now clearly separates the public source code from the player-ready release archive.

### Compatibility

- Existing Nexus and WishlistRealizer saved data remains supported and is migrated automatically when possible.
- Details! remains required for DPS capture and leaderboard records.

## 1.0

- Initial public release.
- Echo board recommendations and supported automation.
- Wishlist creation, switching, progress tracking, and loadout convergence.
- Community Builds.
- Exact-loadout DPS records and leaderboards.
