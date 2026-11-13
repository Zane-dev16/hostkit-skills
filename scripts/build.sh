#!/usr/bin/env bash
# Build the two installable skill modes from the single source, then gate them.
#
#   Full      skills/hostkit                     → plugins/hostkit/skills/hostkit
#   Readonly  same code, hk.mode=readonly, WRITE blocks stripped,
#             skill name hostkit-readonly        → plugins/hostkit-readonly/skills/hostkit-readonly
#
# The two modes differ by configuration (scripts/hk.mode), not by copy-pasted prose. The
# read-only gate lives in the script, so it holds whatever the documentation says.
#
# usage: build.sh [--check]   (--check builds into a scratch dir and fails on any drift)
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=skills/hostkit
VERSION=$(cat VERSION)
FULL=plugins/hostkit
RO=plugins/hostkit-readonly
# Documentation and shipped content. scripts/ holds this build tool and its own check patterns.
SCOPE=(skills plugins docs README.md .claude-plugin)
# A write in this skill is always a call shape plus the unlock; the read-only build ships neither.
WRITE_CALL='hk\.sh (add|update|remove|cancel|delete|close|send|generate|create|reopen|upload|set)[A-Za-z]*'

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  '') ;;
  *) echo "usage: build.sh [--check]"; exit 2 ;;
esac

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/hostkit-build.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

manifest() { # <dir> <name> <description>
  cat >"$1/plugin.json" <<EOF
{"author": {"name": "Irell Zane"}, "description": "$3", "homepage": "https://github.com/Zane-dev16/hostkit-skills", "keywords": ["hostkit", "skills", "api"], "license": "MIT", "name": "$2", "repository": "https://github.com/Zane-dev16/hostkit-skills", "skills": ["./skills/$2"], "version": "$VERSION"}
EOF
}

build_into() { # <root>
  local root=$1
  rm -rf "$root/plugins"
  mkdir -p "$root/$FULL/skills/hostkit" "$root/$RO/skills/hostkit-readonly/scripts"

  # Full: the source, byte for byte, with the full gate configuration.
  cp -R "$SRC/." "$root/$FULL/skills/hostkit/"
  printf 'full\n' >"$root/$FULL/skills/hostkit/scripts/hk.mode"

  # Readonly: same code and same gate, told to refuse writes; write documentation stripped so a
  # reader of this build is never handed an example it cannot run.
  sed '/<!-- WRITE-BEGIN -->/,/<!-- WRITE-END -->/d' "$SRC/SKILL.md" \
    | sed 's|^name: hostkit$|name: hostkit-readonly|' \
    | sed 's|^description: .*|description: "Hostkit reads: properties, reservations, invoices, SIBA"|' \
    | awk 'BEGIN{d=0} /^---$/ {d++; print; if (d==2) print "\n> Read-only build: `scripts/hk.sh` runs reads only and refuses every write before any network work. Install the full build when a write is needed."; next} {print}' \
    >"$root/$RO/skills/hostkit-readonly/SKILL.md"
  cp "$SRC/scripts/hk.sh" "$SRC/scripts/hk_project.py" \
    "$root/$RO/skills/hostkit-readonly/scripts/"
  printf 'readonly\n' >"$root/$RO/skills/hostkit-readonly/scripts/hk.mode"

  manifest "$root/$FULL" hostkit-skills "Agent skills for the Hostkit API (properties, reservations, guests, invoicing, SIBA). Full access: reads plus reservation, guest, SIBA, and invoicing writes behind a per-call unlock."
  manifest "$root/$RO" hostkit-skills-readonly "Agent skills for the Hostkit API (properties, reservations, guests, invoicing, SIBA). Read-only: the bundled CLI refuses every write, in code."
}

gate_source() {
  local opens closes
  opens=$(grep -c 'WRITE-BEGIN' "$SRC/SKILL.md" || true)
  closes=$(grep -c 'WRITE-END' "$SRC/SKILL.md" || true)
  [[ $opens == "$closes" && $opens -gt 0 ]] || fail "unbalanced WRITE markers in the source ($opens/$closes)"
  [[ $(tr -d '[:space:]' <"$SRC/scripts/hk.mode") == full ]] || fail "the source must ship hk.mode=full"
  [[ -x $SRC/scripts/hk.sh ]] || fail "skills/hostkit/scripts/hk.sh must be executable"
}

gate_docs() {
  # Documentation never carries a command that bears the credential: the CLI is the only client.
  local hits
  hits=$(grep -rniE '\b(curl|wget)\b' --include='*.md' "${SCOPE[@]}" || true)
  [[ -z $hits ]] || fail "documentation names curl/wget; ship the call through scripts/hk.sh instead:
$hits"
  # Same lexical rule the installer applies, so a blocked install is caught before pushing.
  hits=$(grep -rnE 'curl\s[^\n]*\$\{?[A-Za-z_0-9]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)' \
    --include='*.sh' --include='*.py' --include='*.md' "${SCOPE[@]}" || true)
  [[ -z $hits ]] || fail "a curl line interpolates a secret-shaped variable:
$hits"
}

gate_modes() {
  diff -r "$SRC" "$FULL/skills/hostkit" >/dev/null || fail "the full build drifted from the source"
  [[ $(tr -d '[:space:]' <"$FULL/skills/hostkit/scripts/hk.mode") == full ]] \
    || fail "the full build must ship hk.mode=full"
  [[ $(tr -d '[:space:]' <"$RO/skills/hostkit-readonly/scripts/hk.mode") == readonly ]] \
    || fail "the read-only build must ship hk.mode=readonly"
  [[ -z $(grep -nE "$WRITE_CALL|HOSTKIT_ALLOW_WRITES|WRITE-(BEGIN|END)|^## Writes$" \
    "$RO/skills/hostkit-readonly/SKILL.md" || true) ]] \
    || fail "the read-only build still shows how to write"
  grep -qE "$WRITE_CALL" "$FULL/skills/hostkit/SKILL.md" || fail "the full build lost its write documentation"
  python3 -c "import json,sys; [json.load(open(p)) for p in sys.argv[1:]]" \
    "$FULL/plugin.json" "$RO/plugin.json" .claude-plugin/marketplace.json
}

gate_guard() {
  # Optional: run the installer's own scanner when a Hermes install is present.
  local hermes=${HERMES_INSTALL_DIR:-$HOME/.hermes/hermes-agent}
  [[ -f $hermes/tools/skills_guard.py ]] || { echo "guard scan: skipped (no Hermes install at $hermes)"; return 0; }
  ( cd "$hermes" && python3 - "$@" <<'PY'
import sys
from pathlib import Path
from tools.skills_guard import scan_skill
bad = 0
for path in sys.argv[1:]:
    result = scan_skill(Path(path), source="community")
    print(f"guard scan: {path} -> {result.verdict} ({len(result.findings)} finding(s))")
    for finding in result.findings:
        print(f"  {finding.severity} {finding.pattern_id} {finding.file}:{finding.line}")
    bad |= result.verdict != "safe"
raise SystemExit(1 if bad else 0)
PY
  ) || fail "the installer's scanner would not call this skill safe"
}

build_into "$scratch"
if ((CHECK == 1)); then
  diff -r "$scratch/plugins" plugins >/dev/null || fail "committed plugins/ are stale; run ./scripts/build.sh"
  target=$scratch
else
  rm -rf plugins
  cp -R "$scratch/plugins" plugins
  target=.
fi

gate_source
gate_docs
gate_modes
gate_guard "$SRC" "$target/$FULL/skills/hostkit" "$target/$RO/skills/hostkit-readonly"

echo "OK: built full + readonly ($VERSION); gates green"
