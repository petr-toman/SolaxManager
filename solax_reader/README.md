# solax_reader

Autonomous reader for the local SolaX inverter API.

## Responsibility

- poll the inverter at a configurable interval, initially approximately every 5 seconds
- parse the device-specific response
- convert values to normalized engineering units and meaningful field names
- store normalized raw measurements in PostgreSQL
- optionally preserve the original JSON payload for diagnostics
- never change inverter configuration

## Initial protocol

The current inverter responds to local HTTP POST requests using:

```text
?optType=ReadRealTimeData&pwd=<password>
```

The existing `petr-toman/rpiSolaxPT` project is the reference implementation for SolaX reading and field mapping.

## Data contract

The reader should eventually produce fields such as:

```text
timestamp
pv1_power_w
pv2_power_w
pv_total_power_w
house_power_w
grid_power_w
battery_power_w
battery_soc_pct
battery_voltage_v
battery_current_a
inverter_state
raw_payload
```

Exact mapping is inverter-model and firmware dependent and will be verified against current realtime responses.

## Configuration

Environment variables:

- `SOLAX_URL`
- `SOLAX_PASSWORD`
- `POLL_INTERVAL_SECONDS`
- `DATABASE_URL`

## Autonomy

This container can run independently if a compatible PostgreSQL instance is provided through `DATABASE_URL`.
