-- 1) SolaX realtime
SELECT
    measured_at,
    pv1_power_w,
    pv2_power_w,
    pv_total_power_w,
    production_dc_today_kwh,
    yield_ac_today_kwh,
    house_power_w,
    grid_power_w,
    grid_import_today_kwh,
    grid_export_today_kwh,
    battery_power_w,
    battery_soc_pct,
    battery_voltage_v,
    battery_current_a,
    battery_stored_energy_kwh,
    battery_temp_c,
    battery_charge_today_kwh,
    battery_discharge_today_kwh,
    inverter_power_w,
    inverter_temp_c,
    inverter_mode,
    inverter_state,
    inverter_l1_power_w,
    inverter_l2_power_w,
    inverter_l3_power_w,
    grid_l1_voltage_v,
    grid_l2_voltage_v,
    grid_l3_voltage_v,
    inverter_l1_current_a,
    inverter_l2_current_a,
    inverter_l3_current_a,
    grid_frequency_l1_hz,
    grid_frequency_l2_hz,
    grid_frequency_l3_hz
FROM solax_raw
WHERE measured_at >= '2026-09-30 08:00:00+02'
  AND measured_at <= '2026-09-30 19:30:00+02'
ORDER BY measured_at;



-- 2) AZ Router – síť po fázích
SELECT
    measured_at,
    device_last_update,
    grid_l1_power_w,
    grid_l2_power_w,
    grid_l3_power_w,
    grid_total_power_w,
    grid_l1_voltage_v,
    grid_l2_voltage_v,
    grid_l3_voltage_v,
    grid_l1_current_a,
    grid_l2_current_a,
    grid_l3_current_a
FROM azrouter_raw
WHERE measured_at >= '2026-09-30 08:00:00+02'
  AND measured_at <= '2026-09-30 19:30:00+02'
ORDER BY measured_at;





-- 3) AZ Router – bojler
SELECT
    measured_at,
    device_id,
    name,
    status_code,
    temperature_c,
    boost,
    boost_source ,
    power_l1_w,
    power_l2_w,
    power_l3_w,
    power_total_w,
    max_power_w,
    connected_l1,
    connected_l2,
    connected_l3
FROM azrouter_device_raw
WHERE measured_at >= '2026-09-30 08:00:00+02'
  AND measured_at <= '2026-09-30 19:30:00+02'
ORDER BY measured_at;




-- 4) forecast – všechny dnešní vintages
SELECT
    provider,
    fetched_at,
    period_start,
    period_end,
    temperature_c,
    cloud_cover_pct,
    precipitation_mm,
    sunshine_duration_s,
    is_day,
    ghi_w_m2,
    direct_radiation_w_m2,
    diffuse_radiation_w_m2,
    dni_w_m2,
    gti_w_m2,
    sunrise,
    sunset
FROM solar_forecast
WHERE period_end >= '2026-09-30 08:00:00+02'
  AND period_start <= '2026-09-30 19:30:00+02'
ORDER BY fetched_at, period_start;



-- 5) konfigurace SolaXu platná během dne
SELECT
    id,
    begdat,
    enddat,
    work_mode,
    min_soc_pct,
    charge_from_grid,
    charge_to_soc_pct,
    forced_charge_start,
    forced_charge_end,
    allowed_discharge_start,
    allowed_discharge_end,
    phase_unbalanced,
    hot_standby
FROM solax_config
WHERE validity && tstzrange(
    '2026-09-30 08:00:00+02',
    '2026-09-30 19:30:00+02',
    '[)'
)
ORDER BY begdat;