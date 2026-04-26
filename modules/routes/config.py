from flask import Blueprint, jsonify, request

from modules.auth import require_auth
from modules.config_editor import (read_client_config, read_config,
                                   read_installed_version, read_key,
                                   reset_client_config, reset_config,
                                   write_client_config, write_config,
                                   write_key)

config_bp = Blueprint("config", __name__)

_CONFIRM_SERVER_MSG = "This will save and restart MasterDnsVPN. Continue?"
_CONFIRM_MSG = "Are you sure you are finished, and want to save changes?"


@config_bp.route("/api/config/server", methods=["GET", "POST"])
@require_auth
def config_server():
    if request.method == "GET":
        return jsonify({"content": read_config()})

    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify({"requires_confirmation": True, "message": _CONFIRM_SERVER_MSG})

    success = write_config(data.get("content", ""), confirmed=True)
    return jsonify(
        {"ok": success, "message": "Saved and restarted" if success else "Failed"}
    )


@config_bp.route("/api/config/key", methods=["GET", "POST"])
@require_auth
def config_key():
    if request.method == "GET":
        return jsonify({"content": read_key()})

    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify({"requires_confirmation": True, "message": _CONFIRM_SERVER_MSG})

    success = write_key(data.get("content", ""), confirmed=True)
    return jsonify(
        {"ok": success, "message": "Saved and restarted" if success else "Failed"}
    )


@config_bp.route("/api/config/client", methods=["GET", "POST"])
@require_auth
def config_client():
    version = read_installed_version()
    content = read_client_config()

    if request.method == "GET":
        return jsonify(
            {
                "content": content,
                "version": version,
                "available": bool(content),
            }
        )

    data = request.get_json(silent=True) or {}
    if not data.get("confirmed"):
        return jsonify({"requires_confirmation": True, "message": _CONFIRM_MSG})

    success = write_client_config(
        data.get("content", ""), confirmed=True, version=version
    )
    return jsonify({"ok": success, "message": "Saved" if success else "Failed"})


@config_bp.route("/api/config/server/reset", methods=["POST"])
@require_auth
def config_server_reset():
    """Reset server_config.toml to the shipped default and restart VPN."""
    ok, message = reset_config()
    return jsonify({"ok": ok, "message": message}), (200 if ok else 500)


@config_bp.route("/api/config/client/reset", methods=["POST"])
@require_auth
def config_client_reset():
    """Reset client config template to the shipped default."""
    ok, message = reset_client_config()
    return jsonify({"ok": ok, "message": message}), (200 if ok else 500)
