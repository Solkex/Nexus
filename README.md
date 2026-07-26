# Nexus

## Download Nexus

### [Download Nexus.zip](https://github.com/Solkex/Nexus/releases/latest/download/Nexus.zip)

This is the player-ready Nexus 1.0 addon.

> **Do not use GitHub's “Code → Download ZIP” button to install the addon.** That download contains the repository source and will not have the intended player package layout. Use the **Download Nexus.zip** link above.

## Installation

1. Download [Nexus.zip](https://github.com/Solkex/Nexus/releases/latest/download/Nexus.zip).
2. Open the ZIP and extract the `Nexus` folder.
3. Put that folder inside Ebonhold's `Interface\AddOns` folder.
4. Confirm the installed file exists at `...\Interface\AddOns\Nexus\Nexus.toc`.
5. Start Ebonhold or type `/reload` if the game is already running.

Example addon folder:

```text
F:\Ebonhold\Ebonhold\Interface\AddOns
```

The finished installation should look like:

```text
F:\Ebonhold\Ebonhold\Interface\AddOns\Nexus\Nexus.toc
```

If your archive tool shows another surrounding folder, extract the inner `Nexus` folder—the folder that directly contains `Nexus.toc`.

## About Nexus

Nexus provides Echo build automation, community builds, and DPS leaderboards for Project Ebonhold.

It helps you choose and complete an Echo build, share builds with other players, and compare exact loadouts using verified DPS records.

## Getting Started

1. Install Nexus and Details!.
   - Details! is required for DPS tracking and leaderboard records.
   - Disabling other addons that automate or modify Echo choices is recommended.
2. Log in or type `/reload`.
   - The Nexus HUD should appear automatically.
   - If it does not, left-click the Nexus minimap button.
3. Pick a build.
   - Import an in-game loadout.
   - Create your own wishlist.
   - Or open **Community Builds**, filter by class, and copy a build.
4. Press **Switch** on the Nexus HUD and select the wishlist you want to use.
5. Choose your roll mode.
   - Leave **Auto ON** for full supported automation.
   - Turn **Auto OFF** to roll manually while still seeing Nexus recommendations and explanations.

## What Nexus Does

### Echo Board Automation

When an Echo board opens, Nexus recommends what to take, freeze, banish, or reroll based on your selected wishlist.

- **Auto ON:** Nexus handles supported Echo choices for you.
- **Auto OFF:** You make the choices manually while Nexus shows its recommendation and explains the logic.

Nexus accounts for guaranteed Echoes, freeze and banish sequencing, quality requirements, stack quantities, and temporary filler.

### Wishlist Progress

The HUD shows:

- Echoes you still need
- Extra Echoes you should eventually shed
- Unlearned tomes preventing wishlist Echoes from appearing
- Your best Dummy and Lich King DPS for the selected loadout
- The current global best for that same exact loadout

### Community Builds

Browse builds shared by other Nexus users, filter by class, read descriptions, preview Echoes, and copy an exact build into your own wishlist.

Builds and updates sync through online Nexus users with safeguards to prevent lag when you press **Sync now**. Nexus also performs a safe, throttled sync after login.

### DPS Leaderboards

With Details! enabled, Nexus records valid Training Dummy and Lich King sessions lasting at least 30 seconds.

Each record is tied to the exact Echo IDs and stack quantities used during the pull. When you set a new personal record, Nexus can automatically create or update the build for that character.

Mouse over another Nexus user to see that they use Nexus and, when applicable, their leaderboard rank.

## Why Nexus Sometimes Takes Filler

When none of your target Echoes are available, Nexus may take the least harmful temporary filler.

This is intentional. The filler holds the slot until a wanted Echo appears and replaces it later. A strange-looking choice does not always mean the recommendation is wrong; Nexus may be planning around future replacements or protecting a harder-to-find Echo.

The HUD's **STILL NEEDED** section shows what is missing and will replace filler on following runs. Hover over relevant information for more detail.

## Unlearned Tomes

If the HUD shows **UNLEARNED**, one or more Echoes in the selected wishlist cannot appear yet because the related tome has not been learned.

Obtain the tome through world content and the Echo will become eligible to roll.

## Commands

Primary command: `/nexus`

Aliases: `/nx` and `/wr`

- `/nexus` — Show all commands
- `/nexus builds` — Open Community Builds
- `/nexus leaderboard` — Open the DPS Leaderboard
- `/nexus editor` — Open the Wishlist Editor
- `/nexus sync` — Request current builds and records from nearby Nexus users
- `/nexus dps` — Show DPS capture status
- `/nexus auto` — Toggle Auto mode
- `/nexus panel` — Show or hide the main HUD
- `/nexus overlay` — Show or hide the on-screen wishlist
- `/nexus status` — Show diagnostic status

## Requirements

- Details! is required for DPS tracking and leaderboard records.
- [Details! 3.3.5 download](https://warperia.com/addon-wotlk/details-damagemeter/)

## Important Notes

- Leaderboard records use the exact Echo IDs and stack quantities from the recorded pull.
- Different Echo quantities count as different loadouts.
- Verified leaderboard sessions must last at least 30 seconds.
- Only the character that owns a build can edit it.
- A loadout tied to a leaderboard record cannot have its Echo list changed afterward.
- The owner can still rename the record build and update its description.
- Nexus safely throttles login syncing and only downloads large exact loadouts when they are missing.
- Saved WishlistRealizer data is migrated automatically on first load.

## Source Code

The public Nexus 1.0 source is available in this repository. Players should install the prepared [Nexus.zip release](https://github.com/Solkex/Nexus/releases/latest/download/Nexus.zip), not the repository ZIP.
