# reporter

Statistics and retention service.

## Responsibility

Reporter consumes normalized raw measurements from PostgreSQL and creates derived data. It never talks to SolaX or AZ Router directly.

Planned functions:

- numerical integration of power samples into energy
- separate import/export integration
- separate battery charge/discharge integration
- 15-minute aggregates compatible with distributor meter periods
- daily aggregates
- optional one-minute aggregates for UI
- data-retention cleanup
- later: comparison and calibration against distributor meter data

## Numerical integration

Power samples are not assumed to arrive at perfectly regular intervals. Energy should therefore be calculated using actual timestamps, initially with trapezoidal integration:

```text
E += ((P1 + P2) / 2) * delta_t
```

Import/export and charge/discharge must be integrated separately rather than cancelling each other through signed power.

## Configuration

- `DATABASE_URL`
- `REPORT_INTERVAL_SECONDS`
- `RAW_RETENTION_DAYS`

## Status

The initial container is a scheduler scaffold. Calculation logic is added after raw field mapping is verified.
