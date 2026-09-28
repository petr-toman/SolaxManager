# azrouter_reader

Autonomous reader for AZ Router.

## Responsibility

- poll AZ Router at a configurable interval
- normalize device-specific values
- store measurements in PostgreSQL
- never perform control actions

Candidate data includes boiler power, output level, relay state, energy counters and temperatures depending on the available AZ Router local API.

## Configuration

Environment variables:

- `AZROUTER_URL`
- `POLL_INTERVAL_SECONDS`
- `DATABASE_URL`

## Status

Scaffold only. The local AZ Router API and field mapping will be documented and implemented after the first SolaX telemetry and controller proof-of-concept are working.
