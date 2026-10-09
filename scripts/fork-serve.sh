#!/usr/bin/env bash
# Serve the snapshotted fork (.fork/state.json from scripts/fork-deploy.sh) as a standalone chain with id 4663.
# No upstream RPC is needed, so it never goes stale. Stop scripts/fork-up.sh first (same port).
set -euo pipefail
cd "$(dirname "$0")/.."
FORK_PORT="${FORK_PORT:-8555}"
exec anvil --chain-id 4663 --port "$FORK_PORT" --auto-impersonate --load-state .fork/state.json
