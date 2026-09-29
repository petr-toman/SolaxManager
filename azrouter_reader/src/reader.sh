#!/usr/bin/env bash
set -u

interval="${AZROUTER_POLL_INTERVAL_SECONDS:-5}"
run_once="${RUN_ONCE:-false}"
base_url="${AZROUTER_URL:-}"
endpoint="${base_url%/}/api/v1/power"

log() {
  printf '%s azrouter_reader: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ -z "${DATABASE_URL:-}" ]]; then
  log "DATABASE_URL is not configured"
  exit 1
fi

if [[ -z "$base_url" ]]; then
  log "AZROUTER_URL is not configured"
  exit 1
fi

log "starting; endpoint=${endpoint}; interval=${interval}s"

while true; do
  measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  response="$(curl -fsS --max-time 4 "$endpoint" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    log "no response from AZ Router"
  elif ! echo "$response" | jq -e '
      (.input.power | type == "array") and
      (.input.voltage | type == "array") and
      (.input.current | type == "array")
    ' >/dev/null 2>&1; then
    log "response received but payload is not recognized as expected AZ Router power data"
  else
    mapped="$(
      echo "$response" | jq -c '
        def by_id(a; id): ([a[]? | select(.id == id) | .value][0] // null);
        def scale1000(v): if v == null then null else (v / 1000) end;

        (by_id(.input.power; 0)) as $p1 |
        (by_id(.input.power; 1)) as $p2 |
        (by_id(.input.power; 2)) as $p3 |
        {
          grid_l1_power_w: $p1,
          grid_l2_power_w: $p2,
          grid_l3_power_w: $p3,
          grid_total_power_w:
            (if ($p1 == null or $p2 == null or $p3 == null)
             then null else ($p1 + $p2 + $p3) end),

          grid_l1_voltage_v: scale1000(by_id(.input.voltage; 0)),
          grid_l2_voltage_v: scale1000(by_id(.input.voltage; 1)),
          grid_l3_voltage_v: scale1000(by_id(.input.voltage; 2)),

          grid_l1_current_a: scale1000(by_id(.input.current; 0)),
          grid_l2_current_a: scale1000(by_id(.input.current; 1)),
          grid_l3_current_a: scale1000(by_id(.input.current; 2)),

          output_0_power_w: by_id(.output.power; 0),
          output_1_power_w: by_id(.output.power; 1),
          output_2_power_w: by_id(.output.power; 2),
          output_3_power_w: by_id(.output.power; 3),

          device_last_update_epoch: (.lastUpdate // null)
        }
      '
    )"

    IFS=$'\t' read -r \
      grid_l1_power_w grid_l2_power_w grid_l3_power_w grid_total_power_w \
      grid_l1_voltage_v grid_l2_voltage_v grid_l3_voltage_v \
      grid_l1_current_a grid_l2_current_a grid_l3_current_a \
      output_0_power_w output_1_power_w output_2_power_w output_3_power_w \
      device_last_update_epoch \
      <<< "$(
        echo "$mapped" | jq -r '
          [
            .grid_l1_power_w, .grid_l2_power_w, .grid_l3_power_w, .grid_total_power_w,
            .grid_l1_voltage_v, .grid_l2_voltage_v, .grid_l3_voltage_v,
            .grid_l1_current_a, .grid_l2_current_a, .grid_l3_current_a,
            .output_0_power_w, .output_1_power_w, .output_2_power_w, .output_3_power_w,
            .device_last_update_epoch
          ]
          | map(if . == null then "" else tostring end)
          | @tsv
        '
      )"

    compact_raw="$(echo "$response" | jq -c '.')"

    if psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
      -v measured_at="$measured_at" \
      -v grid_l1_power_w="$grid_l1_power_w" \
      -v grid_l2_power_w="$grid_l2_power_w" \
      -v grid_l3_power_w="$grid_l3_power_w" \
      -v grid_total_power_w="$grid_total_power_w" \
      -v grid_l1_voltage_v="$grid_l1_voltage_v" \
      -v grid_l2_voltage_v="$grid_l2_voltage_v" \
      -v grid_l3_voltage_v="$grid_l3_voltage_v" \
      -v grid_l1_current_a="$grid_l1_current_a" \
      -v grid_l2_current_a="$grid_l2_current_a" \
      -v grid_l3_current_a="$grid_l3_current_a" \
      -v output_0_power_w="$output_0_power_w" \
      -v output_1_power_w="$output_1_power_w" \
      -v output_2_power_w="$output_2_power_w" \
      -v output_3_power_w="$output_3_power_w" \
      -v device_last_update_epoch="$device_last_update_epoch" \
      -v raw_payload="$compact_raw" <<'SQL'
INSERT INTO azrouter_raw (
  measured_at,
  grid_l1_power_w, grid_l2_power_w, grid_l3_power_w, grid_total_power_w,
  grid_l1_voltage_v, grid_l2_voltage_v, grid_l3_voltage_v,
  grid_l1_current_a, grid_l2_current_a, grid_l3_current_a,
  output_0_power_w, output_1_power_w, output_2_power_w, output_3_power_w,
  device_last_update,
  raw_payload
) VALUES (
  :'measured_at'::timestamptz,
  NULLIF(:'grid_l1_power_w','')::double precision,
  NULLIF(:'grid_l2_power_w','')::double precision,
  NULLIF(:'grid_l3_power_w','')::double precision,
  NULLIF(:'grid_total_power_w','')::double precision,
  NULLIF(:'grid_l1_voltage_v','')::double precision,
  NULLIF(:'grid_l2_voltage_v','')::double precision,
  NULLIF(:'grid_l3_voltage_v','')::double precision,
  NULLIF(:'grid_l1_current_a','')::double precision,
  NULLIF(:'grid_l2_current_a','')::double precision,
  NULLIF(:'grid_l3_current_a','')::double precision,
  NULLIF(:'output_0_power_w','')::double precision,
  NULLIF(:'output_1_power_w','')::double precision,
  NULLIF(:'output_2_power_w','')::double precision,
  NULLIF(:'output_3_power_w','')::double precision,
  CASE
    WHEN NULLIF(:'device_last_update_epoch','') IS NULL THEN NULL
    ELSE to_timestamp(NULLIF(:'device_last_update_epoch','')::double precision)
  END,
  :'raw_payload'::jsonb
);
SQL
    then
      log "stored grid L1=${grid_l1_power_w:-?}W L2=${grid_l2_power_w:-?}W L3=${grid_l3_power_w:-?}W total=${grid_total_power_w:-?}W"
    else
      log "database insert failed"
    fi
  fi

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$interval"
done
