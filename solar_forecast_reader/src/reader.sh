#!/usr/bin/env bash
set -u

base_interval="${SOLAR_FORECAST_BASE_INTERVAL_SECONDS:-300}"
openmeteo_every="${OPENMETEO_EVERY_N_LOOPS:-12}"
forecast_hours="${OPENMETEO_FORECAST_HOURS:-72}"
run_once="${RUN_ONCE:-false}"

openmeteo_url="${OPENMETEO_URL:-https://api.open-meteo.com/v1/forecast}"

latitude="${SOLAR_FORECAST_LAT:-}"
longitude="${SOLAR_FORECAST_LON:-}"
panel_tilt="${SOLAR_PANEL_TILT_DEG:-}"
panel_azimuth="${SOLAR_PANEL_AZIMUTH_DEG:-}"

log() {
  printf '%s solar_forecast_reader: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

if [[ -z "${DATABASE_URL:-}" ]]; then
  log "DATABASE_URL is not configured"
  exit 1
fi

for required_name in latitude longitude panel_tilt panel_azimuth; do
  value="${!required_name}"
  if [[ -z "$value" ]] || ! is_number "$value"; then
    log "$required_name must be configured as a number"
    exit 1
  fi
done

for integer_name in base_interval openmeteo_every forecast_hours; do
  value="${!integer_name}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    log "$integer_name must be a positive integer"
    exit 1
  fi
done

if ! jq -ne --arg v "$latitude" '($v|tonumber) >= -90 and ($v|tonumber) <= 90' >/dev/null; then
  log "SOLAR_FORECAST_LAT must be between -90 and 90"
  exit 1
fi

if ! jq -ne --arg v "$longitude" '($v|tonumber) >= -180 and ($v|tonumber) <= 180' >/dev/null; then
  log "SOLAR_FORECAST_LON must be between -180 and 180"
  exit 1
fi

if ! jq -ne --arg v "$panel_tilt" '($v|tonumber) >= 0 and ($v|tonumber) <= 90' >/dev/null; then
  log "SOLAR_PANEL_TILT_DEG must be between 0 and 90"
  exit 1
fi

if ! jq -ne --arg v "$panel_azimuth" '($v|tonumber) >= -180 and ($v|tonumber) <= 180' >/dev/null; then
  log "SOLAR_PANEL_AZIMUTH_DEG must be between -180 and 180"
  exit 1
fi

poll_openmeteo() {
  local fetched_at response compact_payload inserted

  fetched_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  response="$(
    curl -fsS \
      --connect-timeout 5 \
      --max-time 20 \
      --retry 2 \
      --get "$openmeteo_url" \
      --data-urlencode "latitude=$latitude" \
      --data-urlencode "longitude=$longitude" \
      --data-urlencode "timezone=GMT" \
      --data-urlencode "timeformat=unixtime" \
      --data-urlencode "forecast_hours=$forecast_hours" \
      --data-urlencode "tilt=$panel_tilt" \
      --data-urlencode "azimuth=$panel_azimuth" \
      --data-urlencode "hourly=temperature_2m,cloud_cover,precipitation,precipitation_probability,sunshine_duration,is_day,shortwave_radiation,direct_radiation,diffuse_radiation,direct_normal_irradiance,global_tilted_irradiance" \
      --data-urlencode "daily=sunrise,sunset" \
      2>/dev/null || true
  )"

  if [[ -z "$response" ]]; then
    log "no response from Open-Meteo"
    return
  fi

  if ! echo "$response" | jq -e '
      (.hourly.time | type == "array" and length > 0) and
      (.hourly.global_tilted_irradiance | type == "array") and
      (.daily.time | type == "array") and
      (.daily.sunrise | type == "array") and
      (.daily.sunset | type == "array")
    ' >/dev/null 2>&1; then
    error_reason="$(echo "$response" | jq -r '.reason // .error // "payload shape not recognized"' 2>/dev/null || true)"
    log "Open-Meteo response invalid: ${error_reason:-payload shape not recognized}"
    return
  fi

  compact_payload="$(echo "$response" | jq -c '.')"

  if inserted="$(
    psql "$DATABASE_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
      -v fetched_at="$fetched_at" \
      -v provider="open_meteo" \
      -v requested_latitude="$latitude" \
      -v requested_longitude="$longitude" \
      -v panel_tilt="$panel_tilt" \
      -v panel_azimuth="$panel_azimuth" \
      -v payload="$compact_payload" <<'SQL'
WITH payload AS (
  SELECT
    :'payload'::jsonb AS j,
    :'provider'::text AS provider,
    :'fetched_at'::timestamptz AS fetched_at,
    :'requested_latitude'::double precision AS requested_latitude,
    :'requested_longitude'::double precision AS requested_longitude,
    :'panel_tilt'::double precision AS panel_tilt_deg,
    :'panel_azimuth'::double precision AS panel_azimuth_deg
),
hourly AS (
  SELECT
    p.*,
    (h.ordinality - 1)::integer AS idx,
    (h.value #>> '{}')::bigint AS valid_epoch
  FROM payload p
  CROSS JOIN LATERAL
    jsonb_array_elements(p.j->'hourly'->'time')
      WITH ORDINALITY AS h(value, ordinality)
),
mapped AS (
  SELECT
    h.*,
    to_timestamp(h.valid_epoch) AS valid_at,
    (
      SELECT (d.ordinality - 1)::integer
      FROM jsonb_array_elements(h.j->'daily'->'time')
        WITH ORDINALITY AS d(value, ordinality)
      WHERE (to_timestamp((d.value #>> '{}')::bigint) AT TIME ZONE 'UTC')::date
          = (to_timestamp(h.valid_epoch) AT TIME ZONE 'UTC')::date
      LIMIT 1
    ) AS day_idx
  FROM hourly h
),
inserted AS (
  INSERT INTO solar_forecast (
    provider,
    fetched_at,
    valid_at,
    period_start,
    period_end,
    requested_latitude,
    requested_longitude,
    source_latitude,
    source_longitude,
    source_elevation_m,
    panel_tilt_deg,
    panel_azimuth_deg,
    temperature_c,
    cloud_cover_pct,
    precipitation_mm,
    precipitation_probability_pct,
    sunshine_duration_s,
    is_day,
    ghi_w_m2,
    direct_radiation_w_m2,
    diffuse_radiation_w_m2,
    dni_w_m2,
    gti_w_m2,
    sunrise,
    sunset
  )
  SELECT
    provider,
    fetched_at,
    valid_at,
    valid_at - interval '1 hour',
    valid_at,
    requested_latitude,
    requested_longitude,
    NULLIF(j->>'latitude','')::double precision,
    NULLIF(j->>'longitude','')::double precision,
    NULLIF(j->>'elevation','')::double precision,
    panel_tilt_deg,
    panel_azimuth_deg,
    NULLIF(j->'hourly'->'temperature_2m'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'cloud_cover'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'precipitation'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'precipitation_probability'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'sunshine_duration'->>idx, 'null')::double precision,
    CASE
      WHEN NULLIF(j->'hourly'->'is_day'->>idx, 'null') IS NULL THEN NULL
      ELSE (j->'hourly'->'is_day'->>idx)::integer <> 0
    END,
    NULLIF(j->'hourly'->'shortwave_radiation'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'direct_radiation'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'diffuse_radiation'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'direct_normal_irradiance'->>idx, 'null')::double precision,
    NULLIF(j->'hourly'->'global_tilted_irradiance'->>idx, 'null')::double precision,
    CASE
      WHEN day_idx IS NULL
        OR NULLIF(j->'daily'->'sunrise'->>day_idx, 'null') IS NULL
      THEN NULL
      ELSE to_timestamp((j->'daily'->'sunrise'->>day_idx)::bigint)
    END,
    CASE
      WHEN day_idx IS NULL
        OR NULLIF(j->'daily'->'sunset'->>day_idx, 'null') IS NULL
      THEN NULL
      ELSE to_timestamp((j->'daily'->'sunset'->>day_idx)::bigint)
    END
  FROM mapped
  ON CONFLICT (provider, fetched_at, valid_at) DO NOTHING
  RETURNING 1
)
SELECT count(*) FROM inserted;
SQL
  )"; then
    log "Open-Meteo stored ${inserted:-0} forecast hour(s); horizon=${forecast_hours}h"
  else
    log "database insert failed for Open-Meteo forecast"
  fi
}

log "starting; base_interval=${base_interval}s; openmeteo_every=${openmeteo_every}; horizon=${forecast_hours}h"
poll_count=0

while true; do
  if (( poll_count % openmeteo_every == 0 )); then
    poll_openmeteo
  fi

  poll_count=$((poll_count + 1))

  if [[ "$run_once" == "true" || "$run_once" == "1" ]]; then
    break
  fi

  sleep "$base_interval"
done
