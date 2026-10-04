import http.cookiejar
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

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, model_validator


SOLAX_URL = os.getenv("SOLAX_URL", "http://192.168.1.20").rstrip("/")
SOLAX_PASSWORD = os.getenv("SOLAX_PASSWORD", "")
SOLAX_HTTP_TIMEOUT_SECONDS = float(os.getenv("SOLAX_HTTP_TIMEOUT_SECONDS", "5"))

AZROUTER_URL = os.getenv("AZROUTER_URL", "http://192.168.1.21").rstrip("/")
AZROUTER_USERNAME = os.getenv("AZROUTER_USERNAME", "")
AZROUTER_PASSWORD = os.getenv("AZROUTER_PASSWORD", "")
AZROUTER_HTTP_TIMEOUT_SECONDS = float(os.getenv("AZROUTER_HTTP_TIMEOUT_SECONDS", "5"))

CONTROLLER_MODE = os.getenv("CONTROLLER_MODE", "dry-run").lower()
CONTROLLER_HOST = os.getenv("CONTROLLER_HOST", "0.0.0.0")
CONTROLLER_PORT = int(os.getenv("CONTROLLER_PORT", "8090"))
CONTROLLER_LOG_LEVEL = os.getenv("CONTROLLER_LOG_LEVEL", "info").lower()

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
IDX_PHASE_UNBALANCED = 116
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

# Empirically verified by before/after ReadSetData diff on the target inverter:
#   disabled -> 0, enabled -> 1
PHASE_UNBALANCED = {
    0: False,
    1: True,
}


class ControllerError(RuntimeError):
    pass


class SolaxConfigError(ControllerError):
    pass


class AzRouterError(ControllerError):
    pass


class ActionWindowError(ControllerError):
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
    phase_unbalanced: bool
    phase_unbalanced_code: int
    hot_standby: bool
    hot_standby_code: int


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def decode_hhmm(value: int) -> str:
    hour = value & 0xFF
    minute = (value >> 8) & 0xFF
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise SolaxConfigError(
            f"Invalid encoded time value {value}: {hour:02d}:{minute:02d}"
        )
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
            f"{year:04d}-{month:02d}-{day:02d} "
            f"{hour:02d}:{minute:02d}:{second:02d}"
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
        with urllib.request.urlopen(
            request, timeout=SOLAX_HTTP_TIMEOUT_SECONDS
        ) as response:
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
            f"ReadSetData is too short: {len(data)} values, "
            f"need at least {required_max_index + 1}"
        )

    if not all(isinstance(value, int) for value in data):
        raise SolaxConfigError("ReadSetData contains non-integer values")

    return data


def parse_config(data: list[int]) -> SolaxConfig:
    work_mode_code = data[IDX_WORK_MODE]
    phase_unbalanced_code = data[IDX_PHASE_UNBALANCED]
    hot_standby_code = data[IDX_HOT_STANDBY]

    if phase_unbalanced_code not in PHASE_UNBALANCED:
        raise SolaxConfigError(
            f"Unknown phase_unbalanced code {phase_unbalanced_code}; refusing to guess"
        )

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
        phase_unbalanced=PHASE_UNBALANCED[phase_unbalanced_code],
        phase_unbalanced_code=phase_unbalanced_code,
        hot_standby=HOT_STANDBY[hot_standby_code],
        hot_standby_code=hot_standby_code,
    )


def get_config() -> SolaxConfig:
    return parse_config(read_set_data())


