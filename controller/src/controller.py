import os
import time
from datetime import datetime, timezone

mode = os.getenv("CONTROLLER_MODE", "dry-run").lower()
allowed = {"off", "manual", "dry-run", "auto"}

if mode not in allowed:
    raise SystemExit(f"Invalid CONTROLLER_MODE={mode!r}; expected one of {sorted(allowed)}")

print(f"controller starting in {mode.upper()} mode", flush=True)

while True:
    print(
        f"{datetime.now(timezone.utc).isoformat()} controller: "
        f"mode={mode}; device adapter not implemented yet",
        flush=True,
    )
    time.sleep(60)
