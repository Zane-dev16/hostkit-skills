#!/usr/bin/env bash
# Editable-files install: scripts/install.sh [--mode full|readonly] [--dest DIR]
# Default mode is full; default dest is ~/.agents/skills.
#
#   full      → <dest>/hostkit           writes available behind HOSTKIT_ALLOW_WRITES
#   readonly  → <dest>/hostkit-readonly  same CLI, configured to refuse every write
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=full
DEST="$HOME/.agents/skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    *) echo "usage: install.sh [--mode full|readonly] [--dest DIR]"; exit 2 ;;
  esac
done
case $MODE in
  full) SRC=plugins/hostkit/skills/hostkit; NAME=hostkit ;;
  readonly) SRC=plugins/hostkit-readonly/skills/hostkit-readonly; NAME=hostkit-readonly ;;
  *) echo "mode must be full|readonly"; exit 2 ;;
esac

./scripts/build.sh >/dev/null
mkdir -p "${DEST:?}"
rm -rf "${DEST:?}/${NAME:?}"
cp -R "$SRC" "${DEST:?}/${NAME:?}"
echo "OK: installed $NAME ($MODE) to $DEST/$NAME"
