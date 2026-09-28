import os
import time
from datetime import datetime, timezone

interval = int(os.getenv("REPORT_INTERVAL_SECONDS", "60"))
retention = int(os.getenv("RAW_RETENTION_DAYS", "30"))

print(f"reporter starting; interval={interval}s raw_retention={retention}d", flush=True)

while True:
    print(f"{datetime.now(timezone.utc).isoformat()} reporter: scaffold tick", flush=True)
    time.sleep(interval)
