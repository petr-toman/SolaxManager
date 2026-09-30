-- M1.8: canonical 15-minute energy integration.
--
-- Upgrade the original energy_15m scaffold in place. The reporter then
-- backfills/recalculates derived values from raw telemetry.
--
-- No PL/pgSQL dollar-quoted block is used here so the migration is plain SQL
-- and can be piped directly to psql.

CREATE TABLE IF NOT EXISTS energy_15m (
    period_start TIMESTAMPTZ PRIMARY KEY
);

ALTER TABLE energy_15m
    ADD COLUMN IF NOT EXISTS period_end TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS solax_first_sample_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS solax_last_sample_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS solax_sample_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS solax_max_gap_seconds DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS azrouter_sample_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS azrouter_max_gap_seconds DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS pv_dc_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_l1_ac_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_l2_ac_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_l3_ac_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_ac_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS solax_house_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS solax_grid_import_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS solax_grid_export_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS grid_l1_import_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l1_export_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_import_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_export_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_import_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_export_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS grid_import_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_export_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS house_l1_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS house_l2_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS house_l3_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS house_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS battery_charge_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_discharge_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS boiler_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS production_dc_counter_start_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS production_dc_counter_end_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS yield_ac_counter_start_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS yield_ac_counter_end_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_import_counter_start_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_import_counter_end_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_export_counter_start_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_export_counter_end_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_charge_counter_start_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_charge_counter_end_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_discharge_counter_start_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_discharge_counter_end_kwh DOUBLE PRECISION,

    ADD COLUMN IF NOT EXISTS calculated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- The old scaffold did not calculate rows. If a local development database
-- contains hand-made scaffold rows, align their period end to the canonical
-- quarter-hour start before adding the constraints below.
UPDATE energy_15m
SET period_end = period_start + interval '15 minutes'
WHERE period_end IS NULL;

ALTER TABLE energy_15m
    ALTER COLUMN period_end SET NOT NULL;

ALTER TABLE energy_15m
    ADD COLUMN IF NOT EXISTS validity TSTZRANGE GENERATED ALWAYS AS (
        tstzrange(period_start, period_end, '[)')
    ) STORED;

ALTER TABLE energy_15m
    DROP CONSTRAINT IF EXISTS energy_15m_exact_duration;

ALTER TABLE energy_15m
    ADD CONSTRAINT energy_15m_exact_duration
        CHECK (period_end = period_start + interval '15 minutes');

ALTER TABLE energy_15m
    DROP CONSTRAINT IF EXISTS energy_15m_aligned_start;

ALTER TABLE energy_15m
    ADD CONSTRAINT energy_15m_aligned_start
        CHECK (
            period_start = date_bin(
                interval '15 minutes',
                period_start,
                timestamptz '2000-01-01 00:00:00+00'
            )
        );

CREATE INDEX IF NOT EXISTS idx_energy_15m_validity
    ON energy_15m USING gist (validity);
