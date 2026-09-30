# telemetry_api

Small read-only HTTP API between PostgreSQL and the browser UI.

## Responsibility

- read normalized telemetry from PostgreSQL
- expose the latest SolaX/AZ Router state as JSON
- expose the newest Open-Meteo solar forecast vintage for current/upcoming hours
- mark stale realtime samples so the UI never presents old data as live
- never communicate with SolaX directly
- never write to the database or change device configuration

## Endpoints

### `GET /api/realtime`

Returns the newest row from `solax_raw`, current AZ Router data and the newest
Open-Meteo forecast vintage.

Forecast fields include:

- `solar_forecast_available`
- `solar_forecast_fetched_at`
- `solar_forecast_age_seconds`
- `solar_sunrise` / `solar_sunset`
- `solar_forecast[]` – current/upcoming hourly slices

The number of hourly forecast rows is controlled by
`TELEMETRY_FORECAST_HOURS` (default 8).

The UI polls this endpoint every two seconds. PostgreSQL remains the single
source of truth for both current state and history.

### `GET /health`

Simple process health endpoint.

## Database configuration

The service uses standard PostgreSQL environment variables:

- `PGHOST`
- `PGPORT`
- `PGDATABASE`
- `PGUSER`
- `PGPASSWORD`

Using separate variables avoids URL-encoding problems when database passwords
contain reserved URL characters.
