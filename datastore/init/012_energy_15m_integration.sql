-- M1.8: rebuildable, canonical 15-minute energy integration table.
--
-- energy_15m is derived data. The original scaffold table is deliberately
-- replaced on the first application of this migration rather than shifting
-- already-derived timestamps in place. Reporter backfills the new table from
-- raw telemetry, which is the source of truth.
--
-- Re-running this migration is safe: once the legacy pv_kwh column is gone,
-- the existing rich energy_15m table is preserved.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'energy_15m'
          AND column_name = 'pv_kwh'
    ) THEN
        ALTER TABLE energy_15m RENAME TO energy_15m_legacy_012;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS energy_15m (
    period_start TIMESTAMPTZ PRIMARY KEY,
    period_end TIMESTAMPTZ NOT NULL,
    validity TSTZRANGE GENERATED ALWAYS AS (
        tstzrange(period_start, period_end, '[)')
    ) STORED,

    solax_first_sample_at TIMESTAMPTZ,
    solax_last_sample_at TIMESTAMPTZ,
    solax_sample_count INTEGER NOT NULL DEFAULT 0,
    solax_max_gap_seconds DOUBLE PRECISION,

    azrouter_sample_count INTEGER NOT NULL DEFAULT 0,
    azrouter_max_gap_seconds DOUBLE PRECISION,

    -- SolaX DC / AC integration.
    pv_dc_kwh DOUBLE PRECISION,
    inverter_l1_ac_kwh DOUBLE PRECISION,
    inverter_l2_ac_kwh DOUBLE PRECISION,
    inverter_l3_ac_kwh DOUBLE PRECISION,
    inverter_ac_kwh DOUBLE PRECISION,

    -- Direct aggregate SolaX values retained for independent comparison.
    solax_house_kwh DOUBLE PRECISION,
    solax_grid_import_kwh DOUBLE PRECISION,
    solax_grid_export_kwh DOUBLE PRECISION,

    -- Primary grid integration from AZ Router CTs, phase first and then sum.
    grid_l1_import_kwh DOUBLE PRECISION,
    grid_l1_export_kwh DOUBLE PRECISION,
    grid_l2_import_kwh DOUBLE PRECISION,
    grid_l2_export_kwh DOUBLE PRECISION,
    grid_l3_import_kwh DOUBLE PRECISION,
    grid_l3_export_kwh DOUBLE PRECISION,
    grid_import_kwh DOUBLE PRECISION,
    grid_export_kwh DOUBLE PRECISION,

    -- Derived per-phase household consumption:
    -- inverter AC + grid import - grid export.
    house_l1_kwh DOUBLE PRECISION,
    house_l2_kwh DOUBLE PRECISION,
    house_l3_kwh DOUBLE PRECISION,
    house_kwh DOUBLE PRECISION,

    battery_charge_kwh DOUBLE PRECISION,
    battery_discharge_kwh DOUBLE PRECISION,

    -- Reserved until AZ Router boiler power semantics are fully verified.
    boiler_kwh DOUBLE PRECISION,

    -- SolaX daily cumulative counters at first/last raw sample in the bucket.
    production_dc_counter_start_kwh DOUBLE PRECISION,
    production_dc_counter_end_kwh DOUBLE PRECISION,
    yield_ac_counter_start_kwh DOUBLE PRECISION,
    yield_ac_counter_end_kwh DOUBLE PRECISION,
    grid_import_counter_start_kwh DOUBLE PRECISION,
    grid_import_counter_end_kwh DOUBLE PRECISION,
    grid_export_counter_start_kwh DOUBLE PRECISION,
    grid_export_counter_end_kwh DOUBLE PRECISION,
    battery_charge_counter_start_kwh DOUBLE PRECISION,
    battery_charge_counter_end_kwh DOUBLE PRECISION,
    battery_discharge_counter_start_kwh DOUBLE PRECISION,
    battery_discharge_counter_end_kwh DOUBLE PRECISION,

    calculated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT energy_15m_exact_duration
        CHECK (period_end = period_start + interval '15 minutes'),
    CONSTRAINT energy_15m_aligned_start
        CHECK (
            period_start = date_bin(
                interval '15 minutes',
                period_start,
                timestamptz '2000-01-01 00:00:00+00'
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_energy_15m_validity
    ON energy_15m USING gist (validity);

DROP TABLE IF EXISTS energy_15m_legacy_012;
