#!/usr/bin/env bash
# Editable-files install: scripts/install.sh [--mode full|readonly] [--dest DIR]
# Default mode is full; default dest is ~/.agents/skills.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=full
DEST="$HOME/.agents/skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --dest) DEST="$2"; shift 2;;
    *) echo "usage: install.sh [--mode full|readonly] [--dest DIR]"; exit 2;;
  esac
done
[ "$MODE" = full ] || [ "$MODE" = readonly ] || { echo "mode must be full|readonly"; exit 2; }

./scripts/build.sh >/dev/null
if [ "$MODE" = full ]; then SRC=plugins/hostkit/skills/hostkit; else SRC=plugins/hostkit-readonly/skills/hostkit; fi
mkdir -p "$DEST"
rm -rf "$DEST/hostkit"
cp -r "$SRC" "$DEST/hostkit"
echo "OK: installed hostkit ($MODE) to $DEST/hostkit"
