#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MRVPN Manager Panel - Clean version with external templates + JS"""

from __future__ import annotations

import json
import os
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

import psutil
from flask import Flask, jsonify, render_template, request, send_from_directory
from flask_socketio import SocketIO

# Modules
from modules.auth import (blacklist_token, create_access_token,
                          create_refresh_token, verify_token)
from modules.config_editor import (read_config, read_key, write_config,
                                   write_key)
from modules.service_manager import restart_masterdnsvpn

# ========================= CONFIG =========================
BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "mrvpn_manager_config.json"
DEFAULT_WEB_PORT = 5000
DEFAULT_MONITOR_REFRESH = 2

app = Flask(__name__, template_folder="templates", static_folder="static")
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

config = (
    json.loads(CONFIG_FILE.read_text())
    if CONFIG_FILE.exists()
    else {"web_port": DEFAULT_WEB_PORT, "monitoring_refresh": DEFAULT_MONITOR_REFRESH}
)

# ========================= MONITORING STATE =========================
state_lock = threading.Lock()
latest_snapshot: Dict[str, Any] = {
    "health": {"cpu": 0.0, "ram": 0.0, "disk": 0.0},
    "speed": {"rx": 0.0, "tx": 0.0},
    "ifaces": {},
    "updated_at": None,
}


def get_health() -> Dict[str, float]:
    return {
        "cpu": psutil.cpu_percent(interval=None),
        "ram": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
    }


def get_net() -> tuple[int, int]:
    c = psutil.net_io_counters()
    return c.bytes_recv, c.bytes_sent


def get_ifaces() -> Dict[str, Dict[str, float]]:
    result = {}
    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as f:
            for line in f.readlines()[2:]:
                parts = line.split()
                iface = parts[0].replace(":", "")
                result[iface] = {
                    "rx": round(float(parts[1]) / (1024**3), 2),
                    "tx": round(float(parts[9]) / (1024**3), 2),
                }
    except Exception:
        pass
    return result


def update_snapshot(health, speed, ifaces):
    with state_lock:
        latest_snapshot.update(
            {
                "health": health,
                "speed": speed.copy(),
                "ifaces": ifaces,
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            }
        )


# ========================= JWT ROUTES =========================
@app.route("/api/auth/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    if data.get("username") == "admin" and data.get("password"):
        return jsonify(
            {
                "ok": True,
                "access_token": create_access_token(),
                "refresh_token": create_refresh_token(),
            }
        )
    return jsonify({"ok": False, "error": "invalid_credentials"}), 401


@app.route("/api/auth/refresh", methods=["POST"])
def api_refresh():
    data = request.get_json(silent=True) or {}
    token = data.get("refresh_token")
    if token and verify_token(token, "refresh"):
        blacklist_token(token)
        return jsonify(
            {
                "ok": True,
                "access_token": create_access_token(),
                "refresh_token": create_refresh_token(),
            }
        )
    return jsonify({"ok": False, "error": "invalid_refresh"}), 401


# ========================= CONFIG EDITOR =========================
@app.route("/api/config/server", methods=["GET", "POST"])
def config_server():
    if request.method == "GET":
        return jsonify({"content": read_config()})
    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify(
            {
                "requires_confirmation": True,
                "message": "This will save and restart MasterDnsVPN. Continue?",
            }
        )
    success = write_config(data.get("content", ""), confirmed=True)
    return jsonify(
        {"ok": success, "message": "Saved and restarted" if success else "Failed"}
    )


@app.route("/api/config/key", methods=["GET", "POST"])
def config_key():
    if request.method == "GET":
        return jsonify({"content": read_key()})
    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify(
            {
                "requires_confirmation": True,
                "message": "This will save and restart MasterDnsVPN. Continue?",
            }
        )
    success = write_key(data.get("content", ""), confirmed=True)
    return jsonify(
        {"ok": success, "message": "Saved and restarted" if success else "Failed"}
    )


# ========================= SERVICE =========================
@app.route("/api/restart", methods=["POST"])
def api_restart():
    return jsonify({"ok": restart_masterdnsvpn()})


@app.route("/api/status", methods=["GET"])
def api_status():
    with state_lock:
        return jsonify(latest_snapshot)


# ========================= STATIC & TEMPLATES =========================
@app.route("/")
def index():
    return render_template("dashboard.html")


@app.route("/login")
def login_page():
    return render_template("login.html")


@app.route("/static/js/<path:filename>")
def serve_js(filename):
    return send_from_directory("static/js", filename)


# ========================= MONITOR THREAD =========================
def monitor():
    last_rx, last_tx = get_net()
    last_t = time.time()
    psutil.cpu_percent(interval=None)

    while True:
        try:
            health = get_health()
            rx, tx = get_net()
            dt = max(time.time() - last_t, 1e-6)
            speed = {
                "rx": (rx - last_rx) / dt / 1024 / 1024,
                "tx": (tx - last_tx) / dt / 1024 / 1024,
            }
            ifaces = get_ifaces()

            update_snapshot(health, speed, ifaces)
            socketio.emit(
                "update", {"health": health, "speed": speed, "ifaces": ifaces}
            )

            last_rx, last_tx, last_t = rx, tx, time.time()
            time.sleep(config.get("monitoring_refresh", DEFAULT_MONITOR_REFRESH))
        except Exception:
            time.sleep(2)


threading.Thread(target=monitor, daemon=True).start()

# ========================= START =========================
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
