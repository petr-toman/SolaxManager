import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Any

SOLAX_URL = os.getenv("SOLAX_URL", "http://192.168.1.20").rstrip("/")
SOLAX_PASSWORD = os.getenv("SOLAX_PASSWORD", "")
CONTROLLER_MODE = os.getenv("CONTROLLER_MODE", "dry-run").lower()
HTTP_TIMEOUT_SECONDS = float(os.getenv("SOLAX_HTTP_TIMEOUT_SECONDS", "5"))

ALLOWED_MODES = {"off", "manual", "dry-run", "auto"}

# ReadSetData indexes reverse-engineered on the target inverter/firmware.
IDX_RTC_MINUTE_SECOND = 24
IDX_RTC_DAY_HOUR = 25
IDX_RTC_YEAR_MONTH = 26
IDX_WORK_MODE = 27
IDX_MIN_SOC = 28
IDX_CHARGE_FROM_GRID = 29
IDX_CHARGE_TO_SOC = 30
IDX_FORCED_CHARGE_START = 36
IDX_FORCED_CHARGE_END = 37
IDX_ALLOWED_DISCHARGE_START = 38
IDX_ALLOWED_DISCHARGE_END = 39
IDX_HOT_STANDBY = 185

WORK_MODES = {
    0: "self_use",
    2: "backup_mode",
}

# Observed on this inverter:
#   0 = Enable, 1 = Disable
HOT_STANDBY = {
    0: True,
    1: False,
}



class SolaxConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class SolaxConfig:
    inverter_time: str
    work_mode_code: int
    work_mode: str
    min_soc_pct: int
    charge_from_grid: bool
    charge_to_soc_pct: int
    forced_charge_start: str
    forced_charge_end: str
    allowed_discharge_start: str
    allowed_discharge_end: str
    hot_standby: bool
    hot_standby_code: int


def decode_hhmm(value: int) -> str:
    hour = value & 0xFF
    minute = (value >> 8) & 0xFF
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise SolaxConfigError(f"Invalid encoded time value {value}: {hour:02d}:{minute:02d}")
    return f"{hour:02d}:{minute:02d}"


def decode_rtc(data: list[int]) -> str:
    minute_second = data[IDX_RTC_MINUTE_SECOND]
    day_hour = data[IDX_RTC_DAY_HOUR]
    year_month = data[IDX_RTC_YEAR_MONTH]

    second = minute_second & 0xFF
    minute = (minute_second >> 8) & 0xFF
    hour = day_hour & 0xFF
    day = (day_hour >> 8) & 0xFF
    month = year_month & 0xFF
    year = 2000 + ((year_month >> 8) & 0xFF)

    try:
        return datetime(year, month, day, hour, minute, second).isoformat()
    except ValueError as exc:
        raise SolaxConfigError(
            "Invalid inverter RTC decoded from ReadSetData: "
            f"{year:04d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}:{second:02d}"
        ) from exc


