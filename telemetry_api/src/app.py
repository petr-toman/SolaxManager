import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from psycopg.rows import dict_row

HOST = os.getenv("TELEMETRY_API_HOST", "0.0.0.0")
PORT = int(os.getenv("TELEMETRY_API_PORT", "8000"))
STALE_AFTER_SECONDS = int(os.getenv("TELEMETRY_STALE_AFTER_SECONDS", "15"))
FORECAST_HOURS = int(os.getenv("TELEMETRY_FORECAST_HOURS", "36"))
FORECAST_PROVIDER = "open_meteo"

DB_KWARGS = {
    "host": os.getenv("PGHOST", "datastore"),
    "port": int(os.getenv("PGPORT", "5432")),
    "dbname": os.getenv("PGDATABASE", "solaxmanager"),
    "user": os.getenv("PGUSER", "solax"),
    "password": os.getenv("PGPASSWORD", ""),
    "connect_timeout": 3,
}

LATEST_SOLAX_SQL = """
SELECT
    measured_at,
    serial_number,
    api_version,
    inverter_type,
    pv1_power_w, pv2_power_w, pv_total_power_w,
    production_dc_today_kwh, yield_ac_today_kwh,
    house_power_w,
    grid_power_w, grid_import_today_kwh, grid_export_today_kwh,
    battery_power_w, battery_soc_pct, battery_voltage_v, battery_current_a,
    battery_stored_energy_kwh, battery_temp_c,
    battery_charge_today_kwh, battery_discharge_today_kwh,
    inverter_power_w, inverter_temp_c, inverter_mode, inverter_state,
    inverter_l1_power_w, inverter_l2_power_w, inverter_l3_power_w,
    grid_l1_voltage_v, grid_l2_voltage_v, grid_l3_voltage_v,
    inverter_l1_current_a, inverter_l2_current_a, inverter_l3_current_a,
    grid_frequency_l1_hz, grid_frequency_l2_hz, grid_frequency_l3_hz,
    pv1_voltage_v, pv2_voltage_v, pv1_current_a, pv2_current_a
FROM solax_raw
ORDER BY measured_at DESC
LIMIT 1
"""

LATEST_AZROUTER_SQL = """
SELECT
    measured_at,
    device_last_update,
    grid_l1_power_w, grid_l2_power_w, grid_l3_power_w, grid_total_power_w,
    grid_l1_voltage_v, grid_l2_voltage_v, grid_l3_voltage_v,
    grid_l1_current_a, grid_l2_current_a, grid_l3_current_a,
    output_0_power_w, output_1_power_w, output_2_power_w, output_3_power_w
FROM azrouter_raw
ORDER BY measured_at DESC
LIMIT 1
"""

LATEST_AZROUTER_DEVICES_SQL = """
SELECT DISTINCT ON (device_id)
    measured_at,
    device_type, device_id, priority, name, status_code, signal_db,
    serial_number, fw_version, hw_version,
    power_l1_w, power_l2_w, power_l3_w, power_total_w, max_power_w,
    temperature_c,
    boost, boost_source, boost_temp_override, outlet_mode,
    connected_l1, connected_l2, connected_l3
FROM azrouter_device_raw
ORDER BY device_id, measured_at DESC
"""

LATEST_SOLAR_FORECAST_SQL = """
SELECT
    provider,
    fetched_at,
    period_start,
    period_end,
    gti_w_m2,
    ghi_w_m2,
    cloud_cover_pct,
    temperature_c,
    precipitation_mm,
    precipitation_probability_pct,
    sunshine_duration_s,
    is_day,
    sunrise,
    sunset
FROM solar_forecast
WHERE provider = %s
  AND fetched_at = (
      SELECT max(fetched_at)
      FROM solar_forecast
      WHERE provider = %s
  )
  AND period_end > now()
ORDER BY period_start
LIMIT %s
"""


def sample_age(measured_at):
    now = datetime.now(timezone.utc)
    return max(0.0, (now - measured_at).total_seconds())


