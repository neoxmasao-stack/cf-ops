# cf-ops

Operational tooling for the TCB / fin-os production estate on Cloudflare
(D1 + Workers + KV). **Read-only diagnostics live here** — anything that moves
money or mutates state belongs on the gateway routes a human hits with the
physical key, not in this repo.

## Contents

| Path | What it is |
|---|---|
| `scripts/db-infra-health-check.sh` | Read-only DB + infra health snapshot (D1 counts, kill-switch state, audit-chain liveness, worker `/health` probes). Never writes. |
| `reports/` | Timestamped point-in-time health snapshots (operational evidence). |

## Running the health check

Requires `bash`, `curl`, and an authenticated `wrangler`
(`CLOUDFLARE_API_TOKEN` env var, or `wrangler login`):

```bash
./scripts/db-infra-health-check.sh                 # full check (D1 + workers)
WORKERS_ONLY=1 ./scripts/db-infra-health-check.sh  # worker health only (no D1 auth needed)
```

Every query is fail-soft: a missing table or transient error prints a `WARN`
line and the run continues. The script only issues `SELECT` / `COUNT` against
D1 and `GET` against worker health endpoints.

## Canonical data stores (verified 2026-06-17)

| Alias | D1 name | UUID | Role |
|---|---|---|---|
| LG | `tcb_ledger` | `977aa2b4-…` | State-machine DB. Its `audit_hash_chain` is a **stale** 8-row segment (abandoned 2026-05-27) — **not** canonical. |
| LM | `tcb_ledger_main` | `9efffcf0-…` | **Live canonical** `audit_hash_chain` + asset-truth source. |
| MA | `tcb-master-002` | `b9c7294f-…` | Active master: licenses / sanctions / correspondent banks. |

> The audit hash chain on `tcb_ledger_main` is the regulatory artifact. When in
> doubt about which DB holds the live chain, check `MAX(created_at)` — the live
> one is extended continuously; the stale `tcb_ledger` segment stops at
> 2026-05-27.

## Hard rules

- **Read-only only.** No writes, no `wrangler secret put`, no DDL from this repo.
- **Never point a check at a scratch/wrong DB and call it canonical** — verify
  the UUID and the chain freshness first.
- Treat `reports/*.md` as append-only evidence; add new snapshots, don't rewrite
  old ones.
