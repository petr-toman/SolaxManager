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

## Development and production

Production target: Raspberry Pi with Docker Compose.

Development target: macOS / Docker Desktop.

Configuration is loaded from a local `.env` file. Start by copying the template:

```bash
cp .env.example .env
```

Never commit real device or database credentials.

Compose has one shared base and exactly two runtime modes:

```text
docker-compose.yml       common services, environment, health checks and named volumes
docker-compose.dev.yml   local source bind mounts + development host ports
docker-compose.prod.yml  production host exposure (UI only)
```

The Compose project name is fixed to `solaxmanager`. DEV and PROD therefore use
the same named PostgreSQL volume `solaxmanager_pgdata`; switching mode does not
create a second application database.

Common commands:

```bash
make dev
make prod
make down
make rebuild-dev
make rebuild-prod
make ps
make db
```

There is deliberately no third `make up` runtime mode.

### Host ports

SolaxManager reserves the host range `18880-18889`:

| Host port | Service | DEV | PROD |
|---:|---|:---:|:---:|
| 18880 | UI | yes | yes |
| 18881 | telemetry API | yes | no |
| 18882 | controller / Swagger | yes | no |
| 18883 | PostgreSQL | yes | no |
| 18884 | planner (reserved) | future | no |

Container-internal ports remain native (`80`, `8000`, `8090`, `5432`).
DEV mappings are bound to `127.0.0.1`; PROD exposes only the UI.

With DEV running:

```text
http://127.0.0.1:18880              UI
http://127.0.0.1:18881/api/realtime telemetry API
http://127.0.0.1:18882/docs         controller Swagger
127.0.0.1:18883                     PostgreSQL
```

`CONTROLLER_MODE` always comes from `.env` in both DEV and PROD.

### Source code layout

DEV bind-mounts application source directories from the local filesystem, so
source edits are visible inside the running containers.

PROD has no source bind mounts. Application sources are the copies baked into
the Docker images by each service Dockerfile.

### Persistent database

PostgreSQL always stores its data in the Docker named volume:

```text
solaxmanager_pgdata -> /var/lib/postgresql/data
```

Normal DEV/PROD switches and rebuilds preserve this volume.

A destructive reset is explicit:

```bash
make initialize
```

This removes persistent SolaxManager volumes and starts a clean DEV stack.
For a clean production start use:

```bash
make initialize MODE=prod
```
