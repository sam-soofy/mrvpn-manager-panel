#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MRVPN Config Scheduler
Runs as a systemd service. Every 30 seconds it checks whether any schedule
entry matches the current day+time, and if so writes the stored TOML config
to /opt/masterdnsvpn/server_config.toml and restarts the VPN service.

Deduplication: the same schedule won't be applied twice in the same minute.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

PANEL_DIR = Path("/opt/mrvpn-manager-panel")
SCHEDULES_FILE = PANEL_DIR / "schedules.json"
SERVER_CFG = Path("/root/server_config.toml")

# Maps the 3-letter day names used in schedules.json → Python weekday() integers
# Monday=0 … Sunday=6
DAY_MAP: dict[str, int] = {
    "mon": 0,
    "tue": 1,
    "wed": 2,
    "thu": 3,
    "fri": 4,
    "sat": 5,
    "sun": 6,
}


def log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_schedules() -> list[dict]:
    """Read schedules.json; return [] on any error."""
    try:
        return json.loads(SCHEDULES_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        log(f"WARN: could not read schedules file: {e}")
        return []


def apply_config(config_content: str, schedule_name: str):
    """Write config to disk and restart the VPN service."""
    try:
        SERVER_CFG.write_text(config_content, encoding="utf-8")
        subprocess.run(["systemctl", "restart", "masterdnsvpn"], check=True)
        log(f"Applied schedule '{schedule_name}' and restarted masterdnsvpn")
    except Exception as e:
        log(f"ERROR applying schedule '{schedule_name}': {e}")


def main():
    log("MRVPN Config Scheduler started")

    # Track the last applied (schedule_id, HH:MM) pair to avoid re-applying
    # the same schedule multiple times within the same minute.
    last_applied: tuple[str, str] | None = None

    while True:
        now = datetime.now()
        current_hm = now.strftime("%H:%M")  # e.g. "22:00"
        current_dow = now.weekday()  # Monday=0, Sunday=6

        schedules = load_schedules()

        for s in schedules:
            s_time = s.get("time", "")
            s_days = [DAY_MAP[d] for d in s.get("days", []) if d in DAY_MAP]
            s_id = s.get("id", "")
            s_name = s.get("name", "Unnamed")
            config = s.get("config", "")

            # Only trigger when time matches AND today is in the schedule's days
            if s_time != current_hm or current_dow not in s_days:
                continue

            # Deduplicate: don't apply the same schedule twice in one minute
            key = (s_id, current_hm)
            if last_applied == key:
                continue

            if not config.strip():
                log(f"WARN: schedule '{s_name}' has empty config — skipping")
                continue

            if not SERVER_CFG.parent.exists():
                log(
                    f"ERROR: MasterDnsVPN directory not found ({SERVER_CFG.parent}) — skipping"
                )
                continue

            last_applied = key
            apply_config(config, s_name)
            break  # Apply only the first matching schedule per tick

        time.sleep(30)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Scheduler stopped.")
        sys.exit(0)
