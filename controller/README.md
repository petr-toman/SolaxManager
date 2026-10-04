# controller

Hardware-control boundary for SolaxManager.

The controller is the **only** service allowed to change SolaX or AZ Router
configuration. Reader services remain read-only and continue to own background
telemetry/config polling.

The controller now exposes a small REST API with automatically generated
OpenAPI documentation.

## Architecture

```text
UI / planner / manual client
          |
          | HTTP / JSON
          v
+----------------------------+
| controller                 |
|                            |
| REST action catalog        |
|   |                    |   |
|   v                    v   |
| SolaX adapter     AZ adapter|
+---|--------------------|---+
    |                    |
    v                    v
  SolaX              AZ Router
```

The controller does not schedule scenarios. `valid_from` / `valid_until` on an
action are validity guards only. Future scheduling belongs to the planner.

## REST API

Default container-internal port:

```text
8090
```

Development maps the controller to the reserved SolaxManager host port:

```text
http://127.0.0.1:18882
```

The container itself continues to listen on port `8090`.

Production does **not** publish the controller port to the Docker host. Other
services in the Compose stack can reach it through the Docker network as
`http://controller:8090`.

Interactive documentation:

```text
GET /docs
GET /redoc
GET /openapi.json
```

Service endpoints:

```text
GET /health
GET /api/capabilities
```

SolaX reads:

```text
GET /api/solax/config
```

SolaX actions:

```text
POST /api/actions/solax/min-soc
```

Example:

```json
{
  "min_soc_pct": 25,
  "verification_elapsed_ms": 750,
  "requested_by": "manual-test"
}
```

The action first reads the current SolaX configuration and returns explicit
`before` and `after` snapshots. It is idempotent, respects controller mode
and action validity guards, waits before read-back verification, and returns
HTTP 502 if the observed Min SOC does not match the requested value.

For the local G4 HTTP API, Min SOC is read from `ReadSetData[28]` but written
through `setReg` register `29`. The write register is an internal adapter
mapping and is not selectable through the REST action.

AZ Router reads:

```text
GET /api/azrouter/status
GET /api/azrouter/config
GET /api/azrouter/devices
```

AZ Router actions:

```text
POST /api/actions/azrouter/device-boost
POST /api/actions/azrouter/master-boost
```

## AZ Router BOOST

Device BOOST is implemented against the local API as:

```text
POST /api/v1/device/boost
```

with payload:

```json
{
  "data": {
    "device": {
      "common": {
        "id": 1
      }
    },
    "boost": 1
  }
}
```

Master BOOST uses:

```text
POST /api/v1/system/boost
```

The controller performs BOOST changes transactionally:

1. read the current state,
2. do nothing when the requested value is already active,
3. honor controller safety mode,
4. send the write request only when required,
5. read the state back,
6. verify the resulting value,
7. return the before/after result to the caller.

For Smart Slave devices the controller currently recognizes `power.boost`.
It also accepts `charge.boost` for charger-style devices.

Example device request:

```json
{
  "device_id": 1,
  "enabled": true,
  "verification_elapsed_ms": 750,
  "requested_by": "manual-test"
}
```

Optional execution guards:

```json
{
  "device_id": 1,
  "enabled": true,
  "valid_from": "2026-10-05T10:00:00+02:00",
  "valid_until": "2026-10-05T13:00:00+02:00",
  "requested_by": "planner"
}
```

These timestamps do **not** schedule the request. If the request arrives outside
the interval, the controller rejects it.

`verification_elapsed_ms` controls the one-time delay between the AZ Router
write request and the following read-back verification. It defaults to `750`
milliseconds and may be set from `0` to `10000` in each request, which makes
it possible to tune the router's state-propagation delay directly from Swagger
without rebuilding the image.

## AZ Router authentication

Read-only local endpoints may work without credentials. Write endpoints can
require authentication.

Configure:

```text
AZROUTER_USERNAME=
AZROUTER_PASSWORD=
```

Both must be configured together. On the verified router firmware,
`/api/v1/login` returns the authentication token directly as response text.
The controller sends that token on write requests as the `token` cookie.

If both credential fields are empty, the controller attempts the write without
login. This supports installations where the local write API is unrestricted;
an HTTP authentication error is otherwise returned to the caller.

## Controller modes

```text
off
manual
dry-run
auto
```

- `off` — reads work; hardware-changing requests are rejected.
- `manual` — explicit REST actions can write hardware.
- `dry-run` — actions are evaluated and returned, but no hardware write occurs.
- `auto` — validated future planner actions may write hardware.

The default is `dry-run` when `CONTROLLER_MODE` is unset. All Compose modes,
including development, take `CONTROLLER_MODE` from `.env`; the development
overlay does not override it.

## SolaX configuration adapter

The existing SolaX `ReadSetData` adapter remains available through REST and CLI.
It exposes only indexes verified on the target inverter/firmware.

Verified mapping:

| Index | Meaning | Encoding / observed values |
|---:|---|---|
| 24 | inverter RTC minute/second | high byte = minute, low byte = second |
| 25 | inverter RTC day/hour | high byte = day, low byte = hour |
| 26 | inverter RTC year/month | high byte = 2-digit year, low byte = month |
| 27 | work mode | `0=self_use`, `2=backup_mode`; unknown values are not guessed |
| 28 | Self Use minimum SOC | percent |
| 29 | charge from grid | `0=disabled`, `1=enabled` |
| 30 | grid-charge target SOC | percent |
| 36 | forced charge start | high byte = minute, low byte = hour |
| 37 | forced charge end | high byte = minute, low byte = hour |
| 38 | allowed discharge start | high byte = minute, low byte = hour |
| 39 | allowed discharge end | high byte = minute, low byte = hour |
| 116 | phase unbalanced | observed `0=disabled`, `1=enabled` |
| 185 | HotStandby | observed `0=enabled`, `1=disabled` |

CLI diagnostics are kept:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get min_soc
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get work_mode
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller config --json
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller raw
```

## Safety rules

- device-specific protocol details stay inside controller adapters
- no raw register/index writes are exposed as public actions
- actions are idempotent where possible
- every write is read-before-write and read-back verified
- unknown values fail closed rather than being guessed
- HTTP/device timeouts are explicit
- controller credentials are read only from environment variables
- readers remain read-only
- scheduling/rules remain outside the controller

## Next controller milestones

Planned SolaX write actions remain:

```text
set_work_mode
set_grid_charge
start_force_charge
stop_force_charge
```

Each will follow the same read / validate / write / read-back / verify pattern
already used for AZ Router BOOST.
