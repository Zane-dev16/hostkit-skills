#!/usr/bin/env bash
# Build the two installable skill modes from the single source.
#   Full:     everything (default mode at install).
#   Readonly: WRITE blocks stripped + read-only banner; must name zero write endpoints.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=skills/hostkit/SKILL.md
VERSION=$(cat VERSION)
FULL=plugins/hostkit
RO=plugins/hostkit-readonly

FULL_BANNER='> Full-access build: reads run freely; writes (reservations, guests, SIBA sends, invoicing) require explicit approval each time.'
RO_BANNER='> Read-only build: GET requests only. Refuse reservation/guest/invoicing writes and SIBA sends; tell the user which access the task needs.'

# 1. Markers balanced and present.
o=$(grep -c 'WRITE-BEGIN' "$SRC"); c=$(grep -c 'WRITE-END' "$SRC")
[ "$o" = "$c" ] && [ "$o" -gt 0 ] || { echo "FAIL: unbalanced WRITE markers ($o/$c)"; exit 1; }

rm -rf "$FULL" "$RO"
mkdir -p "$FULL/skills/hostkit" "$RO/skills/hostkit"

insert_banner() { # $1=banner $2=src $3=dest
  awk -v banner="$1" 'BEGIN{d=0} /^---$/ {d++; print; if (d==2) print banner; next} {print}' "$2" > "$3"
}

# 2. Full = source + banner.
insert_banner "$FULL_BANNER" "$SRC" "$FULL/skills/hostkit/SKILL.md"

# 3. Readonly = strip WRITE blocks + banner + read-only wording.
sed '/<!-- WRITE-BEGIN -->/,/<!-- WRITE-END -->/d' "$SRC" \
  | sed 's/every write below is TBC — no write has ever run\./this build contains no write examples — see the full-access build for those (all TBC)./; s/Use for any Hostkit call:/Use for any Hostkit read:/' \
  > "$RO/skills/hostkit/SKILL.md.tmp"
insert_banner "$RO_BANNER" "$RO/skills/hostkit/SKILL.md.tmp" "$RO/skills/hostkit/SKILL.md"
rm "$RO/skills/hostkit/SKILL.md.tmp"

# 4. Per-mode plugin manifests (single version source).
mkmanifest() { # $1=dir $2=name $3=desc
  cat > "$1/plugin.json" <<EOF
{"author": {"name": "Irell Zane"}, "description": "$3", "homepage": "https://github.com/Zane-dev16/hostkit-skills", "keywords": ["hostkit", "skills", "api"], "license": "MIT", "name": "$2", "repository": "https://github.com/Zane-dev16/hostkit-skills", "skills": ["./skills/hostkit"], "version": "$VERSION"}
EOF
}
mkmanifest "$FULL" hostkit-skills "Agent skills for the Hostkit API (properties, reservations, guests, invoicing, SIBA). Full access: reads plus reservation, guest, SIBA, and invoicing writes."
mkmanifest "$RO" hostkit-skills-readonly "Agent skills for the Hostkit API (properties, reservations, guests, invoicing, SIBA). Read-only: no examples for any write operation."

# 5. Gate: readonly must name zero write endpoints and keep zero marker leftovers
#    (exempt: the quoted-error-strings line — verbatim server text agents match on, not instructions);
#    full must retain the write blocks.
WRITES='addProperty|updateProperty|addReservation|updateReservation|cancelReservation|deleteReservation|addGuest|removeGuest|sendSIBA|removeAllGuests|addInvoice|addReceipt|addCreditNote|closeInvoice|deleteInvoice|addInvoiceLine|generateSAFT|deleteReservationExtras|addReservationExtra|WRITE-(BEGIN|END)'
if grep -nE "$WRITES" "$RO/skills/hostkit/SKILL.md" | grep -v 'quote these'; then
  echo "FAIL: readonly build names write endpoints or keeps markers"; exit 1
fi
grep -q 'sendSIBA' "$FULL/skills/hostkit/SKILL.md" || { echo "FAIL: full build lost write blocks"; exit 1; }
grep -q 'addInvoice' "$FULL/skills/hostkit/SKILL.md" || { echo "FAIL: full build lost write blocks"; exit 1; }
python3 -c "import json; [json.load(open(f)) for f in ['$FULL/plugin.json','$RO/plugin.json','.claude-plugin/marketplace.json']]"
echo "OK: built full + readonly ($VERSION), gates green"
