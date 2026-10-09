#!/usr/bin/env bash
# Wire the externally launched $DIVS token into ProjectTokenHooks through the 48h Timelock.
#   bash scripts/set-project-token.sh schedule <DIVS_ADDRESS>   # proposer, starts the 48h delay
#   bash scripts/set-project-token.sh execute  <DIVS_ADDRESS>   # anyone, after the delay
# Env: RPC_URL (default public mainnet RPC), ACCOUNT (Foundry keystore account, default divsplit-deployer)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:?schedule|execute}"
TOKEN="${2:?project token address}"
RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
ACCOUNT="${ACCOUNT:-divsplit-deployer}"
DEP=deployments/4663.json
TIMELOCK=$(python -c "import json;print(json.load(open('$DEP'))['timelock'])")
HOOKS=$(python -c "import json;print(json.load(open('$DEP'))['projectTokenHooks'])")
DATA=$(cast calldata "setProjectToken(address)" "$TOKEN")
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
SALT=$(cast keccak "divsplit:setProjectToken:$TOKEN")
case "$MODE" in
  schedule)
    cast send "$TIMELOCK" "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" "$HOOKS" 0 "$DATA" "$ZERO" "$SALT" 172800 \
      --account "$ACCOUNT" --rpc-url "$RPC_URL" ;;
  execute)
    cast send "$TIMELOCK" "execute(address,uint256,bytes,bytes32,bytes32)" "$HOOKS" 0 "$DATA" "$ZERO" "$SALT" \
      --account "$ACCOUNT" --rpc-url "$RPC_URL" ;;
  *) echo "mode must be schedule or execute" >&2; exit 1 ;;
esac
