# Notes

Both modes build from `skills/hostkit/` through `scripts/build.sh`. The full plugin is a
byte-identical copy of that source. The read-only plugin ships the same `scripts/hk.sh` with
`scripts/hk.mode = readonly` and the write documentation stripped, so the difference is
configuration, and the restriction is enforced by the script rather than promised by prose.

Pair either install with a tightly scoped key. The credential is the real gate; the skill mode is
the guardrail on top of it.

Keys are property scoped, from the Hostkit app Properties API key tab. Never commit a key. Adding a
property issues a new key, so store each one and use the one that matches the property.

A JSON license object from `scripts/hk.sh getLicense` means the key works and its plan is valid.
From there ask the agent to list reservations, check a booking, or show invoices. The skill holds
the operations, filters, and pitfalls; the script holds the wire mechanics.

Reads run freely. A write — reservation, guest, SIBA send, invoicing — runs only when that call
carries `HOSTKIT_ALLOW_WRITES=1` (or the endpoint name). There is no stored default, and a refusal
happens before any credential lookup, so a refused write never reaches the network.

Skill claims marked verified were probed live. TBC means unprobed and unsafe to rely on.

Claude Code marketplace option: `hostkit-skills` for full access, `hostkit-skills-readonly` for
reads only. Codex and other agents can use editable files with `./scripts/install.sh` (default dest
`~/.agents/skills`).
