# azrouter_reader

Autonomous read-only reader for the AZ Router local LAN API.

## Responsibility

- poll AZ Router every few seconds
- read the local `/api/v1/power` endpoint without authentication
- normalize three-phase grid measurements
- preserve the original JSON response in `raw_payload`
- store each successful sample in PostgreSQL
- never perform control actions

## Endpoint

With:

```text
AZROUTER_URL=http://192.168.1.21
```

the reader calls:

```text
http://192.168.1.21/api/v1/power
```

No login/password is required for this endpoint.

## Mapping

AZ Router `input.*` is used as the independent CT measurement of the actual
house/grid connection.

Sign convention:

```text
grid_lN_power_w > 0  export to grid
grid_lN_power_w < 0  import from grid
```

Normalized fields:

| Field | Source | Unit |
| --- | --- | --- |
| `grid_l1_power_w` | `input.power[id=0].value` | W |
| `grid_l2_power_w` | `input.power[id=1].value` | W |
| `grid_l3_power_w` | `input.power[id=2].value` | W |
| `grid_total_power_w` | sum L1+L2+L3 | W |
| `grid_l1..3_voltage_v` | `input.voltage[id=0..2].value / 1000` | V |
| `grid_l1..3_current_a` | `input.current[id=0..2].value / 1000` | A |
| `output_0..3_power_w` | `output.power[id=0..3].value` | W |
| `device_last_update` | `lastUpdate` Unix timestamp | timestamp |

The output channels are retained now even though their final physical meaning
(boiler / SSR / aggregate channel) will be documented later.

## Storage

Every successful poll creates one row in `azrouter_raw` and also stores the
complete source JSON in `raw_payload`.

High-frequency raw data is intended for short retention (for example 30 days).
The reporter will later derive 1-minute and 15-minute aggregates and energy
integrals. Import and export energy must be integrated separately because
different phases may import and export simultaneously.

## Configuration

- `AZROUTER_URL` – base URL / IP of AZ Router
- `AZROUTER_POLL_INTERVAL_SECONDS` – poll period, default 5 seconds
- `DATABASE_URL` – PostgreSQL connection string
- `RUN_ONCE=true` – optional one-shot reader test

## Failure behaviour

Network errors, malformed payloads and database failures are logged. A failed
read does not create a fake database row.
