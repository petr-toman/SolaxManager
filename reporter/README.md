# reporter

Statistics and retention service.

## Responsibility

Reporter consumes normalized raw measurements from PostgreSQL and creates
derived data. It never communicates with SolaX or AZ Router directly.

The current implementation builds canonical 15-minute energy buckets. Daily
aggregates and retention cleanup remain later steps.

## 15-minute integration

Buckets are aligned exactly to quarter-hour boundaries:

```text
hh:00:00–hh:15:00
hh:15:00–hh:30:00
hh:30:00–hh:45:00
hh:45:00–next hour
```

Raw samples are integrated with actual timestamps using linear trapezoidal
integration. A sample segment that crosses a quarter-hour boundary is split at
the boundary.

Signed values are also split at their exact linear zero crossing before
integration. Therefore import/export and charge/discharge never cancel one
another inside a segment.

### Gap handling

A pair of neighbouring samples is integrated only when its time gap is at most:

```text
REPORTER_MAX_INTEGRATION_GAP_SECONDS
```

Default: 120 seconds.

Longer gaps are not filled with invented energy. Every bucket stores:

- `solax_sample_count`
- `solax_max_gap_seconds`
- `azrouter_sample_count`
- `azrouter_max_gap_seconds`

so input quality remains visible.

## Source semantics

Primary grid energy comes from AZ Router CT measurements. Import/export is
integrated separately for L1/L2/L3 first, then summed.

SolaX contributes:

- PV DC energy
- AC inverter energy per phase
- direct aggregate house energy
- direct aggregate grid import/export as an independent comparison
- battery charge/discharge
- daily cumulative counter snapshots

Derived household phase energy is:

```text
house phase = inverter phase + grid import phase - grid export phase
```

The SolaX aggregate `solax_house_kwh` is retained independently so the derived
phase sum can be compared with the inverter's own house/load estimate.

## Cumulative counters

For every bucket, reporter stores SolaX daily counters from the first and last
raw sample inside the interval:

- DC production
- AC yield
- grid import
- grid export
- battery charge
- battery discharge

Counter deltas are deliberately not stored; calculate `end - start` in SQL.
These counters have coarser resolution than trapezoidal integration, so they
are validation signals rather than the primary energy source.

Example:

```sql
SELECT
    period_start,
    inverter_ac_kwh,
    yield_ac_counter_end_kwh - yield_ac_counter_start_kwh
        AS yield_counter_delta_kwh,
    inverter_ac_kwh
      - (yield_ac_counter_end_kwh - yield_ac_counter_start_kwh)
        AS difference_kwh
FROM energy_15m
ORDER BY period_start;
```

## Recalculation / backfill

`energy_15m` is derived and rebuildable from raw telemetry.

On an empty table the reporter backfills all retained raw data up to the latest
closed quarter hour. Afterwards each run recalculates the most recent N periods
and also catches up all newly closed periods since the last stored bucket.

```text
REPORTER_RECALCULATE_PERIODS=8
```

Repeated runs are safe because rows are upserted by canonical
`period_start`.

Migration `012_energy_15m_integration.sql` replaces the original scaffold
table once. Existing scaffold rows are intentionally discarded rather than
having their timestamps shifted; raw telemetry is the source of truth and the
reporter rebuilds aligned values.

## Configuration

- `DATABASE_URL`
- `REPORT_INTERVAL_SECONDS=60`
- `REPORTER_MAX_INTEGRATION_GAP_SECONDS=120`
- `REPORTER_RECALCULATE_PERIODS=8`
- `RAW_RETENTION_DAYS=30` (reserved for retention cleanup)
