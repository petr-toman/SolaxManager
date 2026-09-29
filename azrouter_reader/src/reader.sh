#!/usr/bin/env bash
set -u

interval="${AZROUTER_POLL_INTERVAL_SECONDS:-5}"
devices_every="${AZROUTER_DEVICES_EVERY_N_POLLS:-3}"
run_once="${RUN_ONCE:-false}"
base_url="${AZROUTER_URL:-}"
power_endpoint="${base_url%/}/api/v1/power"
devices_endpoint="${base_url%/}/api/v1/devices"

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

if ! [[ "$devices_every" =~ ^[1-9][0-9]*$ ]]; then
  log "AZROUTER_DEVICES_EVERY_N_POLLS must be a positive integer"
  exit 1
fi

log "starting; power=${power_endpoint}; devices=${devices_endpoint}; interval=${interval}s; devices_every=${devices_every}"
poll_count=0

while true; do
  measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  response="$(curl -fsS --max-time 4 "$power_endpoint" 2>/dev/null || true)"

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


  if (( poll_count % devices_every == 0 )); then
    devices_measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    devices_response="$(curl -fsS --max-time 4 "$devices_endpoint" 2>/dev/null || true)"

    if [[ -z "$devices_response" ]]; then
      log "no response from AZ Router devices endpoint"
    elif ! echo "$devices_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
      log "devices response received but payload is not an array"
    else
      devices_stored=0

      while IFS= read -r device; do
        [[ -z "$device" ]] && continue

        mapped_device="$(
          echo "$device" | jq -c '
            {
              device_type: (.deviceType // null),
              device_id: (.common.id // null),
              priority: (.common.priority // null),
              name: (.common.name // null),
              status_code: (.common.status // null),
              signal_db: (.common.signal // null),
              serial_number: (.common.sn // null),
              fw_version: (.common.fw // null),
              hw_version: (.common.hw // null),

              power_l1_w: (.power.output[0] // null),
              power_l2_w: (.power.output[1] // null),
              power_l3_w: (.power.output[2] // null),
              power_total_w: (.power.totalPower // null),
              max_power_w: (.power.maxPower // null),
              temperature_c: (.power.temperature // null),

              boost: (.power.boost // null),
              boost_source: (.power.boostSource // null),
              boost_temp_override: (.power.boostTempOverride // null),
              outlet_mode: (.power.outletMode // null),

              connected_l1: (.power.connectedPhase[0] // null),
              connected_l2: (.power.connectedPhase[1] // null),
              connected_l3: (.power.connectedPhase[2] // null)
            }
          '
        )"

        IFS=$'\t' read -r \
          device_type device_id priority name status_code signal_db serial_number fw_version hw_version \
          power_l1_w power_l2_w power_l3_w power_total_w max_power_w temperature_c \
          boost boost_source boost_temp_override outlet_mode connected_l1 connected_l2 connected_l3 \
          <<< "$(
            echo "$mapped_device" | jq -r '
              [
                .device_type, .device_id, .priority, .name, .status_code, .signal_db,
                .serial_number, .fw_version, .hw_version,
                .power_l1_w, .power_l2_w, .power_l3_w, .power_total_w, .max_power_w,
                .temperature_c, .boost, .boost_source, .boost_temp_override,
                .outlet_mode, .connected_l1, .connected_l2, .connected_l3
              ]
              | map(if . == null then "" else tostring end)
              | @tsv
            '
          )"

        compact_device_raw="$(echo "$device" | jq -c '.')"

        if psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
          -v measured_at="$devices_measured_at" \
          -v device_type="$device_type" \
          -v device_id="$device_id" \
          -v priority="$priority" \
          -v name="$name" \
          -v status_code="$status_code" \
          -v signal_db="$signal_db" \
          -v serial_number="$serial_number" \
          -v fw_version="$fw_version" \
          -v hw_version="$hw_version" \
          -v power_l1_w="$power_l1_w" \
          -v power_l2_w="$power_l2_w" \
          -v power_l3_w="$power_l3_w" \
          -v power_total_w="$power_total_w" \
          -v max_power_w="$max_power_w" \
          -v temperature_c="$temperature_c" \
          -v boost="$boost" \
          -v boost_source="$boost_source" \
          -v boost_temp_override="$boost_temp_override" \
          -v outlet_mode="$outlet_mode" \
          -v connected_l1="$connected_l1" \
          -v connected_l2="$connected_l2" \
          -v connected_l3="$connected_l3" \
          -v raw_payload="$compact_device_raw" <<'SQL'
INSERT INTO azrouter_device_raw (
  measured_at,
  device_type, device_id, priority, name, status_code, signal_db,
  serial_number, fw_version, hw_version,
  power_l1_w, power_l2_w, power_l3_w, power_total_w, max_power_w,
  temperature_c,
  boost, boost_source, boost_temp_override, outlet_mode,
  connected_l1, connected_l2, connected_l3,
  raw_payload
) VALUES (
  :'measured_at'::timestamptz,
  NULLIF(:'device_type','')::integer,
  NULLIF(:'device_id','')::integer,
  NULLIF(:'priority','')::integer,
  NULLIF(:'name',''),
  NULLIF(:'status_code','')::integer,
  NULLIF(:'signal_db','')::double precision,
  NULLIF(:'serial_number',''),
  NULLIF(:'fw_version',''),
  NULLIF(:'hw_version','')::integer,
  NULLIF(:'power_l1_w','')::double precision,
  NULLIF(:'power_l2_w','')::double precision,
  NULLIF(:'power_l3_w','')::double precision,
  NULLIF(:'power_total_w','')::double precision,
  NULLIF(:'max_power_w','')::double precision,
  NULLIF(:'temperature_c','')::double precision,
  CASE WHEN NULLIF(:'boost','') IS NULL THEN NULL ELSE NULLIF(:'boost','')::integer <> 0 END,
  NULLIF(:'boost_source','')::integer,
  NULLIF(:'boost_temp_override','')::double precision,
  NULLIF(:'outlet_mode','')::integer,
  CASE WHEN NULLIF(:'connected_l1','') IS NULL THEN NULL ELSE NULLIF(:'connected_l1','')::integer <> 0 END,
  CASE WHEN NULLIF(:'connected_l2','') IS NULL THEN NULL ELSE NULLIF(:'connected_l2','')::integer <> 0 END,
  CASE WHEN NULLIF(:'connected_l3','') IS NULL THEN NULL ELSE NULLIF(:'connected_l3','')::integer <> 0 END,
  :'raw_payload'::jsonb
);
SQL
        then
          devices_stored=$((devices_stored + 1))
        else
          log "database insert failed for AZ Router device id=${device_id:-?}"
        fi
      done < <(echo "$devices_response" | jq -c '.[]')

      log "stored ${devices_stored} AZ Router device sample(s)"
    fi
  fi

  poll_count=$((poll_count + 1))

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$interval"
done
\t' read -r \
          device_type device_id priority name status_code signal_db serial_number fw_version hw_version \
          power_l1_w power_l2_w power_l3_w power_total_w max_power_w temperature_c \
          boost boost_source boost_temp_override outlet_mode connected_l1 connected_l2 connected_l3 \
          <<< "$(
            echo "$mapped_device" | jq -r '
              [
                .device_type, .device_id, .priority, .name, .status_code, .signal_db,
                .serial_number, .fw_version, .hw_version,
                .power_l1_w, .power_l2_w, .power_l3_w, .power_total_w, .max_power_w,
                .temperature_c, .boost, .boost_source, .boost_temp_override,
                .outlet_mode, .connected_l1, .connected_l2, .connected_l3
              ]
              | map(if . == null then "" else tostring end)
              | @tsv
            '
          )"

        compact_device_raw="$(echo "$device" | jq -c '.')"

        if psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
          -v measured_at="$devices_measured_at" \
          -v device_type="$device_type" \
          -v device_id="$device_id" \
          -v priority="$priority" \
          -v name="$name" \
          -v status_code="$status_code" \
          -v signal_db="$signal_db" \
          -v serial_number="$serial_number" \
          -v fw_version="$fw_version" \
          -v hw_version="$hw_version" \
          -v power_l1_w="$power_l1_w" \
          -v power_l2_w="$power_l2_w" \
          -v power_l3_w="$power_l3_w" \
          -v power_total_w="$power_total_w" \
          -v max_power_w="$max_power_w" \
          -v temperature_c="$temperature_c" \
          -v boost="$boost" \
          -v boost_source="$boost_source" \
          -v boost_temp_override="$boost_temp_override" \
          -v outlet_mode="$outlet_mode" \
          -v connected_l1="$connected_l1" \
          -v connected_l2="$connected_l2" \
          -v connected_l3="$connected_l3" \
          -v raw_payload="$compact_device_raw" <<'SQL'
INSERT INTO azrouter_device_raw (
  measured_at,
  device_type, device_id, priority, name, status_code, signal_db,
  serial_number, fw_version, hw_version,
  power_l1_w, power_l2_w, power_l3_w, power_total_w, max_power_w,
  temperature_c,
  boost, boost_source, boost_temp_override, outlet_mode,
  connected_l1, connected_l2, connected_l3,
  raw_payload
) VALUES (
  :'measured_at'::timestamptz,
  NULLIF(:'device_type','')::integer,
  NULLIF(:'device_id','')::integer,
  NULLIF(:'priority','')::integer,
  NULLIF(:'name',''),
  NULLIF(:'status_code','')::integer,
  NULLIF(:'signal_db','')::double precision,
  NULLIF(:'serial_number',''),
  NULLIF(:'fw_version',''),
  NULLIF(:'hw_version','')::integer,
  NULLIF(:'power_l1_w','')::double precision,
  NULLIF(:'power_l2_w','')::double precision,
  NULLIF(:'power_l3_w','')::double precision,
  NULLIF(:'power_total_w','')::double precision,
  NULLIF(:'max_power_w','')::double precision,
  NULLIF(:'temperature_c','')::double precision,
  CASE WHEN NULLIF(:'boost','') IS NULL THEN NULL ELSE NULLIF(:'boost','')::integer <> 0 END,
  NULLIF(:'boost_source','')::integer,
  NULLIF(:'boost_temp_override','')::double precision,
  NULLIF(:'outlet_mode','')::integer,
  CASE WHEN NULLIF(:'connected_l1','') IS NULL THEN NULL ELSE NULLIF(:'connected_l1','')::integer <> 0 END,
  CASE WHEN NULLIF(:'connected_l2','') IS NULL THEN NULL ELSE NULLIF(:'connected_l2','')::integer <> 0 END,
  CASE WHEN NULLIF(:'connected_l3','') IS NULL THEN NULL ELSE NULLIF(:'connected_l3','')::integer <> 0 END,
  :'raw_payload'::jsonb
);
SQL
        then
          devices_stored=$((devices_stored + 1))
        else
          log "database insert failed for AZ Router device id=${device_id:-?}"
        fi
      done < <(echo "$devices_response" | jq -c '.[]')

      log "stored ${devices_stored} AZ Router device sample(s)"
    fi
  fi

  poll_count=$((poll_count + 1))

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$interval"
done
