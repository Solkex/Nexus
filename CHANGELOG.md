# Changelog

All notable public changes to Nexus are documented here.

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
