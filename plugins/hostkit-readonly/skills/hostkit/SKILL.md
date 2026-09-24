---
name: hostkit
description: "Work with the Hostkit API. Use for any Hostkit read: auth, properties, keycodes, reservations, guests, SIBA, invoices, receipts, credit notes, SAFT, expenses."
license: MIT
---
> Read-only build: GET requests only. Refuse reservation/guest/invoicing writes and SIBA sends; tell the user which access the task needs.

# Hostkit

Base: `https://app.hostkit.pt/api`. Every op is GET with query params, writes included.

_Probe baseline: reads verified live 2026-09-24 on a single-property Business key; this build contains no write examples — see the full-access build for those (all TBC). **TBC** = unprobed._

```bash
export HOSTKIT_API_KEY="<Hostkit app → Properties → API key tab, one key per property>"
BASE=https://app.hostkit.pt/api
```

## Auth and ceiling

- Key is property-scoped (verified: key sees exactly 1 property via `getProperties`). Adding a property returns a NEW key — store it. Env/secret manager only, regen if exposed.
- Bad key → `{"error":"invalid format for APIKEY provided"}` (verified). IP allowlist [TBC]: account-level IPv4/CIDR; empty = unrestricted, any entry = deny-by-default; IPv6 unsupported; rejected → `{"error":"IP address not allowed"}`.
- Failure shape is the ceiling signal: `{"error":"…"}` or `{"status":"failure","error":"…"}` — inspect the payload, not the HTTP status. Auth-shaped errors [TBC]: `no/incorrect APIKEY`, `account expired`, `Business/Premium plan required`.
- Two envelope exceptions (verified): `getInvoices` body decodes as latin-1, not UTF-8; `getLastSIBADate` returns plain text (`1970-01-01 01:00:00` = never submitted), not JSON.

## Wire conventions

- `GET $BASE/{endpoint}?APIKEY=$HOSTKIT_API_KEY&...` URL-encoded (verified: raw key → 403, urlencoded → 200). Prefer curl — urllib hits Cloudflare 1010 on every endpoint. Log endpoint + timestamp + HTTP status + `error` text + retry count; never log full URLs, keys, guest docs, or payloads.
- Dates split by domain: reservations/guests/SIBA use `YYYY-MM-DD` (`check_in/out` optionally `YYYY-MM-DD HH:MM`); invoices/receipts/credit-notes/expenses: MCP uses Unix `date_start/date_end` [postman shows `from_date/to_date` — conflict, TBC live probe]; SAFT uses `year+month`. Mixing formats is a 400 [TBC].
- Countries are ICAO codes; `doc_type` P, ID/B, or O per MCP phrasing.
- No pagination and no currency params observed on any endpoint [both TBC].
- Two leading words, used everywhere below: **window-every-list** (every list carries an explicit date window, ≤1yr back, incremental over blind polling) and **verify-before-retry** (after any uncertain write, re-query by id/`rcode` before re-issuing).

## Limits and errors

- Rate limit enforced, values undisclosed [TBC]. Backoff `1,2,4,8,16s` + jitter, cap retries; serialise destructive/invoicing calls. Malformed dates are a gotcha (verified): `from_date=foo` returns `{"error":"API Internal error"}`, not a validation message. On validation error otherwise, fix params, then retry.
- `database error` = treat as transient: verify-before-retry, never blind-retry.
- Error shapes (verified live, quote these): `missing argument: provide at least one of from_date, to_date or reservation_date`; `invalid argument date_filter (allowed values: checkin, checkout)`; `invalid argument from_date (maximum one year back in time)`; `Missing mandatory field rcode`; `unknown reservation`; `keycode not found`; `parameter doc_id is invalid` (validateSIBA with absent guest docs); `unknown channel manager name or channel manager reservation id` (ByCmId miss); `SAF-T not found, you may need to generate it with generateSAFT first`; `missing document date end` (getExpenses without date_end). Match on the `error` field.

## Properties and keycodes

```bash
curl -s "$BASE/getLicense?APIKEY=$HOSTKIT_API_KEY"                       # verify key; JSON license object = in
curl -s "$BASE/getProperties?APIKEY=$HOSTKIT_API_KEY"                    # list visible to key
curl -s "$BASE/getProperty?APIKEY=$HOSTKIT_API_KEY"                      # key's own property
curl -s "$BASE/getKeycode?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123&provider=nuki"  # provider closed enum [TBC]: nuki|homeit|ttlock|salto|omnitec|voyager|tedee|assa_abloy
```

Done = license object returns; properties done = list resolves visible properties first try (verified: 1 property on a scoped key); keycode done = code payload non-empty for a known `rcode`, or exact `{"error":"keycode not found"}` when no lock is fitted (verified on an Airbnb booking). Take `rcode` from `getReservations` output; never invent codes (`unknown reservation` otherwise — verified).

## Reservations

```bash
curl -s "$BASE/getReservations?APIKEY=$HOSTKIT_API_KEY&from_date=2026-09-01&to_date=2026-09-08"  # window-every-list; needs ≥1 of from_date|to_date|reservation_date
curl -s "$BASE/getReservations?APIKEY=$HOSTKIT_API_KEY&from_date=2026-09-01&to_date=2026-09-08&date_filter=checkin"  # checkin|checkout pins both bounds; needs from+to
curl -s "$BASE/getReservation?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"      # one; +&get_archived=true for archived
curl -s "$BASE/getReservationByCmId?APIKEY=$HOSTKIT_API_KEY&channelmanager=avantio&id=..."  # channel-manager lookup
curl -s "$BASE/getPayments?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"         # payments
curl -s "$BASE/getOnlineCheckin?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"    # checkin link
```


## Guests and SIBA

```bash
curl -s "$BASE/validateSIBA?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"        # readiness check; run before any SIBA submission
curl -s "$BASE/getLastSIBADate" --get --data-urlencode "APIKEY=$HOSTKIT_API_KEY"  # no params besides key
```

Done = guest resolves to a listed `rcode`; SIBA done = `validateSIBA` passes before any submission is even proposed.

## Invoicing, receipts, credit notes, SAFT, expenses

```bash
# Unix window: date_start=$(date -d '2026-09-01' +%s); date_end=$(date -d '2026-09-30' +%s)  # Linux; macOS: date -j -f '%Y-%m-%d' '2026-09-01' +%s (1756684800→1759190400)
curl -s "$BASE/getInvoices?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"  # window-every-list; dates NOT required (verified: dateless = full 55-row set, same 13 keys). Omit invoicing_nif for all, never copy 123456789 — copy exact NIF from prior list output. Reads verified: year-wide returned 55 rows, all invoice_type=FR, closed=1, series=AL2026, date = unix string; decode body as latin-1. `customer_id` matches customer NIF, not invoice id (verified: id → 0 rows, NIF → 1 row). `show_property=1` adds `property_id,property_name` only (verified: 13→15 keys, same 55 rows). `doc_type=BOGUS` on an empty window returns `[]`, not a validation error (verified) — allowed-values text stays TBC.
curl -s "$BASE/getReservationInvoices?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"  # requires rcode; opt invoicing_nif
curl -s "$BASE/getReceipts?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"      # same filters minus doc_type/source/show_property
curl -s "$BASE/getCreditNotes?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"   # receipt filters + opt invoice_type(FR|FT)
curl -s "$BASE/getExpenses?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"      # document-date window, Unix
```


## Gotchas

- 36 endpoints known [TBC].
- No webhooks/changelog observed in postman/MCP/docs; do not assume they exist [TBC].
