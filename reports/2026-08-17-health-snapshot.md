# DB + Infra Health Snapshot — 2026-08-17

Read-only production operating check (全機能本番稼働確認) of the TCB / fin-os
estate. Generated via the Cloudflare API (D1 query + Workers/D1 listing) and
worker `/health` probes, plus the GitHub Actions API for the CI plane. **No
state was mutated.**

Prior snapshot: [`2026-06-17-health-snapshot.md`](./2026-06-17-health-snapshot.md).

## Overall verdict: 🟡 SERVING, BUT NOT TRANSACTING

The infrastructure is up and the regulatory artifact is intact. Three things
stop this from being a green sign-off:

1. **Two scheduled workflows have been dead for 9 days** — including the
   5-minute connector reconciliation. Fixed in fin-os-prod#200.
2. **The money path has not moved since the June snapshot.** Every ledger
   count is byte-identical to 2026-06-17. Uptime here is liveness, not
   throughput.
3. **The bank's own LEI on record fails its ISO 17442 checksum**, and the
   licence table is deliberately serving zero rows.

## 1. Worker health (27 probed)

24/27 return `200`. The three exceptions:

| Worker | Result | Assessment |
|---|---|---|
| `fin-os-gateway` | `302` → `tsukayamabank.cloudflareaccess.com` | **By design.** The gateway now sits behind Cloudflare Access (Zero Trust). Unauthenticated probes get the Access login. This is a posture *improvement* over an open `/api`. |
| `swift-gpi-callback` | `401 {"ok":false,"error":"UNAUTHORIZED"}` | **Deploy drift.** `src/index.ts:127` returns a public `/health` (marker `SWIFT_HEALTH_PUBLIC_BYPASS`), but the live worker falls through to the auth wall — the deployed build predates that line. Worker itself is serving; only the health bypass is missing. |
| `finos-noc-status` | `404` | No `/health` route on this worker. Not a fault; the probe list should target its real path. |

All green: `bank-clearing-core`, `reconciliation-worker`, `fin-os-registry-gateway`,
`fin-os-ai-search`, `fin-os-payments`, `fin-os-mcp`, `fin-os-ops-agent`,
`fin-os-search-api`, `fin-os-rail-simulator`, `aml-screening-worker`,
`dlq-handler`, `fin-os-compliance-monitor`, `fraud-engine`, `treasury-sync`,
`visa-callback`, `mastercard-webhook`, `fx-engine`, `audit-chain-writer`,
`tcb-api-production`, `fin-os-voice`, `custody-gateway`, `usdc-gateway`,
`btc-gateway`, `eth-gateway`.

> ⚠️ The June snapshot recorded the gateway's `302` as a benign "Cloudflare edge
> redirect". It is not — it is an Access authentication challenge. Any probe
> that follows the redirect lands on a login page, never on `OPERATIONAL`.

## 2. Kill switches — all OFF 🟢

| Source (DB) | State |
|---|---|
| `global_kill_switch_v2` (tcb_ledger_main) | `system_state=RUNNING`, `kill_switch=0`, `CLI_RESUME`, since 2026-06-12 |
| `kill_switch_state` (tcb-master-002) | `enabled=0`, `DEFAULT_OFF` |
| `fin_runtime_kill_switch` (tcb-master-002) | `enabled=0`, `INITIAL_OFF` |

## 3. Canonical audit hash chain 🟢

On `tcb_ledger_main` (`9efffcf0-…`) — the regulatory artifact.

| Metric | Value |
|---|---|
| Rows | 284 (was 152 on 06-17) |
| Distinct `chain_hash` | 284 — **no collisions** |
| **Broken links** | **0** — every non-genesis `previous_hash` resolves to a real `chain_hash` |
| Genesis rows (`previous_hash` null) | 2 — unchanged; still worth confirming a single genesis was intended |
| Last extended | **2026-08-17T03:00:34Z (today)** |
| `audit_trail` rows | 279, last 2026-08-17T03:00:34Z |

Integrity verified by query, not assumed. The chain is live and continuous.

**But note what is keeping it alive.** Top audit actions by recency:

