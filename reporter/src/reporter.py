import os
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import psycopg
from psycopg.rows import dict_row


REPORT_INTERVAL_SECONDS = int(os.getenv("REPORT_INTERVAL_SECONDS", "60"))
RAW_RETENTION_DAYS = int(os.getenv("RAW_RETENTION_DAYS", "30"))
MAX_INTEGRATION_GAP_SECONDS = int(
    os.getenv("REPORTER_MAX_INTEGRATION_GAP_SECONDS", "120")
)
RECALCULATE_PERIODS = int(os.getenv("REPORTER_RECALCULATE_PERIODS", "8"))
DATABASE_URL = os.getenv("DATABASE_URL", "")

BUCKET_SECONDS = 15 * 60
BUCKET = timedelta(seconds=BUCKET_SECONDS)

SOLAX_POWER_FIELDS = (
    "pv_total_power_w",
    "house_power_w",
    "grid_power_w",
    "battery_power_w",
    "inverter_l1_power_w",
    "inverter_l2_power_w",
    "inverter_l3_power_w",
)

SOLAX_COUNTER_FIELDS = (
    "production_dc_today_kwh",
    "yield_ac_today_kwh",
    "grid_import_today_kwh",
    "grid_export_today_kwh",
    "battery_charge_today_kwh",
    "battery_discharge_today_kwh",
)

AZ_POWER_FIELDS = (
    "grid_l1_power_w",
    "grid_l2_power_w",
    "grid_l3_power_w",
)


def log(message):
    print(f"{datetime.now(timezone.utc).isoformat()} reporter: {message}", flush=True)


def floor_bucket(ts):
    epoch = int(ts.timestamp())
    return datetime.fromtimestamp(
        epoch - (epoch % BUCKET_SECONDS),
        tz=timezone.utc,
    )


def iter_buckets(start, end):
    current = start
    while current < end:
        yield current
        current += BUCKET


def interpolate(v0, v1, fraction):
    if v0 is None or v1 is None:
        return None
    return float(v0) + (float(v1) - float(v0)) * fraction


def trapezoid_kwh(v0, v1, seconds):
    if v0 is None or v1 is None or seconds <= 0:
        return 0.0
    return ((float(v0) + float(v1)) / 2.0) * seconds / 3_600_000.0


def split_signed_kwh(v0, v1, seconds):
    """Integrate a linear signed segment as separate positive/negative energy."""
    if v0 is None or v1 is None or seconds <= 0:
        return 0.0, 0.0

    a = float(v0)
    b = float(v1)

    if a >= 0.0 and b >= 0.0:
        return trapezoid_kwh(a, b, seconds), 0.0

    if a <= 0.0 and b <= 0.0:
        return 0.0, trapezoid_kwh(-a, -b, seconds)

    # Linear interpolation gives the exact zero-crossing fraction.
    zero_fraction = -a / (b - a)
    first_seconds = seconds * zero_fraction
    second_seconds = seconds - first_seconds

    if a < 0.0:
        negative = (abs(a) / 2.0) * first_seconds / 3_600_000.0
        positive = (b / 2.0) * second_seconds / 3_600_000.0
    else:
        positive = (a / 2.0) * first_seconds / 3_600_000.0
        negative = (abs(b) / 2.0) * second_seconds / 3_600_000.0

    return positive, negative


def quality_for_bucket(rows, bucket_start, bucket_end):
    inside = [row for row in rows if bucket_start <= row["measured_at"] < bucket_end]
    sample_count = len(inside)

    candidate_gaps = []

    # Gaps of actual sample pairs whose segment overlaps this bucket.
    for left, right in zip(rows, rows[1:]):
        t0 = left["measured_at"]
        t1 = right["measured_at"]
        if t1 <= bucket_start or t0 >= bucket_end or t1 <= t0:
            continue
        candidate_gaps.append((t1 - t0).total_seconds())

    # Also expose uncovered bucket edges when the neighbouring sample is absent
    # from the query window. This prevents a five-minute missing prefix/suffix
    # from looking like a healthy 5-second max gap.
    if inside:
        candidate_gaps.append((inside[0]["measured_at"] - bucket_start).total_seconds())
        candidate_gaps.append((bucket_end - inside[-1]["measured_at"]).total_seconds())
    else:
        candidate_gaps.append(float(BUCKET_SECONDS))

    return sample_count, max(candidate_gaps), inside


