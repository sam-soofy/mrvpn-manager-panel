import threading
import time
from pathlib import Path

# MasterDnsVPN files live in /root (matches official installer & our install.sh)
MASTER_DIR = Path("/root")
SERVER_CFG = MASTER_DIR / "server_config.toml"
KEY_FILE = MASTER_DIR / "encrypt_key.txt"


def read_config() -> str:
    return SERVER_CFG.read_text(encoding="utf-8") if SERVER_CFG.exists() else ""


def read_key() -> str:
    return KEY_FILE.read_text(encoding="utf-8") if KEY_FILE.exists() else ""


def _delayed_restart(seconds: float = 2.0) -> None:
    """Restart masterdnsvpn after a short delay so the HTTP response
    is delivered to the browser before the service bounces."""

    def _run():
        time.sleep(seconds)
        from .service_manager import restart_masterdnsvpn

        restart_masterdnsvpn()

    threading.Thread(target=_run, daemon=True).start()


def write_config(content: str, confirmed: bool = False) -> bool:
    if not confirmed:
        return False
    SERVER_CFG.write_text(content, encoding="utf-8")
    _delayed_restart()
    return True


def write_key(content: str, confirmed: bool = False) -> bool:
    if not confirmed:
        return False
    KEY_FILE.write_text(content.strip(), encoding="utf-8")
    _delayed_restart()
    return True
