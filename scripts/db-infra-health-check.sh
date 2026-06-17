#!/usr/bin/env bash
#
# db-infra-health-check.sh — read-only DB + infrastructure health snapshot
# for the TCB / fin-os production estate (Cloudflare D1 + Workers + KV).
#
# This script ONLY runs SELECT / COUNT / PRAGMA against D1 and GETs worker
# health endpoints. It never writes, never calls `wrangler secret put`, and
# never mutates state. It is safe to run against production at any time.
#
# Requirements: bash, curl, and an authenticated `wrangler` (CLOUDFLARE_API_TOKEN
# or `wrangler login`). Every command is fail-soft: a missing table or a
# transient error prints a WARN line and the run continues.
#
# Usage:
#   ./scripts/db-infra-health-check.sh                 # full check
#   WORKERS_ONLY=1 ./scripts/db-infra-health-check.sh  # skip D1 (no wrangler auth)
#
set -uo pipefail

# ---- Canonical D1 databases (verified 2026-06-17) -------------------------
# tcb_ledger       (LG) 977aa2b4-… state-machine DB; audit_hash_chain here is
#                       a STALE 8-row segment abandoned 2026-05-27 — NOT canonical.
# tcb_ledger_main  (LM) 9efffcf0-… LIVE canonical audit_hash_chain + asset truth.
# tcb-master-002   (MA) b9c7294f-… active master: licenses / sanctions / banks.
LG="tcb_ledger"
LM="tcb_ledger_main"
MA="tcb-master-002"

WORKERS_BASE="${WORKERS_BASE:-https://%s.tsukayamacenturybank.workers.dev/health}"
WORKERS="${WORKERS:-bank-clearing-core reconciliation-worker fin-os-registry-gateway swift-gpi-callback fin-os-ai-search}"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
hdr()   { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }

# d1 <db> <sql> — run a read-only query, fail-soft.
d1() {
  local db="$1" sql="$2"
  if ! npx wrangler d1 execute "$db" --remote --json --command "$sql" 2>/dev/null; then
    yellow "  WARN: query failed on ${db} (table/column missing or auth) — skipped"
  fi
}

# count <db> <table> [where] — print "table[/where] = N", fail-soft.
count() {
  local db="$1" table="$2" where="${3:-}"
  local sql="SELECT COUNT(*) AS n FROM ${table}"
  [ -n "$where" ] && sql="${sql} WHERE ${where}"
  local out
  out="$(npx wrangler d1 execute "$db" --remote --json --command "$sql" 2>/dev/null \
        | grep -oE '"n":[0-9]+' | head -1 | cut -d: -f2)"
  if [ -n "$out" ]; then
    printf '  %-42s = %s\n' "${table}${where:+ [$where]}" "$out"
  else
    yellow "  WARN: ${table} not present on ${db} — skipped"
  fi
}

hdr "1. Worker health endpoints"
for w in $WORKERS; do
  # shellcheck disable=SC2059
  url="$(printf "$WORKERS_BASE" "$w")"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then green "  $(printf '%-32s' "$w") HTTP $code"
  else yellow "  $(printf '%-32s' "$w") HTTP $code  <-- investigate"; fi
done
# Gateway uses /api (expects body OPERATIONAL), not /health.
gw="$(curl -s --max-time 8 https://fin-os-gateway.tsukayamacenturybank.workers.dev/api 2>/dev/null | head -c 200)"
printf '  %-32s %s\n' "fin-os-gateway /api" "${gw:-<no body>}"

[ "${WORKERS_ONLY:-0}" = "1" ] && { echo; green "WORKERS_ONLY set — done."; exit 0; }

hdr "2. Kill switches (must be OFF for normal operation)"
echo "  LM global_kill_switch_v2:"
d1 "$LM" "SELECT system_state, kill_switch, reason, triggered_at FROM global_kill_switch_v2 LIMIT 1"
echo "  MA kill_switch_state:"
d1 "$MA" "SELECT id, enabled, reason FROM kill_switch_state LIMIT 3"
echo "  MA fin_runtime_kill_switch:"
d1 "$MA" "SELECT enabled, reason FROM fin_runtime_kill_switch LIMIT 1"

hdr "3. Canonical audit hash chain (tcb_ledger_main)"
d1 "$LM" "SELECT COUNT(*) total, COUNT(DISTINCT chain_hash) distinct_hashes, MAX(created_at) last_extended FROM audit_hash_chain"
yellow "  (tcb_ledger.audit_hash_chain is the STALE segment — do not treat as canonical)"

hdr "4. Money path / ledger (tcb_ledger)"
count "$LG" payments
count "$LG" payments "status='DISPATCHED'"
count "$LG" payments "status='COMPLETED'"
count "$LG" finos_payments
count "$LG" rail_transfers
count "$LG" rail_transfers "status='BLOCKED'"
count "$LG" zengin_transfers
count "$LG" swift_messages
count "$LG" bank_accounts

hdr "5. Reconciliation & DLQ (tcb_ledger)"
count "$LG" reconciliation_runs
count "$LG" reconciliation_breaks
count "$LG" dlq_events
count "$LG" finos_dlq
count "$LG" finos_dlq "status NOT IN ('RESOLVED','RESOLVED_OK')"

hdr "6. Asset / custody (tcb_ledger_main)"
count "$LM" wallet_tokens
count "$LM" issued_cards
count "$LM" virtual_accounts
count "$LM" hsm_keys
count "$LM" tx_hsm_signatures
count "$LM" physical_key_registry
count "$LM" finos_live_readiness_matrix_v1

hdr "7. Compliance / licensing (tcb-master-002)"
count "$MA" fin_licenses
count "$MA" sanctions_list
count "$MA" correspondent_banks
count "$MA" two_eye_requests
count "$MA" fx_rates

hdr "8. Infra inventory (Cloudflare)"
echo "  Workers:"; npx wrangler deployments list 2>/dev/null | head -1 >/dev/null || true
npx wrangler kv namespace list 2>/dev/null | grep -c '"id"' \
  | xargs -I{} printf '  KV namespaces: %s\n' {} 2>/dev/null \
  || yellow "  WARN: could not list KV namespaces"

echo; green "Health check complete."
