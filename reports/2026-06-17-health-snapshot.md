# DB + Infra Health Snapshot — 2026-06-17

Read-only snapshot of the TCB / fin-os production estate. Generated via the
Cloudflare API (D1 query + Workers list + KV list) and worker `/health` probes.
No state was mutated.

## Overall verdict: 🟢 HEALTHY

- All probed worker health endpoints return HTTP 200.
- All three kill switches are **OFF** — system reports `RUNNING`.
- Canonical audit hash chain on `tcb_ledger_main` is live and being extended (last row today).
- Reconciliation has **0 breaks**; DLQ has **no unresolved entries**.
- The only non-`OK` rows found are stale test/canary artifacts (see notes).

## Worker health

| Worker | Endpoint | Result |
|---|---|---|
| bank-clearing-core | `/health` | 200 |
| reconciliation-worker | `/health` | 200 |
| fin-os-registry-gateway | `/health` | 200 |
| swift-gpi-callback | `/health` | 200 |
| fin-os-ai-search | `/health` | 200 |
| fin-os-gateway | `/api` | 302 (Cloudflare edge redirect; gate workflow follows it) |

Account hosts ~100 Workers total (full list via `wrangler` / Workers API).

## Kill switches — all OFF

| Source (DB) | State |
|---|---|
| `global_kill_switch_v2` (tcb_ledger_main) | `system_state=RUNNING`, `kill_switch=0`, reason `CLI_RESUME`, since 2026-06-12 |
| `kill_switch_state` (tcb-master-002) | `enabled=0`, reason `DEFAULT_OFF` |
| `fin_runtime_kill_switch` (tcb-master-002) | `enabled=0`, reason `INITIAL_OFF` |

## Audit hash chain (regulatory artifact)

| DB | Rows | Distinct hashes | Last extended | Status |
|---|---|---|---|---|
| **tcb_ledger_main** (`9efffcf0-…`) | 152 | 152 | **2026-06-17T03:00:06Z** | 🟢 LIVE / canonical |
| tcb_ledger (`977aa2b4-…`) | 8 | — | 2026-05-27T15:22:51Z | ⚪ STALE segment — not canonical |

The live chain has no hash collisions (152 rows / 152 distinct `chain_hash`). Two
rows carry a null `previous_hash` (genesis markers) — worth confirming a single
genesis is intended, but not a fault.

## Money path / ledger (tcb_ledger)

| Metric | Count |
|---|---|
| payments (total) | 16 |
| payments DISPATCHED | 15 |
| payments COMPLETED | 1 |
| finos_payments | 15 |
| rail_transfers (total) | 1 |
| rail_transfers BLOCKED | 1 |
| zengin_transfers | 0 |
| swift_messages | 1 |
| bank_accounts | 8 |

## Reconciliation & DLQ (tcb_ledger)

| Metric | Count | Note |
|---|---|---|
| reconciliation_runs | 7 | |
| reconciliation_breaks | 0 | 🟢 clean |
| dlq_events | 0 | |
| finos_dlq | 2 | both `CANARY_ONLY`, status `RESOLVED` (table-liveness probes) |

## Asset / custody (tcb_ledger_main)

| Metric | Count |
|---|---|
| wallet_tokens | (present) |
| issued_cards | 10 |
| physical_key_registry | 2 (active operator keys) |
| finos_live_readiness_matrix_v1 | 52 |
| approval_gate_signatures_v2 | 1 |
| ledger_events | 0 |

## Compliance / licensing (tcb-master-002)

| Metric | Count |
|---|---|
| fin_licenses | 28 |
| sanctions_list | 2 |
| correspondent_banks | 20 |
| two_eye_requests | 1 |
| fx_rates | 19 |

## Infra inventory (Cloudflare)

- **D1 databases:** 8 (`tcb_ledger_main` 486 MB, `tcb_ledger` 43 MB, `tcb-master-002` 856 KB, plus `tcb-jurisdictions`, `tsukayamacenturybank-v2`, `tcb_monitor_reserve`, `tcb-ledger-v2`, `tcb-life-db`).
- **KV namespaces:** 20+ (idempotency, audit-logs, rate-limit, session-store, cert-registry, …).
- **R2:** not enabled on the account (API returns `10042 — enable R2 in dashboard`).

## Items to note (non-blocking)

1. **1 BLOCKED rail_transfer** — `bankapi-existing-689151f8-…`, ¥1,000, source
   `BANK_API_EXISTING_CLOUDFLARE_SECRETS_TEST`, dated 2026-05-01. A connector
   test, not a live customer payment. Safe to leave or archive.
2. **15 payments in DISPATCHED** vs 1 COMPLETED — confirm whether `DISPATCHED`
   is the expected terminal state for these or whether completion callbacks are
   pending.
3. **2 genesis rows** in the live audit chain — confirm a single genesis was
   intended.