def latest_sample():
    with psycopg.connect(**DB_KWARGS, row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(LATEST_SOLAX_SQL)
            solax = cur.fetchone()

            cur.execute(LATEST_AZROUTER_SQL)
            azrouter = cur.fetchone()

            cur.execute(LATEST_AZROUTER_DEVICES_SQL)
            azrouter_devices = cur.fetchall()

            cur.execute(
                LATEST_SOLAR_FORECAST_SQL,
                (FORECAST_PROVIDER, FORECAST_PROVIDER, FORECAST_HOURS),
            )
            solar_forecast = cur.fetchall()

    if solax is None:
        return None

    data = dict(solax)
    solax_age = sample_age(solax["measured_at"])
    data["measured_at"] = solax["measured_at"].isoformat()
    data["sample_age_seconds"] = round(solax_age, 3)
    data["stale"] = solax_age > STALE_AFTER_SECONDS

    if azrouter is None:
        data["azrouter_available"] = False
        data["azrouter_stale"] = True
        data["azrouter_sample_age_seconds"] = None
        data["azrouter_measured_at"] = None
    else:
        az = dict(azrouter)
        az_age = sample_age(az["measured_at"])
        data["azrouter_available"] = True
        data["azrouter_stale"] = az_age > STALE_AFTER_SECONDS
        data["azrouter_sample_age_seconds"] = round(az_age, 3)
        data["azrouter_measured_at"] = az["measured_at"].isoformat()
        data["azrouter_device_last_update"] = (
            az["device_last_update"].isoformat()
            if az["device_last_update"] is not None
            else None
        )

        for key, value in az.items():
            if key not in {"measured_at", "device_last_update"}:
                data[f"azrouter_{key}"] = value

    status_strings = ["unpaired", "online", "offline", "error", "active"]
    devices = []
    for row in azrouter_devices:
        device = dict(row)
        age = sample_age(device["measured_at"])
        device["measured_at"] = device["measured_at"].isoformat()
        device["sample_age_seconds"] = round(age, 3)
        device["stale"] = age > STALE_AFTER_SECONDS

        code = device.get("status_code")
        if isinstance(code, int) and 0 <= code < len(status_strings):
            device["status"] = status_strings[code]
        else:
            device["status"] = None

        devices.append(device)

    data["azrouter_devices"] = devices

    if solar_forecast:
        forecast_rows = []
        for row in solar_forecast:
            item = dict(row)
            for key in ("fetched_at", "period_start", "period_end", "sunrise", "sunset"):
                value = item.get(key)
                item[key] = value.isoformat() if value is not None else None
            forecast_rows.append(item)

        latest_forecast = solar_forecast[0]
        forecast_age = sample_age(latest_forecast["fetched_at"])
        data["solar_forecast_available"] = True
        data["solar_forecast_provider"] = latest_forecast["provider"]
        data["solar_forecast_fetched_at"] = latest_forecast["fetched_at"].isoformat()
        data["solar_forecast_age_seconds"] = round(forecast_age, 3)
        data["solar_sunrise"] = (
            latest_forecast["sunrise"].isoformat()
            if latest_forecast["sunrise"] is not None
            else None
        )
        data["solar_sunset"] = (
            latest_forecast["sunset"].isoformat()
            if latest_forecast["sunset"] is not None
            else None
        )
        data["solar_forecast"] = forecast_rows
    else:
        data["solar_forecast_available"] = False
        data["solar_forecast_provider"] = FORECAST_PROVIDER
        data["solar_forecast_fetched_at"] = None
        data["solar_forecast_age_seconds"] = None
        data["solar_sunrise"] = None
        data["solar_sunset"] = None
        data["solar_forecast"] = []

    return data


class Handler(BaseHTTPRequestHandler):
    server_version = "SolaxManagerTelemetry/0.3"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/health":
            self.send_json(200, {"status": "ok"})
            return

        if path == "/api/realtime":
            try:
                sample = latest_sample()
                if sample is None:
                    self.send_json(
                        503,
                        {"status": "no_data", "message": "No SolaX samples are stored yet."},
                    )
                else:
                    self.send_json(200, {"status": "ok", "data": sample})
            except Exception as exc:
                print(f"telemetry_api: realtime query failed: {exc}", flush=True)
                self.send_json(
                    503,
                    {"status": "error", "message": "Telemetry database is unavailable."},
                )
            return

        self.send_json(404, {"status": "not_found"})


if __name__ == "__main__":
    print(
        f"telemetry_api starting on {HOST}:{PORT}; stale_after={STALE_AFTER_SECONDS}s",
        flush=True,
    )
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
