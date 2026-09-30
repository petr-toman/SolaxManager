const F = SM;

function phaseHtml(i, inv, grid, maxInv, maxGrid) {
  const invPct = Math.min(100, Math.abs(inv || 0) / maxInv * 100);
  const gridPct = Math.min(100, Math.abs(grid || 0) / maxGrid * 100);
  const gs = F.gridState(grid);
  return `
    <div class="phase">
      <div class="phase-label">L${i}</div>
      <div class="bar inv"><i style="width:${invPct}%"></i></div>
      <strong>${F.power(inv)}</strong>
      <div class="bar ct"><i style="width:${gridPct}%"></i></div>
      <strong class="ctv" data-tone="${gs.tone}">${gs.label} ${gs.detail}</strong>
    </div>`;
}

function renderForecast(data) {
  const box = document.getElementById("forecast");
  const rows = Array.isArray(data.solar_forecast) ? data.solar_forecast : [];
  if (!rows.length) {
    box.innerHTML = '<div class="sub">Předpověď není dostupná.</div>';
    return;
  }
  const now = Date.now();
  box.innerHTML = rows.map(r => {
    const current = new Date(r.period_start).getTime() <= now && now < new Date(r.period_end).getTime();
    return `<div class="forecast-hour ${current ? "now" : ""}">
      <div class="time">${F.forecastLabel(r)}</div>
      <div class="gti">${F.fmt(r.gti_w_m2,0)}</div>
      <div class="unit">W/m² GTI</div>
      <div class="meta">GHI ${F.fmt(r.ghi_w_m2,0)}<br>☁ ${F.pct(r.cloud_cover_pct)} · ${F.temp(r.temperature_c)}<br>déšť ${F.fmt(r.precipitation_mm,1,"mm")}</div>
      <div class="sunbar" style="opacity:${Math.max(.08, Math.min(.8, Number(r.gti_w_m2 || 0)/1000))}"></div>
    </div>`;
  }).join("");
}

function render(data) {
  const azGrid = data.azrouter_available ? data.azrouter_grid_total_power_w : null;
  const grid = F.gridState(azGrid);
  const battery = F.batteryState(data.battery_power_w);
  const device = F.primaryDevice(data);

  F.setText("pv-power", F.power(data.pv_total_power_w));
  F.setText("pv-today", F.energy(data.production_dc_today_kwh));
  F.setText("pv1", `${F.power(data.pv1_power_w)} · ${F.volts(data.pv1_voltage_v)}`);
  F.setText("pv2", `${F.power(data.pv2_power_w)} · ${F.volts(data.pv2_voltage_v)}`);

  F.setText("soc", F.fmt(data.battery_soc_pct,0));
  F.setText("battery-flow", `${battery.label} · ${battery.detail}`);
  F.setTone("battery-flow", battery.tone);
  document.getElementById("soc-fill").style.width = `${Math.max(0,Math.min(100,Number(data.battery_soc_pct || 0)))}%`;

  F.setText("house-power", F.power(data.house_power_w));
  F.setText("ac-today", F.energy(data.yield_ac_today_kwh));
  F.setText("inverter-power", F.power(data.inverter_power_w));

  F.setText("grid-power", grid.detail);
  F.setText("grid-state", grid.label);
  F.setTone("grid-state", grid.tone);
  F.setText("solax-grid", F.power(data.grid_power_w));
  F.setText("az-age", data.azrouter_sample_age_seconds == null ? "—" : F.fmt(data.azrouter_sample_age_seconds,1,"s"));

  F.setText("flow-pv", F.power(data.pv_total_power_w));
  F.setText("flow-inverter", F.power(data.inverter_power_w));
  F.setText("flow-house", F.power(data.house_power_w));
  F.setText("flow-battery", battery.detail);
  F.setText("flow-battery-state", battery.label);
  F.setTone("flow-battery-state", battery.tone);
  F.setText("flow-grid", grid.detail);
  F.setText("flow-grid-state", grid.label);
  F.setTone("flow-grid-state", grid.tone);

  F.setText("inv-state", data.inverter_state || "—");
  F.setText("inv-mode", data.inverter_mode ?? "—");
  F.setText("inv-temp", F.temp(data.inverter_temp_c));
  F.setText("bat-detail", `${F.energy(data.battery_stored_energy_kwh)} · SOC ${F.pct(data.battery_soc_pct)}`);
  F.setText("bat-vi", `${F.volts(data.battery_voltage_v)} · ${F.amps(data.battery_current_a)}`);
  F.setText("bat-temp", F.temp(data.battery_temp_c));
  F.setText("serial", data.serial_number || "—");
  F.setText("measured", F.dateTime(data.measured_at));

  const inv = [1,2,3].map(i => Number(data[`inverter_l${i}_power_w`] || 0));
  const az = [1,2,3].map(i => Number(data[`azrouter_grid_l${i}_power_w`] || 0));
  const maxInv = Math.max(500, ...inv.map(Math.abs));
  const maxGrid = Math.max(200, ...az.map(Math.abs));
  document.getElementById("phases").innerHTML = [1,2,3].map((i,n) => phaseHtml(i, inv[n], az[n], maxInv, maxGrid)).join("");

  F.setText("boiler-name", device?.name || "Bojler");
  F.setText("boiler-status", device?.status || "bez dat");
  F.setTone("boiler-status", device?.stale ? "warn" : (device ? "good" : "muted"));
  F.setText("boiler-temp", device?.temperature_c == null ? "—" : F.fmt(device.temperature_c,1));
  F.setText("boiler-power", F.power(device?.power_total_w));
  F.setText("boiler-boost", device?.boost === true ? "zapnut" : device?.boost === false ? "vypnut" : "—");
  F.setTone("boiler-boost", device?.boost ? "warn" : "neutral");
  F.setText("boiler-source", device?.boost_source ?? "—");
  F.setText("boiler-phases", F.connectedPhases(device));
  F.setText("boiler-max", F.power(device?.max_power_w));
  F.setText("boiler-signal", F.fmt(device?.signal_db,0,"dB"));

  F.setText("sunrise", F.time(data.solar_sunrise));
  F.setText("sunset", F.time(data.solar_sunset));
  renderForecast(data);

  const age = Number(data.sample_age_seconds || 0);
  F.setText("freshness", data.stale ? `stará data · ${F.fmt(age,1,"s")}` : `live · ${F.fmt(age,1,"s")}`);
  F.setTone("freshness", data.stale ? "warn" : "good");

  const alert = document.getElementById("alert");
  if (data.stale || data.azrouter_stale) {
    alert.style.display = "block";
    alert.textContent = data.stale ? "SolaX data jsou starší než nastavený limit." : "AZ Router data jsou starší než nastavený limit.";
  } else {
    alert.style.display = "none";
  }
}

F.start(render, err => {
  const alert = document.getElementById("alert");
  alert.style.display = "block";
  alert.textContent = "Realtime API není dostupné: " + err.message;
  F.setText("freshness", "bez spojení");
  F.setTone("freshness", "bad");
});