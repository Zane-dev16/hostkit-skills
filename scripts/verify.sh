#!/usr/bin/env bash
# Verify the safety properties this repo claims. No network and no credential by default;
# the live checks run only when a real credential is available.
#
# usage: scripts/verify.sh [--live]
set -uo pipefail
cd "$(dirname "$0")/.."

HK=skills/hostkit/scripts/hk.sh
RO=plugins/hostkit-readonly/skills/hostkit-readonly/scripts/hk.sh
pass=0
fail=0

ok() { printf 'ok   %s\n' "$*"; pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail + 1)); }

expect_exit() { # <want> <label> <command...>
  local want=$1 label=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ $got == "$want" ]]; then ok "$label (exit $got)"; else no "$label: expected exit $want, got $got"; fi
}

# 1. Documentation carries no credential-bearing command and no key parameter.
if grep -qF 'APIKEY=' skills/hostkit/SKILL.md; then no "SKILL.md names an APIKEY parameter"; else ok "SKILL.md names no APIKEY parameter"; fi
if grep -rniE '\b(curl|wget)\b' --include='*.md' skills plugins README.md >/dev/null; then
  no "documentation names a command-line HTTP client"
else
  ok "documentation names no command-line HTTP client"
fi

# 2. Generated modes are current and the installer's scanner calls them safe.
if ./scripts/build.sh --check >/dev/null 2>&1; then ok "build --check is clean"; else no "build --check reports drift or a gate failure"; fi

# 3. Usage and credential failures exit 2 without touching the network.
node_key=$HOME/does-not-exist/hostkit-none
expect_exit 2 "no credential exits 2" env -i HOME=/nonexistent /bin/bash "$HK" getLicense
expect_exit 2 "unknown endpoint exits 2" env -i HOSTKIT_API_KEY_FILE="$node_key" /bin/bash "$HK" frobnicate
expect_exit 2 "malformed date exits 2" env -i HOSTKIT_API_KEY_FILE="$node_key" /bin/bash "$HK" getReservations from_date=foo
expect_exit 2 "date_filter outside its enum exits 2" \
  env -i HOSTKIT_API_KEY_FILE="$node_key" /bin/bash "$HK" getReservations 2026-11-01 2026-11-30 date_filter=bogus
expect_exit 2 "a list without a window exits 2" env -i HOSTKIT_API_KEY_FILE="$node_key" /bin/bash "$HK" getReservations

# 4. The write gate refuses before the credential lookup: no key is present here, and the
#    answer is still 3, not 2 — which is only possible if nothing tried to authenticate.
expect_exit 3 "a write without the unlock exits 3" env -i HOME=/nonexistent /bin/bash "$HK" addGuest rcode=X name=Y
expect_exit 3 "an unlock for another endpoint exits 3" \
  env -i HOME=/nonexistent HOSTKIT_ALLOW_WRITES=getLicense /bin/bash "$HK" addGuest rcode=X name=Y

# 5. The read-only build is a boundary in code: the same call with the unlock still refuses.
expect_exit 3 "the read-only build refuses an unlocked write" \
  env -i HOME=/nonexistent HOSTKIT_ALLOW_WRITES=1 /bin/bash "$RO" addGuest rcode=X name=Y

# 6. Reads are gated in: get*/validate* are the only endpoints that pass the gate without a key.
expect_exit 2 "a read passes the write gate (fails later on the credential)" \
  env -i HOME=/nonexistent /bin/bash "$HK" getReservations 2026-11-01 2026-11-30

# 7. Live checks, only with a credential in this shell.
if [[ -n ${HOSTKIT_API_KEY:-} || -r ~/.config/hostkit/api_key ]] || [[ ${1:-} == --live ]]; then
  out=$(env -i /bin/bash "$HK" getLicense 2>/dev/null)
  if [[ $? == 0 && $out == *'"plan"'* ]]; then ok "live getLicense returns a license object"; else no "live getLicense failed"; fi
  out=$(env -i /bin/bash "$HK" getReservations 2026-11-01 2026-11-30 2>/dev/null)
  if [[ $? == 0 ]]; then ok "live getReservations returns"; else no "live getReservations failed"; fi
  expect_exit 4 "an unlocked write reaches the API and returns its validation error" \
    env -i HOSTKIT_ALLOW_WRITES=1 /bin/bash "$HK" addGuest rcode=verify-shape
else
  printf 'skip live checks (no credential; pass --live to insist)\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
