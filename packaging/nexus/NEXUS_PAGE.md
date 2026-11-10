# Nexus page — Kill Counter v1.0.0

Upload `dist/KillCounter-1.0.0.zip` as the main file.

The Nexus mod description field uses **BBCode** (not Markdown). Paste the block
below straight into the Description field (BBCode/source view). Markdown `#`
and `**` will NOT render on Nexus.

---

**Title:**

```
Kill Counter — Total Monster Kills in Hunter Profiles (REFramework)
```

**Short description:**

```
Adds the total kill count the Hunter Profile never shows: the sum of all monsters hunted, for your own profile and for anyone in your lobby or link party, plus a per-monster breakdown.
```

**Full description (BBCode — paste as-is):**

```
[size=6][b]Kill Counter[/b][/size]

The Hunter Profile tells you how many Rathalos you have hunted. It never tells you how many monsters in [b]total[/b].

This mod adds that number — for you, and for anyone whose profile you open — with a per-monster breakdown underneath.

[code]
HR 250 (Palico: Fluffy) — 1,847 hunted
  Hunted:    1,847  (34 monsters)
  Captured:    412
  ▸ Arkveld:     634 / 455
    Rathalos:    137 / 3
    Lagiacrus:   128 / 23
    ...
[/code]
[size=2](hunted / captured)[/size]

[line]

[size=5][b]What it shows[/b][/size]

[list]
[*][b]Hunted total[/b] — the sum of every per-monster hunt count in the profile. These are exactly the numbers the game's own profile screen shows, so the total is the real total.
[*][b]Captured total[/b] — summed separately, so hunts and captures are never mixed together.
[*][b]Per-monster list[/b] — name, hunted and captured, sorted by kills. Click the triangle on a row to expand it.
[*][b]Always-on window[/b] — optional compact overlay with the totals while you play, so you don't have to open the REFramework menu.
[/list]

[line]

[size=5][b]How to use[/b][/size]

[list=1]
[*]Install REFramework, then extract this archive into your game folder (Vortex: install normally). You should end up with:
[code]<game>\reframework\autorun\kill_counter.lua[/code]
[*]In game, press [b]Insert[/b] to open REFramework.
[*]Go to [b]Script Generated UI[/b] → [b]Kill Counter[/b].
[*]Open a Hunter Profile — yours, or anyone's in your lobby / link party. The row appears as soon as the profile opens; you can close it again straight away.
[*]Click the triangle on a row for the per-monster breakdown.
[/list]

Default Steam path:
[code]...\steamapps\common\MonsterHunterWilds\[/code]

[line]

[size=5][b]About other players[/b][/size]

The game only keeps a Hunter Profile in memory [b]while it is on screen[/b], and the lobby hunter object itself carries no record data at all. So for someone else, open their profile once — the mod copies the numbers at that moment and keeps the row afterwards, even after the profile is closed. This is a game limitation; there is no other data source.

Rows are labelled by [b]Hunter Rank and Palico name[/b], because profile data does not include the hunter's display name.

[line]

[size=5][b]Safety[/b][/size]

[list]
[*][b]Read-only.[/b] Nothing is written to the game, to your save, or to other players.
[*]No network access, no config file, no keybinds.
[*]One read-only constructor capture; no per-frame work while idle.
[*]Every SDK call is guarded, so the script never throws into the game.
[/list]

[line]

[size=5][b]Credits[/b][/size]

[list]
[*][url=https://github.com/praydog/REFramework]REFramework[/url] by praydog
[*]Script shape follows [url=https://github.com/thieleju/HUNT_DUMPER]Hunt Dumper[/url] (MIT) by thieleju
[/list]

Source and issues: [url=https://github.com/Diegoeyza/kill-counter]github.com/Diegoeyza/kill-counter[/url]
```
