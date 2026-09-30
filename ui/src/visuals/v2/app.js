const F = SM;

function renderPhaseLab(data) {
  const inv = [1,2,3].map(i => Number(data[`inverter_l${i}_power_w`] || 0));
  const grid = [1,2,3].map(i => Number(data[`azrouter_grid_l${i}_power_w`] || 0));
  const maxInv = Math.max(500, ...inv.map(Math.abs));
  const maxGrid = Math.max(200, ...grid.map(Math.abs));
  document.getElementById("phase-lab").innerHTML = [0,1,2].map(n => {
    const gs = F.gridState(grid[n]);
    return `<div class="phase-row">
      <b>L${n+1}</b>
      <div class="meter inv"><i style="width:${Math.min(100,Math.abs(inv[n])/maxInv*100)}%"></i></div>
      <b>${F.power(inv[n])}</b>
      <div class="meter grid gridm"><i style="width:${Math.min(100,Math.abs(grid[n])/maxGrid*100)}%"></i></div>
      <b class="gridv" data-tone="${gs.tone}">${gs.label} ${gs.detail}</b>
    </div>`;
  }).join("");
}

function renderForecast(data) {
  const rows = Array.isArray(data.solar_forecast) ? data.solar_forecast : [];
  const box = document.getElementById("forecast");
  if (!rows.length) {
    box.innerHTML = '<div class="hcol"><div class="val">bez forecastu</div></div>';
    return;
  }
  const max = Math.max(1, ...rows.map(r => Number(r.gti_w_m2 || 0)));
  const now = Date.now();
  box.innerHTML = rows.map(r => {
    const val = Number(r.gti_w_m2 || 0);
    const current = new Date(r.period_start).getTime() <= now && now < new Date(r.period_end).getTime();
    return `<div class="hcol ${current ? "now" : ""}">
      <div class="val">${F.fmt(val,0)}</div>
      <div class="barwrap"><div class="bar" style="height:${Math.max(2,val/max*100)}%"></div></div>
      <div class="time">${F.time(r.period_start)}<br>☁ ${F.pct(r.cloud_cover_pct)}</div>
    </div>`;
  }).join("");
}

function render(data) {
  const gridValue = data.azrouter_available ? data.azrouter_grid_total_power_w : null;
  const gs = F.gridState(gridValue);
  const bs = F.batteryState(data.battery_power_w);
  const device = F.primaryDevice(data);

  F.setText("pv", F.power(data.pv_total_power_w));
  F.setText("pv-sub", `S1 ${F.power(data.pv1_power_w)} · S2 ${F.power(data.pv2_power_w)}`);
  F.setText("soc", F.fmt(data.battery_soc_pct,0));
  document.getElementById("soc-ring").style.setProperty("--soc", Math.max(0,Math.min(100,Number(data.battery_soc_pct || 0))));
  F.setText("battery-state", `${bs.label} · ${bs.detail}`);
  F.setTone("battery-state", bs.tone);

  F.setText("inverter", F.power(data.inverter_power_w));
  F.setText("inverter-state", data.inverter_state || "—");
  F.setText("inv-temp", F.temp(data.inverter_temp_c));
  F.setText("sample-age", data.sample_age_seconds == null ? "—" : F.fmt(data.sample_age_seconds,1,"s"));

  F.setText("grid", gs.detail);
  F.setText("grid-state", gs.label);
  F.setTone("grid-state", gs.tone);

  F.setText("house", F.power(data.house_power_w));
  F.setText("house-sub", `SolaX load · AC dnes ${F.energy(data.yield_ac_today_kwh)}`);

  F.setText("today-pv", F.energy(data.production_dc_today_kwh));
  F.setText("today-ac", F.energy(data.yield_ac_today_kwh));
  F.setText("today-import", F.energy(data.grid_import_today_kwh,2));
  F.setText("today-export", F.energy(data.grid_export_today_kwh,2));
  F.setText("today-battery", `${F.energy(data.battery_charge_today_kwh)} / ${F.energy(data.battery_discharge_today_kwh)}`);

  renderPhaseLab(data);

  F.setText("boiler-name", device?.name || "Bojler");
  F.setText("boiler-status", device?.status || "bez dat");
  F.setTone("boiler-status", device?.stale ? "warn" : (device ? "good" : "muted"));
  F.setText("boiler-temp", device?.temperature_c == null ? "—" : F.fmt(device.temperature_c,1));
  const heatPct = device?.temperature_c == null ? 0 : Math.max(0,Math.min(100,Number(device.temperature_c)/80*100));
  document.getElementById("heat-fill").style.height = `${heatPct}%`;
  F.setText("boiler-power", F.power(device?.power_total_w));
  F.setText("boiler-boost", device ? `${device.boost ? "ON" : "OFF"} / ${device.boost_source ?? "—"}` : "—");
  F.setTone("boiler-boost", device?.boost ? "warn" : "");
  F.setText("boiler-phases", F.connectedPhases(device));
  F.setText("boiler-max", F.power(device?.max_power_w));

  F.setText("sun-times", `↑ ${F.time(data.solar_sunrise)} · ↓ ${F.time(data.solar_sunset)}`);
  renderForecast(data);

  F.setText("serial", "SN " + (data.serial_number || "—"));
  F.setText("measured", F.dateTime(data.measured_at));
  F.setText("clock", F.time(data.measured_at, true));

  const alert = document.getElementById("alert");
  if (data.stale || data.azrouter_stale) {
    alert.style.display = "block";
    alert.textContent = data.stale ? "SolaX realtime je stale." : "AZ Router realtime je stale.";
  } else {
    alert.style.display = "none";
  }
}

F.start(render, err => {
  const alert = document.getElementById("alert");
  alert.style.display = "block";
  alert.textContent = "Realtime API není dostupné: " + err.message;
});