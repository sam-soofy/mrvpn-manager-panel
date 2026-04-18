from flask import Blueprint, jsonify, request

from modules.auth import require_auth
from modules.config_editor import read_config, read_key, write_config, write_key

config_bp = Blueprint("config", __name__)

_CONFIRM_MSG = "This will save and restart MasterDnsVPN. Continue?"


@config_bp.route("/api/config/server", methods=["GET", "POST"])
@require_auth
def config_server():
    if request.method == "GET":
        return jsonify({"content": read_config()})

    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify({"requires_confirmation": True, "message": _CONFIRM_MSG})

    success = write_config(data.get("content", ""), confirmed=True)
    return jsonify({"ok": success, "message": "Saved and restarted" if success else "Failed"})


@config_bp.route("/api/config/key", methods=["GET", "POST"])
@require_auth
def config_key():
    if request.method == "GET":
        return jsonify({"content": read_key()})

    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify({"requires_confirmation": True, "message": _CONFIRM_MSG})

    success = write_key(data.get("content", ""), confirmed=True)
    return jsonify({"ok": success, "message": "Saved and restarted" if success else "Failed"})
