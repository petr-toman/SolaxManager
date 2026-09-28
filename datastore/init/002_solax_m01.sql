-- M0.1: expand normalized SolaX telemetry.
-- Safe to apply to an existing development volume.

ALTER TABLE solax_raw
    ADD COLUMN IF NOT EXISTS serial_number TEXT,
    ADD COLUMN IF NOT EXISTS api_version TEXT,
    ADD COLUMN IF NOT EXISTS inverter_type INTEGER,
    ADD COLUMN IF NOT EXISTS production_dc_today_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS yield_ac_today_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_import_today_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_export_today_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_charge_today_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_discharge_today_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_stored_energy_kwh DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS battery_temp_c DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_temp_c DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS inverter_mode INTEGER,
    ADD COLUMN IF NOT EXISTS grid_l1_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_power_w DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l1_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l1_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l2_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_l3_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS pv1_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS pv2_voltage_v DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS pv1_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS pv2_current_a DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_frequency_l1_hz DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_frequency_l2_hz DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS grid_frequency_l3_hz DOUBLE PRECISION;

CREATE INDEX IF NOT EXISTS idx_solax_raw_serial_measured_at
    ON solax_raw (serial_number, measured_at);
