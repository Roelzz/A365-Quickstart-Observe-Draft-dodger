#!/usr/bin/env bash
# Start an Aspire Dashboard locally for live OTel trace visualisation.
#
# Spans land in this dashboard when:
#   - OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 is set in .env
#   - The agent is restarted to pick up the env change
#
# This dashboard is the recommended demo surface when the tenant doesn't
# have Defender for Cloud Apps (i.e. no CloudAppEvents in Advanced Hunting)
# and admin.cloud.microsoft -> Activity tab is aggregated/delayed.
#
# Auto-detects podman vs docker. Container is detached and named
# `aspire-dashboard` for easy stop/start.

set -euo pipefail

if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
  if ! podman machine list --format '{{.Running}}' | grep -q true; then
    echo "Starting podman-machine-default..."
    podman machine start podman-machine-default
  fi
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
else
  echo "Need podman or docker installed." >&2
  exit 1
fi

$RUNTIME rm -f aspire-dashboard >/dev/null 2>&1 || true

echo "Starting Aspire Dashboard via $RUNTIME..."
# DASHBOARD__FRONTEND__AUTHMODE=Unsecured skips the one-time login token on the
# UI (http://localhost:18888 opens straight into Traces). Only safe because the
# port is bound to localhost — never expose this container to a network.
$RUNTIME run --rm -d \
  --name aspire-dashboard \
  -p 18888:18888 \
  -p 4317:18889 \
  -e DASHBOARD__OTLP__AUTHMODE=Unsecured \
  -e DASHBOARD__FRONTEND__AUTHMODE=Unsecured \
  mcr.microsoft.com/dotnet/aspire-dashboard:latest

echo ""
echo "Aspire Dashboard up:"
echo "  UI:        http://localhost:18888"
echo "  OTLP gRPC: http://localhost:4317"
echo ""
echo "Make sure .env has:  OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317"
echo "Then restart the agent. Spans appear in real time in the Traces tab."
echo ""
echo "Stop with: $RUNTIME stop aspire-dashboard"

if [[ "$(uname -s)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
  sleep 2
  open http://localhost:18888 || true
fi
