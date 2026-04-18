import threading
import time
from datetime import datetime
from typing import Any, Dict, Tuple

import psutil

# ── Shared state (read by service route, written by monitor thread) ────────────
state_lock = threading.Lock()
latest_snapshot: Dict[str, Any] = {
    "health": {"cpu": 0.0, "ram": 0.0, "disk": 0.0},
    "speed":  {"rx": 0.0, "tx": 0.0},
    "ifaces": {},
    "updated_at": None,
}


# ── Metric collectors ─────────────────────────────────────────────────────────

def get_health() -> Dict[str, float]:
    return {
        "cpu":  psutil.cpu_percent(interval=None),
        "ram":  psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
    }


def get_net() -> Tuple[int, int]:
    c = psutil.net_io_counters()
    return c.bytes_recv, c.bytes_sent


def get_ifaces() -> Dict[str, Dict[str, float]]:
    result: Dict[str, Dict[str, float]] = {}
    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as f:
            for line in f.readlines()[2:]:
                parts = line.split()
                iface = parts[0].replace(":", "")
                result[iface] = {
                    "rx": round(float(parts[1]) / (1024 ** 3), 2),
                    "tx": round(float(parts[9]) / (1024 ** 3), 2),
                }
    except Exception:
        pass
    return result


def _update_snapshot(health: dict, speed: dict, ifaces: dict) -> None:
    with state_lock:
        latest_snapshot.update({
            "health":     health,
            "speed":      speed.copy(),
            "ifaces":     ifaces,
            "updated_at": datetime.now().isoformat(timespec="seconds"),
        })


# ── Background thread ─────────────────────────────────────────────────────────

def start_monitor(socketio, refresh_interval: int = 2) -> None:
    """Spawn the background monitoring thread.

    Takes socketio as a parameter to avoid circular imports — the main app
    creates socketio, then passes it here after registering blueprints.
    """
    def _run() -> None:
        last_rx, last_tx = get_net()
        last_t = time.time()
        psutil.cpu_percent(interval=None)  # prime the CPU sampler

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

                _update_snapshot(health, speed, ifaces)
                socketio.emit("update", {"health": health, "speed": speed, "ifaces": ifaces})

                last_rx, last_tx, last_t = rx, tx, time.time()
                time.sleep(refresh_interval)
            except Exception:
                time.sleep(2)

    threading.Thread(target=_run, daemon=True).start()
