#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MRVPN Manager Panel"""

from __future__ import annotations

import json
import os
from pathlib import Path

from flask import Flask
from flask_socketio import SocketIO

from modules.monitor import start_monitor
from modules.routes import register_blueprints

# ── Panel config ──────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "mrvpn_manager_config.json"

DEFAULT_WEB_PORT = 5000
DEFAULT_MONITOR_REFRESH = 2

config: dict = (
    json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    if CONFIG_FILE.exists()
    else {"web_port": DEFAULT_WEB_PORT, "monitoring_refresh": DEFAULT_MONITOR_REFRESH}
)

# ── App setup ─────────────────────────────────────────────────────────────────
app = Flask(__name__, template_folder="templates", static_folder="static")
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

register_blueprints(app)

# ── Background monitor ────────────────────────────────────────────────────────
start_monitor(socketio, refresh_interval=config.get("monitoring_refresh", DEFAULT_MONITOR_REFRESH))

# ── Run ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if os.geteuid() != 0:
        print("Run as root")
        exit(1)
    socketio.run(
        app,
        host="0.0.0.0",
        port=int(config.get("web_port", DEFAULT_WEB_PORT)),
        allow_unsafe_werkzeug=True,
        use_reloader=False,
    )
