# Hostkit skills

Agent skills for the Hostkit API (`https://app.hostkit.pt/api`) covering auth, properties, keycodes, reservations, guests, SIBA submissions, invoices, receipts, credit notes, SAFT, and expenses.

## Setup

Full access:

```bash
./scripts/install.sh
```

Reads only:

```bash
./scripts/install.sh --mode readonly
```

Add the property-scoped key:

```bash
export HOSTKIT_API_KEY="<your key>"
```

Verify the key returns a JSON license object:

```bash
curl -s "https://app.hostkit.pt/api/getLicense?APIKEY=$HOSTKIT_API_KEY"
```

See `docs/notes.md` for build, key scope, and write-approval notes.
