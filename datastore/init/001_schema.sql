CREATE TABLE IF NOT EXISTS solax_raw (
    id BIGSERIAL PRIMARY KEY,
    measured_at TIMESTAMPTZ NOT NULL,
    pv1_power_w DOUBLE PRECISION,
    pv2_power_w DOUBLE PRECISION,
    pv_total_power_w DOUBLE PRECISION,
    house_power_w DOUBLE PRECISION,
    grid_power_w DOUBLE PRECISION,
    battery_power_w DOUBLE PRECISION,
    battery_soc_pct DOUBLE PRECISION,
    battery_voltage_v DOUBLE PRECISION,
    battery_current_a DOUBLE PRECISION,
    inverter_state TEXT,
    raw_payload JSONB
);

CREATE INDEX IF NOT EXISTS idx_solax_raw_measured_at
    ON solax_raw (measured_at);

CREATE TABLE IF NOT EXISTS azrouter_raw (
    id BIGSERIAL PRIMARY KEY,
    measured_at TIMESTAMPTZ NOT NULL,
    boiler_power_w DOUBLE PRECISION,
    output_pct DOUBLE PRECISION,
    temperature_c DOUBLE PRECISION,
    relay_state BOOLEAN,
    raw_payload JSONB
);

CREATE INDEX IF NOT EXISTS idx_azrouter_raw_measured_at
    ON azrouter_raw (measured_at);

CREATE TABLE IF NOT EXISTS energy_15m (
    period_start TIMESTAMPTZ PRIMARY KEY,
    pv_kwh DOUBLE PRECISION,
    house_kwh DOUBLE PRECISION,
    grid_import_kwh DOUBLE PRECISION,
    grid_export_kwh DOUBLE PRECISION,
    battery_charge_kwh DOUBLE PRECISION,
    battery_discharge_kwh DOUBLE PRECISION,
    boiler_kwh DOUBLE PRECISION,
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS energy_day (
    day DATE PRIMARY KEY,
    pv_kwh DOUBLE PRECISION,
    house_kwh DOUBLE PRECISION,
    grid_import_kwh DOUBLE PRECISION,
    grid_export_kwh DOUBLE PRECISION,
    battery_charge_kwh DOUBLE PRECISION,
    battery_discharge_kwh DOUBLE PRECISION,
    boiler_kwh DOUBLE PRECISION,
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS controller_action (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    mode TEXT NOT NULL,
    rule_name TEXT,
    action_name TEXT NOT NULL,
    requested_parameters JSONB,
    before_state JSONB,
    after_state JSONB,
    executed BOOLEAN NOT NULL DEFAULT FALSE,
    success BOOLEAN,
    message TEXT
);

CREATE INDEX IF NOT EXISTS idx_controller_action_created_at
    ON controller_action (created_at);
