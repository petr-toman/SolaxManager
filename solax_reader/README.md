# solax_reader

Autonomous reader for the local SolaX inverter API.

## Responsibility

- poll the inverter at a configurable interval, initially every 5 seconds
- parse the device-specific response
- convert SolaX `Data[]` values to normalized engineering units and meaningful field names
- store one normalized raw measurement in PostgreSQL
- preserve the original response in `raw_payload` for diagnostics and future remapping
- never change inverter configuration

## Current protocol

The inverter is read through the local HTTP API:

```text
POST <SOLAX_URL>
optType=ReadRealTimeData&pwd=<password>
```

The field mapping in M0.1 is inherited from the existing and field-tested
`petr-toman/rpiSolaxPT` implementation.

## Important sign conventions

These conventions are part of the SolaxManager data contract:

```text
grid_power_w > 0     export / delivery to grid
grid_power_w < 0     import / consumption from grid

battery_power_w > 0  battery charging
battery_power_w < 0  battery discharging
```

Reporter must preserve these semantics when it later splits signed power into
import/export and charge/discharge energy.

## M0.1 mapping

| Normalized field | SolaX source | Unit |
| --- | --- | --- |
| `serial_number` | `sn` | text |
| `api_version` | `ver` | text |
| `inverter_type` | `type` | enum/id |
| `pv1_power_w` | `Data[14]` | W |
| `pv2_power_w` | `Data[15]` | W |
| `production_dc_today_kwh` | `Data[82] / 10` | kWh |
| `yield_ac_today_kwh` | `Data[70] / 10` | kWh |
| `grid_power_w` | signed `Data[34]` | W |
| `grid_import_total_kwh` | `Data[93:92] / 100` | kWh |
| `grid_export_total_kwh` | `Data[91:90] / 100` | kWh |
| `house_power_w` | signed `Data[47]` | W |
| `battery_power_w` | signed `Data[41]` | W |
| `battery_soc_pct` | `Data[103]` | % |
| `battery_charged_total_kwh` | `Data[79] / 10` | kWh |
| `battery_discharged_total_kwh` | `Data[78] / 10` | kWh |
| `battery_capacity_kwh` | `Data[106] / 10` | kWh |
| `battery_temp_c` | `Data[105]` | °C |
| `inverter_power_w` | signed `Data[9]` | W |
| `inverter_temp_c` | `Data[54]` | °C |
| `inverter_mode` | `Data[19]` | enum |
| phase powers | signed `Data[6..8]` | W |
| PV voltages | `Data[10..11] / 10` | V |
| PV currents | `Data[12..13] / 10` | A |
| grid voltages | `Data[0..2] / 10` | V |
| grid currents | signed `Data[3..5] / 10` | A |
| grid frequencies | `Data[16..18] / 100` | Hz |

Values not yet independently verified against the physical installation remain
traceable because every sample also stores the original JSON payload.

## Configuration

Environment variables:

- `SOLAX_URL`
- `SOLAX_PASSWORD`
- `POLL_INTERVAL_SECONDS`
- `DATABASE_URL`
- `RUN_ONCE=true` – useful for one-shot development testing

## Failure behaviour

Connection, malformed-payload or database errors are logged and the process
continues with the next polling interval. A failed read does not create a fake
measurement row.

## Development test

After configuring local `.env`:

```bash
make dev
make logs-solax
```

Inspect recent rows:

```bash
make db
```

then:

```sql
SELECT measured_at, pv_total_power_w, house_power_w,
       grid_power_w, battery_power_w, battery_soc_pct
FROM solax_raw
ORDER BY measured_at DESC
LIMIT 10;
```

## Autonomy

This container can run independently when supplied with a compatible PostgreSQL
database and the four configuration variables above.
