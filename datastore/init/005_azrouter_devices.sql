-- M1.1: AZ Router paired-device telemetry.
-- One row is stored per device and poll. The complete device object, including
-- both settings profiles, is retained in raw_payload for later mapping.

CREATE TABLE IF NOT EXISTS azrouter_device_raw (
    id BIGSERIAL PRIMARY KEY,
    measured_at TIMESTAMPTZ NOT NULL,

    device_type INTEGER,
    device_id INTEGER,
    priority INTEGER,
    name TEXT,
    status_code INTEGER,
    signal_db DOUBLE PRECISION,

    serial_number TEXT,
    fw_version TEXT,
    hw_version INTEGER,

    power_l1_w DOUBLE PRECISION,
    power_l2_w DOUBLE PRECISION,
    power_l3_w DOUBLE PRECISION,
    power_total_w DOUBLE PRECISION,
    max_power_w DOUBLE PRECISION,

    temperature_c DOUBLE PRECISION,

    boost BOOLEAN,
    boost_source INTEGER,
    boost_temp_override DOUBLE PRECISION,
    outlet_mode INTEGER,

    connected_l1 BOOLEAN,
    connected_l2 BOOLEAN,
    connected_l3 BOOLEAN,

    raw_payload JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_azrouter_device_raw_measured_at
    ON azrouter_device_raw (measured_at);

CREATE INDEX IF NOT EXISTS idx_azrouter_device_raw_device_id_measured_at
    ON azrouter_device_raw (device_id, measured_at DESC);
