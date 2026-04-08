#!/usr/bin/env bash
set -euo pipefail

# During analysis/wiki phase, always report healthy so the container
# is not marked unhealthy during long-running startup tasks.
ANALYSIS_LOCK="/state/.analyzing"

if [[ -f "$ANALYSIS_LOCK" ]]; then
    exit 0
fi

# After startup, check the real /healthz endpoint on Supergateway
INTERNAL_PORT="${INTERNAL_PORT:-38011}"
curl -sf "http://127.0.0.1:${INTERNAL_PORT}/healthz" >/dev/null 2>&1
