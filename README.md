# Hostkit skills

Agent skills for the Hostkit API (`https://app.hostkit.pt/api`) — properties, reservations, guests, invoicing, SIBA.

> Status: scaffolding. Skill content lands next. Baseline rule for all future claims: unmarked = triangulated, **TBC** = unprobed, **verified** = probed live.

## Setup

**1. Add your key.** Property-scoped, from Hostkit app → Properties → API key tab. Never commit it:

```bash
export HOSTKIT_API_KEY="<your key>"
```

**2. Verify it works.**

```bash
curl -s "https://app.hostkit.pt/api/getLicense?APIKEY=$HOSTKIT_API_KEY"
```

A JSON license object means you are in.
