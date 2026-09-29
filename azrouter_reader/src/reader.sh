#!/usr/bin/env bash
set -u

base_interval="${READER_BASE_INTERVAL_SECONDS:-5}"
power_every="${AZROUTER_POWER_EVERY_N_LOOPS:-1}"
devices_every="${AZROUTER_DEVICES_EVERY_N_LOOPS:-3}"
config_every="${AZROUTER_CONFIG_EVERY_N_LOOPS:-12}"
run_once="${RUN_ONCE:-false}"

base_url="${AZROUTER_URL:-}"
power_endpoint="${base_url%/}/api/v1/power"
devices_endpoint="${base_url%/}/api/v1/devices"
settings_endpoint="${base_url%/}/api/v1/settings"

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

for value_name in base_interval power_every devices_every config_every; do
  value="${!value_name}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    log "$value_name must be a positive integer"
    exit 1
  fi
done

poll_power() {
  local measured_at response mapped compact_raw
  local grid_l1_power_w grid_l2_power_w grid_l3_power_w grid_total_power_w
  local grid_l1_voltage_v grid_l2_voltage_v grid_l3_voltage_v
  local grid_l1_current_a grid_l2_current_a grid_l3_current_a
  local output_0_power_w output_1_power_w output_2_power_w output_3_power_w
  local device_last_update_epoch

  measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  response="$(curl -fsS --max-time 4 "$power_endpoint" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    log "no response from AZ Router power endpoint"
    return
  fi

  if ! echo "$response" | jq -e '
      (.input.power | type == "array") and
      (.input.voltage | type == "array") and
      (.input.current | type == "array")
    ' >/dev/null 2>&1; then
    log "power response received but payload is not recognized"
    return
  fi

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
    log "database insert failed for AZ Router power"
  fi
}

store_device_state() {
  local device="$1"
  local measured_at="$2"
  local mapped compact_raw
  local device_type device_id priority name status_code signal_db serial_number fw_version hw_version
  local power_l1_w power_l2_w power_l3_w power_total_w max_power_w temperature_c
  local boost boost_source boost_temp_override outlet_mode connected_l1 connected_l2 connected_l3

  mapped="$(
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
      echo "$mapped" | jq -r '
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

  compact_raw="$(echo "$device" | jq -c '.')"

  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
    -v measured_at="$measured_at" \
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
    -v raw_payload="$compact_raw" <<'SQL'
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
}

