# Notes

Both modes build from the same source (`skills/hostkit/SKILL.md` via `scripts/build.sh`); the read-only build strips write blocks and names no write endpoints.

Pair the install with a tightly scoped key. The credential is the real gate and the skill mode is the guardrail.

Keys are property scoped, from the Hostkit app Properties API key tab. Never commit a key; adding a property returns a new key, so store each one.

A JSON license object from `getLicense` means the key works. From there ask the agent to list reservations, check a booking, or show invoices. The skill holds the endpoints, filters, and gotchas.

Reads run freely. Writes for reservations, guests, SIBA sends, and invoicing need explicit approval each time.

Skill claims marked verified were probed live. TBC means unprobed and unsafe to rely on.

Claude Code marketplace option: `hostkit-skills` for full access, `hostkit-skills-readonly` for reads only. Codex and other agents can use editable files with `./scripts/install.sh` (default dest `~/.agents/skills`).
