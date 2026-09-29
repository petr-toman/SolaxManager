-- M1: normalized AZ Router raw telemetry.
-- Existing placeholder columns are retained for forward compatibility.
-- The local /api/v1/power endpoint is sampled independently from SolaX.

ALTER TABLE azrouter_raw
    ADD COLUMN IF NOT EXISTS grid_l1_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_total_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l1_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l1_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS output_0_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS output_1_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS output_2_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS output_3_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS device_last_update TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_azrouter_raw_device_last_update
    ON azrouter_raw (device_last_update);
