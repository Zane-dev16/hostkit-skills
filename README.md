# Hostkit skills

Agent skills for the Hostkit API (`https://app.hostkit.pt/api`) — properties, reservations, guests, invoicing, SIBA.

> Status: scaffolding. Skill content lands next. Baseline rule for all future claims: unmarked = triangulated, **TBC** = unprobed, **verified** = probed live.

## Setup

**1. Install the skill.**

Claude Code:

```bash
/plugin marketplace add Zane-dev16/hostkit-skills
/plugin install hostkit-skills@zane-dev16
```

Codex / other agents:

```bash
npx skills@latest add Zane-dev16/hostkit-skills
```

**2. Add your key.** Property-scoped, from Hostkit app → Properties → API key tab. Never commit it:

```bash
export HOSTKIT_API_KEY="<your key>"
```

**3. Verify it works.**

```bash
curl -s "https://app.hostkit.pt/api/getLicense?APIKEY=$HOSTKIT_API_KEY"
```

A JSON license object means you are in. Then ask your agent to list reservations, check a booking, or show invoices. The skill holds the endpoints, filters, and gotchas.

## Notes

- Reads run freely. Writes (reservations, guests, SIBA sends, invoicing) require explicit approval each time.
- Skill claims marked **verified** were probed live. **TBC** means unprobed and unsafe to rely on.
