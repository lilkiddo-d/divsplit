#!/usr/bin/env bash
# Start a local anvil fork of Robinhood Chain mainnet (chain id stays 4663).
#   RPC_URL   upstream RPC (default: public endpoint; it is rate-limited and not an archive node, so the fork must
#             start at the latest block and the deploy should run right after)
#   FORK_PORT local port (default 8555)
# --auto-impersonate lets local scripts and the dev UI send transactions from any address WITHOUT private keys.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
FORK_PORT="${FORK_PORT:-8555}"
mkdir -p .fork
exec anvil --fork-url "$RPC_URL" --auto-impersonate --port "$FORK_PORT" \
  --fork-retry-backoff 1000 --retries 20 --timeout 60000 --no-rate-limit \
  --dump-state .fork/state.json
