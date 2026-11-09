# Kill Counter

**A tiny REFramework mod for Monster Hunter Wilds.** The game's Hunter Profile
shows how many of *each* monster you've hunted, but never the total. This mod
adds the sum — for you and for anyone whose profile you open.

```
HR 912 (Palico: Michurris) — 2,113 hunted
  Hunted: 2,113  (34 monsters)
  Captured: 542
  ▸ Arkveld: 634 / 455
    Lagiacrus: 128 / 23
    Rathalos: 137 / 3
    ...
```

## What it does

- **Total kills** per player: the sum of every per-monster hunt count from the
  Hunter Profile (`HuntingNum`), with captures summed separately.
- **Per-monster list**: name, hunted, captured — sorted by kills.
- **Anyone in your lobby or link party**: open their Hunter Profile once and
  the row sticks, even after you close it.
- **Optional always-on window** so the numbers are visible without opening the
  REFramework menu.

## Why profiles have to be opened

A `cHunterProfile` object only exists while its profile screen is on screen —
the pointers go dead as soon as it closes (verified in the probe: 2 of 4
captures dead). The mod therefore copies the numbers into plain Lua values the
moment a profile appears, and the row survives afterwards.

A player's hunter object in the lobby carries no record data at all, so opening
their profile once is the only source. That is a game limitation, not a mod
one.

Rows are labelled by **Hunter Rank + Palico name** because the game exposes no
hunter display name on profile objects.

## Requirements

- Monster Hunter Wilds
- [REFramework for MH Wilds](https://www.nexusmods.com/monsterhunterwilds) (install `dinput8.dll` first)

## Install

1. Install REFramework if you have not already.
2. Copy `reframework/kill_counter.lua` to
   `<game>\reframework\autorun\kill_counter.lua`
   (Steam: `...\steamapps\common\MonsterHunterWilds\reframework\autorun\`)
3. Launch the game → REFramework menu (Insert) → **Script Generated UI** →
   **Kill Counter**.

Release zips (`./package.sh` → `dist/`) come in two shapes: a flat bundle and a
`KillCounter-<version>.zip` laid out for the game folder (Nexus/Vortex).

## Safety

- **Read-only.** The mod never writes a field, never touches save data, never
  talks to the network, and never modifies other players' state.
- No per-frame work: one `on_frame` that returns immediately unless a profile
  was just constructed.
- Everything is `pcall`-guarded: the script never throws into the game.
- No config file, no keybinds.

## How it was derived

See `reframework/kill_probe.lua` — the development probe used to locate the
data (kept in the repo, never shipped in release bundles):

| Step | Finding |
|---|---|
| v1 | Hunter objects (`cHunterStatus`, `cPlayerManageInfo`, `HunterCharacter`) carry no record data |
| v2 | `app.cHunterProfile` is built on profile open; `ProfileEnemyReport.BossReport` = 100 entries |
| v3 | Element `app.cHunterProfile_BossReport`: `FixedId`, `HuntingNum`, `CaptureNum`, `MinSize`, `MaxSize` |
| v4 | `HuntingNum` matches the profile UI exactly (Arkveld anchor: 628) |
| v5-v7 | `FixedId` is **not** an enemy id — feeding it to `EnemyName` yields wrong monsters |
| v10-v12 | Correct chain: `_EnemyCountData:getDataByFixedId(Fixed)` → `get_EnemyId()` → `EnemyName(id)` → `via.gui.message` |

## Credits & license

- [REFramework](https://github.com/praydog/REFramework) by praydog
- Overall script shape follows [Hunt Dumper](https://github.com/thieleju/HUNT_DUMPER) (MIT) by thieleju
- Licensed under Apache-2.0 (see `LICENSE`)
