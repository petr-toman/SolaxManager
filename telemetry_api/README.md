# telemetry_api

Small read-only HTTP API between PostgreSQL and the browser UI.

## Responsibility

- read normalized telemetry from PostgreSQL
- expose the latest SolaX sample as JSON
- mark stale samples so the UI never presents old data as live
- never communicate with SolaX directly
- never write to the database or change device configuration

## Endpoints

### `GET /api/realtime`

Returns the newest row from `solax_raw` plus:

- `sample_age_seconds`
- `stale`

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
