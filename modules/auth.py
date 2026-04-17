import time
from datetime import datetime, timedelta
from typing import Dict, Optional

import jwt

SECRET = "mrvpn-jwt-secret-2026"  # auto-overridden by config on load
BLACKLIST = set()


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
    except:
        return False


def blacklist_token(token: str):
    BLACKLIST.add(token)
