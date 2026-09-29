-- M1.2: versioned configuration history for SolaX and AZ Router.
--
-- begdat/enddat stay explicit for readability and maintenance.
-- validity is generated as [begdat,enddat), so adjacent versions can touch
-- but never overlap. NULL enddat means the current/open-ended version.

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE IF NOT EXISTS solax_config (
    id BIGSERIAL PRIMARY KEY,
    begdat TIMESTAMPTZ NOT NULL,
    enddat TIMESTAMPTZ,
    validity TSTZRANGE GENERATED ALWAYS AS (
        tstzrange(begdat, enddat, '[)')
    ) STORED,

    work_mode_code INTEGER,
    work_mode TEXT,
    min_soc_pct INTEGER,
    charge_from_grid BOOLEAN,
    charge_to_soc_pct INTEGER,
    forced_charge_start TIME,
    forced_charge_end TIME,
    allowed_discharge_start TIME,
    allowed_discharge_end TIME,
    hot_standby BOOLEAN,
    hot_standby_code INTEGER,

    CONSTRAINT solax_config_valid_dates
        CHECK (enddat IS NULL OR enddat > begdat),
    CONSTRAINT solax_config_no_overlap
        EXCLUDE USING gist (validity WITH &&)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_solax_config_current
    ON solax_config ((1))
    WHERE enddat IS NULL;

CREATE INDEX IF NOT EXISTS idx_solax_config_validity
    ON solax_config USING gist (validity);


CREATE TABLE IF NOT EXISTS azrouter_config (
    id BIGSERIAL PRIMARY KEY,
    scope TEXT NOT NULL,
    device_id INTEGER NOT NULL,
    begdat TIMESTAMPTZ NOT NULL,
    enddat TIMESTAMPTZ,
    validity TSTZRANGE GENERATED ALWAYS AS (
        tstzrange(begdat, enddat, '[)')
    ) STORED,

    -- Router-level settings (scope=router, device_id=0)
    master_target_power_w INTEGER,

    -- Device identity/config (scope=device, device_id>0)
    device_type INTEGER,
    device_name TEXT,
    priority INTEGER,
    connected_l1 BOOLEAN,
    connected_l2 BOOLEAN,
    connected_l3 BOOLEAN,

    -- settings[0] / profile 1
    profile1_max_power_w INTEGER,
    profile1_target_temperature_c INTEGER,
    profile1_target_boost_temperature_c INTEGER,
    profile1_solar_window_enabled BOOLEAN,
    profile1_solar_window_start TIME,
    profile1_solar_window_stop TIME,
    profile1_block_solar_heating BOOLEAN,
    profile1_block_heating_from_battery BOOLEAN,
    profile1_offline_only BOOLEAN,
    profile1_ignore_cycle BOOLEAN,
    profile1_boost_mode INTEGER,

    -- settings[1] / profile 2
    profile2_max_power_w INTEGER,
    profile2_target_temperature_c INTEGER,
    profile2_target_boost_temperature_c INTEGER,
    profile2_solar_window_enabled BOOLEAN,
    profile2_solar_window_start TIME,
    profile2_solar_window_stop TIME,
    profile2_block_solar_heating BOOLEAN,
    profile2_block_heating_from_battery BOOLEAN,
    profile2_offline_only BOOLEAN,
    profile2_ignore_cycle BOOLEAN,
    profile2_boost_mode INTEGER,

    CONSTRAINT azrouter_config_valid_scope
        CHECK (
            (scope = 'router' AND device_id = 0)
            OR
            (scope = 'device' AND device_id > 0)
        ),
    CONSTRAINT azrouter_config_valid_dates
        CHECK (enddat IS NULL OR enddat > begdat),
    CONSTRAINT azrouter_config_no_overlap
        EXCLUDE USING gist (
            scope WITH =,
            device_id WITH =,
            validity WITH &&
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_azrouter_config_current
    ON azrouter_config (scope, device_id)
    WHERE enddat IS NULL;

CREATE INDEX IF NOT EXISTS idx_azrouter_config_validity
    ON azrouter_config USING gist (scope, device_id, validity);