| Action | Count | Last seen |
|---|---|---|
| `RECON_CRON` | 70 | **2026-08-17** (today) |
| `REGISTRY_SELFSERVE_WEBHOOK_INVALID_SIG` | 48 | 2026-08-14 |
| `TENANT_CREATED` / `TENANT_BILLING_SUBSCRIBE_INITIATED` | 4 / 4 | 2026-08-15 |
| `OFFICIAL_LIST_SCREENED` | 10 | 2026-08-08 |
| `SWIFT_GPI_CALLBACK` | 49 | 2026-06-16 |
| `CLEARING_CONNECTOR_EXEC` | 64 | 2026-06-11 |
| `MASTERCARD_WEBHOOK` / `VISA_CALLBACK` | 3 / 3 | 2026-06-06 |

The chain's daily extension comes almost entirely from the `RECON_CRON`
heartbeat. **Every money-rail action — SWIFT gpi, clearing exec, Visa,
Mastercard — last fired in June.** The rails are reachable but idle.

48 × `REGISTRY_SELFSERVE_WEBHOOK_INVALID_SIG` shows the fail-closed signature
check working as designed, but the volume is worth tracing to a source
(misconfigured sender vs. probing).

## 4. Money path / ledger (tcb_ledger) — unchanged since June

| Metric | 2026-06-17 | 2026-08-17 |
|---|---|---|
| payments | 16 | **16** |
| payments DISPATCHED | 15 | **15** |
| payments COMPLETED | 1 | **1** |
| rail_transfers | 1 | **1** |
| rail_transfers BLOCKED | 1 | **1** |
| reconciliation_runs | 7 | **7** (last 2026-05-14) |
| reconciliation_breaks | 0 | **0** 🟢 |

Not a single new payment in two months. The 15 `DISPATCHED` vs 1 `COMPLETED`
split flagged in June is unchanged — completion callbacks are still outstanding.
`reconciliation_runs` has not advanced since **2026-05-14**.

## 5. Sanctions screening 🟢 (but check which table)

| Table | DB | Rows |
|---|---|---|
| `official_sanctions_entries` | tcb_ledger_main | **19,199** ✅ real list |
| `sanctions_list` | tcb-master-002 | 2 ⚠️ legacy stub |

The live screening corpus is healthy. The 2-row `sanctions_list` on the master
DB is a legacy stub — **do not read it as the sanctions source**; the June
snapshot's "sanctions_list = 2" line is misleading for that reason.

## 6. Licensing ⚠️ — deliberately empty, and one invalid identifier

`fin_licenses` on `tcb-master-002` is **not a table**. It is a view:

```sql
CREATE VIEW fin_licenses AS SELECT * FROM zz_q_fin_licenses WHERE 0
```

It returns zero rows unconditionally. The 28 licence rows counted in June now
sit quarantined in `zz_q_fin_licenses` (28) plus two 28-row backups. This reads
as a **deliberate, correct quarantine** — consistent with the known placeholder
identifiers — and any consumer of `fin_licenses` now gets an honest empty set
rather than unverified claims. It should stay that way until real licences are
delivered.

Authoritative identifiers in `tcb_licenses` (tcb_ledger_main):

| Type | Identifier | Status | Validation |
|---|---|---|---|
| `LEI` | `5493006Z2K4V9B7H6P11` | ACTIVE | ❌ **ISO 17442 mod 97-10 = 33, must be 1** |
| `SWIFT_BIC` | `TCBJJPT1XXX` | ACTIVE | ✅ format OK (JP) |

**The LEI marked ACTIVE is not a valid LEI.** It is a different value from the
placeholder documented in `CLAUDE.md` (`5493001KJTIIGC8Y1R17`, which also fails,
mod97=6), so it has been rotated at some point — but it still does not pass the
checksum, meaning it was never GLEIF-issued.

This matters because the regulatory chassis validates identifiers with
`isValidLei` and rejects failures with `IDENTIFIER_INVALID_*`. An ACTIVE row
carrying a checksum-failing LEI therefore did **not** arrive through the
HMAC-verified agency-webhook path — it was written by a path that bypassed that
validation. Treat the bank's LEI as **not yet acquired**.

## 7. CI / control plane ⚠️

**Two workflows have been unparseable YAML since 2026-08-08 (commit `9df384c`)**,
so every run died as `startup_failure` (`BuildFailed`) without executing a step:

| Workflow | Trigger | Effect |
|---|---|---|
| `wise-recon-5min.yml` | `cron: */5 * * * *` | 5-minute connector reconciliation **never ran** for 9 days |
| `bic-gpi-full.yml` | `workflow_dispatch`, `push` | BIC / SWIFT gpi deploy path dead |

