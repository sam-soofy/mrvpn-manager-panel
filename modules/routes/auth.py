import os
from pathlib import Path

from flask import Blueprint, jsonify, request

from modules.auth import (
    blacklist_token,
    create_access_token,
    create_refresh_token,
    verify_token,
)

auth_bp = Blueprint("auth", __name__)

# Load admin password once at startup.
# This file sits at PROJECT_ROOT/modules/routes/auth.py, so go up 3 levels.
_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
_PASS_FILE = _PROJECT_ROOT / "admin_pass.txt"
ADMIN_PASSWORD: str = (
    _PASS_FILE.read_text(encoding="utf-8").strip()
    if _PASS_FILE.exists()
    else os.environ.get("ADMIN_PASSWORD", "")  # fallback for legacy installs
)


@auth_bp.route("/api/auth/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    username = data.get("username", "")
    password = data.get("password", "")

    # If password is somehow empty, refuse all logins rather than being wide open.
    if not ADMIN_PASSWORD:
        return jsonify({"ok": False, "error": "server_misconfigured"}), 500

    if username == "admin" and password == ADMIN_PASSWORD:
        return jsonify({
            "ok": True,
            "access_token": create_access_token(),
            "refresh_token": create_refresh_token(),
        })
    return jsonify({"ok": False, "error": "invalid_credentials"}), 401


@auth_bp.route("/api/auth/refresh", methods=["POST"])
def api_refresh():
    data = request.get_json(silent=True) or {}
    token = data.get("refresh_token")
    if token and verify_token(token, "refresh"):
        blacklist_token(token)
        return jsonify({
            "ok": True,
            "access_token": create_access_token(),
            "refresh_token": create_refresh_token(),
        })
    return jsonify({"ok": False, "error": "invalid_refresh"}), 401
