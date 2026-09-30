-- M1.7: solar/weather forecast time slices.
--
-- Each row is one forecast vintage for one hourly period. Multiple fetched_at
-- vintages are intentionally retained so forecasts can later be compared with
-- actual SolaX telemetry and with the configuration that was valid at the same
-- time.
--
-- Open-Meteo solar radiation values are preceding-hour means. Therefore
-- valid_at is the provider timestamp and validity is [valid_at-1h, valid_at).

CREATE TABLE IF NOT EXISTS solar_forecast (
    id BIGSERIAL PRIMARY KEY,

    provider TEXT NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL,

    valid_at TIMESTAMPTZ NOT NULL,
    period_start TIMESTAMPTZ NOT NULL,
    period_end TIMESTAMPTZ NOT NULL,
    validity TSTZRANGE GENERATED ALWAYS AS (
        tstzrange(period_start, period_end, '[)')
    ) STORED,

    requested_latitude DOUBLE PRECISION NOT NULL,
    requested_longitude DOUBLE PRECISION NOT NULL,
    source_latitude DOUBLE PRECISION,
    source_longitude DOUBLE PRECISION,
    source_elevation_m DOUBLE PRECISION,
    panel_tilt_deg DOUBLE PRECISION NOT NULL,
    panel_azimuth_deg DOUBLE PRECISION NOT NULL,

    temperature_c DOUBLE PRECISION,
    cloud_cover_pct DOUBLE PRECISION,
    precipitation_mm DOUBLE PRECISION,
    precipitation_probability_pct DOUBLE PRECISION,
    sunshine_duration_s DOUBLE PRECISION,
    is_day BOOLEAN,

    ghi_w_m2 DOUBLE PRECISION,
    direct_radiation_w_m2 DOUBLE PRECISION,
    diffuse_radiation_w_m2 DOUBLE PRECISION,
    dni_w_m2 DOUBLE PRECISION,
    gti_w_m2 DOUBLE PRECISION,

    sunrise TIMESTAMPTZ,
    sunset TIMESTAMPTZ,

    CONSTRAINT solar_forecast_valid_period
        CHECK (period_end > period_start),
    CONSTRAINT solar_forecast_unique_vintage
        UNIQUE (provider, fetched_at, valid_at)
);

CREATE INDEX IF NOT EXISTS idx_solar_forecast_validity
    ON solar_forecast USING gist (validity);

CREATE INDEX IF NOT EXISTS idx_solar_forecast_provider_valid_at_fetched
    ON solar_forecast (provider, valid_at, fetched_at DESC);

CREATE INDEX IF NOT EXISTS idx_solar_forecast_fetched_at
    ON solar_forecast (fetched_at DESC);
