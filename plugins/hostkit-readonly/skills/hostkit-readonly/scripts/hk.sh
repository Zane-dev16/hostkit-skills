#!/usr/bin/env bash
# hk — the Hostkit API client shipped with the hostkit skill.
#
# Hostkit carries the credential in the query string, so a logged URL is a logged key.
# This script therefore logs only the endpoint, the HTTP status and the reservation code,
# and hands the URL to curl through a config stream so the key never lands in argv
# (readable in ps) and never reaches a shell history file.
#
# Reads run freely. Every write needs a per-invocation unlock passed on the command line:
# HOSTKIT_ALLOW_WRITES=1 (or =<endpoint> to bind it to that one operation). A read-only
# build refuses writes before any credential lookup or network work.
#
# usage: hk.sh <endpoint> [param=value | YYYY-MM-DD]... [--fields=a,b] [--json]
# exit:  0 ok · 2 usage or missing credential · 3 write refused · 4 API error

set -uo pipefail

EX_USAGE=2
EX_REFUSED=3
EX_API=4

DEFAULT_BASE=https://app.hostkit.pt/api
MAX_ATTEMPTS=4

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P) || exit "$EX_USAGE"
projector=${script_dir}/hk_project.py

die() { # die <exit-code> <message...>
  local code=$1
  shift
  printf 'hk: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'TXT'
usage: hk.sh <endpoint> [param=value | YYYY-MM-DD]... [--fields=a,b] [--json]

  endpoint       Hostkit operation, e.g. getLicense, getReservations, addGuest
  param=value    query parameter; hk.sh URL-encodes the value for you
  YYYY-MM-DD     window shorthand, in order: the start date, then the end date.
                 Reservations map it to from_date/to_date; the invoicing lists map
                 it to date_start/date_end and convert it to Unix seconds.
  --fields=a,b   print only these response fields
  --json         print the whole response instead of the default field projection

credential  HOSTKIT_API_KEY, else HOSTKIT_API_KEY_FILE, else ~/.config/hostkit/api_key
writes      HOSTKIT_ALLOW_WRITES=1 or HOSTKIT_ALLOW_WRITES=<endpoint>, on the call itself
exit        0 ok · 2 usage or missing credential · 3 write refused · 4 API error
TXT
}

# ── date helpers ────────────────────────────────────────────────────────────────

is_date() { # YYYY-MM-DD, real calendar day
  local y m d max
  [[ $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  y=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  ((m >= 1 && m <= 12 && d >= 1)) || return 1
  case $m in
    1|3|5|7|8|10|12) max=31 ;;
    4|6|9|11) max=30 ;;
    2) if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then max=29; else max=28; fi ;;
  esac
  ((d <= max))
}

is_datetime() { # YYYY-MM-DD, or "YYYY-MM-DD HH:MM" where the API accepts a time
  local stamp=$1
  if [[ $stamp == *' '* ]]; then
    [[ $stamp =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}):([0-9]{2})$ ]] || return 1
    is_date "${BASH_REMATCH[1]}" || return 1
    ((10#${BASH_REMATCH[2]} <= 23 && 10#${BASH_REMATCH[3]} <= 59))
  else
    is_date "$stamp"
  fi
}

to_epoch() { # <YYYY-MM-DD> [HH:MM:SS] -> Unix seconds, UTC; both BSD and GNU date
  local stamp="$1 ${2:-00:00:00}" epoch
  if epoch=$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$stamp" +%s 2>/dev/null); then
    printf '%s' "$epoch"
    return 0
  fi
  if epoch=$(date -u -d "$stamp" +%s 2>/dev/null); then
    printf '%s' "$epoch"
    return 0
  fi
  return 1
}

# ── endpoint policy ────────────────────────────────────────────────────────────

classify() { # reads are get*/validate*; writes are named by their verb; nothing else is guessed
  case $1 in
    get*|validate*) printf 'read' ;;
    add*|update*|remove*|cancel*|delete*|close*|send*|generate*|create*|reopen*|upload*|set*) printf 'write' ;;
    *) printf 'unknown' ;;
  esac
}

window_params() { # print "<start-param> <end-param>" for endpoints that take a date window
  case $1 in
    getReservations) printf 'from_date to_date' ;;
    getInvoices|getReceipts|getCreditNotes|getExpenses) printf 'date_start date_end' ;;
  esac
}

# ── request plumbing ───────────────────────────────────────────────────────────

