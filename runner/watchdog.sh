#!/usr/bin/env bash
# Container watchdog. Self-destructs the Vast instance when:
#   1. uptime_h * DPH_TOTAL >= SPEND_CAP_USD            (hard spend cap)
#   2. chain synced AND no shares in SHARE_KILLSWITCH_HOURS  (productivity cap)
#
# Reads /etc/pearl/pearl.env and /etc/pearl/vast.key.

set -euo pipefail

# shellcheck disable=SC1091
. /etc/pearl/pearl.env
# shellcheck disable=SC1091
. /etc/pearl/vast.key

VAST_API="${VAST_API:-https://console.vast.ai/api/v0}"

# Vast injects the container label as C.<instance_id>; CONTAINER_ID is a fallback.
INSTANCE_ID="${VAST_CONTAINERLABEL#C.}"
INSTANCE_ID="${INSTANCE_ID:-${CONTAINER_ID:-}}"

START_TS=$(date +%s)
SYNC_DONE_TS=""
LAST_SHARE_TS=""

log() { printf '[watchdog %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

if [[ -z "${INSTANCE_ID:-}" ]]; then
  log "no VAST instance id in env; running in spend-cap mode without self-destroy"
fi

destroy_self() {
  local reason=$1
  log "DESTROY (instance=$INSTANCE_ID): $reason"
  if [[ -n "${INSTANCE_ID:-}" ]]; then
    curl -fsS -X DELETE -H "Authorization: Bearer $VAST_API_KEY" \
        "$VAST_API/instances/$INSTANCE_ID/" || \
        log "destroy API call failed; manual cleanup required"
  fi
  sleep 30
  exit 0
}

prl() {
  prlctl -u "$PEARLD_RPC_USER" -P "$PEARLD_RPC_PASSWORD" --skipverify "$@"
}

is_synced() {
  local prog
  prog=$(prl getblockchaininfo 2>/dev/null \
    | jq -r '.verificationprogress // 0' 2>/dev/null || echo 0)
  awk -v p="$prog" 'BEGIN{exit !(p+0 >= 0.999)}'
}

share_seen_recent() {
  local since=$(( $(date +%s) - 3600 ))
  for log_file in /var/log/pearl/gateway.log; do
    [[ -r $log_file ]] || continue
    local mtime
    mtime=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
    [[ $mtime -ge $since ]] || continue
    if grep -Eqi 'accepted|share|submit(ted)? block|new block' "$log_file"; then
      return 0
    fi
  done
  return 1
}

log "start cap=\$$SPEND_CAP_USD dph=\$$DPH_TOTAL killswitch=${SHARE_KILLSWITCH_HOURS}h"

while true; do
  now=$(date +%s)
  uptime_h=$(awk -v s="$START_TS" -v n="$now" 'BEGIN{printf "%.4f",(n-s)/3600.0}')
  spent=$(awk -v u="$uptime_h" -v d="$DPH_TOTAL" 'BEGIN{printf "%.4f",u*d}')
  log "uptime=${uptime_h}h spent=\$$spent / cap \$$SPEND_CAP_USD"

  if awk -v s="$spent" -v c="$SPEND_CAP_USD" 'BEGIN{exit !(s+0 >= c+0)}'; then
    destroy_self "spend cap reached: \$$spent >= \$$SPEND_CAP_USD"
  fi

  if [[ -z "$SYNC_DONE_TS" ]] && is_synced; then
    SYNC_DONE_TS=$now
    log "chain synced; share killswitch armed for ${SHARE_KILLSWITCH_HOURS}h"
  fi

  if [[ -n "$SYNC_DONE_TS" ]]; then
    if share_seen_recent; then
      LAST_SHARE_TS=$now
    fi
    deadline=$(( SYNC_DONE_TS + SHARE_KILLSWITCH_HOURS * 3600 ))
    if [[ $now -ge $deadline && -z "$LAST_SHARE_TS" ]]; then
      destroy_self "no shares within ${SHARE_KILLSWITCH_HOURS}h of sync"
    fi
  fi

  sleep 300
done
