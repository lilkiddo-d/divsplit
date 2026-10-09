#!/usr/bin/env bash
# Static analysis. Config in contracts/slither.config.json (excludes lib/, test/, script/).
set -euo pipefail
cd "$(dirname "$0")/../contracts"
slither . --config-file slither.config.json "$@"
