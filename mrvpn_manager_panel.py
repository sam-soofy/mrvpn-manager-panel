#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MRVPN Manager Panel"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from datetime import datetime
from functools import wraps
from pathlib import Path
from typing import Any, Dict

import psutil
from flask import Flask, jsonify, render_template, request, send_from_directory
from flask_socketio import SocketIO

from modules.auth import (blacklist_token, create_access_token,
                          create_refresh_token, verify_token)
from modules.config_editor import (read_config, read_key, write_config,
                                   write_key)
from modules.service_manager import restart_masterdnsvpn

# ========================= CONFIG =========================
BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "mrvpn_manager_config.json"
SCHEDULES_FILE = BASE_DIR / "schedules.json"
DEFAULT_WEB_PORT = 5000
DEFAULT_MONITOR_REFRESH = 2

# Password is read from the file on every startup.
# To reset: edit this file, then: systemctl restart mrvpn-manager-panel
PASS_FILE = BASE_DIR / "admin_pass.txt"
ADMIN_PASSWORD = (
    PASS_FILE.read_text(encoding="utf-8").strip()
    if PASS_FILE.exists()
    else os.environ.get("ADMIN_PASSWORD", "")  # fallback for legacy installs
)

app = Flask(__name__, template_folder="templates", static_folder="static")
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

config = (
    json.loads(CONFIG_FILE.read_text())
    if CONFIG_FILE.exists()
    else {"web_port": DEFAULT_WEB_PORT, "monitoring_refresh": DEFAULT_MONITOR_REFRESH}
)

# ========================= AUTH HELPERS =========================

def require_auth(f):
    """Decorator that validates the Bearer JWT on every protected route."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        if not verify_token(token, "access"):
            return jsonify({"ok": False, "error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


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
    username = data.get("username", "")
    password = data.get("password", "")

    # ADMIN_PASSWORD must be set (via systemd Environment= in service file).
    # If somehow empty, refuse all logins so the server isn't wide open.
    if not ADMIN_PASSWORD:
        return jsonify({"ok": False, "error": "server_misconfigured"}), 500

    if username == "admin" and password == ADMIN_PASSWORD:
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
@require_auth
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
@require_auth
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
@require_auth
def api_restart():
    return jsonify({"ok": restart_masterdnsvpn()})


@app.route("/api/status", methods=["GET"])
@require_auth
def api_status():
    with state_lock:
        return jsonify(latest_snapshot)


# ========================= SCHEDULER =========================

def _load_schedules() -> list:
    if SCHEDULES_FILE.exists():
        try:
            return json.loads(SCHEDULES_FILE.read_text())
        except Exception:
            return []
    return []


def _save_schedules(schedules: list):
    SCHEDULES_FILE.write_text(json.dumps(schedules, indent=2))


@app.route("/api/schedules", methods=["GET"])
@require_auth
def get_schedules():
    """Return all schedules (config content omitted to keep response small)."""
    schedules = _load_schedules()
    # Strip full config from list view — client fetches it on demand via GET /<id>
    preview = [
        {k: v for k, v in s.items() if k != "config"}
        for s in schedules
    ]
    return jsonify(preview)


@app.route("/api/schedules", methods=["POST"])
@require_auth
def add_schedule():
    """
    Create a new schedule entry.
    Body: { name, time ("HH:MM"), days (["mon","tue",...]), config (TOML string) }
    """
    data = request.get_json(silent=True) or {}
    time_val = data.get("time", "")
    # Validate HH:MM format
    try:
        datetime.strptime(time_val, "%H:%M")
    except ValueError:
        return jsonify({"ok": False, "error": "invalid_time_format"}), 400

    all_days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    days = [d for d in data.get("days", all_days) if d in all_days]

    entry = {
        "id": str(uuid.uuid4()),
        "name": data.get("name", "Unnamed").strip() or "Unnamed",
        "time": time_val,
        "days": days,
        "config": data.get("config", ""),
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }
    schedules = _load_schedules()
    schedules.append(entry)
    _save_schedules(schedules)
    return jsonify({"ok": True, "id": entry["id"]})


@app.route("/api/schedules/<schedule_id>", methods=["GET"])
@require_auth
def get_schedule(schedule_id: str):
    """Fetch a single schedule including its full config content."""
    schedules = _load_schedules()
    for s in schedules:
        if s["id"] == schedule_id:
            return jsonify(s)
    return jsonify({"ok": False, "error": "not_found"}), 404


@app.route("/api/schedules/<schedule_id>", methods=["PUT"])
@require_auth
def update_schedule(schedule_id: str):
    """Update an existing schedule."""
    data = request.get_json(silent=True) or {}
    schedules = _load_schedules()
    for s in schedules:
        if s["id"] == schedule_id:
            if "name" in data:
                s["name"] = data["name"].strip() or "Unnamed"
            if "time" in data:
                try:
                    datetime.strptime(data["time"], "%H:%M")
                except ValueError:
                    return jsonify({"ok": False, "error": "invalid_time_format"}), 400
                s["time"] = data["time"]
            if "days" in data:
                all_days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
                s["days"] = [d for d in data["days"] if d in all_days]
            if "config" in data:
                s["config"] = data["config"]
            _save_schedules(schedules)
            return jsonify({"ok": True})
    return jsonify({"ok": False, "error": "not_found"}), 404


@app.route("/api/schedules/<schedule_id>", methods=["DELETE"])
@require_auth
def delete_schedule(schedule_id: str):
    schedules = _load_schedules()
    new_schedules = [s for s in schedules if s["id"] != schedule_id]
    if len(new_schedules) == len(schedules):
        return jsonify({"ok": False, "error": "not_found"}), 404
    _save_schedules(new_schedules)
    return jsonify({"ok": True})


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
