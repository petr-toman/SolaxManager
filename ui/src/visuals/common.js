(() => {
  const nf0 = new Intl.NumberFormat("cs-CZ", { maximumFractionDigits: 0 });
  const nf1 = new Intl.NumberFormat("cs-CZ", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  const nf2 = new Intl.NumberFormat("cs-CZ", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  const fmt = (value, digits = 0, unit = "") => {
    if (value === null || value === undefined || Number.isNaN(Number(value))) return "—";
    const f = digits === 2 ? nf2 : digits === 1 ? nf1 : nf0;
    return f.format(Number(value)) + (unit ? " " + unit : "");
  };

  const power = (value) => {
    if (value === null || value === undefined || Number.isNaN(Number(value))) return "—";
    const v = Number(value);
    return Math.abs(v) >= 1000 ? fmt(v / 1000, 2, "kW") : fmt(v, 0, "W");
  };

  const energy = (value, digits = 1) => fmt(value, digits, "kWh");
  const pct = (value) => fmt(value, 0, "%");
  const temp = (value) => fmt(value, 1, "°C");
  const volts = (value) => fmt(value, 1, "V");
  const amps = (value) => fmt(value, 2, "A");
  const hz = (value) => fmt(value, 2, "Hz");

  const time = (value, seconds = false) => {
    if (!value) return "—";
    return new Date(value).toLocaleTimeString("cs-CZ", {
      hour: "2-digit",
      minute: "2-digit",
      ...(seconds ? { second: "2-digit" } : {})
    });
  };

  const dateTime = (value) => {
    if (!value) return "—";
    return new Date(value).toLocaleString("cs-CZ", {
      day: "2-digit", month: "2-digit", year: "numeric",
      hour: "2-digit", minute: "2-digit", second: "2-digit"
    });
  };

  const gridState = (value) => {
    if (value === null || value === undefined || Number.isNaN(Number(value))) {
      return { label: "bez dat", detail: "—", tone: "muted", direction: "none" };
    }
    const v = Number(value);
    if (v > 40) return { label: "dodávka", detail: power(v), tone: "good", direction: "export" };
    if (v < -40) return { label: "odběr", detail: power(Math.abs(v)), tone: "bad", direction: "import" };
    return { label: "vyrovnáno", detail: power(Math.abs(v)), tone: "neutral", direction: "idle" };
  };

  const batteryState = (value) => {
    if (value === null || value === undefined || Number.isNaN(Number(value))) {
      return { label: "bez dat", detail: "—", tone: "muted", direction: "none" };
    }
    const v = Number(value);
    if (v > 40) return { label: "nabíjení", detail: power(v), tone: "good", direction: "charge" };
    if (v < -40) return { label: "vybíjení", detail: power(Math.abs(v)), tone: "warn", direction: "discharge" };
    return { label: "v klidu", detail: power(Math.abs(v)), tone: "neutral", direction: "idle" };
  };

  const primaryDevice = (data) => {
    const devices = Array.isArray(data?.azrouter_devices) ? [...data.azrouter_devices] : [];
    devices.sort((a, b) => (a.priority ?? 999) - (b.priority ?? 999));
    return devices[0] || null;
  };

  const connectedPhases = (device) => {
    if (!device) return "—";
    const p = [];
    if (device.connected_l1) p.push("L1");
    if (device.connected_l2) p.push("L2");
    if (device.connected_l3) p.push("L3");
    return p.length ? p.join(" · ") : "—";
  };

  const forecastLabel = (row) => {
    if (!row) return "—";
    return `${time(row.period_start)}–${time(row.period_end)}`;
  };

  const setText = (id, value) => {
    const el = document.getElementById(id);
    if (el) el.textContent = value;
  };

  const setTone = (id, tone) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.dataset.tone = tone || "";
  };

  const apiUrl = "/api/realtime";

  async function fetchRealtime() {
    const res = await fetch(apiUrl, { cache: "no-store" });
    const payload = await res.json();
    if (!res.ok || payload.status !== "ok") {
      throw new Error(payload.message || `HTTP ${res.status}`);
    }
    return payload.data;
  }

  function start(render, onError, intervalMs = 2000) {
    let active = true;

    async function tick() {
      try {
        const data = await fetchRealtime();
        if (active) render(data);
      } catch (err) {
        if (active && onError) onError(err);
      }
    }

    tick();
    const timer = setInterval(tick, intervalMs);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }

  window.SM = {
    fmt, power, energy, pct, temp, volts, amps, hz, time, dateTime,
    gridState, batteryState, primaryDevice, connectedPhases, forecastLabel,
    setText, setTone, fetchRealtime, start
  };
})();