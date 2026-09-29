#!/usr/bin/env bash
set -u

base_interval="${READER_BASE_INTERVAL_SECONDS:-5}"
realtime_every="${SOLAX_REALTIME_EVERY_N_LOOPS:-1}"
config_every="${SOLAX_CONFIG_EVERY_N_LOOPS:-12}"
run_once="${RUN_ONCE:-false}"

log() {
  printf '%s solax_reader: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ -z "${DATABASE_URL:-}" ]]; then
  log "DATABASE_URL is not configured"
  exit 1
fi

if [[ -z "${SOLAX_URL:-}" ]]; then
  log "SOLAX_URL is not configured"
  exit 1
fi

for value_name in base_interval realtime_every config_every; do
  value="${!value_name}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    log "$value_name must be a positive integer"
    exit 1
  fi
done

log "starting; endpoint=${SOLAX_URL}; base_interval=${base_interval}s; realtime_every=${realtime_every}; config_every=${config_every}"
poll_count=0

while true; do
  if (( poll_count % realtime_every == 0 )); then
    measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "${SOLAX_PASSWORD:-}" ]]; then
    log "SOLAX_PASSWORD not configured; waiting"
  else
    response="$(
      curl -fsS --max-time 4 \
        --data "optType=ReadRealTimeData" \
        --data-urlencode "pwd=${SOLAX_PASSWORD}" \
        -X POST "${SOLAX_URL}" 2>/dev/null || true
    )"

    if [[ -z "$response" ]]; then
      log "no response from inverter"
    elif ! echo "$response" | jq -e '.Data | type == "array" and length > 170' >/dev/null 2>&1; then
      log "response received but payload is not recognized as expected SolaX realtime data"
    else
      # Mapping inherited from the field-tested rpiSolaxPT implementation.
      # Sign conventions:
      #   grid_power_w    > 0 = export to grid, < 0 = import from grid
      #   battery_power_w > 0 = charging,       < 0 = discharging
      mapped="$(
        echo "$response" | jq -c '
          def s16(x):
            if (x // 0) >= 32768 then (x // 0) - 65536 else (x // 0) end;
          def u32(hi; lo):
            ((hi // 0) * 65536) + (lo // 0);
          def inverter_state(mode):
            {
              "0": "Waiting",
              "1": "Checking",
              "2": "Normal",
              "3": "Fault",
              "4": "Permanent Fault",
              "5": "Upgrading",
              "6": "EPS Checking/Waiting",
              "7": "EPS",
              "8": "Self Testing",
              "9": "Idle",
              "10": "Standby"
            }[(mode | tostring)] // ("Unknown(" + (mode | tostring) + ")");

          {
            serial_number:               (.sn // null),
            api_version:                 (.ver // null),
            inverter_type:               (.type // null),

            pv1_power_w:                 (.Data[14] // 0),
            pv2_power_w:                 (.Data[15] // 0),
            pv_total_power_w:            ((.Data[14] // 0) + (.Data[15] // 0)),
            production_dc_today_kwh:     ((.Data[82] // 0) / 10),
            yield_ac_today_kwh:          ((.Data[70] // 0) / 10),

            grid_power_w:                s16(.Data[34] // 0),
            grid_import_today_kwh:       (u32(.Data[93] // 0; .Data[92] // 0) / 100),
            grid_export_today_kwh:       (u32(.Data[91] // 0; .Data[90] // 0) / 100),

            house_power_w:               s16(.Data[47] // 0),

            battery_power_w:             s16(.Data[41] // 0),
            battery_current_a:           (s16(.Data[40] // 0) / 100),
            battery_soc_pct:             (.Data[103] // 0),
            battery_charge_today_kwh:   ((.Data[79] // 0) / 10),
            battery_discharge_today_kwh:((.Data[78] // 0) / 10),
            battery_stored_energy_kwh:  ((.Data[106] // 0) / 10),
            battery_temp_c:              s16(.Data[105] // 0),
            battery_voltage_v:           (u32(.Data[170] // 0; .Data[169] // 0) / 100),

            inverter_power_w:            s16(.Data[9] // 0),
            inverter_temp_c:             (.Data[54] // 0),
            inverter_mode:               (.Data[19] // 0),
            inverter_state:              inverter_state(.Data[19] // 0),

            inverter_l1_power_w:             s16(.Data[6] // 0),
            inverter_l2_power_w:             s16(.Data[7] // 0),
            inverter_l3_power_w:             s16(.Data[8] // 0),

            pv1_voltage_v:               ((.Data[10] // 0) / 10),
            pv2_voltage_v:               ((.Data[11] // 0) / 10),
            pv1_current_a:               ((.Data[12] // 0) / 10),
            pv2_current_a:               ((.Data[13] // 0) / 10),

            grid_l1_voltage_v:           ((.Data[0] // 0) / 10),
            grid_l2_voltage_v:           ((.Data[1] // 0) / 10),
            grid_l3_voltage_v:           ((.Data[2] // 0) / 10),
            inverter_l1_current_a:           (s16(.Data[3] // 0) / 10),
            inverter_l2_current_a:           (s16(.Data[4] // 0) / 10),
            inverter_l3_current_a:           (s16(.Data[5] // 0) / 10),

            grid_frequency_l1_hz:        ((.Data[16] // 0) / 100),
            grid_frequency_l2_hz:        ((.Data[17] // 0) / 100),
            grid_frequency_l3_hz:        ((.Data[18] // 0) / 100)
          }
        '
      )"

      IFS=$'\t' read -r \
        serial_number api_version inverter_type \
        pv1_power_w pv2_power_w pv_total_power_w \
        production_dc_today_kwh yield_ac_today_kwh \
        grid_power_w grid_import_today_kwh grid_export_today_kwh \
        house_power_w \
        battery_power_w battery_current_a battery_soc_pct battery_charge_today_kwh battery_discharge_today_kwh battery_stored_energy_kwh battery_temp_c battery_voltage_v \
        inverter_power_w inverter_temp_c inverter_mode inverter_state \
        inverter_l1_power_w inverter_l2_power_w inverter_l3_power_w \
        pv1_voltage_v pv2_voltage_v pv1_current_a pv2_current_a \
        grid_l1_voltage_v grid_l2_voltage_v grid_l3_voltage_v \
        inverter_l1_current_a inverter_l2_current_a inverter_l3_current_a \
        grid_frequency_l1_hz grid_frequency_l2_hz grid_frequency_l3_hz \
        <<< "$(
          echo "$mapped" | jq -r '
            [
              .serial_number, .api_version, .inverter_type,
              .pv1_power_w, .pv2_power_w, .pv_total_power_w,
              .production_dc_today_kwh, .yield_ac_today_kwh,
              .grid_power_w, .grid_import_today_kwh, .grid_export_today_kwh,
              .house_power_w,
              .battery_power_w, .battery_current_a, .battery_soc_pct, .battery_charge_today_kwh,
              .battery_discharge_today_kwh, .battery_stored_energy_kwh, .battery_temp_c, .battery_voltage_v,
              .inverter_power_w, .inverter_temp_c, .inverter_mode, .inverter_state,
              .inverter_l1_power_w, .inverter_l2_power_w, .inverter_l3_power_w,
              .pv1_voltage_v, .pv2_voltage_v, .pv1_current_a, .pv2_current_a,
              .grid_l1_voltage_v, .grid_l2_voltage_v, .grid_l3_voltage_v,
              .inverter_l1_current_a, .inverter_l2_current_a, .inverter_l3_current_a,
              .grid_frequency_l1_hz, .grid_frequency_l2_hz, .grid_frequency_l3_hz
            ]
            | map(if . == null then "" else tostring end)
            | @tsv
          '
        )"

      compact_raw="$(echo "$response" | jq -c '.')"

      if psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
        -v measured_at="$measured_at" \
        -v serial_number="$serial_number" \
        -v api_version="$api_version" \
        -v inverter_type="$inverter_type" \
        -v pv1_power_w="$pv1_power_w" \
        -v pv2_power_w="$pv2_power_w" \
        -v pv_total_power_w="$pv_total_power_w" \
        -v production_dc_today_kwh="$production_dc_today_kwh" \
        -v yield_ac_today_kwh="$yield_ac_today_kwh" \
        -v grid_power_w="$grid_power_w" \
        -v grid_import_today_kwh="$grid_import_today_kwh" \
        -v grid_export_today_kwh="$grid_export_today_kwh" \
        -v house_power_w="$house_power_w" \
        -v battery_power_w="$battery_power_w" \
        -v battery_current_a="$battery_current_a" \
        -v battery_soc_pct="$battery_soc_pct" \
        -v battery_charge_today_kwh="$battery_charge_today_kwh" \
        -v battery_discharge_today_kwh="$battery_discharge_today_kwh" \
        -v battery_stored_energy_kwh="$battery_stored_energy_kwh" \
        -v battery_temp_c="$battery_temp_c" \
        -v battery_voltage_v="$battery_voltage_v" \
        -v inverter_power_w="$inverter_power_w" \
        -v inverter_temp_c="$inverter_temp_c" \
        -v inverter_mode="$inverter_mode" \
        -v inverter_state="$inverter_state" \
        -v inverter_l1_power_w="$inverter_l1_power_w" \
        -v inverter_l2_power_w="$inverter_l2_power_w" \
        -v inverter_l3_power_w="$inverter_l3_power_w" \
        -v pv1_voltage_v="$pv1_voltage_v" \
        -v pv2_voltage_v="$pv2_voltage_v" \
        -v pv1_current_a="$pv1_current_a" \
        -v pv2_current_a="$pv2_current_a" \
        -v grid_l1_voltage_v="$grid_l1_voltage_v" \
        -v grid_l2_voltage_v="$grid_l2_voltage_v" \
        -v grid_l3_voltage_v="$grid_l3_voltage_v" \
        -v inverter_l1_current_a="$inverter_l1_current_a" \
        -v inverter_l2_current_a="$inverter_l2_current_a" \
        -v inverter_l3_current_a="$inverter_l3_current_a" \
        -v grid_frequency_l1_hz="$grid_frequency_l1_hz" \
        -v grid_frequency_l2_hz="$grid_frequency_l2_hz" \
        -v grid_frequency_l3_hz="$grid_frequency_l3_hz" \
        -v raw_payload="$compact_raw" <<'SQL'
INSERT INTO solax_raw (
  measured_at,
  serial_number, api_version, inverter_type,
  pv1_power_w, pv2_power_w, pv_total_power_w,
  production_dc_today_kwh, yield_ac_today_kwh,
  grid_power_w, grid_import_today_kwh, grid_export_today_kwh,
  house_power_w,
  battery_power_w, battery_current_a, battery_soc_pct,
  battery_charge_today_kwh, battery_discharge_today_kwh,
  battery_stored_energy_kwh, battery_temp_c, battery_voltage_v,
  inverter_power_w, inverter_temp_c, inverter_mode, inverter_state,
  inverter_l1_power_w, inverter_l2_power_w, inverter_l3_power_w,
  pv1_voltage_v, pv2_voltage_v, pv1_current_a, pv2_current_a,
  grid_l1_voltage_v, grid_l2_voltage_v, grid_l3_voltage_v,
  inverter_l1_current_a, inverter_l2_current_a, inverter_l3_current_a,
  grid_frequency_l1_hz, grid_frequency_l2_hz, grid_frequency_l3_hz,
  raw_payload
) VALUES (
  :'measured_at'::timestamptz,
  NULLIF(:'serial_number',''), NULLIF(:'api_version',''), NULLIF(:'inverter_type','')::integer,
  NULLIF(:'pv1_power_w','')::double precision,
  NULLIF(:'pv2_power_w','')::double precision,
  NULLIF(:'pv_total_power_w','')::double precision,
  NULLIF(:'production_dc_today_kwh','')::double precision,
  NULLIF(:'yield_ac_today_kwh','')::double precision,
  NULLIF(:'grid_power_w','')::double precision,
  NULLIF(:'grid_import_today_kwh','')::double precision,
  NULLIF(:'grid_export_today_kwh','')::double precision,
  NULLIF(:'house_power_w','')::double precision,
  NULLIF(:'battery_power_w','')::double precision,
  NULLIF(:'battery_current_a','')::double precision,
  NULLIF(:'battery_soc_pct','')::double precision,
  NULLIF(:'battery_charge_today_kwh','')::double precision,
  NULLIF(:'battery_discharge_today_kwh','')::double precision,
  NULLIF(:'battery_stored_energy_kwh','')::double precision,
  NULLIF(:'battery_temp_c','')::double precision,
  NULLIF(:'battery_voltage_v','')::double precision,
  NULLIF(:'inverter_power_w','')::double precision,
  NULLIF(:'inverter_temp_c','')::double precision,
  NULLIF(:'inverter_mode','')::integer,
  NULLIF(:'inverter_state',''),
  NULLIF(:'inverter_l1_power_w','')::double precision,
  NULLIF(:'inverter_l2_power_w','')::double precision,
  NULLIF(:'inverter_l3_power_w','')::double precision,
  NULLIF(:'pv1_voltage_v','')::double precision,
  NULLIF(:'pv2_voltage_v','')::double precision,
  NULLIF(:'pv1_current_a','')::double precision,
  NULLIF(:'pv2_current_a','')::double precision,
  NULLIF(:'grid_l1_voltage_v','')::double precision,
  NULLIF(:'grid_l2_voltage_v','')::double precision,
  NULLIF(:'grid_l3_voltage_v','')::double precision,
  NULLIF(:'inverter_l1_current_a','')::double precision,
  NULLIF(:'inverter_l2_current_a','')::double precision,
  NULLIF(:'inverter_l3_current_a','')::double precision,
  NULLIF(:'grid_frequency_l1_hz','')::double precision,
  NULLIF(:'grid_frequency_l2_hz','')::double precision,
  NULLIF(:'grid_frequency_l3_hz','')::double precision,
  :'raw_payload'::jsonb
);
SQL
      then
        log "stored serial=${serial_number:-?} pv=${pv_total_power_w:-?}W load=${house_power_w:-?}W grid=${grid_power_w:-?}W battery=${battery_power_w:-?}W soc=${battery_soc_pct:-?}% state=${inverter_state:-?}"
      else
        log "database insert failed"
      fi
    fi
  fi

  fi

  if (( poll_count % config_every == 0 )); then
    config_measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [[ -z "${SOLAX_PASSWORD:-}" ]]; then
      log "SOLAX_PASSWORD not configured; config read skipped"
    else
      config_response="$(
        curl -fsS --max-time 4 \
          --data "optType=ReadSetData" \
          --data-urlencode "pwd=${SOLAX_PASSWORD}" \
          -X POST "${SOLAX_URL}" 2>/dev/null || true
      )"

      config_data="$(
        echo "$config_response" | jq -c '
          if type == "array" then .
          elif (type == "object" and (.Data | type) == "array") then .Data
          else empty
          end
        ' 2>/dev/null || true
      )"

      if [[ -z "$config_data" ]] || ! echo "$config_data" | jq -e 'length > 190' >/dev/null 2>&1; then
        log "ReadSetData response missing or not recognized"
      else
        config_mapped="$(
          echo "$config_data" | jq -c '
            (.[27] // null) as $work_mode_code |
            {
              work_mode_code: $work_mode_code,
              work_mode:
                (if $work_mode_code == 0 then "self_use"
                 elif $work_mode_code == 2 then "backup_mode"
                 elif $work_mode_code == null then null
                 else ("unknown_" + ($work_mode_code | tostring))
                 end),
              min_soc_pct: (.[28] // null),
              charge_from_grid: (.[29] // null),
              charge_to_soc_pct: (.[30] // null),
              forced_charge_start_raw: (.[36] // null),
              forced_charge_end_raw: (.[37] // null),
              allowed_discharge_start_raw: (.[38] // null),
              allowed_discharge_end_raw: (.[39] // null),
              hot_standby_code: (.[185] // null),
              phase_unbalanced_code: (.[190] // null)
            }
          '
        )"

        IFS=$'\t' read -r \
          work_mode_code work_mode min_soc_pct charge_from_grid charge_to_soc_pct \
          forced_charge_start_raw forced_charge_end_raw \
          allowed_discharge_start_raw allowed_discharge_end_raw hot_standby_code phase_unbalanced_code \
          <<< "$(
            echo "$config_mapped" | jq -r '
              [
                .work_mode_code, .work_mode, .min_soc_pct, .charge_from_grid,
                .charge_to_soc_pct, .forced_charge_start_raw, .forced_charge_end_raw,
                .allowed_discharge_start_raw, .allowed_discharge_end_raw,
                .hot_standby_code, .phase_unbalanced_code
              ]
              | map(if . == null then "" else tostring end)
              | @tsv
            '
          )"

        if [[ "$phase_unbalanced_code" != "0" && "$phase_unbalanced_code" != "1" ]]; then
          log "unknown Phase Unbalanced code at ReadSetData[190]: ${phase_unbalanced_code:-empty}; config version skipped"
        elif config_result="$(
          psql "$DATABASE_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
            -v observed_at="$config_measured_at" \
            -v work_mode_code="$work_mode_code" \
            -v work_mode="$work_mode" \
            -v min_soc_pct="$min_soc_pct" \
            -v charge_from_grid="$charge_from_grid" \
            -v charge_to_soc_pct="$charge_to_soc_pct" \
            -v forced_charge_start_raw="$forced_charge_start_raw" \
            -v forced_charge_end_raw="$forced_charge_end_raw" \
            -v allowed_discharge_start_raw="$allowed_discharge_start_raw" \
            -v allowed_discharge_end_raw="$allowed_discharge_end_raw" \
            -v hot_standby_code="$hot_standby_code" \
            -v phase_unbalanced_code="$phase_unbalanced_code" <<'SQL'
WITH candidate AS (
  SELECT
    :'observed_at'::timestamptz AS begdat,
    NULLIF(:'work_mode_code','')::integer AS work_mode_code,
    NULLIF(:'work_mode','') AS work_mode,
    NULLIF(:'min_soc_pct','')::integer AS min_soc_pct,
    CASE
      WHEN NULLIF(:'charge_from_grid','') IS NULL THEN NULL
      ELSE NULLIF(:'charge_from_grid','')::integer <> 0
    END AS charge_from_grid,
    NULLIF(:'charge_to_soc_pct','')::integer AS charge_to_soc_pct,
    CASE WHEN NULLIF(:'forced_charge_start_raw','') IS NULL THEN NULL
      ELSE make_time(
        NULLIF(:'forced_charge_start_raw','')::integer & 255,
        (NULLIF(:'forced_charge_start_raw','')::integer >> 8) & 255,
        0
      ) END AS forced_charge_start,
    CASE WHEN NULLIF(:'forced_charge_end_raw','') IS NULL THEN NULL
      ELSE make_time(
        NULLIF(:'forced_charge_end_raw','')::integer & 255,
        (NULLIF(:'forced_charge_end_raw','')::integer >> 8) & 255,
        0
      ) END AS forced_charge_end,
    CASE WHEN NULLIF(:'allowed_discharge_start_raw','') IS NULL THEN NULL
      ELSE make_time(
        NULLIF(:'allowed_discharge_start_raw','')::integer & 255,
        (NULLIF(:'allowed_discharge_start_raw','')::integer >> 8) & 255,
        0
      ) END AS allowed_discharge_start,
    CASE WHEN NULLIF(:'allowed_discharge_end_raw','') IS NULL THEN NULL
      ELSE make_time(
        NULLIF(:'allowed_discharge_end_raw','')::integer & 255,
        (NULLIF(:'allowed_discharge_end_raw','')::integer >> 8) & 255,
        0
      ) END AS allowed_discharge_end,
    CASE NULLIF(:'hot_standby_code','')::integer
      WHEN 0 THEN TRUE
      WHEN 1 THEN FALSE
      ELSE NULL
    END AS hot_standby,
    NULLIF(:'hot_standby_code','')::integer AS hot_standby_code,
    CASE NULLIF(:'phase_unbalanced_code','')::integer
      WHEN 0 THEN FALSE
      WHEN 1 THEN TRUE
      ELSE NULL
    END AS phase_unbalanced,
    NULLIF(:'phase_unbalanced_code','')::integer AS phase_unbalanced_code
),
current AS (
  SELECT *
  FROM solax_config
  WHERE enddat IS NULL
),
needs_change AS (
  SELECT NOT EXISTS (
    SELECT 1
    FROM current c
    CROSS JOIN candidate n
    WHERE ROW(
      c.work_mode_code, c.work_mode, c.min_soc_pct,
      c.charge_from_grid, c.charge_to_soc_pct,
      c.forced_charge_start, c.forced_charge_end,
      c.allowed_discharge_start, c.allowed_discharge_end,
      c.hot_standby, c.hot_standby_code,
      c.phase_unbalanced, c.phase_unbalanced_code
    ) IS NOT DISTINCT FROM ROW(
      n.work_mode_code, n.work_mode, n.min_soc_pct,
      n.charge_from_grid, n.charge_to_soc_pct,
      n.forced_charge_start, n.forced_charge_end,
      n.allowed_discharge_start, n.allowed_discharge_end,
      n.hot_standby, n.hot_standby_code,
      n.phase_unbalanced, n.phase_unbalanced_code
    )
  ) AS value
),
closed AS (
  UPDATE solax_config
  SET enddat = (SELECT begdat FROM candidate)
  WHERE enddat IS NULL
    AND (SELECT value FROM needs_change)
  RETURNING id
)
INSERT INTO solax_config (
  begdat, enddat,
  work_mode_code, work_mode, min_soc_pct,
  charge_from_grid, charge_to_soc_pct,
  forced_charge_start, forced_charge_end,
  allowed_discharge_start, allowed_discharge_end,
  hot_standby, hot_standby_code,
  phase_unbalanced, phase_unbalanced_code
)
SELECT
  begdat, NULL,
  work_mode_code, work_mode, min_soc_pct,
  charge_from_grid, charge_to_soc_pct,
  forced_charge_start, forced_charge_end,
  allowed_discharge_start, allowed_discharge_end,
  hot_standby, hot_standby_code,
  phase_unbalanced, phase_unbalanced_code
FROM candidate
WHERE (SELECT value FROM needs_change)
RETURNING id;
SQL
        )"; then
          if [[ -n "$config_result" ]]; then
            log "configuration changed; stored new solax_config version id=$config_result phase_unbalanced=$([[ "$phase_unbalanced_code" == "1" ]] && echo enabled || echo disabled)"
          fi
        else
          log "failed to version SolaX configuration"
        fi
      fi
    fi
  fi

  poll_count=$((poll_count + 1))

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$base_interval"
done