def integrate_rows(rows, range_start, range_end, fields, split_fields):
    """Integrate linearly interpolated sample segments into canonical buckets."""
    result = defaultdict(lambda: defaultdict(float))
    split_fields = set(split_fields)

    for left, right in zip(rows, rows[1:]):
        t0 = left["measured_at"]
        t1 = right["measured_at"]
        if t1 <= t0:
            continue

        gap_seconds = (t1 - t0).total_seconds()
        if gap_seconds > MAX_INTEGRATION_GAP_SECONDS:
            continue
        if t1 <= range_start or t0 >= range_end:
            continue

        segment_start = max(t0, range_start)
        segment_end = min(t1, range_end)
        if segment_end <= segment_start:
            continue

        bucket_start = floor_bucket(segment_start)

        while bucket_start < segment_end:
            bucket_end = bucket_start + BUCKET
            part_start = max(segment_start, bucket_start)
            part_end = min(segment_end, bucket_end)

            if part_end > part_start:
                f0 = (part_start - t0).total_seconds() / gap_seconds
                f1 = (part_end - t0).total_seconds() / gap_seconds
                seconds = (part_end - part_start).total_seconds()

                result[bucket_start]["__coverage_seconds"] += seconds

                for field in fields:
                    v0 = interpolate(left.get(field), right.get(field), f0)
                    v1 = interpolate(left.get(field), right.get(field), f1)

                    if field in split_fields:
                        positive, negative = split_signed_kwh(v0, v1, seconds)
                        result[bucket_start][field + "__positive"] += positive
                        result[bucket_start][field + "__negative"] += negative
                    else:
                        result[bucket_start][field] += trapezoid_kwh(v0, v1, seconds)

            bucket_start = bucket_end

    return result


def read_rows(conn, table, fields, start, end):
    select_fields = ", ".join(fields)
    sql = f"""
        SELECT measured_at, {select_fields}
        FROM {table}
        WHERE measured_at >= %s
          AND measured_at <= %s
        ORDER BY measured_at
    """
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, (start, end))
        return cur.fetchall()


