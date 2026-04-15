#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MRVPN Manager Panel

Drop-in rewrite of the original module with:
- HTML login page
- HTML dashboard UI
- JSON API compatibility for existing clients
- Same core monitoring/restart behavior
- Cleaner structure and safer request handling
"""

from __future__ import annotations

import json
import os
import secrets
import string
import subprocess
import threading
import time
from collections import deque
from datetime import datetime
from functools import wraps
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import psutil
from flask import (Flask, jsonify, redirect, render_template_string, request,
                   session, url_for)
from flask_socketio import SocketIO
from werkzeug.security import check_password_hash, generate_password_hash

# =========================
# CONFIG
# =========================
BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "mrvpn_manager_config.json"
SERVICE_NAME = "masterdnsvpn"

DEFAULT_USERNAME = "admin"
DEFAULT_WEB_PORT = 5000
DEFAULT_MONITOR_REFRESH = 2

# =========================
# APP
# =========================
app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

# =========================
# STATE
# =========================
state_lock = threading.Lock()
cpu_data = deque(maxlen=30)
memory_data = deque(maxlen=30)
network_speed = {"rx": 0.0, "tx": 0.0}
active_connections = 0
last_restart_time: Optional[datetime] = None
monitor_thread_started = False

# Cache latest monitoring snapshot for the dashboard/API.
latest_snapshot: Dict[str, Any] = {
    "health": {"cpu": 0.0, "ram": 0.0, "disk": 0.0},
    "speed": {"rx": 0.0, "tx": 0.0},
    "ifaces": {},
    "updated_at": None,
}

# =========================
# UTILITIES
# =========================


def gen_pass(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def load_or_create_config() -> Dict[str, Any]:
    if CONFIG_FILE.exists():
        with CONFIG_FILE.open("r", encoding="utf-8") as f:
            return json.load(f)

    password = gen_pass()
    cfg = {
        "username": DEFAULT_USERNAME,
        "password_hash": generate_password_hash(password),
        "secret_key": gen_pass(32),
        "web_port": DEFAULT_WEB_PORT,
        "monitoring_refresh": DEFAULT_MONITOR_REFRESH,
    }
    with CONFIG_FILE.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=4)

    print("\n=== LOGIN ===")
    print("User:", cfg["username"])
    print("Pass:", password)
    print("============\n")

    return cfg


def is_json_request() -> bool:
    return request.is_json or (
        request.headers.get("Content-Type", "").startswith("application/json")
    )


def read_login_payload() -> Tuple[Optional[str], Optional[str]]:
    if request.method == "POST" and is_json_request():
        data = request.get_json(silent=True) or {}
        return data.get("username"), data.get("password")

    return request.form.get("username"), request.form.get("password")


def get_health() -> Dict[str, float]:
    return {
        "cpu": psutil.cpu_percent(interval=None),
        "ram": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
    }


def get_net() -> Tuple[int, int]:
    counters = psutil.net_io_counters()
    return counters.bytes_recv, counters.bytes_sent


def get_ifaces() -> Dict[str, Dict[str, float]]:
    result: Dict[str, Dict[str, float]] = {}
    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as f:
            lines = f.readlines()[2:]
        for line in lines:
            parts = line.split()
            iface = parts[0].replace(":", "")
            result[iface] = {
                "rx": round(float(parts[1]) / (1024**3), 2),
                "tx": round(float(parts[9]) / (1024**3), 2),
            }
    except Exception:
        # Keep the panel working even if interface stats cannot be read.
        pass
    return result


def restart_service() -> bool:
    global last_restart_time
    try:
        subprocess.run(["systemctl", "restart", SERVICE_NAME], check=True)
        last_restart_time = datetime.now()
        return True
    except Exception:
        return False


def update_latest_snapshot(
    health: Dict[str, float], speed: Dict[str, float], ifaces: Dict[str, Any]
) -> None:
    with state_lock:
        latest_snapshot["health"] = health
        latest_snapshot["speed"] = speed.copy()
        latest_snapshot["ifaces"] = ifaces
        latest_snapshot["updated_at"] = datetime.now().isoformat(timespec="seconds")


def current_snapshot() -> Dict[str, Any]:
    with state_lock:
        return {
            "health": dict(latest_snapshot["health"]),
            "speed": dict(latest_snapshot["speed"]),
            "ifaces": dict(latest_snapshot["ifaces"]),
            "updated_at": latest_snapshot["updated_at"],
            "last_restart_time": (
                last_restart_time.isoformat(timespec="seconds")
                if last_restart_time
                else None
            ),
            "active_connections": active_connections,
        }


# =========================
# CONFIG LOAD
# =========================
config = load_or_create_config()
app.config["SECRET_KEY"] = config["secret_key"]

# =========================
# AUTH
# =========================


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("ok"):
            next_url = request.path if request.path else "/"
            return redirect(url_for("login", next=next_url))
        return view(*args, **kwargs)

    return wrapped


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username, password = read_login_payload()

        if (
            username == config.get("username")
            and password is not None
            and check_password_hash(config.get("password_hash", ""), password)
        ):
            session["ok"] = True

            if is_json_request():
                return jsonify({"ok": True, "redirect": url_for("index")})

            return redirect(url_for("index"))

        if is_json_request():
            return jsonify({"ok": False, "error": "invalid_credentials"}), 401

        return render_template_string(LOGIN_HTML, error="Invalid username or password.")

    # GET
    if session.get("ok"):
        return redirect(url_for("index"))

    return render_template_string(LOGIN_HTML, error=None)


@app.route("/logout", methods=["GET", "POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


# =========================
# CORE API
# =========================
@app.route("/")
@login_required
def index():
    return render_template_string(
        DASHBOARD_HTML,
        service_name=SERVICE_NAME,
        web_port=config.get("web_port", DEFAULT_WEB_PORT),
        username=config.get("username", DEFAULT_USERNAME),
    )


@app.route("/api/restart", methods=["POST"])
@login_required
def api_restart():
    return jsonify({"ok": restart_service()})


@app.route("/api/status", methods=["GET"])
@login_required
def api_status():
    return jsonify(current_snapshot())


@app.route("/api/me", methods=["GET"])
@login_required
def api_me():
    return jsonify(
        {
            "ok": True,
            "username": config.get("username", DEFAULT_USERNAME),
            "service_name": SERVICE_NAME,
            "web_port": config.get("web_port", DEFAULT_WEB_PORT),
        }
    )


# =========================
# MONITOR THREAD
# =========================


def monitor() -> None:
    last_rx, last_tx = get_net()
    last_t = time.time()

    # Warm up psutil's CPU reading so the first live value is meaningful.
    psutil.cpu_percent(interval=None)

    while True:
        try:
            health = get_health()
            now = time.time()
            rx, tx = get_net()

            dt = max(now - last_t, 1e-6)
            sp_rx = (rx - last_rx) / dt / 1024 / 1024
            sp_tx = (tx - last_tx) / dt / 1024 / 1024

            with state_lock:
                cpu_data.append(health["cpu"])
                memory_data.append(health["ram"])
                network_speed["rx"] = sp_rx
                network_speed["tx"] = sp_tx

            ifaces = get_ifaces()
            update_latest_snapshot(health, network_speed, ifaces)

            socketio.emit(
                "update",
                {
                    "health": health,
                    "speed": {"rx": sp_rx, "tx": sp_tx},
                    "ifaces": ifaces,
                    "meta": current_snapshot(),
                },
            )

            last_rx, last_tx, last_t = rx, tx, now
            time.sleep(config.get("monitoring_refresh", DEFAULT_MONITOR_REFRESH))
        except Exception as exc:
            print("ERR:", exc)
            time.sleep(2)


def start_monitor_once() -> None:
    global monitor_thread_started
    if monitor_thread_started:
        return

    monitor_thread_started = True
    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()


# =========================
# HTML
# =========================
LOGIN_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MRVPN Login</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0b1020;
      --panel: #111933;
      --panel-2: #0f1730;
      --text: #e8eefc;
      --muted: #97a3c2;
      --border: #263253;
      --accent: #5b8cff;
      --danger: #ff6b6b;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: Arial, Helvetica, sans-serif;
      background: radial-gradient(circle at top, #152044, var(--bg));
      color: var(--text);
    }
    .card {
      width: min(420px, calc(100vw - 32px));
      background: rgba(17, 25, 51, 0.92);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 28px;
      box-shadow: 0 24px 80px rgba(0,0,0,.35);
    }
    h1 { margin: 0 0 8px; font-size: 28px; }
    p { margin: 0 0 20px; color: var(--muted); line-height: 1.5; }
    label {
      display: block;
      margin: 14px 0 8px;
      font-size: 14px;
      color: var(--muted);
    }
    input {
      width: 100%;
      border: 1px solid var(--border);
      background: var(--panel-2);
      color: var(--text);
      border-radius: 12px;
      padding: 12px 14px;
      font-size: 15px;
      outline: none;
    }
    input:focus { border-color: var(--accent); }
    button {
      width: 100%;
      margin-top: 18px;
      border: none;
      border-radius: 12px;
      padding: 12px 14px;
      background: var(--accent);
      color: white;
      font-size: 15px;
      font-weight: 700;
      cursor: pointer;
    }
    .error {
      margin-top: 14px;
      color: var(--danger);
      background: rgba(255, 107, 107, 0.12);
      border: 1px solid rgba(255, 107, 107, 0.35);
      padding: 10px 12px;
      border-radius: 12px;
      font-size: 14px;
    }
    .hint {
      margin-top: 16px;
      font-size: 13px;
      color: var(--muted);
      line-height: 1.45;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>MRVPN Panel</h1>
    <p>Sign in to access the dashboard and service controls.</p>
    <form method="post" action="/login">
      <label for="username">Username</label>
      <input id="username" name="username" autocomplete="username" required />

      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required />

      <button type="submit">Login</button>
    </form>
    {% if error %}
      <div class="error">{{ error }}</div>
    {% endif %}
    <div class="hint">
      You can still POST JSON to <code>/login</code> for API clients.
    </div>
  </div>
</body>
</html>
"""

DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MRVPN Dashboard</title>
  <script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0b1020;
      --panel: #111933;
      --panel-2: #0f1730;
      --text: #e8eefc;
      --muted: #97a3c2;
      --border: #263253;
      --accent: #5b8cff;
      --good: #31c48d;
      --warn: #f59e0b;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Arial, Helvetica, sans-serif;
      background: linear-gradient(180deg, #0b1020, #090d18);
      color: var(--text);
    }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 24px; }
    .topbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 18px;
      flex-wrap: wrap;
    }
    .title h1 { margin: 0; font-size: 28px; }
    .title p { margin: 6px 0 0; color: var(--muted); }
    .actions { display: flex; gap: 10px; flex-wrap: wrap; }
    .btn {
      border: 1px solid var(--border);
      background: var(--panel);
      color: var(--text);
      border-radius: 12px;
      padding: 10px 14px;
      cursor: pointer;
      text-decoration: none;
      font-size: 14px;
    }
    .btn.primary { background: var(--accent); border-color: transparent; }
    .grid {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 16px;
    }
    .card {
      background: rgba(17, 25, 51, 0.92);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 18px;
      box-shadow: 0 18px 50px rgba(0,0,0,.22);
    }
    .span-3 { grid-column: span 3; }
    .span-4 { grid-column: span 4; }
    .span-6 { grid-column: span 6; }
    .span-12 { grid-column: span 12; }
    .metric { font-size: 30px; font-weight: 700; margin-top: 10px; }
    .label { color: var(--muted); font-size: 14px; }
    .sub { color: var(--muted); font-size: 13px; margin-top: 6px; }
    .list {
      margin-top: 10px;
      display: grid;
      gap: 8px;
      font-size: 14px;
      color: var(--text);
    }
    .iface {
      display: flex;
      justify-content: space-between;
      gap: 10px;
      padding: 10px 12px;
      background: var(--panel-2);
      border: 1px solid var(--border);
      border-radius: 12px;
    }
    .footer {
      margin-top: 14px;
      color: var(--muted);
      font-size: 13px;
    }
    canvas { width: 100% !important; height: 280px !important; }
    @media (max-width: 900px) {
      .span-3, .span-4, .span-6, .span-12 { grid-column: span 12; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="topbar">
      <div class="title">
        <h1>MRVPN Dashboard</h1>
        <p>Service: <strong>{{ service_name }}</strong> · User: <strong>{{ username }}</strong></p>
      </div>
      <div class="actions">
        <button class="btn primary" onclick="restartService()">Restart VPN</button>
        <a class="btn" href="/logout">Logout</a>
      </div>
    </div>

    <div class="grid">
      <div class="card span-3">
        <div class="label">CPU</div>
        <div class="metric" id="cpu">0%</div>
        <div class="sub">Current processor load</div>
      </div>
      <div class="card span-3">
        <div class="label">RAM</div>
        <div class="metric" id="ram">0%</div>
        <div class="sub">Memory usage</div>
      </div>
      <div class="card span-3">
        <div class="label">Disk</div>
        <div class="metric" id="disk">0%</div>
        <div class="sub">Root filesystem usage</div>
      </div>
      <div class="card span-3">
        <div class="label">Network</div>
        <div class="metric" id="net">0 / 0</div>
        <div class="sub">RX / TX MB/s</div>
      </div>

      <div class="card span-6">
        <div class="label">CPU / RAM Trend</div>
        <div class="sub">Live chart from the monitoring thread</div>
        <div style="margin-top: 12px;"><canvas id="chart"></canvas></div>
      </div>

      <div class="card span-6">
        <div class="label">Interfaces</div>
        <div class="sub">RX / TX totals in GB</div>
        <div class="list" id="ifaces"></div>
      </div>

      <div class="card span-12">
        <div class="label">Status</div>
        <div class="sub" id="status">Waiting for updates...</div>
      </div>
    </div>

    <div class="footer">
      Web port: {{ web_port }} · API: <code>/api/status</code> · Restart: <code>/api/restart</code>
    </div>
  </div>

  <script>
    const socket = io();
    const statusEl = document.getElementById('status');

    const ctx = document.getElementById('chart');
    const chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: [],
        datasets: [
          { label: 'CPU %', data: [] },
          { label: 'RAM %', data: [] },
        ]
      },
      options: {
        responsive: true,
        animation: false,
        scales: {
          y: { beginAtZero: true, suggestedMax: 100 }
        }
      }
    });

    function renderIfaces(ifaces) {
      const root = document.getElementById('ifaces');
      const keys = Object.keys(ifaces || {});
      if (keys.length === 0) {
        root.innerHTML = '<div class="iface"><span>No interface data available</span></div>';
        return;
      }
      root.innerHTML = keys.map((name) => {
        const item = ifaces[name] || {};
        const rx = Number(item.rx || 0).toFixed(2);
        const tx = Number(item.tx || 0).toFixed(2);
        return `<div class="iface"><span>${name}</span><span>RX ${rx} GB · TX ${tx} GB</span></div>`;
      }).join('');
    }

    function applyUpdate(payload) {
      const health = payload.health || {};
      const speed = payload.speed || {};
      const ifaces = payload.ifaces || {};
      const meta = payload.meta || {};

      document.getElementById('cpu').innerText = `${Number(health.cpu || 0).toFixed(1)}%`;
      document.getElementById('ram').innerText = `${Number(health.ram || 0).toFixed(1)}%`;
      document.getElementById('disk').innerText = `${Number(health.disk || 0).toFixed(1)}%`;
      document.getElementById('net').innerText = `${Number(speed.rx || 0).toFixed(2)} / ${Number(speed.tx || 0).toFixed(2)}`;

      const updatedAt = meta.updated_at ? `Updated at ${meta.updated_at}` : 'Updated just now';
      const restartAt = meta.last_restart_time ? ` · Last restart ${meta.last_restart_time}` : '';
      statusEl.innerText = updatedAt + restartAt;

      renderIfaces(ifaces);

      chart.data.labels.push('');
      chart.data.datasets[0].data.push(Number(health.cpu || 0));
      chart.data.datasets[1].data.push(Number(health.ram || 0));

      if (chart.data.labels.length > 20) {
        chart.data.labels.shift();
        chart.data.datasets[0].data.shift();
        chart.data.datasets[1].data.shift();
      }
      chart.update();
    }

    socket.on('update', applyUpdate);

    async function restartService() {
      const btns = document.querySelectorAll('button');
      btns.forEach(b => b.disabled = true);
      try {
        await fetch('/api/restart', { method: 'POST' });
      } finally {
        setTimeout(() => btns.forEach(b => b.disabled = false), 1000);
      }
    }

    fetch('/api/status').then(r => r.json()).then(applyUpdate).catch(() => {});
  </script>
</body>
</html>
"""

# =========================
# STARTUP
# =========================
if __name__ == "__main__":
    if os.geteuid() != 0:
        print("Run as root")
        raise SystemExit(1)

    start_monitor_once()
    socketio.run(
        app, host="0.0.0.0", port=int(config.get("web_port", DEFAULT_WEB_PORT))
    )
