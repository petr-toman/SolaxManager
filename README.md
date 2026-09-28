# SolaxManager

Modular Docker-based home energy manager for a SolaX hybrid inverter, AZ Router, battery storage and hot-water management.

The project is intentionally split into autonomous services. Each service owns one responsibility and can be developed, tested and operated independently. Docker Compose provides orchestration for the complete stack.

## Architecture

```text
SolaX inverter ──> solax_reader ──────┐
                                      │
AZ Router ──────> azrouter_reader ────┼──> datastore (PostgreSQL)
                                      │
                                      ├──> reporter
                                      │
                                      ├──> ui
                                      │
                                      └<── controller ──> SolaX / AZ Router
```

### Services

- **solax_reader** – reads local SolaX realtime data, maps device-specific payloads to normalized fields and stores raw normalized measurements.
- **azrouter_reader** – reads AZ Router data and stores normalized measurements.
- **datastore** – PostgreSQL database shared through explicit schemas/tables.
- **reporter** – calculates energy integrations and time aggregates, and performs retention cleanup.
- **controller** – reads/writes device configuration and later evaluates configurable automation rules. Starts in **dry-run** mode.
- **ui** – lightweight web UI. Initially only a status page; statistics and configuration will be added later.

## Design rules

1. Readers only read devices and write measurements.
2. Reporter only reads measurements and writes derived statistics.
3. Controller is the only service allowed to change device configuration.
4. UI never talks directly to SolaX or AZ Router.
5. Device-specific protocol details stay inside device adapters.
6. Automation starts in dry-run/shadow mode before any autonomous write operations are enabled.
7. Raw device payloads may be retained for diagnostics, but business logic uses normalized fields.

## Project phases

### M0 – telemetry foundation
- Docker Compose stack
- PostgreSQL
- SolaX local reader
- normalized raw data storage

### M0.5 – controller GO / NO-GO
- read SolaX configuration
- read Min SOC
- safely set Min SOC
- read back and verify
- restore original value
- verify work mode / charge controls
- verify force-charge capability

If M0.5 cannot be implemented reliably on the inverter/firmware, further automation work will be reconsidered before investing in reporting and UI.

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
- current values
- basic charts and statistics
- controller state and action log

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

Start the stack:

```bash
docker compose up --build
```

Stop it:

```bash
docker compose down
```

The initial scaffold intentionally contains minimal implementations. Hardware access and credentials are supplied through environment variables and must not be committed to the repository.
