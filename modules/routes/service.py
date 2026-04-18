from flask import Blueprint, jsonify

from modules.auth import require_auth
from modules.monitor import latest_snapshot, state_lock
from modules.service_manager import restart_masterdnsvpn

service_bp = Blueprint("service", __name__)


@service_bp.route("/api/restart", methods=["POST"])
@require_auth
def api_restart():
    return jsonify({"ok": restart_masterdnsvpn()})


@service_bp.route("/api/status", methods=["GET"])
@require_auth
def api_status():
    with state_lock:
        return jsonify(latest_snapshot)
