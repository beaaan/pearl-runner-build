#!/usr/bin/env bash
# Container entrypoint: starts pearld, pearl-gateway, watchdog, then exec's
# vllm serve so PID 1 = vllm and the container dies if vllm dies.
#
# Required env (Vast injects via the launch script):
#   PEARLD_MINING_ADDRESS   payout taproot address
#   VAST_API_KEY            for the watchdog's self-destruct
#   SPEND_CAP_USD           e.g. 50
#   DPH_TOTAL               offer price at launch, e.g. 2.80
#   SHARE_KILLSWITCH_HOURS  e.g. 6
#
# Optional env:
#   MINER_MODEL             default pearl-ai/Llama-3.3-70B-Instruct-pearl
#   HF_TOKEN                if the model is gated
#   PEARLD_NETWORK          "" (mainnet) | "--testnet" | "--simnet"

set -euo pipefail
exec > >(tee -a /var/log/pearl-runner.log) 2>&1
echo "=== pearl-runner $(date -u +%FT%TZ) ==="

: "${PEARLD_MINING_ADDRESS:?PEARLD_MINING_ADDRESS required}"
: "${VAST_API_KEY:?VAST_API_KEY required}"
: "${SPEND_CAP_USD:=50}"
: "${DPH_TOTAL:=2.80}"
: "${SHARE_KILLSWITCH_HOURS:=6}"
: "${MINER_MODEL:=pearl-ai/Llama-3.3-70B-Instruct-pearl}"
: "${PEARLD_NETWORK:=}"

# Random RPC creds per boot
RPC_USER="rpc_$(head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
RPC_PASS="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 32)"

mkdir -p /var/lib/pearl/.pearld /var/log/pearl /run/pearl /etc/pearl
chmod 0700 /var/lib/pearl/.pearld

cat >/etc/pearl/pearl.env <<EOF
PEARLD_RPC_USER=$RPC_USER
PEARLD_RPC_PASSWORD=$RPC_PASS
PEARLD_RPC_URL=https://127.0.0.1:44107
PEARLD_MINING_ADDRESS=$PEARLD_MINING_ADDRESS
SPEND_CAP_USD=$SPEND_CAP_USD
DPH_TOTAL=$DPH_TOTAL
SHARE_KILLSWITCH_HOURS=$SHARE_KILLSWITCH_HOURS
EOF
chmod 0600 /etc/pearl/pearl.env
echo "VAST_API_KEY=$VAST_API_KEY" >/etc/pearl/vast.key
chmod 0600 /etc/pearl/vast.key

# ---- pearld -------------------------------------------------------------
echo "+ start pearld"
nohup setsid pearld \
    --datadir=/var/lib/pearl/.pearld \
    --rpcuser="$RPC_USER" --rpcpass="$RPC_PASS" \
    --rpclisten=127.0.0.1:44107 \
    --listen=0.0.0.0:44108 \
    --miningaddr="$PEARLD_MINING_ADDRESS" \
    --txindex \
    $PEARLD_NETWORK \
    >/var/log/pearl/pearld.log 2>&1 < /dev/null &
echo $! > /run/pearl/pearld.pid

for _ in $(seq 1 60); do
  if prlctl -u "$RPC_USER" -P "$RPC_PASS" --skipverify ping >/dev/null 2>&1; then
    echo "+ pearld RPC up"
    break
  fi
  sleep 2
done

# ---- pearl-gateway ------------------------------------------------------
echo "+ start pearl-gateway"
PEARLD_RPC_URL="https://127.0.0.1:44107" \
PEARLD_RPC_USER="$RPC_USER" \
PEARLD_RPC_PASSWORD="$RPC_PASS" \
PEARLD_MINING_ADDRESS="$PEARLD_MINING_ADDRESS" \
nohup setsid pearl-gateway start \
    >/var/log/pearl/gateway.log 2>&1 < /dev/null &
echo $! > /run/pearl/gateway.pid

# Wait for gateway metrics endpoint (matches upstream entrypoint behavior)
curl -s --retry-delay 1 --retry 30 --retry-all-errors \
    http://127.0.0.1:8339/metrics >/dev/null || \
    echo "warn: gateway metrics endpoint not reachable; continuing"

# ---- Watchdog -----------------------------------------------------------
echo "+ start watchdog"
nohup setsid /usr/local/bin/pearl-watchdog \
    >/var/log/pearl/watchdog.log 2>&1 < /dev/null &
echo $! > /run/pearl/watchdog.pid

# ---- vLLM (PID 1 worth dying for) ---------------------------------------
echo "+ exec vllm serve $MINER_MODEL"
exec vllm serve "$MINER_MODEL" \
    --host 127.0.0.1 --port 8000 \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.9 \
    --enforce-eager