def earliest_raw_time(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT LEAST(
                (SELECT min(measured_at) FROM solax_raw),
                (SELECT min(measured_at) FROM azrouter_raw)
            )
            """
        )
        return cur.fetchone()[0]


def latest_energy_period(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT max(period_start) FROM energy_15m")
        return cur.fetchone()[0]


def counter_value(row, field):
    if row is None:
        return None
    value = row.get(field)
    return float(value) if value is not None else None


def add_if_all(*values):
    if any(value is None for value in values):
        return None
    return sum(values)


def source_value(bucket, field, available):
    return bucket[field] if available else None


def calculate_range(conn, start, end):
    query_start = start - timedelta(seconds=MAX_INTEGRATION_GAP_SECONDS)
    query_end = end + timedelta(seconds=MAX_INTEGRATION_GAP_SECONDS)

    solax_rows = read_rows(
        conn,
        "solax_raw",
        SOLAX_POWER_FIELDS + SOLAX_COUNTER_FIELDS,
        query_start,
        query_end,
    )
    az_rows = read_rows(
        conn,
        "azrouter_raw",
        AZ_POWER_FIELDS,
        query_start,
        query_end,
    )

    solax_energy = integrate_rows(
        solax_rows,
        start,
        end,
        SOLAX_POWER_FIELDS,
        split_fields=("grid_power_w", "battery_power_w"),
    )
    az_energy = integrate_rows(
        az_rows,
        start,
        end,
        AZ_POWER_FIELDS,
        split_fields=AZ_POWER_FIELDS,
    )

    rows_to_write = []

    for period_start in iter_buckets(start, end):
        period_end = period_start + BUCKET

        solax_count, solax_max_gap, solax_inside = quality_for_bucket(
            solax_rows, period_start, period_end
        )
        az_count, az_max_gap, _ = quality_for_bucket(
            az_rows, period_start, period_end
        )

        first_solax = solax_inside[0] if solax_inside else None
        last_solax = solax_inside[-1] if solax_inside else None

        se = solax_energy[period_start]
        ae = az_energy[period_start]
        solax_available = se["__coverage_seconds"] > 0
        az_available = ae["__coverage_seconds"] > 0

        pv_dc = source_value(se, "pv_total_power_w", solax_available)
        solax_house = source_value(se, "house_power_w", solax_available)

        inverter_l1 = source_value(se, "inverter_l1_power_w", solax_available)
        inverter_l2 = source_value(se, "inverter_l2_power_w", solax_available)
        inverter_l3 = source_value(se, "inverter_l3_power_w", solax_available)
        inverter_ac = add_if_all(inverter_l1, inverter_l2, inverter_l3)

        solax_grid_export = source_value(
            se, "grid_power_w__positive", solax_available
        )
        solax_grid_import = source_value(
            se, "grid_power_w__negative", solax_available
        )

        battery_charge = source_value(
            se, "battery_power_w__positive", solax_available
        )
        battery_discharge = source_value(
            se, "battery_power_w__negative", solax_available
        )

        grid_l1_export = source_value(
            ae, "grid_l1_power_w__positive", az_available
        )
        grid_l1_import = source_value(
            ae, "grid_l1_power_w__negative", az_available
        )
        grid_l2_export = source_value(
            ae, "grid_l2_power_w__positive", az_available
        )
        grid_l2_import = source_value(
            ae, "grid_l2_power_w__negative", az_available
        )
        grid_l3_export = source_value(
            ae, "grid_l3_power_w__positive", az_available
        )
        grid_l3_import = source_value(
            ae, "grid_l3_power_w__negative", az_available
        )

        grid_import = add_if_all(grid_l1_import, grid_l2_import, grid_l3_import)
        grid_export = add_if_all(grid_l1_export, grid_l2_export, grid_l3_export)

        house_l1 = add_if_all(inverter_l1, grid_l1_import, -grid_l1_export if grid_l1_export is not None else None)
        house_l2 = add_if_all(inverter_l2, grid_l2_import, -grid_l2_export if grid_l2_export is not None else None)
        house_l3 = add_if_all(inverter_l3, grid_l3_import, -grid_l3_export if grid_l3_export is not None else None)
        house = add_if_all(house_l1, house_l2, house_l3)

        rows_to_write.append(
            {
                "period_start": period_start,
                "period_end": period_end,
                "solax_first_sample_at": first_solax["measured_at"] if first_solax else None,
                "solax_last_sample_at": last_solax["measured_at"] if last_solax else None,
                "solax_sample_count": solax_count,
                "solax_max_gap_seconds": solax_max_gap,
                "azrouter_sample_count": az_count,
                "azrouter_max_gap_seconds": az_max_gap,
                "pv_dc_kwh": pv_dc,
                "inverter_l1_ac_kwh": inverter_l1,
                "inverter_l2_ac_kwh": inverter_l2,
                "inverter_l3_ac_kwh": inverter_l3,
                "inverter_ac_kwh": inverter_ac,
                "solax_house_kwh": solax_house,
                "solax_grid_import_kwh": solax_grid_import,
                "solax_grid_export_kwh": solax_grid_export,
                "grid_l1_import_kwh": grid_l1_import,
                "grid_l1_export_kwh": grid_l1_export,
                "grid_l2_import_kwh": grid_l2_import,
                "grid_l2_export_kwh": grid_l2_export,
                "grid_l3_import_kwh": grid_l3_import,
                "grid_l3_export_kwh": grid_l3_export,
                "grid_import_kwh": grid_import,
                "grid_export_kwh": grid_export,
                "house_l1_kwh": house_l1,
                "house_l2_kwh": house_l2,
                "house_l3_kwh": house_l3,
                "house_kwh": house,
                "battery_charge_kwh": battery_charge,
                "battery_discharge_kwh": battery_discharge,
                "boiler_kwh": None,
                "production_dc_counter_start_kwh": counter_value(
                    first_solax, "production_dc_today_kwh"
                ),
                "production_dc_counter_end_kwh": counter_value(
                    last_solax, "production_dc_today_kwh"
                ),
                "yield_ac_counter_start_kwh": counter_value(
                    first_solax, "yield_ac_today_kwh"
                ),
                "yield_ac_counter_end_kwh": counter_value(
                    last_solax, "yield_ac_today_kwh"
                ),
                "grid_import_counter_start_kwh": counter_value(
                    first_solax, "grid_import_today_kwh"
                ),
                "grid_import_counter_end_kwh": counter_value(
                    last_solax, "grid_import_today_kwh"
                ),
                "grid_export_counter_start_kwh": counter_value(
                    first_solax, "grid_export_today_kwh"
                ),
                "grid_export_counter_end_kwh": counter_value(
                    last_solax, "grid_export_today_kwh"
                ),
                "battery_charge_counter_start_kwh": counter_value(
                    first_solax, "battery_charge_today_kwh"
                ),
                "battery_charge_counter_end_kwh": counter_value(
                    last_solax, "battery_charge_today_kwh"
                ),
                "battery_discharge_counter_start_kwh": counter_value(
                    first_solax, "battery_discharge_today_kwh"
                ),
                "battery_discharge_counter_end_kwh": counter_value(
                    last_solax, "battery_discharge_today_kwh"
                ),
            }
        )

    upsert_rows(conn, rows_to_write)
    return len(rows_to_write)


UPSERT_SQL = """
INSERT INTO energy_15m (
    period_start, period_end,
    solax_first_sample_at, solax_last_sample_at,
    solax_sample_count, solax_max_gap_seconds,
    azrouter_sample_count, azrouter_max_gap_seconds,
    pv_dc_kwh,
    inverter_l1_ac_kwh, inverter_l2_ac_kwh, inverter_l3_ac_kwh, inverter_ac_kwh,
    solax_house_kwh, solax_grid_import_kwh, solax_grid_export_kwh,
    grid_l1_import_kwh, grid_l1_export_kwh,
    grid_l2_import_kwh, grid_l2_export_kwh,
    grid_l3_import_kwh, grid_l3_export_kwh,
    grid_import_kwh, grid_export_kwh,
    house_l1_kwh, house_l2_kwh, house_l3_kwh, house_kwh,
    battery_charge_kwh, battery_discharge_kwh, boiler_kwh,
    production_dc_counter_start_kwh, production_dc_counter_end_kwh,
    yield_ac_counter_start_kwh, yield_ac_counter_end_kwh,
    grid_import_counter_start_kwh, grid_import_counter_end_kwh,
    grid_export_counter_start_kwh, grid_export_counter_end_kwh,
    battery_charge_counter_start_kwh, battery_charge_counter_end_kwh,
    battery_discharge_counter_start_kwh, battery_discharge_counter_end_kwh,
    calculated_at
) VALUES (
    %(period_start)s, %(period_end)s,
    %(solax_first_sample_at)s, %(solax_last_sample_at)s,
    %(solax_sample_count)s, %(solax_max_gap_seconds)s,
    %(azrouter_sample_count)s, %(azrouter_max_gap_seconds)s,
    %(pv_dc_kwh)s,
    %(inverter_l1_ac_kwh)s, %(inverter_l2_ac_kwh)s, %(inverter_l3_ac_kwh)s, %(inverter_ac_kwh)s,
    %(solax_house_kwh)s, %(solax_grid_import_kwh)s, %(solax_grid_export_kwh)s,
    %(grid_l1_import_kwh)s, %(grid_l1_export_kwh)s,
    %(grid_l2_import_kwh)s, %(grid_l2_export_kwh)s,
    %(grid_l3_import_kwh)s, %(grid_l3_export_kwh)s,
    %(grid_import_kwh)s, %(grid_export_kwh)s,
    %(house_l1_kwh)s, %(house_l2_kwh)s, %(house_l3_kwh)s, %(house_kwh)s,
    %(battery_charge_kwh)s, %(battery_discharge_kwh)s, %(boiler_kwh)s,
    %(production_dc_counter_start_kwh)s, %(production_dc_counter_end_kwh)s,
    %(yield_ac_counter_start_kwh)s, %(yield_ac_counter_end_kwh)s,
    %(grid_import_counter_start_kwh)s, %(grid_import_counter_end_kwh)s,
    %(grid_export_counter_start_kwh)s, %(grid_export_counter_end_kwh)s,
    %(battery_charge_counter_start_kwh)s, %(battery_charge_counter_end_kwh)s,
    %(battery_discharge_counter_start_kwh)s, %(battery_discharge_counter_end_kwh)s,
    now()
)
ON CONFLICT (period_start) DO UPDATE SET
    period_end = EXCLUDED.period_end,
    solax_first_sample_at = EXCLUDED.solax_first_sample_at,
    solax_last_sample_at = EXCLUDED.solax_last_sample_at,
    solax_sample_count = EXCLUDED.solax_sample_count,
    solax_max_gap_seconds = EXCLUDED.solax_max_gap_seconds,
    azrouter_sample_count = EXCLUDED.azrouter_sample_count,
    azrouter_max_gap_seconds = EXCLUDED.azrouter_max_gap_seconds,
    pv_dc_kwh = EXCLUDED.pv_dc_kwh,
    inverter_l1_ac_kwh = EXCLUDED.inverter_l1_ac_kwh,
    inverter_l2_ac_kwh = EXCLUDED.inverter_l2_ac_kwh,
    inverter_l3_ac_kwh = EXCLUDED.inverter_l3_ac_kwh,
    inverter_ac_kwh = EXCLUDED.inverter_ac_kwh,
    solax_house_kwh = EXCLUDED.solax_house_kwh,
    solax_grid_import_kwh = EXCLUDED.solax_grid_import_kwh,
    solax_grid_export_kwh = EXCLUDED.solax_grid_export_kwh,
    grid_l1_import_kwh = EXCLUDED.grid_l1_import_kwh,
    grid_l1_export_kwh = EXCLUDED.grid_l1_export_kwh,
    grid_l2_import_kwh = EXCLUDED.grid_l2_import_kwh,
    grid_l2_export_kwh = EXCLUDED.grid_l2_export_kwh,
    grid_l3_import_kwh = EXCLUDED.grid_l3_import_kwh,
    grid_l3_export_kwh = EXCLUDED.grid_l3_export_kwh,
    grid_import_kwh = EXCLUDED.grid_import_kwh,
    grid_export_kwh = EXCLUDED.grid_export_kwh,
    house_l1_kwh = EXCLUDED.house_l1_kwh,
    house_l2_kwh = EXCLUDED.house_l2_kwh,
    house_l3_kwh = EXCLUDED.house_l3_kwh,
    house_kwh = EXCLUDED.house_kwh,
    battery_charge_kwh = EXCLUDED.battery_charge_kwh,
    battery_discharge_kwh = EXCLUDED.battery_discharge_kwh,
    boiler_kwh = EXCLUDED.boiler_kwh,
    production_dc_counter_start_kwh = EXCLUDED.production_dc_counter_start_kwh,
    production_dc_counter_end_kwh = EXCLUDED.production_dc_counter_end_kwh,
    yield_ac_counter_start_kwh = EXCLUDED.yield_ac_counter_start_kwh,
    yield_ac_counter_end_kwh = EXCLUDED.yield_ac_counter_end_kwh,
    grid_import_counter_start_kwh = EXCLUDED.grid_import_counter_start_kwh,
    grid_import_counter_end_kwh = EXCLUDED.grid_import_counter_end_kwh,
    grid_export_counter_start_kwh = EXCLUDED.grid_export_counter_start_kwh,
    grid_export_counter_end_kwh = EXCLUDED.grid_export_counter_end_kwh,
    battery_charge_counter_start_kwh = EXCLUDED.battery_charge_counter_start_kwh,
    battery_charge_counter_end_kwh = EXCLUDED.battery_charge_counter_end_kwh,
    battery_discharge_counter_start_kwh = EXCLUDED.battery_discharge_counter_start_kwh,
    battery_discharge_counter_end_kwh = EXCLUDED.battery_discharge_counter_end_kwh,
    calculated_at = now()
"""


def upsert_rows(conn, rows):
    if not rows:
        return
    with conn.cursor() as cur:
        cur.executemany(UPSERT_SQL, rows)


def run_once():
    now = datetime.now(timezone.utc)
    closed_end = floor_bucket(now)

    with psycopg.connect(DATABASE_URL) as conn:
        earliest = earliest_raw_time(conn)
        if earliest is None:
            log("no raw data yet")
            return

        earliest_bucket = floor_bucket(earliest)
        latest_period = latest_energy_period(conn)

        if latest_period is None:
            start = earliest_bucket
        else:
            start = latest_period - BUCKET * max(RECALCULATE_PERIODS - 1, 0)
            if start < earliest_bucket:
                start = earliest_bucket

        if start >= closed_end:
            return

        count = calculate_range(conn, start, closed_end)
        conn.commit()

    log(
        f"calculated {count} closed 15m period(s) "
        f"from {start.isoformat()} to {closed_end.isoformat()} "
        f"max_gap={MAX_INTEGRATION_GAP_SECONDS}s"
    )


def validate_config():
    if not DATABASE_URL:
        raise SystemExit("DATABASE_URL is not configured")
    if REPORT_INTERVAL_SECONDS <= 0:
        raise SystemExit("REPORT_INTERVAL_SECONDS must be positive")
    if RAW_RETENTION_DAYS <= 0:
        raise SystemExit("RAW_RETENTION_DAYS must be positive")
    if MAX_INTEGRATION_GAP_SECONDS <= 0:
        raise SystemExit("REPORTER_MAX_INTEGRATION_GAP_SECONDS must be positive")
    if RECALCULATE_PERIODS <= 0:
        raise SystemExit("REPORTER_RECALCULATE_PERIODS must be positive")


if __name__ == "__main__":
    validate_config()
    print(
        "reporter starting; "
        f"interval={REPORT_INTERVAL_SECONDS}s "
        f"raw_retention={RAW_RETENTION_DAYS}d "
        f"max_integration_gap={MAX_INTEGRATION_GAP_SECONDS}s "
        f"recalculate_periods={RECALCULATE_PERIODS}",
        flush=True,
    )

    while True:
        try:
            run_once()
        except Exception as exc:
            log(f"15m calculation failed: {exc}")
        time.sleep(REPORT_INTERVAL_SECONDS)
