import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from psycopg.rows import dict_row

HOST = os.getenv("TELEMETRY_API_HOST", "0.0.0.0")
PORT = int(os.getenv("TELEMETRY_API_PORT", "8000"))
STALE_AFTER_SECONDS = int(os.getenv("TELEMETRY_STALE_AFTER_SECONDS", "15"))

DB_KWARGS = {
    "host": os.getenv("PGHOST", "datastore"),
    "port": int(os.getenv("PGPORT", "5432")),
    "dbname": os.getenv("PGDATABASE", "solaxmanager"),
    "user": os.getenv("PGUSER", "solax"),
    "password": os.getenv("PGPASSWORD", ""),
    "connect_timeout": 3,
}

LATEST_SQL = """
SELECT
    measured_at,
    serial_number,
    api_version,
    inverter_type,

    pv1_power_w,
    pv2_power_w,
    pv_total_power_w,
    production_dc_today_kwh,
    yield_ac_today_kwh,

    house_power_w,

    grid_power_w,
    grid_import_today_kwh,
    grid_export_today_kwh,

    battery_power_w,
    battery_soc_pct,
    battery_voltage_v,
    battery_current_a,
    battery_stored_energy_kwh,
    battery_temp_c,
    battery_charge_today_kwh,
    battery_discharge_today_kwh,

    inverter_power_w,
    inverter_temp_c,
    inverter_mode,
    inverter_state,

    grid_l1_power_w,
    grid_l2_power_w,
    grid_l3_power_w,
    grid_l1_voltage_v,
    grid_l2_voltage_v,
    grid_l3_voltage_v,
    grid_l1_current_a,
    grid_l2_current_a,
    grid_l3_current_a,
    grid_frequency_l1_hz,
    grid_frequency_l2_hz,
    grid_frequency_l3_hz,

    pv1_voltage_v,
    pv2_voltage_v,
    pv1_current_a,
    pv2_current_a
FROM solax_raw
ORDER BY measured_at DESC
LIMIT 1
"""


def latest_sample():
    with psycopg.connect(**DB_KWARGS, row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(LATEST_SQL)
            row = cur.fetchone()

    if row is None:
        return None

    measured_at = row["measured_at"]
    now = datetime.now(timezone.utc)
    age_seconds = max(0.0, (now - measured_at).total_seconds())

    data = dict(row)
    data["measured_at"] = measured_at.isoformat()
    data["sample_age_seconds"] = round(age_seconds, 3)
    data["stale"] = age_seconds > STALE_AFTER_SECONDS
    return data


class Handler(BaseHTTPRequestHandler):
    server_version = "SolaxManagerTelemetry/0.1"

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
