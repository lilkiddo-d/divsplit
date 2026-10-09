#!/usr/bin/env bash
# Full deploy + fund + seed against a FRESH local fork (start scripts/fork-up.sh first, then run this immediately:
# the public RPC is not an archive node, so fork state older than a few minutes cannot be fetched).
# No private keys anywhere: anvil impersonates the deployer (--auto-impersonate / --unlocked).
#   FORK_RPC   local fork RPC (default http://127.0.0.1:8555)
#   DEPLOYER   impersonated deployer, also the test account that gets stock + USDG and seeds every pool
# Note: storage the deploy/seed did not touch cannot be read later (the upstream prunes it), so ForkAll pre-touches
# everything the UI needs (balances, pool/Router allowances, feeds, Multicall3).
set -euo pipefail
cd "$(dirname "$0")/../contracts"
FORK_RPC="${FORK_RPC:-http://127.0.0.1:8555}"
DEPLOYER="${DEPLOYER:-0x1000000000000000000000000000000000000d15}"

rpc() { curl -s -m 120 -X POST "$FORK_RPC" -H "content-type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"; }

ready=0
for i in $(seq 1 60); do rpc eth_chainId '[]' | grep -q '"0x1237"' && ready=1 && break; sleep 1; done
# refuse to touch anything that is not a fork of chain 4663 (another local node may own the port)
[ "$ready" = 1 ] || { echo "No Robinhood Chain (4663) fork at $FORK_RPC — start scripts/fork-up.sh or set FORK_RPC/FORK_PORT" >&2; exit 1; }
rpc anvil_setBalance "[\"$DEPLOYER\",\"0x56BC75E2D63100000\"]" >/dev/null

echo "== Deploy (production Deploy.s.sol) + fund + seed, in one invocation"
forge script script/ForkAll.s.sol --sig "runFork()" --rpc-url "$FORK_RPC" --unlocked --sender "$DEPLOYER" --broadcast

echo "== Done. Start the app against this fork:"
echo "   cd app && NEXT_PUBLIC_RPC_URL=$FORK_RPC NEXT_PUBLIC_DEV_IMPERSONATE=$DEPLOYER pnpm dev"
