# Nexus

Echo build automation, community builds, DPS leaderboards, and mesh-style synchronization for Project Ebonhold.

## Download Nexus
### [Download Nexus.zip](https://github.com/Solkex/Nexus/releases)

This is the correct download for normal players.

> **Do not use the green “Code” button or “Download ZIP” to install Nexus.** That option downloads the source repository, not the prepared addon package. Use the **Nexus.zip** release link above.

## Installation

1. Download Nexus.zip latest release here
https://github.com/Solkex/Nexus/releases
2. Open the archive and extract the `Nexus` folder.
3. Place that folder inside Ebonhold's `Interface\AddOns` folder.
4. Confirm this file exists:

```text
...\Interface\AddOns\Nexus\Nexus.toc
```

5. Start Ebonhold, or type `/reload` if the game is already running.

A typical finished installation looks like:

```text
F:\Ebonhold\Ebonhold\Interface\AddOns\Nexus\Nexus.toc
```

If the archive opens into another surrounding folder, use the inner `Nexus` folder—the folder that directly contains `Nexus.toc`.

## Updating from an Older Version

1. Exit the game or log out.
2. Delete the old `Interface\AddOns\Nexus` folder.
3. Extract the new `Nexus` folder into `Interface\AddOns`.
4. Do **not** delete your SavedVariables unless you intentionally want to reset Nexus.

Nexus automatically migrates saved WishlistRealizer data when possible.

## What Nexus Does

### Echo Board Automation

Nexus recommends what to take, freeze, banish, or reroll based on your selected wishlist.

- **Auto ON:** Nexus handles supported Echo choices.
- **Auto OFF:** You make the choices while Nexus shows its recommendation and reasoning.

Nexus accounts for guaranteed Echoes, freeze and banish sequencing, exact quality requirements, stack quantities, temporary filler, and safe two-Snapshot convergence.

Only the active Snapshot supplies guaranteed Echoes, and the active Snapshot cannot be overwritten. Nexus therefore saves a confirmed improvement into an inactive Snapshot and arms that exact Snapshot on the next level-1 visit. Unrelated, unverified, or stronger Snapshots are never overwritten.

### Wishlist Progress

The HUD shows:

- Echoes you still need
- Extra Echoes you should eventually shed
- Unlearned tomes preventing wishlist Echoes from appearing
- Your best Dummy and Lich King DPS for the selected loadout
- The current global best for that exact loadout

### Community Builds and Mesh Sync

Browse builds shared by other Nexus users, filter by class, preview Echoes, and copy an exact build into your own wishlist.

Nexus 1.17 uses a throttled peer-to-peer sync system. **Sync now** requests build summaries and DPS records from online Nexus users, then safely backfills missing exact loadouts. Nexus also performs a delayed, rate-limited sync after login.

### DPS Leaderboards

With Details! enabled, Nexus records valid Training Dummy and Lich King sessions lasting at least 30 seconds.

Each record is tied to the exact Echo IDs and stack quantities used during the pull. Different Echo quantities count as different loadouts.

## Getting Started

1. Install Nexus and Details!.
2. Log in or type `/reload`.
3. Open Nexus with the minimap button or `/nexus`.
4. Import an in-game loadout, create a wishlist, or copy a Community Build.
5. In the Echo Journal, associate the active saved Snapshot with the wishlist Nexus should progress.
6. Keep a second unlocked Snapshot slot empty, or associate a weaker second Snapshot with the same wishlist, so Nexus can relay improvements safely.
7. Leave **Auto ON** for supported automation, or use **Auto OFF** for manual choices with recommendations.

## Commands

Primary command: `/nexus`

Aliases: `/nx` and `/wr`

- `/nexus` — Show all commands
- `/nexus builds` — Open Community Builds
- `/nexus leaderboard` — Open the DPS Leaderboard
- `/nexus editor` — Open the Wishlist Editor
- `/nexus sync` — Request current builds and records from online Nexus users
- `/nexus dps` — Show DPS capture status
- `/nexus auto` — Toggle Auto mode
- `/nexus panel` — Show or hide the main HUD
- `/nexus overlay` — Show or hide the on-screen wishlist
- `/nexus status` — Show diagnostic status

## Requirements

- Details! is required for DPS tracking and leaderboard records.
- [Details! 3.3.5 download](https://warperia.com/addon-wotlk/details-damagemeter/)

## Troubleshooting

### Nexus does not appear in the addon list

Check that the folder is not nested twice. The correct path ends in:

```text
Interface\AddOns\Nexus\Nexus.toc
```

Not:

```text
Interface\AddOns\Nexus-main\Nexus\Nexus.toc
```

### Community Builds are not updating

- Make sure other Nexus users are online.
- You may have to be in normal world tier it bugs sometimes idk
- Press **Sync now** once and allow the sync window to finish.
- Avoid repeatedly pressing Sync; Nexus deliberately rate-limits traffic.
- Use `/nexus status` for diagnostic information.

### DPS is not recording

- Confirm Details! is enabled.
- The session must last at least 30 seconds.
- The record is tied to the exact Echo IDs and stack quantities used.

## Important Notes

- Only the character that owns a build can edit it.
- A loadout tied to a leaderboard record cannot have its Echo list changed afterward.
- The owner can still rename the record build and update its description.
- Nexus throttles login syncing and only downloads large exact loadouts when needed.
- Saved WishlistRealizer data is migrated automatically on first load.

## Source Code

The complete Nexus 1.17 source code is publicly available in this repository.

Developers may clone or download the repository source. Players should install the prepared [Nexus.zip release](https://github.com/Solkex/Nexus/releases/latest/download/Nexus.zip) instead.

See [CHANGELOG.md](CHANGELOG.md) for release notes.
