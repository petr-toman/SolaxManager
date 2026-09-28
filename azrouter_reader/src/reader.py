import os
import time
from datetime import datetime, timezone

interval = int(os.getenv("POLL_INTERVAL_SECONDS", "5"))
url = os.getenv("AZROUTER_URL", "")

print(f"azrouter_reader starting; endpoint={url or 'not configured'}; interval={interval}s", flush=True)

while True:
    print(f"{datetime.now(timezone.utc).isoformat()} azrouter_reader: scaffold / no device adapter configured", flush=True)
    time.sleep(interval)
