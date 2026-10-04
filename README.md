# SolaxManager

Modular Docker-based home energy manager for a SolaX hybrid inverter, AZ Router, battery storage and hot-water management.

The project is intentionally split into autonomous services. Each service owns one responsibility and can be developed, tested and operated independently. Docker Compose provides orchestration for the complete stack.

## Architecture

```text
SolaX inverter ──> solax_reader ─────────────┐
                                             │
AZ Router ──────> azrouter_reader ───────────┼──> datastore (PostgreSQL)
                                             │
Open-Meteo ────> solar_forecast_reader ─────┘
                                             │
                                             ├──> reporter
                                             ├──> telemetry_api ──> ui
                                             │
                                             └<── controller ──────────> SolaX / AZ Router
```

### Services

- **solax_reader** – reads local SolaX realtime data, maps device-specific payloads to normalized fields and stores raw normalized measurements.
- **azrouter_reader** – reads AZ Router data and stores normalized measurements.
- **solar_forecast_reader** – reads external solar/weather forecasts and stores versioned hourly forecast time slices.
- **datastore** – PostgreSQL database shared through explicit schemas/tables.
- **reporter** – calculates energy integrations and time aggregates, and performs retention cleanup.
- **telemetry_api** – read-only HTTP API over normalized PostgreSQL telemetry. It is the data boundary used by the browser UI.
- **controller** – hardware-control boundary; exposes validated device reads/actions and is the only service allowed to write SolaX or AZ Router configuration.
- **planner** – future decision layer; will evaluate telemetry, history, forecasts and rules, then request actions from the controller.
- **ui** – lightweight realtime status dashboard. It never talks directly to SolaX or PostgreSQL.

## Design rules

1. Readers only read devices and write measurements.
2. Reporter only reads measurements and writes derived statistics.
3. Controller is the only service allowed to change device configuration.
4. UI never talks directly to SolaX, AZ Router or PostgreSQL.
5. Browser-facing telemetry is served through `telemetry_api`; PostgreSQL remains the single source of truth.
6. Device-specific protocol details stay inside device adapters.
7. Automation starts in dry-run/shadow mode before any autonomous write operations are enabled.
8. Raw device payloads may be retained for diagnostics, but business logic uses normalized fields.

## Project phases

### M0 – telemetry foundation
- Docker Compose stack
- PostgreSQL
- SolaX local reader
- normalized raw data storage

### M0.2 – realtime visibility
- read-only telemetry API
- current-state browser dashboard
- stale-data indication

### M0.5 – controller GO / NO-GO
- read SolaX configuration
- read Min SOC
- safely set Min SOC
- read back and verify
- restore original value
- verify work mode / charge controls
- verify force-charge capability

If M0.5 cannot be implemented reliably on the inverter/firmware, further automation work will be reconsidered before investing in advanced reporting and UI.

### M1 – complete telemetry
- AZ Router reader
- stable raw measurements
- health/error monitoring

### M2 – reporting
- numerical energy integration
- 1 minute / 15 minute / daily statistics as needed
- configurable data retention
- comparison against calibrated distributor meter data

### M3 – UI
- basic charts and statistics
- controller state and action log
- configuration views

### M4 – rule engine
- configurable conditions
- dry-run evaluation
- guarded automatic execution
- seasonal battery management
- battery recovery and periodic full-charge logic
- boiler optimization

## Development

Production target: Raspberry Pi with Docker Compose.

Development target: macOS / Docker Desktop.

Configuration is loaded from a local `.env` file. Start by copying the template:

```bash
cp .env.example .env
```

Never commit real device or database credentials.

Compose project name is fixed to `solaxmanager`, so `make up`, `make dev` and `make prod` use the same named Docker volumes, including the PostgreSQL data volume.

The project provides a Makefile for the common Docker workflows:

```bash
make help
make dev
make prod
make up
make down
make logs
make logs-solax
make logs-forecast
make logs-controller
make ps
make db
```

Development uses the base Compose file plus `docker-compose.dev.yml`. Source directories are bind-mounted where practical and PostgreSQL/controller APIs are exposed only to the development host. Controller safety mode is always taken from `.env` via `CONTROLLER_MODE`; the dev overlay does not override it.

The realtime dashboard is available at:

```text
http://localhost:8088
```

The browser calls `/api/realtime` on the UI origin; nginx proxies that request internally to `telemetry_api`. The API reads the newest normalized PostgreSQL row, so the UI never needs inverter credentials.

Production uses the base Compose file plus `docker-compose.prod.yml`. Source code is taken from built images and PostgreSQL/controller APIs remain internal to the Docker network. Controller mode is taken from `.env` and defaults to `dry-run` when unset.

Clean rebuilds are available through:

```bash
make rebuild
make rebuild-dev
make rebuild-prod
```

A destructive reset of persistent Docker data is deliberately explicit:

```bash
make initialize
```

This removes the PostgreSQL volume and recreates the base stack, so it requires interactive confirmation.
