---
title: README
type: note
permalink: 2ndm1nd/scripts/secondmind/raycast/readme
---

# 2ndMind — Raycast extension

Four commands that talk to the local BrainServer (`127.0.0.1:4517`, bearer token read from `~/Library/Application Support/2ndMind/server-token`):

- **Now** — the rolling recommendation (`Now.md`).
- **Today** — today's activity spans.
- **Search Brain** — full-text search across all captured activity.
- **Ask Brain** — agentic question over your ledger + memory.

## Install (dev)
```sh
cd scripts/secondmind/raycast
npm install
npm run dev        # imports into Raycast; ⌘, to manage
```
`npm run build` verifies it compiles (`ray build`). The 2ndMind app must be running (`make v2-up`) so the server is up.

## Notes
- `@types/react` / `@types/node` are pinned to `@raycast/api`'s exact peer versions (19.0.10 / 22.19.17) — mismatches cause the "bigint is not a valid ReactNode" build error.