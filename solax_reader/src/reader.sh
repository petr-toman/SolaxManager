#!/usr/bin/env bash
set -u

interval="${POLL_INTERVAL_SECONDS:-5}"
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

log "starting; endpoint=${SOLAX_URL}; interval=${interval}s"

while true; do
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
            battery_soc_pct:             (.Data[103] // 0),
            battery_charge_today_kwh:   ((.Data[79] // 0) / 10),
            battery_discharge_today_kwh:((.Data[78] // 0) / 10),
            battery_stored_energy_kwh:        ((.Data[106] // 0) / 10),
            battery_temp_c:              (.Data[105] // 0),

            inverter_power_w:            s16(.Data[9] // 0),
            inverter_temp_c:             (.Data[54] // 0),
            inverter_mode:               (.Data[19] // 0),

            grid_l1_power_w:             s16(.Data[6] // 0),
            grid_l2_power_w:             s16(.Data[7] // 0),
            grid_l3_power_w:             s16(.Data[8] // 0),

            pv1_voltage_v:               ((.Data[10] // 0) / 10),
            pv2_voltage_v:               ((.Data[11] // 0) / 10),
            pv1_current_a:               ((.Data[12] // 0) / 10),
            pv2_current_a:               ((.Data[13] // 0) / 10),

            grid_l1_voltage_v:           ((.Data[0] // 0) / 10),
            grid_l2_voltage_v:           ((.Data[1] // 0) / 10),
            grid_l3_voltage_v:           ((.Data[2] // 0) / 10),
            grid_l1_current_a:           (s16(.Data[3] // 0) / 10),
            grid_l2_current_a:           (s16(.Data[4] // 0) / 10),
            grid_l3_current_a:           (s16(.Data[5] // 0) / 10),

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
        battery_power_w battery_soc_pct battery_charge_today_kwh battery_discharge_today_kwh battery_stored_energy_kwh battery_temp_c \
        inverter_power_w inverter_temp_c inverter_mode \
        grid_l1_power_w grid_l2_power_w grid_l3_power_w \
        pv1_voltage_v pv2_voltage_v pv1_current_a pv2_current_a \
        grid_l1_voltage_v grid_l2_voltage_v grid_l3_voltage_v \
        grid_l1_current_a grid_l2_current_a grid_l3_current_a \
        grid_frequency_l1_hz grid_frequency_l2_hz grid_frequency_l3_hz \
        <<< "$(
          echo "$mapped" | jq -r '
            [
              .serial_number, .api_version, .inverter_type,
              .pv1_power_w, .pv2_power_w, .pv_total_power_w,
              .production_dc_today_kwh, .yield_ac_today_kwh,
              .grid_power_w, .grid_import_today_kwh, .grid_export_today_kwh,
              .house_power_w,
              .battery_power_w, .battery_soc_pct, .battery_charge_today_kwh,
              .battery_discharge_today_kwh, .battery_stored_energy_kwh, .battery_temp_c,
              .inverter_power_w, .inverter_temp_c, .inverter_mode,
              .grid_l1_power_w, .grid_l2_power_w, .grid_l3_power_w,
              .pv1_voltage_v, .pv2_voltage_v, .pv1_current_a, .pv2_current_a,
              .grid_l1_voltage_v, .grid_l2_voltage_v, .grid_l3_voltage_v,
              .grid_l1_current_a, .grid_l2_current_a, .grid_l3_current_a,
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
        -v battery_soc_pct="$battery_soc_pct" \
        -v battery_charge_today_kwh="$battery_charge_today_kwh" \
        -v battery_discharge_today_kwh="$battery_discharge_today_kwh" \
        -v battery_stored_energy_kwh="$battery_stored_energy_kwh" \
        -v battery_temp_c="$battery_temp_c" \
        -v inverter_power_w="$inverter_power_w" \
        -v inverter_temp_c="$inverter_temp_c" \
        -v inverter_mode="$inverter_mode" \
        -v grid_l1_power_w="$grid_l1_power_w" \
        -v grid_l2_power_w="$grid_l2_power_w" \
        -v grid_l3_power_w="$grid_l3_power_w" \
        -v pv1_voltage_v="$pv1_voltage_v" \
        -v pv2_voltage_v="$pv2_voltage_v" \
        -v pv1_current_a="$pv1_current_a" \
        -v pv2_current_a="$pv2_current_a" \
        -v grid_l1_voltage_v="$grid_l1_voltage_v" \
        -v grid_l2_voltage_v="$grid_l2_voltage_v" \
        -v grid_l3_voltage_v="$grid_l3_voltage_v" \
        -v grid_l1_current_a="$grid_l1_current_a" \
        -v grid_l2_current_a="$grid_l2_current_a" \
        -v grid_l3_current_a="$grid_l3_current_a" \
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
  battery_power_w, battery_soc_pct,
  battery_charge_today_kwh, battery_discharge_today_kwh,
  battery_stored_energy_kwh, battery_temp_c,
  inverter_power_w, inverter_temp_c, inverter_mode,
  grid_l1_power_w, grid_l2_power_w, grid_l3_power_w,
  pv1_voltage_v, pv2_voltage_v, pv1_current_a, pv2_current_a,
  grid_l1_voltage_v, grid_l2_voltage_v, grid_l3_voltage_v,
  grid_l1_current_a, grid_l2_current_a, grid_l3_current_a,
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
  NULLIF(:'battery_soc_pct','')::double precision,
  NULLIF(:'battery_charge_today_kwh','')::double precision,
  NULLIF(:'battery_discharge_today_kwh','')::double precision,
  NULLIF(:'battery_stored_energy_kwh','')::double precision,
  NULLIF(:'battery_temp_c','')::double precision,
  NULLIF(:'inverter_power_w','')::double precision,
  NULLIF(:'inverter_temp_c','')::double precision,
  NULLIF(:'inverter_mode','')::integer,
  NULLIF(:'grid_l1_power_w','')::double precision,
  NULLIF(:'grid_l2_power_w','')::double precision,
  NULLIF(:'grid_l3_power_w','')::double precision,
  NULLIF(:'pv1_voltage_v','')::double precision,
  NULLIF(:'pv2_voltage_v','')::double precision,
  NULLIF(:'pv1_current_a','')::double precision,
  NULLIF(:'pv2_current_a','')::double precision,
  NULLIF(:'grid_l1_voltage_v','')::double precision,
  NULLIF(:'grid_l2_voltage_v','')::double precision,
  NULLIF(:'grid_l3_voltage_v','')::double precision,
  NULLIF(:'grid_l1_current_a','')::double precision,
  NULLIF(:'grid_l2_current_a','')::double precision,
  NULLIF(:'grid_l3_current_a','')::double precision,
  NULLIF(:'grid_frequency_l1_hz','')::double precision,
  NULLIF(:'grid_frequency_l2_hz','')::double precision,
  NULLIF(:'grid_frequency_l3_hz','')::double precision,
  :'raw_payload'::jsonb
);
SQL
      then
        log "stored serial=${serial_number:-?} pv=${pv_total_power_w:-?}W load=${house_power_w:-?}W grid=${grid_power_w:-?}W battery=${battery_power_w:-?}W soc=${battery_soc_pct:-?}%"
      else
        log "database insert failed"
      fi
    fi
  fi

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$interval"
done
