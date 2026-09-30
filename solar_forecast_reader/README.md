# solar_forecast_reader

Read-only solar/weather forecast acquisition for SolaxManager.

## Responsibility

- fetch forecast data from external providers
- normalize forecast data into PostgreSQL time slices
- retain forecast vintages via `fetched_at`
- never control SolaX or AZ Router

The first provider is Open-Meteo. Additional providers such as PV Forecast can
be added to this same service later and stored in the same `solar_forecast`
table using a different `provider` value.

## Open-Meteo request

The reader requests hourly:

- temperature
- cloud cover
- precipitation and precipitation probability
- sunshine duration
- day/night flag
- GHI
- direct radiation
- diffuse radiation
- DNI
- GTI for the configured panel tilt/azimuth

It also requests sunrise and sunset.

Open-Meteo solar radiation values are preceding-hour means. The database
therefore stores each provider timestamp as `valid_at` and creates the
forecast time slice as:

```text
period_start = valid_at - 1 hour
period_end   = valid_at
validity     = [period_start, period_end)
```

This makes the radiation period directly joinable with SolaX raw telemetry.

## Configuration

The exact installation coordinates belong in local `.env`, not in the public
repository.

```text
SOLAR_FORECAST_LAT
SOLAR_FORECAST_LON
SOLAR_PANEL_TILT_DEG
SOLAR_PANEL_AZIMUTH_DEG

SOLAR_FORECAST_BASE_INTERVAL_SECONDS=300
OPENMETEO_EVERY_N_LOOPS=12
OPENMETEO_FORECAST_HOURS=72
```

Open-Meteo azimuth convention:

```text
0    = south
-90  = east
+90  = west
+/-180 = north
```

With the defaults, the container wakes every 5 minutes and fetches Open-Meteo
once every 12 loops, i.e. about once per hour. Loop zero fetches immediately on
container startup.

## Forecast vintages

Forecast rows are not overwritten. A new fetch creates another set of rows with
a new `fetched_at`. This allows later comparison of:

- what was forecast
- what SolaX actually produced
- which SolaX configuration was valid at that time

Example temporal join using the newest forecast that was already known at each
raw sample:

```sql
SELECT
    r.measured_at,
    r.pv_total_power_w,
    f.gti_w_m2,
    f.cloud_cover_pct,
    c.min_soc_pct,
    c.phase_unbalanced
FROM solax_raw r
LEFT JOIN LATERAL (
    SELECT sf.*
    FROM solar_forecast sf
    WHERE r.measured_at <@ sf.validity
      AND sf.fetched_at <= r.measured_at
    ORDER BY sf.fetched_at DESC
    LIMIT 1
) f ON TRUE
LEFT JOIN solax_config c
  ON r.measured_at <@ c.validity
ORDER BY r.measured_at DESC;
```

For energy/model evaluation, aggregate the 5-second SolaX samples over each
forecast `validity` range rather than comparing a single instantaneous sample
to an hourly radiation mean.
