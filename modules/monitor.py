import json
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Tuple

import psutil

# ── Persistence ───────────────────────────────────────────────────────────────
_TOTALS_FILE = Path("/opt/mrvpn-manager-panel/network_totals.json")
_FLUSH_EVERY = 30  # ticks; at 2 s/tick = 60 s between disk writes


def _load_persisted() -> Tuple[float, float]:
    """Load saved lifetime totals (GB) from disk. Returns (rx, tx) = (0, 0) on failure."""
    try:
        data = json.loads(_TOTALS_FILE.read_text(encoding="utf-8"))
        return float(data.get("rx_gb", 0.0)), float(data.get("tx_gb", 0.0))
    except Exception:
        return 0.0, 0.0


def _save_persisted(rx_gb: float, tx_gb: float) -> None:
    try:
        _TOTALS_FILE.write_text(
            json.dumps({"rx_gb": round(rx_gb, 4), "tx_gb": round(tx_gb, 4)}),
            encoding="utf-8",
        )
    except Exception:
        pass


# ── Shared state ──────────────────────────────────────────────────────────────
state_lock = threading.Lock()
latest_snapshot: Dict[str, Any] = {
    "health": {"cpu": 0.0, "ram": 0.0, "disk": 0.0},
    "speed": {"rx": 0.0, "tx": 0.0},
    "ifaces": {},
    "totals": {"rx": 0.0, "tx": 0.0},
    "updated_at": None,
}


# ── Metric collectors ─────────────────────────────────────────────────────────


def get_health() -> Dict[str, float]:
    return {
        "cpu": psutil.cpu_percent(interval=None),
        "ram": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
    }


def get_net() -> Tuple[int, int]:
    c = psutil.net_io_counters()
    return c.bytes_recv, c.bytes_sent


def get_ifaces() -> Dict[str, Dict[str, float]]:
    """Per-interface cumulative rx/tx in GB from /proc/net/dev."""
    result: Dict[str, Dict[str, float]] = {}
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


def _get_iface_raw_bytes() -> Tuple[int, int]:
    """Sum raw bytes (rx, tx) across all non-loopback interfaces from /proc/net/dev.

    Used for baseline and delta tracking. Returns (0, 0) on any read failure.
    """
    rx = tx = 0
    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as f:
            for line in f.readlines()[2:]:
                parts = line.split()
                iface = parts[0].replace(":", "")
                if iface == "lo":
                    continue
                rx += int(parts[1])
                tx += int(parts[9])
    except Exception:
        pass
    return rx, tx


def _update_snapshot(health: dict, speed: dict, ifaces: dict, totals: dict) -> None:
    with state_lock:
        latest_snapshot.update(
            {
                "health": health,
                "speed": speed.copy(),
                "ifaces": ifaces,
                "totals": totals,
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            }
        )


# ── Background thread ─────────────────────────────────────────────────────────


def start_monitor(socketio, refresh_interval: int = 2) -> None:
    """Spawn the background monitoring thread."""

    def _run() -> None:
        # ── Persistent counter bootstrap ──────────────────────────────────────
        # persisted_*: lifetime GB accumulated before this boot (from disk)
        # baseline_*:  raw bytes reported by /proc/net/dev at this boot
        #
        # Each tick:  total = persisted + (current_raw - baseline) / 1024^3
        #
        # After reboot, /proc/net/dev resets near 0.  The new baseline absorbs
        # that reset and persisted carries the old lifetime value forward.
        persisted_rx, persisted_tx = _load_persisted()
        baseline_raw_rx, baseline_raw_tx = _get_iface_raw_bytes()

        last_rx, last_tx = get_net()
        last_t = time.time()
        psutil.cpu_percent(interval=None)  # prime the CPU sampler

        flush_counter = 0

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

                # Persistent totals
                cur_raw_rx, cur_raw_tx = _get_iface_raw_bytes()
                total_rx = persisted_rx + (cur_raw_rx - baseline_raw_rx) / (1024**3)
                total_tx = persisted_tx + (cur_raw_tx - baseline_raw_tx) / (1024**3)
                totals = {"rx": round(total_rx, 2), "tx": round(total_tx, 2)}

                _update_snapshot(health, speed, ifaces, totals)
                socketio.emit(
                    "update",
                    {
                        "health": health,
                        "speed": speed,
                        "ifaces": ifaces,
                        "totals": totals,
                    },
                )

                last_rx, last_tx, last_t = rx, tx, time.time()

                # Flush totals to disk periodically
                flush_counter += 1
                if flush_counter >= _FLUSH_EVERY:
                    _save_persisted(total_rx, total_tx)
                    flush_counter = 0

                time.sleep(refresh_interval)

            except Exception:
                time.sleep(2)

    threading.Thread(target=_run, daemon=True).start()