def read_set_data() -> list[int]:
    if not SOLAX_PASSWORD:
        raise SolaxConfigError("SOLAX_PASSWORD is not configured")

    payload = urllib.parse.urlencode(
        {"optType": "ReadSetData", "pwd": SOLAX_PASSWORD}
    ).encode("utf-8")

    request = urllib.request.Request(
        SOLAX_URL,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            raw = response.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise SolaxConfigError(f"ReadSetData request failed: {exc}") from exc

    try:
        document: Any = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SolaxConfigError("ReadSetData returned invalid JSON") from exc

    # Current local endpoint returns the settings array directly. Accept
    # {"Data": [...]} as well so the adapter remains tolerant of wrapper variants.
    if isinstance(document, list):
        data = document
    elif isinstance(document, dict) and isinstance(document.get("Data"), list):
        data = document["Data"]
    else:
        raise SolaxConfigError("Unexpected ReadSetData response shape")

    required_max_index = IDX_HOT_STANDBY
    if len(data) <= required_max_index:
        raise SolaxConfigError(
            f"ReadSetData is too short: {len(data)} values, need at least {required_max_index + 1}"
        )

    if not all(isinstance(value, int) for value in data):
        raise SolaxConfigError("ReadSetData contains non-integer values")

    return data


def parse_config(data: list[int]) -> SolaxConfig:
    work_mode_code = data[IDX_WORK_MODE]
    hot_standby_code = data[IDX_HOT_STANDBY]

    if hot_standby_code not in HOT_STANDBY:
        raise SolaxConfigError(
            f"Unknown hot_standby code {hot_standby_code}; refusing to guess"
        )


    return SolaxConfig(
        inverter_time=decode_rtc(data),
        work_mode_code=work_mode_code,
        work_mode=WORK_MODES.get(work_mode_code, f"unknown_{work_mode_code}"),
        min_soc_pct=data[IDX_MIN_SOC],
        charge_from_grid=bool(data[IDX_CHARGE_FROM_GRID]),
        charge_to_soc_pct=data[IDX_CHARGE_TO_SOC],
        forced_charge_start=decode_hhmm(data[IDX_FORCED_CHARGE_START]),
        forced_charge_end=decode_hhmm(data[IDX_FORCED_CHARGE_END]),
        allowed_discharge_start=decode_hhmm(data[IDX_ALLOWED_DISCHARGE_START]),
        allowed_discharge_end=decode_hhmm(data[IDX_ALLOWED_DISCHARGE_END]),
        hot_standby=HOT_STANDBY[hot_standby_code],
        hot_standby_code=hot_standby_code,
    )


def get_config() -> SolaxConfig:
    return parse_config(read_set_data())


def print_config(config: SolaxConfig, as_json: bool = False) -> None:
    values = asdict(config)
    if as_json:
        print(json.dumps(values, indent=2, sort_keys=True))
        return

    for key, value in values.items():
        print(f"{key}={value}")


def run_get(name: str) -> int:
    config = get_config()

    aliases = {
        "min_soc": ("min_soc_pct", config.min_soc_pct),
        "work_mode": ("work_mode", config.work_mode),
        "charge_from_grid": ("charge_from_grid", config.charge_from_grid),
        "charge_to_soc": ("charge_to_soc_pct", config.charge_to_soc_pct),
        "forced_charge_start": ("forced_charge_start", config.forced_charge_start),
        "forced_charge_end": ("forced_charge_end", config.forced_charge_end),
        "allowed_discharge_start": (
            "allowed_discharge_start",
            config.allowed_discharge_start,
        ),
        "allowed_discharge_end": (
            "allowed_discharge_end",
            config.allowed_discharge_end,
        ),
        "hot_standby": ("hot_standby", config.hot_standby),
        "inverter_time": ("inverter_time", config.inverter_time),
    }

    if name not in aliases:
        print(
            f"Unknown config key {name!r}. Available: {', '.join(sorted(aliases))}",
            file=sys.stderr,
        )
        return 2

    key, value = aliases[name]
    if isinstance(value, bool):
        rendered = "enabled" if value else "disabled"
    else:
        rendered = value
    print(f"{key}={rendered}")
    return 0


def serve() -> int:
    if CONTROLLER_MODE not in ALLOWED_MODES:
        print(
            f"Invalid CONTROLLER_MODE={CONTROLLER_MODE!r}; "
            f"expected one of {sorted(ALLOWED_MODES)}",
            file=sys.stderr,
        )
        return 2

    print(
        f"controller starting in {CONTROLLER_MODE.upper()} mode; "
        "background configuration polling belongs to readers",
        flush=True,
    )

    # The controller deliberately does not poll device configuration in the
    # background. Reader services own observed state/history. Direct reads
    # remain available here for transactional read-before-write/read-back
    # checks once SET operations are implemented.
    while True:
        time.sleep(3600)


def usage() -> None:
    print(
        "Usage:\n"
        "  controller.py serve\n"
        "  controller.py config [--json]\n"
        "  controller.py get <key>\n"
        "  controller.py raw\n"
        "\n"
        "This milestone is read-only; no SET operation is implemented."
    )


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "serve"

    try:
        if command == "serve":
            return serve()
        if command == "config":
            print_config(get_config(), as_json="--json" in argv[2:])
            return 0
        if command == "get":
            if len(argv) != 3:
                usage()
                return 2
            return run_get(argv[2])
        if command == "raw":
            print(json.dumps(read_set_data()))
            return 0

        usage()
        return 2
    except SolaxConfigError as exc:
        print(f"controller: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
