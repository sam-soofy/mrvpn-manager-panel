from datetime import datetime, timedelta
from functools import wraps

import jwt
from flask import jsonify, request

SECRET = "mrvpn-jwt-secret-2026"  # auto-overridden by config on load
BLACKLIST: set = set()


def create_access_token() -> str:
    payload = {"exp": datetime.utcnow() + timedelta(hours=1), "type": "access"}
    return jwt.encode(payload, SECRET, algorithm="HS256")


def create_refresh_token() -> str:
    payload = {"exp": datetime.utcnow() + timedelta(days=3), "type": "refresh"}
    return jwt.encode(payload, SECRET, algorithm="HS256")


def verify_token(token: str, token_type: str = "access") -> bool:
    if token in BLACKLIST:
        return False
    try:
        payload = jwt.decode(token, SECRET, algorithms=["HS256"])
        return payload.get("type") == token_type
    except Exception:
        return False


def blacklist_token(token: str) -> None:
    BLACKLIST.add(token)


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
