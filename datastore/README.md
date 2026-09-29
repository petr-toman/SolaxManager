# datastore

PostgreSQL persistence layer for SolaxManager.

## Why PostgreSQL

The expected data volume is small for a relational database. PostgreSQL was selected mainly for robust time/date operations, SQL analytics, window functions, JSONB support and the option to add time-series extensions later without changing the basic architecture.

## Responsibilities

- persist normalized raw measurements
- persist original device payloads for diagnostics
- persist derived statistics
- persist controller actions and audit information
- provide a shared data contract between autonomous services

The database performs no hardware communication and no automation decisions.

## Schema migrations

SQL files in `init/` are executed automatically by the official PostgreSQL
image only when a new database volume is initialized.

For a fresh development environment:

```bash
make initialize
```

is sufficient, but it is destructive and removes the PostgreSQL volume.

When an existing persistent database must be upgraded without data loss, apply
the new migration explicitly with `psql` rather than deleting the volume.

## Initial tables

- `solax_raw` – normalized SolaX measurements plus original JSON payload
- `azrouter_raw` – high-frequency AZ Router CT/grid telemetry plus original JSON payload
- `azrouter_device_raw` – lower-frequency paired-device/boiler telemetry plus original device JSON
- `energy_15m`
- `energy_day`
- `controller_action`

Migration `003_solax_phase_semantics.sql` preserves existing measurements while renaming
SolaX phase power/current columns from `grid_*` to `inverter_*`, reflecting the
validated physical semantics. The true per-phase grid flow will be stored from AZ Router CT data.

The M0.1 SolaX schema is intentionally broader than the first UI requirements:
raw acquisition should retain the useful telemetry now so later reporter logic
does not depend on data that were never collected.


## AZ Router raw telemetry

Migration `004_azrouter_telemetry.sql` adds normalized L1/L2/L3 grid power,
voltage and current, their aggregate power, AZ output-channel powers and the
device-reported update timestamp. The source JSON is preserved in every row.

These 5-second samples are the raw buffer. The reporter will later create
1-minute and 15-minute aggregates and integrate import/export energy separately
so simultaneous import on one phase and export on another are not lost.


## AZ Router paired-device telemetry

Migration `005_azrouter_devices.sql` creates `azrouter_device_raw`. One row is
stored per paired device on each device poll. Current-state fields are
normalized for telemetry, while the complete device object (including both
settings profiles) remains available in `raw_payload`.
