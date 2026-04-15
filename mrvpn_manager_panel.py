#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from flask import Flask, request, jsonify, session, redirect, render_template_string
from flask_socketio import SocketIO
from werkzeug.security import generate_password_hash, check_password_hash

import psutil, subprocess, json, time, threading, os
import secrets, string
from datetime import datetime
from collections import deque

# ================= CONFIG =================
CONFIG_FILE = "./mrvpn_manager_config.json"
SERVICE_NAME = "masterdnsvpn"

# ================= APP =================
app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

# ================= STATE =================
lock = threading.Lock()
cpu_data = deque(maxlen=30)
memory_data = deque(maxlen=30)
network_speed = {"rx": 0, "tx": 0}
active_connections = 0
last_restart_time = None


# ================= CONFIG =================
def gen_pass():
    return "".join(
        secrets.choice(string.ascii_letters + string.digits) for _ in range(16)
    )


def load_config():
    if not os.path.exists(CONFIG_FILE):
        password = gen_pass()
        cfg = {
            "username": "admin",
            "password_hash": generate_password_hash(password),
            "secret_key": gen_pass(),
            "web_port": 5000,
            "monitoring_refresh": 2,
        }
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=4)

        print("\n=== LOGIN ===")
        print("User:", cfg["username"])
        print("Pass:", password)
        print("============\n")

    return json.load(open(CONFIG_FILE))


config = load_config()
app.config["SECRET_KEY"] = config["secret_key"]


# ================= AUTH =================
def login_required(f):
    def wrapper(*a, **kw):
        if not session.get("ok"):
            return redirect("/login")
        return f(*a, **kw)

    wrapper.__name__ = f.__name__
    return wrapper


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        d = request.json
        if d["username"] == config["username"] and check_password_hash(
            config["password_hash"], d["password"]
        ):
            session["ok"] = True
            return jsonify({"ok": True})
        return jsonify({"ok": False})
    return "<h3>Use POST JSON</h3>"


# ================= CORE =================
def get_health():
    return {
        "cpu": psutil.cpu_percent(None),
        "ram": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
    }


def get_net():
    n = psutil.net_io_counters()
    return n.bytes_recv, n.bytes_sent


def get_ifaces():
    res = {}
    try:
        for l in open("/proc/net/dev").readlines()[2:]:
            p = l.split()
            i = p[0].replace(":", "")
            res[i] = {
                "rx": round(float(p[1]) / (1024**3), 2),
                "tx": round(float(p[9]) / (1024**3), 2),
            }
    except:
        pass
    return res


def restart():
    global last_restart_time
    try:
        subprocess.run(["systemctl", "restart", SERVICE_NAME], check=True)
        last_restart_time = datetime.now()
        return True
    except:
        return False


# ================= THREAD =================
def monitor():
    last_rx, last_tx = get_net()
    last_t = time.time()
    psutil.cpu_percent(None)

    while True:
        try:
            h = get_health()
            now = time.time()
            rx, tx = get_net()

            dt = now - last_t
            sp_rx = (rx - last_rx) / dt / 1024 / 1024
            sp_tx = (tx - last_tx) / dt / 1024 / 1024

            with lock:
                cpu_data.append(h["cpu"])
                memory_data.append(h["ram"])
                network_speed["rx"] = sp_rx
                network_speed["tx"] = sp_tx

            socketio.emit(
                "update", {"health": h, "speed": network_speed, "ifaces": get_ifaces()}
            )

            last_rx, last_tx, last_t = rx, tx, now
            time.sleep(config["monitoring_refresh"])
        except Exception as e:
            print("ERR:", e)
            time.sleep(2)


# ================= ROUTES =================
@app.route("/")
@login_required
def index():
    return render_template_string(HTML)


@app.route("/api/restart", methods=["POST"])
@login_required
def api_restart():
    return jsonify({"ok": restart()})


# ================= UI =================
HTML = """
<!DOCTYPE html>
<html>
<head>
<title>MRVPN Panel</title>
<script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body {font-family:Arial;background:#111;color:#eee;text-align:center}
.card {background:#222;padding:20px;margin:10px;border-radius:10px}
</style>
</head>
<body>

<h2>MRVPN Dashboard</h2>

<div class="card">
CPU: <span id="cpu">0</span>% |
RAM: <span id="ram">0</span>% |
Disk: <span id="disk">0</span>%
</div>

<div class="card">
RX: <span id="rx">0</span> MB/s |
TX: <span id="tx">0</span> MB/s
</div>

<div class="card">
<h3>Interfaces</h3>
<div id="ifaces"></div>
</div>

<button onclick="restart()">Restart VPN</button>

<canvas id="chart"></canvas>

<script>
const s = io();

const ctx = document.getElementById('chart');
const chart = new Chart(ctx,{
 type:'line',
 data:{labels:[],datasets:[
  {label:'CPU',data:[]},
  {label:'RAM',data:[]}
 ]}
});

s.on("update", d=>{
 document.getElementById("cpu").innerText=d.health.cpu;
 document.getElementById("ram").innerText=d.health.ram;
 document.getElementById("disk").innerText=d.health.disk;

 document.getElementById("rx").innerText=d.speed.rx.toFixed(2);
 document.getElementById("tx").innerText=d.speed.tx.toFixed(2);

 let html="";
 for (let i in d.ifaces){
  html+=`${i}: RX ${d.ifaces[i].rx}GB TX ${d.ifaces[i].tx}GB<br>`;
 }
 document.getElementById("ifaces").innerHTML=html;

 chart.data.labels.push("");
 chart.data.datasets[0].data.push(d.health.cpu);
 chart.data.datasets[1].data.push(d.health.ram);

 if(chart.data.labels.length>20){
  chart.data.labels.shift();
  chart.data.datasets[0].data.shift();
  chart.data.datasets[1].data.shift();
 }
 chart.update();
});

function restart(){
 fetch('/api/restart',{method:'POST'});
}
</script>

</body>
</html>
"""

# ================= MAIN =================
if __name__ == "__main__":
    if os.geteuid() != 0:
        print("Run as root")
        exit()

    threading.Thread(target=monitor, daemon=True).start()
    socketio.run(app, host="0.0.0.0", port=config["web_port"])