All 30 most recent runs in the repo are this single failure bucket, firing every
few minutes — which also **buries real CI signal** in the run history.

Causes: `wise-recon-5min.yml` embedded multi-line `python3 -c "…"` starting at
column 0 inside a `run: |` block (a column-0 line terminates the YAML block
scalar); `bic-gpi-full.yml` was committed with the `cat > … << 'YML'` heredoc
that created it still in the file body.

→ Fixed in **fin-os-prod#200**. All 56 workflow files now parse.

### The gateway's Workers Build has been failing since at least 2026-08-14

The Cloudflare **`Workers Builds: fin-os-gateway`** check fails on every recent
PR, regardless of what the PR touches:

| PR | Date | Touched | Result |
|---|---|---|---|
| #194 | 2026-08-14 | fin-os-voice UI / PWA | ❌ |
| #199 | 2026-08-15 | SaaS session handling | ❌ |
| #200 | 2026-08-17 | 2 workflow YAML files | ❌ |

Every run reports `started_at == completed_at` — it fails instantly, before any
compile step. That is a **build-configuration failure** (wrong target / missing
credentials), not a source error, and it matches the two repair workflows
already committed for this exact problem (`repair-cloudflare-gateway-build-settings.yml`,
`cloudflare-build-settings-repair.yml`). The check run exposes no `output.text`;
detail is Cloudflare-dashboard-only.

Combined with the gate below, this means **the live gateway currently has no
working automated build path and no working automated verification.**

### The deploy gate is a false green

`fin-os-deploy-gate.yml` is Access-aware, but when `CF_ACCESS_CLIENT_ID` /
`CF_ACCESS_CLIENT_SECRET` are absent it **skips the smoke test with `exit 0` and
then seals `DEPLOY_GATE=PASSED`**:

```bash
if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
  echo "::notice::… skipping live gateway smoke …"
  exit 0
fi
```

The skip is intentional (the in-file comment says it avoids a false red while
Access is wired up), but the consequence is that **the gate reports PASSED
without verifying anything**. Until a Zero Trust service token is issued and
stored as repo secrets, no automated check confirms the live gateway is
`OPERATIONAL`. Left unchanged here — flipping it to hard-fail would turn main
red and is a call for the operator, not an automated edit.

## 8. Infra inventory

- **D1 databases: 10** (was 8). New since June: `fin-os` (`29fc632d-…`) and
  `tcb_ledger_prod_v3` (`85975af9-…`) — both currently ~0 tables; confirm intent
  before anything points at them.
- `tcb_ledger_main` 495.8 MB · `tcb_ledger` **196.3 MB (was 43 MB — 4.5× growth
  with zero new payments; worth checking what is writing)** · `tcb-master-002`
  864 kB.

## Action items

| # | Item | Severity |
|---|---|---|
| 1 | Merge fin-os-prod#200 to restore the 5-minute reconciliation and unbury CI | **P1** |
| 2 | Issue a Cloudflare Access service token so the deploy gate actually verifies instead of sealing PASSED | **P1** |
| 2b | Repair the `Workers Builds: fin-os-gateway` build config — broken since ≥2026-08-14, so the gateway has no working CI build path | **P1** |
| 3 | LEI on record fails ISO 17442 — treat as not acquired; drive the GLEIF submission | **P1** |
| 4 | `reconciliation_runs` stalled since 2026-05-14 — confirm whether #1 alone resumes it | **P2** |
| 5 | 15 `DISPATCHED` vs 1 `COMPLETED` — completion callbacks still outstanding (open since June) | **P2** |
| 6 | Redeploy `swift-gpi-callback` to pick up the public `/health` bypass already in source | **P3** |
| 7 | Trace 48 × `REGISTRY_SELFSERVE_WEBHOOK_INVALID_SIG` to its sender | **P3** |
| 8 | Investigate `tcb_ledger` 43 MB → 196 MB growth | **P3** |
| 9 | Confirm the 2 audit-chain genesis rows are intended (carried from June) | **P3** |

## Method

Read-only throughout: `SELECT`/`COUNT` against D1 via the Cloudflare API, `GET`
against worker health endpoints, and read calls against the GitHub Actions API.
No writes, no DDL, no `wrangler secret put`. Chain integrity was verified with a
self-join over `audit_hash_chain` rather than inferred from row counts; the LEI
was checked against the ISO 17442 mod 97-10 algorithm rather than eyeballed.
