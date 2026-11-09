Kill Counter - total monster kills per player (REFramework mod)
===============================================================

The Hunter Profile lists how many of each monster you have hunted, but never
the total. This mod adds the total - for you and for anyone whose profile you
open - plus a per-monster breakdown.

USAGE
-----
1. In game, press Insert to open REFramework.
2. Script Generated UI -> Kill Counter.
3. Open a Hunter Profile: your own, or anyone's in your lobby / link party.
   The row appears immediately; you can close the profile right away.
4. Click the triangle on a row for the per-monster list (hunted / captured).

Tick "Always-on window" to keep a compact overlay of the totals on screen.

WHAT IT SHOWS
-------------
- Hunted total: sum of every per-monster hunt count (matches the numbers the
  profile screen shows, verified against them).
- Captured total: summed separately.
- Per-monster list sorted by kills.

WHY OTHER PLAYERS NEED THEIR PROFILE OPENED ONCE
------------------------------------------------
The game only keeps a Hunter Profile in memory while it is displayed, and the
lobby hunter object carries no record data. So the mod copies the numbers the
moment a profile appears; after that the row stays even when the profile is
closed. This is a game limitation - there is no other data source.

Rows are labelled "HR <rank> (Palico: <name>)" because profiles do not expose
a hunter display name.

SAFETY
------
- Read-only: nothing is ever written to the game or to your save.
- No network access, no config file, no keybinds.
- Single read-only constructor capture; no per-frame work when idle.
- Every SDK call is pcall-guarded, so the script never throws into the game.

REQUIREMENTS
------------
- Monster Hunter Wilds
- REFramework for MH Wilds (dinput8.dll)

INSTALL
-------
Extract into your game folder so you get:

    <game>\reframework\autorun\kill_counter.lua

Default Steam path: ...\steamapps\common\MonsterHunterWilds\

Reload any time: REFramework menu -> Script -> Reset scripts.

CREDITS
-------
REFramework by praydog. Script shape follows Hunt Dumper (MIT) by thieleju.
This mod: Apache-2.0.