cfg_value() { # escape a value for a curl config line
  local v=${1//\\/\\\\}
  printf '%s' "${v//\"/\\\"}"
}

emit_config() { # the request, as a curl config stream: the key stays out of argv
  local p
  printf 'url = "%s/%s"\n' "$base" "$endpoint"
  printf 'data-urlencode = "APIKEY=%s"\n' "$key"
  for p in ${params[@]+"${params[@]}"}; do
    printf 'data-urlencode = "%s"\n' "$(cfg_value "$p")"
  done
}

is_transient() { # transport blips and server-side throttling only
  case $HK_CURL in
    0) ;;
    5|6|7|16|28|35|52|55|56) return 0 ;;
    *) return 1 ;;
  esac
  case $HK_STATUS in
    429|500|502|503|504) return 0 ;;
  esac
  return 1
}

fetch() { # <retry: 1 read, 0 write> -> sets HK_STATUS, HK_CURL and HK_ATTEMPTS
  local retryable=$1 attempt=1 delay=1
  HK_STATUS=000
  HK_CURL=0
  HK_ATTEMPTS=0
  while :; do
    HK_STATUS=$(emit_config | curl -sS --get -K - --connect-timeout 10 --max-time 45 \
      -o "$body_file" -w '%{http_code}' 2>/dev/null)
    HK_CURL=$?
    HK_ATTEMPTS=$attempt
    is_transient || break
    if ((retryable == 1 && attempt < MAX_ATTEMPTS)); then
      printf 'hk: %s status=%s curl=%s retry=%s/%s in %ss\n' \
        "$endpoint" "$HK_STATUS" "$HK_CURL" "$((attempt + 1))" "$((MAX_ATTEMPTS - 1))" "$delay" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      delay=$((delay * 2))
      continue
    fi
    break
  done
}

print_raw_body() { # line-preserving passthrough, no cat and no shell echo of the key
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "$line"
  done <"$body_file"
}

# ── main ───────────────────────────────────────────────────────────────────────

