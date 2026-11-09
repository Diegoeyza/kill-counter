#!/usr/bin/env bash
# Build shareable bundles into dist/:
#   kill-counter-<version>.zip    REFramework mod (flat) + install notes
#   KillCounter-<version>.zip     REFramework mod, game-folder layout (Nexus/Vortex)
set -euo pipefail
cd "$(dirname "$0")"

command -v zip >/dev/null || { echo "error: 'zip' is required" >&2; exit 1; }

MOD_VERSION="$(sed -n 's/^local VERSION = "\([^"]*\)".*/\1/p' \
  reframework/kill_counter.lua | head -1)"
[ -n "$MOD_VERSION" ] || { echo "error: VERSION not found in kill_counter.lua" >&2; exit 1; }

DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# 1) Flat bundle: the Lua file + install notes.
mkdir -p "$DIST/flat"
cp reframework/kill_counter.lua "$DIST/flat/kill_counter.lua"
cp reframework/INSTALL.txt "$DIST/flat/INSTALL.txt"
( cd "$DIST/flat" \
    && zip -q "../kill-counter-${MOD_VERSION}.zip" kill_counter.lua INSTALL.txt )
rm -rf "$DIST/flat"

# 2) Nexus/Vortex bundle: laid out for the game folder so it extracts straight
#    into <game>\ (reframework\autorun\kill_counter.lua) or installs via Vortex.
#    The development probe is deliberately NOT packaged.
mkdir -p "$DIST/nexus/reframework/autorun"
cp reframework/kill_counter.lua "$DIST/nexus/reframework/autorun/kill_counter.lua"
cp packaging/nexus/README.txt "$DIST/nexus/README.txt"
( cd "$DIST/nexus" && zip -q -r "../KillCounter-${MOD_VERSION}.zip" . )
rm -rf "$DIST/nexus"

echo "Built into $DIST/:"
ls -1 "$DIST"
