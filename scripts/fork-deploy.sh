#!/usr/bin/env bash
# Full deploy + fund + seed against a FRESH local fork (start scripts/fork-up.sh first, then run this immediately:
# the public RPC is not an archive node, so fork state older than a few minutes cannot be fetched).
# No private keys anywhere: anvil impersonates the deployer (--auto-impersonate / --unlocked).
#   FORK_RPC   local fork RPC (default http://127.0.0.1:8555)
#   DEPLOYER   impersonated deployer, also the test account that gets stock + USDG and seeds every pool
# Afterwards the fork state is snapshotted to .fork/state.json; scripts/fork-serve.sh serves it without upstream.
set -euo pipefail
cd "$(dirname "$0")/../contracts"
FORK_RPC="${FORK_RPC:-http://127.0.0.1:8555}"
DEPLOYER="${DEPLOYER:-0x1000000000000000000000000000000000000d15}"

rpc() { curl -s -m 120 -X POST "$FORK_RPC" -H "content-type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"; }

for i in $(seq 1 60); do rpc eth_chainId '[]' | grep -q 0x1237 && break; sleep 1; done
rpc anvil_setBalance "[\"$DEPLOYER\",\"0x56BC75E2D63100000\"]" >/dev/null

echo "== Deploy (production Deploy.s.sol) + fund + seed, in one invocation"
forge script script/ForkAll.s.sol --sig "runFork()" --rpc-url "$FORK_RPC" --unlocked --sender "$DEPLOYER" --broadcast --slow

echo "== Snapshot fork state -> .fork/state.json"
mkdir -p ../.fork
rpc anvil_dumpState '[]' > ../.fork/dump.json
python - <<'EOF'
import json, gzip, binascii
raw = json.load(open("../.fork/dump.json"))["result"]
data = binascii.unhexlify(raw[2:] if raw.startswith("0x") else raw)
try:
    data = gzip.decompress(data)
except OSError:
    pass
open("../.fork/state.json", "wb").write(data)
print("state.json bytes:", len(data))
EOF
echo "== Done. Serve it with: bash scripts/fork-serve.sh"
echo "   then: cd app && NEXT_PUBLIC_RPC_URL=$FORK_RPC NEXT_PUBLIC_DEV_IMPERSONATE=$DEPLOYER pnpm dev"
