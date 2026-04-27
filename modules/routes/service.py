import subprocess
import threading
import time
from pathlib import Path

from flask import Blueprint, jsonify

from modules.auth import require_auth
from modules.config_editor import reset_client_config, reset_config
from modules.monitor import latest_snapshot, state_lock
from modules.service_manager import restart_masterdnsvpn

service_bp = Blueprint("service", __name__)

_PANEL_DIR = Path("/opt/mrvpn-manager-panel")
_PANEL_SERVICE = "mrvpn-manager-panel"


@service_bp.route("/api/auth/verify", methods=["GET"])
@require_auth
def api_verify():
    """Lightweight token-check endpoint used by the dashboard on page load."""
    return jsonify({"ok": True})


@service_bp.route("/api/restart", methods=["POST"])
@require_auth
def api_restart():
    return jsonify({"ok": restart_masterdnsvpn()})


@service_bp.route("/api/status", methods=["GET"])
@require_auth
def api_status():
    with state_lock:
        return jsonify(latest_snapshot)


@service_bp.route("/api/panel/update", methods=["POST"])
@require_auth
def api_panel_update():
    """Pull latest main branch, sync deps, and restart the panel service.

    Steps mirror install.sh panel-update logic:
      1. git fetch origin
      2. git checkout main
      3. git reset --hard origin/main   (handles domain-patched local files)
      4. pip install -r requirements.txt
      5. systemctl restart mrvpn-manager-panel  (delayed 2 s so response lands first)
    """
    pip_bin = _PANEL_DIR / ".venv" / "bin" / "pip"
    req_file = _PANEL_DIR / "requirements.txt"

    try:
        subprocess.run(
            ["git", "-C", str(_PANEL_DIR), "fetch", "origin"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(_PANEL_DIR), "checkout", "main"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(_PANEL_DIR), "reset", "--hard", "origin/main"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                str(pip_bin),
                "install",
                "-r",
                str(req_file),
                "--disable-pip-version-check",
                "-q",
            ],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode(errors="replace").strip() if exc.stderr else ""
        return jsonify({"ok": False, "error": stderr or str(exc)}), 500

    ok, message = reset_config()
    if ok:
        ok, message = reset_client_config()
    else:
        ok, message = reset_client_config()
        ok = False

    # Delay restart so this HTTP response reaches the browser before the
    # process is replaced. (Same pattern used by config_editor._delayed_restart)
    def _restart():
        time.sleep(2)
        subprocess.run(["systemctl", "restart", _PANEL_SERVICE], check=False)

    threading.Thread(target=_restart, daemon=True).start()

    if ok:
        return jsonify({"ok": True, "message": "Panel updated — restarting in ~2s"})
    else:
        return jsonify(
            {
                "ok": False,
                "message": "! Something went wrong! But panel might be updated. restarting in ~2s",
            }
        )