version_device_config() {
  local device="$1"
  local observed_at="$2"
  local mapped result
  local device_type device_id device_name priority connected_l1 connected_l2 connected_l3
  local p1_max p1_temp p1_boost_temp p1_window_enabled p1_window_start p1_window_stop
  local p1_block_solar p1_block_battery p1_offline_only p1_ignore_cycle p1_boost_mode
  local p2_max p2_temp p2_boost_temp p2_window_enabled p2_window_start p2_window_stop
  local p2_block_solar p2_block_battery p2_offline_only p2_ignore_cycle p2_boost_mode

  device_type="$(echo "$device" | jq -r '.deviceType // ""')"
  [[ "$device_type" == "1" ]] || return 0

  mapped="$(
    echo "$device" | jq -c '
      {
        device_type: (.deviceType // null),
        device_id: (.common.id // null),
        device_name: (.common.name // null),
        priority: (.common.priority // null),
        connected_l1: (.power.connectedPhase[0] // null),
        connected_l2: (.power.connectedPhase[1] // null),
        connected_l3: (.power.connectedPhase[2] // null),

        p1_max: (.settings[0].power.max // null),
        p1_temp: (.settings[0].power.targetTemperature // null),
        p1_boost_temp: (.settings[0].power.targetTemperatureBoost // null),
        p1_window_enabled: (.settings[0].power.allowed_solar_heating_time.enabled // null),
        p1_window_start: (.settings[0].power.allowed_solar_heating_time.start // null),
        p1_window_stop: (.settings[0].power.allowed_solar_heating_time.stop // null),
        p1_block_solar: (.settings[0].power.block_solar_heating // null),
        p1_block_battery: (.settings[0].power.block_heating_from_battery // null),
        p1_offline_only: (.settings[0].power.offline_only // null),
        p1_ignore_cycle: (.settings[0].power.ignore_cycle // null),
        p1_boost_mode: (.settings[0].boost.mode // null),

        p2_max: (.settings[1].power.max // null),
        p2_temp: (.settings[1].power.targetTemperature // null),
        p2_boost_temp: (.settings[1].power.targetTemperatureBoost // null),
        p2_window_enabled: (.settings[1].power.allowed_solar_heating_time.enabled // null),
        p2_window_start: (.settings[1].power.allowed_solar_heating_time.start // null),
        p2_window_stop: (.settings[1].power.allowed_solar_heating_time.stop // null),
        p2_block_solar: (.settings[1].power.block_solar_heating // null),
        p2_block_battery: (.settings[1].power.block_heating_from_battery // null),
        p2_offline_only: (.settings[1].power.offline_only // null),
        p2_ignore_cycle: (.settings[1].power.ignore_cycle // null),
        p2_boost_mode: (.settings[1].boost.mode // null)
      }
    '
  )"

  IFS=$'\t' read -r \
    device_type device_id device_name priority connected_l1 connected_l2 connected_l3 \
    p1_max p1_temp p1_boost_temp p1_window_enabled p1_window_start p1_window_stop \
    p1_block_solar p1_block_battery p1_offline_only p1_ignore_cycle p1_boost_mode \
    p2_max p2_temp p2_boost_temp p2_window_enabled p2_window_start p2_window_stop \
    p2_block_solar p2_block_battery p2_offline_only p2_ignore_cycle p2_boost_mode \
    <<< "$(
      echo "$mapped" | jq -r '
        [
          .device_type, .device_id, .device_name, .priority,
          .connected_l1, .connected_l2, .connected_l3,
          .p1_max, .p1_temp, .p1_boost_temp, .p1_window_enabled,
          .p1_window_start, .p1_window_stop, .p1_block_solar, .p1_block_battery,
          .p1_offline_only, .p1_ignore_cycle, .p1_boost_mode,
          .p2_max, .p2_temp, .p2_boost_temp, .p2_window_enabled,
          .p2_window_start, .p2_window_stop, .p2_block_solar, .p2_block_battery,
          .p2_offline_only, .p2_ignore_cycle, .p2_boost_mode
        ]
        | map(if . == null then "" else tostring end)
        | @tsv
      '
    )"

  if [[ -z "$device_id" ]]; then
    log "device configuration skipped because common.id is missing"
    return
  fi

  if result="$(
    psql "$DATABASE_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
      -v observed_at="$observed_at" \
      -v device_type="$device_type" -v device_id="$device_id" -v device_name="$device_name" -v priority="$priority" \
      -v connected_l1="$connected_l1" -v connected_l2="$connected_l2" -v connected_l3="$connected_l3" \
      -v p1_max="$p1_max" -v p1_temp="$p1_temp" -v p1_boost_temp="$p1_boost_temp" \
      -v p1_window_enabled="$p1_window_enabled" -v p1_window_start="$p1_window_start" -v p1_window_stop="$p1_window_stop" \
      -v p1_block_solar="$p1_block_solar" -v p1_block_battery="$p1_block_battery" \
      -v p1_offline_only="$p1_offline_only" -v p1_ignore_cycle="$p1_ignore_cycle" -v p1_boost_mode="$p1_boost_mode" \
      -v p2_max="$p2_max" -v p2_temp="$p2_temp" -v p2_boost_temp="$p2_boost_temp" \
      -v p2_window_enabled="$p2_window_enabled" -v p2_window_start="$p2_window_start" -v p2_window_stop="$p2_window_stop" \
      -v p2_block_solar="$p2_block_solar" -v p2_block_battery="$p2_block_battery" \
      -v p2_offline_only="$p2_offline_only" -v p2_ignore_cycle="$p2_ignore_cycle" -v p2_boost_mode="$p2_boost_mode" <<'SQL'
WITH candidate AS (
  SELECT
    :'observed_at'::timestamptz AS begdat,
    NULLIF(:'device_type','')::integer AS device_type,
    NULLIF(:'device_name','') AS device_name,
    NULLIF(:'priority','')::integer AS priority,
    CASE WHEN NULLIF(:'connected_l1','') IS NULL THEN NULL ELSE NULLIF(:'connected_l1','')::integer <> 0 END AS connected_l1,
    CASE WHEN NULLIF(:'connected_l2','') IS NULL THEN NULL ELSE NULLIF(:'connected_l2','')::integer <> 0 END AS connected_l2,
    CASE WHEN NULLIF(:'connected_l3','') IS NULL THEN NULL ELSE NULLIF(:'connected_l3','')::integer <> 0 END AS connected_l3,

    NULLIF(:'p1_max','')::integer AS p1_max,
    NULLIF(:'p1_temp','')::integer AS p1_temp,
    NULLIF(:'p1_boost_temp','')::integer AS p1_boost_temp,
    CASE WHEN NULLIF(:'p1_window_enabled','') IS NULL THEN NULL ELSE NULLIF(:'p1_window_enabled','')::integer <> 0 END AS p1_window_enabled,
    CASE WHEN NULLIF(:'p1_window_start','') IS NULL THEN NULL ELSE time '00:00' + NULLIF(:'p1_window_start','')::integer * interval '1 minute' END AS p1_window_start,
    CASE WHEN NULLIF(:'p1_window_stop','') IS NULL THEN NULL ELSE time '00:00' + NULLIF(:'p1_window_stop','')::integer * interval '1 minute' END AS p1_window_stop,
    CASE WHEN NULLIF(:'p1_block_solar','') IS NULL THEN NULL ELSE NULLIF(:'p1_block_solar','')::integer <> 0 END AS p1_block_solar,
    CASE WHEN NULLIF(:'p1_block_battery','') IS NULL THEN NULL ELSE NULLIF(:'p1_block_battery','')::integer <> 0 END AS p1_block_battery,
    CASE WHEN NULLIF(:'p1_offline_only','') IS NULL THEN NULL ELSE NULLIF(:'p1_offline_only','')::integer <> 0 END AS p1_offline_only,
    CASE WHEN NULLIF(:'p1_ignore_cycle','') IS NULL THEN NULL ELSE NULLIF(:'p1_ignore_cycle','')::integer <> 0 END AS p1_ignore_cycle,
    NULLIF(:'p1_boost_mode','')::integer AS p1_boost_mode,

    NULLIF(:'p2_max','')::integer AS p2_max,
    NULLIF(:'p2_temp','')::integer AS p2_temp,
    NULLIF(:'p2_boost_temp','')::integer AS p2_boost_temp,
    CASE WHEN NULLIF(:'p2_window_enabled','') IS NULL THEN NULL ELSE NULLIF(:'p2_window_enabled','')::integer <> 0 END AS p2_window_enabled,
    CASE WHEN NULLIF(:'p2_window_start','') IS NULL THEN NULL ELSE time '00:00' + NULLIF(:'p2_window_start','')::integer * interval '1 minute' END AS p2_window_start,
    CASE WHEN NULLIF(:'p2_window_stop','') IS NULL THEN NULL ELSE time '00:00' + NULLIF(:'p2_window_stop','')::integer * interval '1 minute' END AS p2_window_stop,
    CASE WHEN NULLIF(:'p2_block_solar','') IS NULL THEN NULL ELSE NULLIF(:'p2_block_solar','')::integer <> 0 END AS p2_block_solar,
    CASE WHEN NULLIF(:'p2_block_battery','') IS NULL THEN NULL ELSE NULLIF(:'p2_block_battery','')::integer <> 0 END AS p2_block_battery,
    CASE WHEN NULLIF(:'p2_offline_only','') IS NULL THEN NULL ELSE NULLIF(:'p2_offline_only','')::integer <> 0 END AS p2_offline_only,
    CASE WHEN NULLIF(:'p2_ignore_cycle','') IS NULL THEN NULL ELSE NULLIF(:'p2_ignore_cycle','')::integer <> 0 END AS p2_ignore_cycle,
    NULLIF(:'p2_boost_mode','')::integer AS p2_boost_mode
),
current AS (
  SELECT *
  FROM azrouter_config
  WHERE scope = 'device'
    AND device_id = NULLIF(:'device_id','')::integer
    AND enddat IS NULL
),
needs_change AS (
  SELECT NOT EXISTS (
    SELECT 1
    FROM current c
    CROSS JOIN candidate n
    WHERE ROW(
      c.device_type, c.device_name, c.priority,
      c.connected_l1, c.connected_l2, c.connected_l3,
      c.profile1_max_power_w, c.profile1_target_temperature_c, c.profile1_target_boost_temperature_c,
      c.profile1_solar_window_enabled, c.profile1_solar_window_start, c.profile1_solar_window_stop,
      c.profile1_block_solar_heating, c.profile1_block_heating_from_battery,
      c.profile1_offline_only, c.profile1_ignore_cycle, c.profile1_boost_mode,
      c.profile2_max_power_w, c.profile2_target_temperature_c, c.profile2_target_boost_temperature_c,
      c.profile2_solar_window_enabled, c.profile2_solar_window_start, c.profile2_solar_window_stop,
      c.profile2_block_solar_heating, c.profile2_block_heating_from_battery,
      c.profile2_offline_only, c.profile2_ignore_cycle, c.profile2_boost_mode
    ) IS NOT DISTINCT FROM ROW(
      n.device_type, n.device_name, n.priority,
      n.connected_l1, n.connected_l2, n.connected_l3,
      n.p1_max, n.p1_temp, n.p1_boost_temp,
      n.p1_window_enabled, n.p1_window_start, n.p1_window_stop,
      n.p1_block_solar, n.p1_block_battery,
      n.p1_offline_only, n.p1_ignore_cycle, n.p1_boost_mode,
      n.p2_max, n.p2_temp, n.p2_boost_temp,
      n.p2_window_enabled, n.p2_window_start, n.p2_window_stop,
      n.p2_block_solar, n.p2_block_battery,
      n.p2_offline_only, n.p2_ignore_cycle, n.p2_boost_mode
    )
  ) AS value
),
closed AS (
  UPDATE azrouter_config
  SET enddat = (SELECT begdat FROM candidate)
  WHERE scope = 'device'
    AND device_id = NULLIF(:'device_id','')::integer
    AND enddat IS NULL
    AND (SELECT value FROM needs_change)
  RETURNING id
)
INSERT INTO azrouter_config (
  scope, device_id, begdat, enddat,
  device_type, device_name, priority,
  connected_l1, connected_l2, connected_l3,
  profile1_max_power_w, profile1_target_temperature_c, profile1_target_boost_temperature_c,
  profile1_solar_window_enabled, profile1_solar_window_start, profile1_solar_window_stop,
  profile1_block_solar_heating, profile1_block_heating_from_battery,
  profile1_offline_only, profile1_ignore_cycle, profile1_boost_mode,
  profile2_max_power_w, profile2_target_temperature_c, profile2_target_boost_temperature_c,
  profile2_solar_window_enabled, profile2_solar_window_start, profile2_solar_window_stop,
  profile2_block_solar_heating, profile2_block_heating_from_battery,
  profile2_offline_only, profile2_ignore_cycle, profile2_boost_mode
)
SELECT
  'device', NULLIF(:'device_id','')::integer, begdat, NULL,
  device_type, device_name, priority,
  connected_l1, connected_l2, connected_l3,
  p1_max, p1_temp, p1_boost_temp,
  p1_window_enabled, p1_window_start, p1_window_stop,
  p1_block_solar, p1_block_battery,
  p1_offline_only, p1_ignore_cycle, p1_boost_mode,
  p2_max, p2_temp, p2_boost_temp,
  p2_window_enabled, p2_window_start, p2_window_stop,
  p2_block_solar, p2_block_battery,
  p2_offline_only, p2_ignore_cycle, p2_boost_mode
FROM candidate
WHERE (SELECT value FROM needs_change)
RETURNING id;
SQL
  )"; then
    if [[ -n "$result" ]]; then
      log "device config changed; device_id=$device_id version_id=$result"
    fi
  else
    log "failed to version AZ Router device config id=$device_id"
  fi
}

poll_devices() {
  local store_state="$1"
  local store_config="$2"
  local measured_at response stored device

  measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  response="$(curl -fsS --max-time 4 "$devices_endpoint" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    log "no response from AZ Router devices endpoint"
    return
  fi

  if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "devices response received but payload is not an array"
    return
  fi

  stored=0
  while IFS= read -r device; do
    [[ -z "$device" ]] && continue

    if [[ "$store_state" == "true" ]]; then
      if store_device_state "$device" "$measured_at"; then
        stored=$((stored + 1))
      else
        log "database insert failed for AZ Router device state"
      fi
    fi

    if [[ "$store_config" == "true" ]]; then
      version_device_config "$device" "$measured_at"
    fi
  done < <(echo "$response" | jq -c '.[]')

  if [[ "$store_state" == "true" ]]; then
    log "stored $stored AZ Router device sample(s)"
  fi
}

version_router_config() {
  local observed_at response target_power_w result

  observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  response="$(curl -fsS --max-time 4 "$settings_endpoint" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    log "no response from AZ Router settings endpoint; router config skipped"
    return
  fi

  target_power_w="$(echo "$response" | jq -r '.regulation.target_power_w // empty' 2>/dev/null || true)"
  if [[ -z "$target_power_w" ]]; then
    log "AZ Router settings response has no mapped regulation.target_power_w; router config skipped"
    return
  fi

  if result="$(
    psql "$DATABASE_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
      -v observed_at="$observed_at" \
      -v target_power_w="$target_power_w" <<'SQL'
WITH candidate AS (
  SELECT
    :'observed_at'::timestamptz AS begdat,
    NULLIF(:'target_power_w','')::integer AS master_target_power_w
),
current AS (
  SELECT *
  FROM azrouter_config
  WHERE scope = 'router'
    AND device_id = 0
    AND enddat IS NULL
),
needs_change AS (
  SELECT NOT EXISTS (
    SELECT 1
    FROM current c
    CROSS JOIN candidate n
    WHERE c.master_target_power_w IS NOT DISTINCT FROM n.master_target_power_w
  ) AS value
),
closed AS (
  UPDATE azrouter_config
  SET enddat = (SELECT begdat FROM candidate)
  WHERE scope = 'router'
    AND device_id = 0
    AND enddat IS NULL
    AND (SELECT value FROM needs_change)
  RETURNING id
)
INSERT INTO azrouter_config (
  scope, device_id, begdat, enddat, master_target_power_w
)
SELECT
  'router', 0, begdat, NULL, master_target_power_w
FROM candidate
WHERE (SELECT value FROM needs_change)
RETURNING id;
SQL
  )"; then
    if [[ -n "$result" ]]; then
      log "router config changed; stored azrouter_config version id=$result"
    fi
  else
    log "failed to version AZ Router router config"
  fi
}

log "starting; base_interval=${base_interval}s; power_every=${power_every}; devices_every=${devices_every}; config_every=${config_every}"
poll_count=0

while true; do
  power_due=false
  devices_due=false
  config_due=false

  (( poll_count % power_every == 0 )) && power_due=true
  (( poll_count % devices_every == 0 )) && devices_due=true
  (( poll_count % config_every == 0 )) && config_due=true

  if [[ "$power_due" == "true" ]]; then
    poll_power
  fi

  if [[ "$devices_due" == "true" || "$config_due" == "true" ]]; then
    poll_devices "$devices_due" "$config_due"
  fi

  if [[ "$config_due" == "true" ]]; then
    version_router_config
  fi

  poll_count=$((poll_count + 1))

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$base_interval"
done