main() {
  local endpoint='' fields='' raw=0 arg
  local params=() dates=()
  local rcode=''

  while (($# > 0)); do
    arg=$1
    shift
    case $arg in
      -h|--help) usage; exit 0 ;;
      --json) raw=1 ;;
      --fields=*) fields=${arg#--fields=} ;;
      --*) die "$EX_USAGE" "unknown flag: $arg (try --help)" ;;
      *)
        if [[ -z $endpoint ]]; then
          endpoint=$arg
        elif [[ $arg == *=* ]]; then
          params+=("$arg")
        elif is_date "$arg"; then
          dates+=("$arg")
        else
          die "$EX_USAGE" "expected param=value or YYYY-MM-DD, got '$arg'"
        fi
        ;;
    esac
  done

  [[ -n $endpoint ]] || { usage >&2; exit "$EX_USAGE"; }
  case $endpoint in
    [!a-z]*|*[!A-Za-z0-9_]*) die "$EX_USAGE" "endpoint must look like getReservations, got '$endpoint'" ;;
  esac

  local kind
  kind=$(classify "$endpoint")
  if [[ $kind == unknown ]]; then
    die "$EX_USAGE" "unknown endpoint '$endpoint': reads are get*/validate*, writes start with their verb"
  fi

  # Mode is configuration shipped next to this script; the read-only build cannot be unlocked.
  local mode='full'
  if [[ -r $script_dir/hk.mode ]]; then
    mode=$(<"$script_dir/hk.mode")
    mode=${mode//[[:space:]]/}
  fi
  [[ $mode == full || $mode == readonly ]] || die "$EX_USAGE" "hk.mode must say full or readonly, found '$mode'"
  if [[ ${HOSTKIT_READONLY:-} == 1 ]]; then
    mode='readonly'
  fi

  # The write gate runs before the credential lookup: a refused write does no network work.
  if [[ $kind == write ]]; then
    local unlock=${HOSTKIT_ALLOW_WRITES:-}
    if [[ $mode == readonly ]]; then
      die "$EX_REFUSED" "refused: this is the read-only build of the skill (hk.mode=readonly). No request was sent. Install the full build to write."
    fi
    [[ -n $unlock ]] || die "$EX_REFUSED" \
      "refused: '$endpoint' is a write. Put HOSTKIT_ALLOW_WRITES=1 on this call once you have confirmed the target. No request was sent."
    [[ $unlock == 1 || $unlock == "$endpoint" ]] || die "$EX_REFUSED" \
      "refused: HOSTKIT_ALLOW_WRITES='$unlock' does not unlock '$endpoint' (use 1 or the endpoint name). No request was sent."
  fi

  local base=${HOSTKIT_API_BASE:-$DEFAULT_BASE}
  base=${base%/}
  case $base in
    http://*|https://*) ;;
    *) die "$EX_USAGE" "HOSTKIT_API_BASE must be an http(s) URL" ;;
  esac

  # ── parameters and date windows ──
  local start_param='' p name value
  start_param=$(window_params "$endpoint")
  start_param=${start_param%% *}

  if ((${#dates[@]} > 0)); then
    ((${#dates[@]} <= 2)) || die "$EX_USAGE" "at most two bare dates: a start, then an end"
    [[ -n $start_param ]] || die "$EX_USAGE" "'$endpoint' takes no date window; pass param=value pairs"
    local d
    for d in "${dates[@]}"; do
      is_date "$d" || die "$EX_USAGE" "not a calendar date: '$d'"
    done
    if [[ $start_param == 'from_date' ]]; then
      params+=("from_date=${dates[0]}")
      ((${#dates[@]} == 2)) && params+=("to_date=${dates[1]}")
    else
      local epoch_start epoch_end
      epoch_start=$(to_epoch "${dates[0]}" 00:00:00) || die "$EX_USAGE" "cannot convert '${dates[0]}' to Unix seconds"
      params+=("date_start=${epoch_start}")
      if ((${#dates[@]} == 2)); then
        epoch_end=$(to_epoch "${dates[1]}" 23:59:59) || die "$EX_USAGE" "cannot convert '${dates[1]}' to Unix seconds"
        params+=("date_end=${epoch_end}")
      fi
    fi
  fi

  local i=0
  for p in ${params[@]+"${params[@]}"}; do
    name=${p%%=*}
    value=${p#*=}
    case $name in
      APIKEY|apikey|api_key)
        die "$EX_USAGE" "the credential is read from the environment; never pass it as a parameter" ;;
      [!a-z]*|*[!a-z0-9_]*)
        die "$EX_USAGE" "parameter names are lowercase snake_case, got '$name'" ;;
    esac
    case $value in
      *$'\n'*|*$'\r'*) die "$EX_USAGE" "parameter '$name' contains a newline" ;;
    esac
    case $name in
      from_date|to_date|reservation_date|check_in|check_out)
        is_datetime "$value" || die "$EX_USAGE" "'$name' needs YYYY-MM-DD or 'YYYY-MM-DD HH:MM', got '$value'" ;;
      date_start|date_end)
        if [[ $value =~ ^[0-9]+$ ]]; then
          :
        elif is_date "$value"; then
          if [[ $name == date_start ]]; then
            value=$(to_epoch "$value" 00:00:00) || die "$EX_USAGE" "cannot convert '$name=$value' to Unix seconds"
          else
            value=$(to_epoch "$value" 23:59:59) || die "$EX_USAGE" "cannot convert '$name=$value' to Unix seconds"
          fi
          params[i]="$name=$value"
        else
          die "$EX_USAGE" "'$name' needs Unix seconds or YYYY-MM-DD, got '$value'"
        fi ;;
      date_filter)
        [[ $value == checkin || $value == checkout ]] || die "$EX_USAGE" \
          "invalid argument date_filter (allowed values: checkin, checkout)" ;;
      year|month)
        [[ $value =~ ^[0-9]+$ ]] || die "$EX_USAGE" "'$name' needs digits, got '$value'" ;;
      rcode) rcode=$value ;;
    esac
    i=$((i + 1))
  done

  has_param() {
    local want=$1 q
    for q in ${params[@]+"${params[@]}"}; do
      [[ ${q%%=*} == "$want" ]] && return 0
    done
    return 1
  }

  # Quirks the API answers with a confusing or late error, checked before the call.
  if [[ $endpoint == getReservations ]]; then
    if ! has_param from_date && ! has_param to_date && ! has_param reservation_date; then
      die "$EX_USAGE" "missing argument: provide at least one of from_date, to_date or reservation_date"
    fi
    if has_param date_filter; then
      if ! has_param from_date || ! has_param to_date; then
        die "$EX_USAGE" "date_filter pins both bounds: pass from_date and to_date"
      fi
    fi
  fi
  if [[ $endpoint == getExpenses ]] && ! has_param date_end; then
    die "$EX_USAGE" "missing document date end: getExpenses needs date_end (pass a second date, or date_end=<YYYY-MM-DD>)"
  fi

  # "maximum one year back in time" is the API's own ceiling; catch it before the round trip.
  if has_param from_date || has_param date_start; then
    local first='' first_epoch today_epoch
    for p in ${params[@]+"${params[@]}"}; do
      case ${p%%=*} in
        from_date|date_start) first=${p#*=} ;;
      esac
    done
    if [[ $first =~ ^[0-9]+$ ]]; then
      first_epoch=$first
    else
      first_epoch=$(to_epoch "${first%% *}" 00:00:00)
    fi
    today_epoch=$(to_epoch "$(date -u +%Y-%m-%d)" 00:00:00)
    if [[ -n $first_epoch && -n $today_epoch ]] && ((first_epoch + 366 * 86400 < today_epoch)); then
      die "$EX_USAGE" "window starts more than a year back: the API answers 'maximum one year back in time'"
    fi
  fi

  if [[ -n $fields ]]; then
    case $fields in
      *[!A-Za-z0-9_,]*) die "$EX_USAGE" "--fields takes comma-separated field names" ;;
    esac
  fi

  # ── credential ──
  key=${HOSTKIT_API_KEY:-}
  if [[ -z $key && -n ${HOSTKIT_API_KEY_FILE:-} ]]; then
    [[ -r $HOSTKIT_API_KEY_FILE ]] || die "$EX_USAGE" "HOSTKIT_API_KEY_FILE is set but not readable"
    key=$(<"$HOSTKIT_API_KEY_FILE")
  fi
  if [[ -z $key && -r ~/.config/hostkit/api_key ]]; then
    key=$(<~/.config/hostkit/api_key)
  fi
  key=${key//[[:space:]]/}
  [[ -n $key ]] || die "$EX_USAGE" \
    "no credential: set HOSTKIT_API_KEY for this call, or HOSTKIT_API_KEY_FILE, or write ~/.config/hostkit/api_key (chmod 600)"
  case $key in
    *\"*|*\\*) die "$EX_USAGE" "the credential contains characters Hostkit keys never carry" ;;
  esac
  ((${#key} <= 200)) || die "$EX_USAGE" "the credential is longer than 200 characters"

  # ── the call ──
  local body_file
  body_file=$(mktemp "${TMPDIR:-/tmp}/hk.XXXXXX") || die "$EX_USAGE" "cannot create a temporary file"
  trap 'rm -f -- "$body_file"' EXIT

  local retryable=1
  [[ $kind == write ]] && retryable=0 # verify-before-retry: a write is never re-sent blind
  fetch "$retryable"

  if ((HK_CURL != 0)); then
    die "$EX_API" "$endpoint: request failed (curl exit $HK_CURL) after $HK_ATTEMPTS attempt(s)"
  fi

  local log_line="hk: ${endpoint} ${HK_STATUS}"
  [[ -n $rcode ]] && log_line="$log_line rcode=$rcode"
  printf '%s\n' "$log_line" >&2

  # Two endpoints answer in plain text, not JSON; a SAF-T file is the payload itself.
  local passthrough=0
  case $endpoint in
    getLastSIBADate|getSAFT) passthrough=1 ;;
  esac

  local python_bin=''
  python_bin=$(command -v python3 2>/dev/null || true)
  if [[ -z $python_bin ]]; then
    case $PATH in
      *:/usr/bin*) [[ -x /usr/bin/python3 ]] && python_bin=/usr/bin/python3 ;;
    esac
  fi
  if [[ -z $python_bin && -x /usr/local/bin/python3 ]]; then
    python_bin=/usr/local/bin/python3
  fi
  if [[ -z $python_bin ]]; then
    if ((raw == 1)) || ((passthrough == 1)); then
      if ((HK_STATUS < 200 || HK_STATUS >= 300)); then
        die "$EX_API" "$endpoint: HTTP $HK_STATUS"
      fi
      print_raw_body
      exit 0
    fi
    die "$EX_USAGE" "python3 is needed to keep guest documents and contact fields out of the output; install it, or pass --json to accept the raw response"
  fi

  local -a project=(--endpoint "$endpoint" --status "$HK_STATUS" --body "$body_file")
  if ((raw == 1)); then
    project+=(--raw)
  elif [[ -n $fields ]]; then
    project+=(--fields "$fields")
  fi
  if ((passthrough == 1)); then
    project+=(--passthrough)
  fi

  "$python_bin" "$projector" ${project[@]+"${project[@]}"}
  local rc=$?
  case $rc in
    0) exit 0 ;;
    4) exit "$EX_API" ;;
    *) die "$EX_API" "$endpoint: could not read the response" ;;
  esac
}

main "$@"
