---
name: hostkit
description: "Work with the Hostkit API. Use for any Hostkit call: auth, properties, keycodes, reservations, guests, SIBA, invoices, receipts, credit notes, SAFT, expenses."
license: MIT
---
> Full-access build: reads run freely; writes (reservations, guests, SIBA sends, invoicing) require explicit approval each time.

# Hostkit

Base: `https://app.hostkit.pt/api`. Every op is GET with query params, writes included.

_Probe baseline: reads verified live 2026-09-24 on a single-property Business key; every write below is TBC — no write has ever run. **TBC** = unprobed._

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
<!-- WRITE-BEGIN -->
Writes [TBC, opt-in each]: `addProperty` (req `property_name,address,zip,city`, returns NEW key — store it), `updateProperty`.
<!-- WRITE-END -->

## Reservations

```bash
curl -s "$BASE/getReservations?APIKEY=$HOSTKIT_API_KEY&from_date=2026-09-01&to_date=2026-09-08"  # window-every-list; needs ≥1 of from_date|to_date|reservation_date
curl -s "$BASE/getReservations?APIKEY=$HOSTKIT_API_KEY&from_date=2026-09-01&to_date=2026-09-08&date_filter=checkin"  # checkin|checkout pins both bounds; needs from+to
curl -s "$BASE/getReservation?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"      # one; +&get_archived=true for archived
curl -s "$BASE/getReservationByCmId?APIKEY=$HOSTKIT_API_KEY&channelmanager=avantio&id=..."  # channel-manager lookup
curl -s "$BASE/getPayments?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"         # payments
curl -s "$BASE/getOnlineCheckin?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"    # checkin link
```

Done = every list carries a window; one-lookup resolves a known `rcode` first try (verified: Oct 2026 returned 5 Airbnb rows; Jul/Aug/Sep returned 0). Without `date_filter`, `from_date` filters check-in and `to_date` filters check-out; open-ended `from_date` alone works (verified: 8 rows vs 5 windowed). `reservation_date=YYYY-MM-DD` filters creation date and works standalone (verified: `[]` on no-match day). `date_filter=checkout` repins both bounds (verified: 6 vs 5 default). `get_archived=true` searches archived INSTEAD of active (verified: Oct archived 0 vs active 5; single-lookup archived miss → exact `unknown reservation`). No pagination params observed; 31-day windows return fine with no truncation signal [larger windows TBC]. `room` is free text (verified: `''` on Airbnb rows, `room=1` enforced → `[]`) — echo exact strings from list output, never invent. `getReservationByCmId` miss → exact `unknown channel manager...` error (verified: airbnb+avantio both miss on list apid — apid ≠ CM id or enum differs). `getOnlineCheckin` keys are `status,shortlink` (verified: 5/5 Oct empty). Take `rcode` from `getReservations` output; placeholder must be replaced. <!-- WRITE-BEGIN -->
Writes [TBC, opt-in each]: `addReservation` (req `rcode,check_in,check_out` + `name` or `first+last_name`; collision behaviour TBC), `updateReservation`, `cancelReservation` (moves to cancellations) vs `deleteReservation` (permanent — never use delete as cancel). Extras: `addReservationExtra` takes `extra_id|extra_name|extra_vat|extra_type(S|I|P)|extra_total` (postman `name/value` is stale); `deleteReservationExtras?rcode=` wipes ALL extras, no single delete.
<!-- WRITE-END -->

## Guests and SIBA

```bash
curl -s "$BASE/validateSIBA?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"        # readiness check; run before any SIBA submission
curl -s "$BASE/getLastSIBADate" --get --data-urlencode "APIKEY=$HOSTKIT_API_KEY"  # no params besides key
```

<!-- WRITE-BEGIN -->
`addGuest` needs `rcode` + `name` (or `first+last_name`) + 9 SIBA fields: `nationality,birthday,doc_id,doc_type,doc_country,arrival,departure,country_residence,city_residence`. `removeGuest` needs `rcode` + `name` or `first+last_name`.
<!-- WRITE-END -->
Done = guest resolves to a listed `rcode`; SIBA done = `validateSIBA` passes before any submission is even proposed.
<!-- WRITE-BEGIN -->
`sendSIBA` submits externally and `removeAllGuests` wipes guest data — both opt-in each, verify-before-retry.
<!-- WRITE-END -->

## Invoicing, receipts, credit notes, SAFT, expenses

```bash
# Unix window: date_start=$(date -d '2026-09-01' +%s); date_end=$(date -d '2026-09-30' +%s)  # Linux; macOS: date -j -f '%Y-%m-%d' '2026-09-01' +%s (1756684800→1759190400)
curl -s "$BASE/getInvoices?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"  # window-every-list; dates NOT required (verified: dateless = full 55-row set, same 13 keys). Omit invoicing_nif for all, never copy 123456789 — copy exact NIF from prior list output. Reads verified: year-wide returned 55 rows, all invoice_type=FR, closed=1, series=AL2026, date = unix string; decode body as latin-1. `customer_id` matches customer NIF, not invoice id (verified: id → 0 rows, NIF → 1 row). `show_property=1` adds `property_id,property_name` only (verified: 13→15 keys, same 55 rows). `doc_type=BOGUS` on an empty window returns `[]`, not a validation error (verified) — allowed-values text stays TBC.
curl -s "$BASE/getReservationInvoices?APIKEY=$HOSTKIT_API_KEY&rcode=ABC123"  # requires rcode; opt invoicing_nif
curl -s "$BASE/getReceipts?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"      # same filters minus doc_type/source/show_property
curl -s "$BASE/getCreditNotes?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"   # receipt filters + opt invoice_type(FR|FT)
curl -s "$BASE/getExpenses?APIKEY=$HOSTKIT_API_KEY&date_start=1756684800&date_end=1759190400"      # document-date window, Unix
```

<!-- WRITE-BEGIN -->
Create is a strict 3-stage [TBC, opt-in each, verify-before-retry throughout]: 1. `addInvoice` (`customer_id` empty = final consumer; req `name,country`; opt `invoicing_nif,series,invoice_type(FR|FT),address,cp,city,rcode,comment,payment_method`) → save open-doc id. 2. `addInvoiceLine` ×N (`id,product_id,custom_descr,qty,price,discount,vat,reason_code` empty = no exemption; new product adds `region(PT|PT-MA|PT-AC),type(S|P|I)`). 3. `closeInvoice` (`id` + opt `invoicing_nif,series,invoice_type`) — final; verify customer/lines/VAT/totals via list first. `deleteInvoice` kills OPEN docs only. `addReceipt` needs a closed FT (`refseries+refid`); `addCreditNote` needs a closed invoice (defaults FR).
<!-- WRITE-END --> Year-wide 2026 verified empty: `getReceipts`, `getCreditNotes`, `getExpenses` all `[]`; per-rcode Oct 5/5: `getReservationInvoices` and `getPayments` all `[]` — no Oct booking has invoices/payments. `getExpenses` without `date_end` → exact `missing document date end`. `getSAFT` fetches generated SAFT (miss → exact `SAF-T not found...generateSAFT first`, no payload); params `year,month` (postman) vs `invoicing_nif,year,month` (MCP) [conflict, TBC live]. SAFT done = base64 file decoded, N bytes.
<!-- WRITE-BEGIN -->
`generateSAFT` creates it — opt-in each, verify-before-retry.
<!-- WRITE-END -->

## Gotchas

- 36 endpoints known [TBC].
- No webhooks/changelog observed in postman/MCP/docs; do not assume they exist [TBC].
