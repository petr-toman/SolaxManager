# datastore

PostgreSQL persistence layer for SolaxManager.

## Why PostgreSQL

The expected data volume is small for a relational database. PostgreSQL was selected mainly for robust time/date operations, SQL analytics, window functions, JSONB support and the option to add time-series extensions later without changing the basic architecture.

## Responsibilities

- persist normalized raw measurements
- persist derived statistics
- persist controller actions and audit information
- provide a shared data contract between autonomous services

The database performs no hardware communication and no automation decisions.

## Initial tables

- `solax_raw`
- `azrouter_raw`
- `energy_15m`
- `energy_day`
- `controller_action`

The schema is intentionally minimal and will evolve once field mapping is verified against real hardware.
