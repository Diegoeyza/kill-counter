# Nexus page — Kill Counter v1.0.0

Upload `dist/KillCounter-1.0.0.zip` as the main file, then paste the fields
below into the mod page.

**Title:**

```
Kill Counter — Total Monster Kills in Hunter Profiles (REFramework)
```

**Short description:**

```
Adds the total kill count the Hunter Profile never shows: sum of all monsters hunted, for your own profile and for anyone in your lobby or link party, plus a per-monster breakdown.
```

**Description (Markdown):**

````markdown
# Kill Counter

The Hunter Profile tells you how many Rathalos you have hunted. It never tells you how many monsters **in total**. This mod adds that number — for you, and for anyone whose profile you open — with a per-monster breakdown underneath.

```
HR 912 (Palico: Michurris) — 2,113 hunted
  Hunted: 2,113  (34 monsters)
  Captured: 542
  ▸ Arkveld: 634 / 455
    Rathalos: 137 / 3
    Lagiacrus: 128 / 23
    ...
```

## What it shows

- **Hunted total** — the sum of every per-monster hunt count from the profile. These are exactly the numbers the game's own profile screen displays.
- **Captured total** — summed separately so the two never mix.
- **Per-monster list** — name, hunted, captured, sorted by kills. Expand a row to see it.
- **Optional always-on window** — a compact overlay with the totals while you play.

## How to use

1. Install REFramework, then extract this archive into your game folder (Vortex: install normally). You should get:
   `\reframework\autorun\kill_counter.lua`
2. In game press **Insert** → **Script Generated UI** → **Kill Counter**.
3. Open a Hunter Profile — yours, or anyone's in your lobby / link party. The row appears as soon as the profile opens; you can close it again straight away.
4. Click the triangle on a row for the per-monster breakdown.

## About other players

The game only keeps a Hunter Profile in memory **while it is on screen**, and the lobby hunter object itself carries no record data. So for someone else, open their profile once — the mod copies the numbers at that moment and keeps the row afterwards.

Rows are labelled by **Hunter Rank and Palico name**, because profile data does not include the hunter's display name.

## Safety

- **Read-only.** Nothing is written to the game, to your save, or to other players.
- No network access, no config file, no keybinds.
- One read-only constructor capture; no per-frame work when idle.
- Every SDK call is guarded, so the script never throws into the game.

## Credits

- REFramework by praydog
- Script shape follows Hunt Dumper (MIT) by thieleju
````
