#!/usr/bin/env bash
# ============================================================================
# entrypoint.sh — MACAE backend (RPSI private landing-zone reuse build)
#
# Corporate DNS returns NXDOMAIN for the privatelink FQDNs of the reused
# Foundry / Cosmos / Search / Storage private endpoints. This entrypoint
# injects static "IP host" mappings (supplied via the EXTRA_HOSTS env var)
# into /etc/hosts before starting the app, so the backend resolves those
# names to their private-endpoint IPs.
#
# The backend image runs as root, so writing /etc/hosts here is allowed.
# EXTRA_HOSTS format: one "<ip> <fqdn>" pair per line.
# ============================================================================
set -euo pipefail

if [[ -n "${EXTRA_HOSTS:-}" ]]; then
  echo "[entrypoint] Injecting EXTRA_HOSTS into /etc/hosts"
  while IFS= read -r line; do
    # skip blank lines
    [[ -z "${line// }" ]] && continue
    if ! grep -qF -- "$line" /etc/hosts; then
      echo "$line" >> /etc/hosts
      echo "[entrypoint]   + $line"
    fi
  done <<< "$EXTRA_HOSTS"
else
  echo "[entrypoint] EXTRA_HOSTS not set; skipping /etc/hosts injection"
fi

echo "[entrypoint] Starting backend: $*"
exec "$@"
