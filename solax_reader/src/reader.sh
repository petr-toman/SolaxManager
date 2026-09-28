#!/usr/bin/env bash
set -u

interval="${POLL_INTERVAL_SECONDS:-5}"

echo "solax_reader starting; interval=${interval}s"
echo "SolaX endpoint: ${SOLAX_URL:-not configured}"

while true; do
  if [[ -z "${SOLAX_PASSWORD:-}" ]]; then
    echo "$(date -Iseconds) solax_reader: SOLAX_PASSWORD not configured; waiting"
    sleep "$interval"
    continue
  fi

  # Initial transport probe only.
  # Mapping and PostgreSQL persistence will be ported from rpiSolaxPT in M0.
  response="$(curl -fsS --max-time 4     -d "?optType=ReadRealTimeData&pwd=${SOLAX_PASSWORD}"     -X POST "${SOLAX_URL}" 2>/dev/null || true)"

  if [[ -n "$response" ]]; then
    if echo "$response" | jq -e '.Data' >/dev/null 2>&1; then
      echo "$(date -Iseconds) solax_reader: valid realtime response"
    else
      echo "$(date -Iseconds) solax_reader: response received but payload is not recognized"
    fi
  else
    echo "$(date -Iseconds) solax_reader: no response"
  fi

  sleep "$interval"
done