class AzRouterClient:
    LOGIN_PATH = "/api/v1/login"
    STATUS_PATH = "/api/v1/status"
    DEVICES_PATH = "/api/v1/devices"
    SETTINGS_PATH = "/api/v1/settings"
    MASTER_BOOST_PATH = "/api/v1/system/boost"
    DEVICE_BOOST_PATH = "/api/v1/device/boost"

    def __init__(
        self,
        base_url: str,
        username: str,
        password: str,
        timeout: float,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.timeout = timeout
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )
        self.token: str | None = None

    def _credentials_configured(self) -> bool:
        if bool(self.username) != bool(self.password):
            raise AzRouterError(
                "AZROUTER_USERNAME and AZROUTER_PASSWORD must either both be set "
                "or both be empty"
            )
        return bool(self.username)

    def _decode_document(self, raw: bytes, path: str) -> Any:
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise AzRouterError(f"AZ Router {path} returned invalid JSON") from exc

    def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        *,
        retry_auth: bool = True,
        response_mode: str = "json",
    ) -> Any:
        url = f"{self.base_url}{path}"
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Accept": "application/json"}

        if body is not None:
            headers["Content-Type"] = "application/json"

        # AZ Router returns the login token as the raw response body and expects
        # it on write requests as a cookie named "token".
        if self.token:
            headers["Cookie"] = f"token={self.token}"

        request = urllib.request.Request(
            url,
            data=body,
            method=method,
            headers=headers,
        )

        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read()
                if response_mode == "text":
                    return raw.decode("utf-8", errors="strict").strip()
                if response_mode != "json":
                    raise AzRouterError(
                        f"Unsupported AZ Router response mode {response_mode!r}"
                    )
                return self._decode_document(raw, path)
        except urllib.error.HTTPError as exc:
            if (
                exc.code in (401, 403)
                and retry_auth
                and path != self.LOGIN_PATH
                and self._credentials_configured()
            ):
                self.login(force=True)
                return self._request(
                    method,
                    path,
                    payload,
                    retry_auth=False,
                    response_mode=response_mode,
                )

            try:
                error_body = exc.read().decode("utf-8", errors="replace")[:500]
            except Exception:
                error_body = ""
            suffix = f"; body={error_body}" if error_body else ""
            raise AzRouterError(
                f"AZ Router {method} {path} failed with HTTP {exc.code}{suffix}"
            ) from exc
        except UnicodeDecodeError as exc:
            raise AzRouterError(
                f"AZ Router {path} returned non-UTF-8 text"
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise AzRouterError(
                f"AZ Router {method} {path} request failed: {exc}"
            ) from exc

    def login(self, *, force: bool = False) -> None:
        if self.token and not force:
            return
        if not self._credentials_configured():
            # Some local firmware/API configurations allow write operations without
            # authentication. In that case let the actual write request decide.
            return

        token = self._request(
            "POST",
            self.LOGIN_PATH,
            {
                "data": {
                    "username": self.username,
                    "password": self.password,
                }
            },
            retry_auth=False,
            response_mode="text",
        )

        if not isinstance(token, str) or not token:
            raise AzRouterError("AZ Router login returned an empty token")

        # Verified on the target router: /api/v1/login returns the token itself
        # as plain response text (despite Content-Type: application/json).
        self.token = token

    def get_status(self) -> dict[str, Any]:
        document = self._request("GET", self.STATUS_PATH)
        if not isinstance(document, dict):
            raise AzRouterError("AZ Router status response is not an object")
        return document

    def get_settings(self) -> dict[str, Any]:
        document = self._request("GET", self.SETTINGS_PATH)
        if not isinstance(document, dict):
            raise AzRouterError("AZ Router settings response is not an object")
        return document

    def get_devices(self) -> list[dict[str, Any]]:
        document = self._request("GET", self.DEVICES_PATH)
        if isinstance(document, list):
            return [item for item in document if isinstance(item, dict)]
        if isinstance(document, dict) and isinstance(document.get("devices"), list):
            return [
                item
                for item in document["devices"]
                if isinstance(item, dict)
            ]
        raise AzRouterError("AZ Router devices response shape is not recognized")

    @staticmethod
    def _bool_value(value: Any, path: str) -> bool:
        if isinstance(value, bool):
            return value
        if isinstance(value, int) and value in (0, 1):
            return bool(value)
        if isinstance(value, str) and value in ("0", "1"):
            return value == "1"
        raise AzRouterError(f"Unsupported boolean value at {path}: {value!r}")

    def find_device(self, device_id: int) -> dict[str, Any]:
        for device in self.get_devices():
            common = device.get("common")
            if not isinstance(common, dict):
                continue
            try:
                current_id = int(common.get("id"))
            except (TypeError, ValueError):
                continue
            if current_id == device_id:
                return device
        raise AzRouterError(f"AZ Router device id={device_id} was not found")

    def get_device_boost(self, device_id: int) -> tuple[bool, str]:
        device = self.find_device(device_id)

        for section_name in ("power", "charge"):
            section = device.get(section_name)
            if isinstance(section, dict) and "boost" in section:
                path = f"{section_name}.boost"
                return self._bool_value(section["boost"], path), path

        if "boost" in device:
            return self._bool_value(device["boost"], "boost"), "boost"

        raise AzRouterError(
            f"AZ Router device id={device_id} does not expose a known boost field"
        )

    def get_master_boost(self) -> bool:
        document = self.get_status()
        system = document.get("system")
        if isinstance(system, dict) and "masterBoost" in system:
            return self._bool_value(system["masterBoost"], "system.masterBoost")
        if "masterBoost" in document:
            return self._bool_value(document["masterBoost"], "masterBoost")
        raise AzRouterError("AZ Router status does not expose masterBoost")

    def set_device_boost(self, device_id: int, enabled: bool) -> None:
        self.login()
        self._request(
            "POST",
            self.DEVICE_BOOST_PATH,
            {
                "data": {
                    "device": {"common": {"id": device_id}},
                    "boost": 1 if enabled else 0,
                }
            },
            response_mode="text",
        )

    def set_master_boost(self, enabled: bool) -> None:
        self.login()
        self._request(
            "POST",
            self.MASTER_BOOST_PATH,
            {"data": {"boost": 1 if enabled else 0}},
            response_mode="text",
        )


azrouter = AzRouterClient(
    AZROUTER_URL,
    AZROUTER_USERNAME,
    AZROUTER_PASSWORD,
    AZROUTER_HTTP_TIMEOUT_SECONDS,
)


class ActionWindowRequest(BaseModel):
    enabled: bool
    verification_elapsed_ms: int = Field(
        default=750,
        ge=0,
        le=10000,
        description=(
            "Delay in milliseconds between a hardware write and the read-back "
            "verification. Use this to tune devices with eventually consistent "
            "HTTP state."
        ),
    )
    valid_from: datetime | None = Field(
        default=None,
        description="Optional earliest execution time. This is a validity guard, not a scheduler.",
    )
    valid_until: datetime | None = Field(
        default=None,
        description="Optional latest execution time. This is a validity guard, not a scheduler.",
    )
    requested_by: str = Field(default="api", min_length=1, max_length=64)

    @model_validator(mode="after")
    def validate_window(self) -> "ActionWindowRequest":
        for name, value in (
            ("valid_from", self.valid_from),
            ("valid_until", self.valid_until),
        ):
            if value is not None and value.tzinfo is None:
                raise ValueError(f"{name} must contain a timezone offset")

        if (
            self.valid_from is not None
            and self.valid_until is not None
            and self.valid_from > self.valid_until
        ):
            raise ValueError("valid_from must not be later than valid_until")
        return self


class DeviceBoostRequest(ActionWindowRequest):
    device_id: int = Field(ge=0)


def validate_mode() -> None:
    if CONTROLLER_MODE not in ALLOWED_MODES:
        raise ControllerError(
            f"Invalid CONTROLLER_MODE={CONTROLLER_MODE!r}; "
            f"expected one of {sorted(ALLOWED_MODES)}"
        )


def check_action_window(
    valid_from: datetime | None,
    valid_until: datetime | None,
) -> None:
    now = utc_now()

    if valid_from is not None and now < valid_from.astimezone(timezone.utc):
        raise ActionWindowError(
            f"Action is not valid before {valid_from.isoformat()}"
        )
    if valid_until is not None and now > valid_until.astimezone(timezone.utc):
        raise ActionWindowError(
            f"Action expired at {valid_until.isoformat()}"
        )


def action_result(
    *,
    action: str,
    target: str,
    requested: bool,
    previous: bool,
    current: bool,
    changed: bool,
    verified: bool,
    executed: bool,
    requested_by: str,
    status_text: str,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "ok": (
            status_text not in {"controller_off", "verification_failed"}
            and (not executed or verified)
        ),
        "status": status_text,
        "device": "azrouter",
        "action": action,
        "target": target,
        "requested": requested,
        "previous": previous,
        "current": current,
        "changed": changed,
        "executed": executed,
        "verified": verified,
        "controller_mode": CONTROLLER_MODE,
        "requested_by": requested_by,
        "completed_at": utc_now().isoformat(),
    }
    if extra:
        result.update(extra)
    return result


def perform_device_boost(request: DeviceBoostRequest) -> dict[str, Any]:
    validate_mode()
    check_action_window(request.valid_from, request.valid_until)

    previous, boost_field = azrouter.get_device_boost(request.device_id)
    target = f"device:{request.device_id}"

    if previous == request.enabled:
        return action_result(
            action="device_boost",
            target=target,
            requested=request.enabled,
            previous=previous,
            current=previous,
            changed=False,
            executed=False,
            verified=True,
            requested_by=request.requested_by,
            status_text="unchanged",
            extra={
                "boost_field": boost_field,
                "verification_elapsed_ms": request.verification_elapsed_ms,
            },
        )

    if CONTROLLER_MODE == "off":
        return action_result(
            action="device_boost",
            target=target,
            requested=request.enabled,
            previous=previous,
            current=previous,
            changed=False,
            executed=False,
            verified=False,
            requested_by=request.requested_by,
            status_text="controller_off",
            extra={
                "boost_field": boost_field,
                "verification_elapsed_ms": request.verification_elapsed_ms,
            },
        )

    if CONTROLLER_MODE == "dry-run":
        return action_result(
            action="device_boost",
            target=target,
            requested=request.enabled,
            previous=previous,
            current=previous,
            changed=False,
            executed=False,
            verified=False,
            requested_by=request.requested_by,
            status_text="dry_run",
            extra={
                "boost_field": boost_field,
                "verification_elapsed_ms": request.verification_elapsed_ms,
            },
        )

    azrouter.set_device_boost(request.device_id, request.enabled)
    if request.verification_elapsed_ms:
        time.sleep(request.verification_elapsed_ms / 1000.0)
    current, current_field = azrouter.get_device_boost(request.device_id)
    verified = current == request.enabled

    return action_result(
        action="device_boost",
        target=target,
        requested=request.enabled,
        previous=previous,
        current=current,
        changed=current != previous,
        executed=True,
        verified=verified,
        requested_by=request.requested_by,
        status_text="changed" if verified else "verification_failed",
        extra={
            "boost_field": current_field,
            "verification_elapsed_ms": request.verification_elapsed_ms,
        },
    )


def perform_master_boost(request: ActionWindowRequest) -> dict[str, Any]:
    validate_mode()
    check_action_window(request.valid_from, request.valid_until)

    previous = azrouter.get_master_boost()

    if previous == request.enabled:
        return action_result(
            action="master_boost",
            target="master",
            requested=request.enabled,
            previous=previous,
            current=previous,
            changed=False,
            executed=False,
            verified=True,
            requested_by=request.requested_by,
            status_text="unchanged",
        )

    if CONTROLLER_MODE == "off":
        return action_result(
            action="master_boost",
            target="master",
            requested=request.enabled,
            previous=previous,
            current=previous,
            changed=False,
            executed=False,
            verified=False,
            requested_by=request.requested_by,
            status_text="controller_off",
        )

    if CONTROLLER_MODE == "dry-run":
        return action_result(
            action="master_boost",
            target="master",
            requested=request.enabled,
            previous=previous,
            current=previous,
            changed=False,
            executed=False,
            verified=False,
            requested_by=request.requested_by,
            status_text="dry_run",
        )

    azrouter.set_master_boost(request.enabled)
    if request.verification_elapsed_ms:
        time.sleep(request.verification_elapsed_ms / 1000.0)
    current = azrouter.get_master_boost()
    verified = current == request.enabled

    return action_result(
        action="master_boost",
        target="master",
        requested=request.enabled,
        previous=previous,
        current=current,
        changed=current != previous,
        executed=True,
        verified=verified,
        requested_by=request.requested_by,
        status_text="changed" if verified else "verification_failed",
        extra={"verification_elapsed_ms": request.verification_elapsed_ms},
    )


app = FastAPI(
    title="SolaxManager Controller API",
    version="0.6.1",
    description=(
        "Hardware control boundary for SolaX and AZ Router. "
        "Readers remain read-only; all hardware writes belong here. "
        "Interactive Swagger UI is available at /docs."
    ),
)


def api_device_error(exc: ControllerError) -> HTTPException:
    return HTTPException(status_code=502, detail=str(exc))


@app.get("/health", tags=["service"])
def health() -> dict[str, Any]:
    try:
        validate_mode()
        state = "ok"
    except ControllerError:
        state = "configuration_error"

    return {
        "status": state,
        "mode": CONTROLLER_MODE,
        "writes_enabled": CONTROLLER_MODE in {"manual", "auto"},
        "time": utc_now().isoformat(),
    }


@app.get("/api/capabilities", tags=["service"])
def capabilities() -> dict[str, Any]:
    return {
        "mode": CONTROLLER_MODE,
        "writes_enabled": CONTROLLER_MODE in {"manual", "auto"},
        "action_window": (
            "valid_from/valid_until are execution guards only; "
            "the controller does not schedule future actions"
        ),
        "solax": {
            "reads": [
                "config",
                "min_soc",
                "work_mode",
                "charge_from_grid",
                "charge_to_soc",
                "forced_charge_start",
                "forced_charge_end",
                "allowed_discharge_start",
                "allowed_discharge_end",
                "phase_unbalanced",
                "hot_standby",
                "inverter_time",
            ],
            "actions": [],
        },
        "azrouter": {
            "reads": ["status", "settings", "devices"],
            "actions": ["device_boost", "master_boost"],
        },
    }


@app.get("/api/solax/config", tags=["SolaX"])
def api_solax_config() -> dict[str, Any]:
    try:
        return asdict(get_config())
    except ControllerError as exc:
        raise api_device_error(exc) from exc


@app.get("/api/azrouter/status", tags=["AZ Router"])
def api_azrouter_status() -> dict[str, Any]:
    try:
        return azrouter.get_status()
    except ControllerError as exc:
        raise api_device_error(exc) from exc


@app.get("/api/azrouter/config", tags=["AZ Router"])
def api_azrouter_config() -> dict[str, Any]:
    try:
        return azrouter.get_settings()
    except ControllerError as exc:
        raise api_device_error(exc) from exc


@app.get("/api/azrouter/devices", tags=["AZ Router"])
def api_azrouter_devices() -> list[dict[str, Any]]:
    try:
        return azrouter.get_devices()
    except ControllerError as exc:
        raise api_device_error(exc) from exc


@app.post("/api/actions/azrouter/device-boost", tags=["AZ Router actions"])
def api_device_boost(request: DeviceBoostRequest) -> Any:
    try:
        result = perform_device_boost(request)
    except ActionWindowError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ControllerError as exc:
        raise api_device_error(exc) from exc

    if result["status"] == "controller_off":
        return JSONResponse(status_code=409, content=result)
    if result["status"] == "verification_failed":
        return JSONResponse(status_code=502, content=result)
    return result


@app.post("/api/actions/azrouter/master-boost", tags=["AZ Router actions"])
def api_master_boost(request: ActionWindowRequest) -> Any:
    try:
        result = perform_master_boost(request)
    except ActionWindowError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ControllerError as exc:
        raise api_device_error(exc) from exc

    if result["status"] == "controller_off":
        return JSONResponse(status_code=409, content=result)
    if result["status"] == "verification_failed":
        return JSONResponse(status_code=502, content=result)
    return result


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
        "phase_unbalanced": ("phase_unbalanced", config.phase_unbalanced),
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
    validate_mode()
    print(
        f"controller starting in {CONTROLLER_MODE.upper()} mode on "
        f"{CONTROLLER_HOST}:{CONTROLLER_PORT}; Swagger UI: /docs",
        flush=True,
    )
    uvicorn.run(
        app,
        host=CONTROLLER_HOST,
        port=CONTROLLER_PORT,
        log_level=CONTROLLER_LOG_LEVEL,
    )
    return 0


def usage() -> None:
    print(
        "Usage:\n"
        "  controller.py serve\n"
        "  controller.py config [--json]\n"
        "  controller.py get <key>\n"
        "  controller.py raw\n"
        "\n"
        "REST API when serving:\n"
        f"  http://127.0.0.1:{CONTROLLER_PORT}/docs\n"
        f"  http://127.0.0.1:{CONTROLLER_PORT}/openapi.json\n"
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
    except ControllerError as exc:
        print(f"controller: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
