import re
import threading
import time
from pathlib import Path

# MasterDnsVPN files live in /root (matches official installer & our install.sh)
MASTER_DIR = Path("/root")
SERVER_CFG = MASTER_DIR / "server_config.toml"
KEY_FILE   = MASTER_DIR / "encrypt_key.txt"

_PROJECT_ROOT   = Path(__file__).resolve().parent.parent
_VERSION_FILE   = _PROJECT_ROOT / "installed_version.txt"
_CLIENT_CFG_DIR = _PROJECT_ROOT / "config" / "client"


# ── Version ────────────────────────────────────────────────────────────────────

def read_installed_version() -> str:
    """Returns 'april5', 'april12', or '' if not set yet."""
    return _VERSION_FILE.read_text(encoding="utf-8").strip() if _VERSION_FILE.exists() else ""


# ── Server config ──────────────────────────────────────────────────────────────

def read_config() -> str:
    return SERVER_CFG.read_text(encoding="utf-8") if SERVER_CFG.exists() else ""


def read_key() -> str:
    return KEY_FILE.read_text(encoding="utf-8") if KEY_FILE.exists() else ""


# ── Client config ──────────────────────────────────────────────────────────────

def _extract_domain() -> str:
    """Parse DOMAIN from the live server_config.toml.
    Line looks like:  DOMAIN = ["vpn.example.com"]
    Returns first domain string, or '' on any error."""
    try:
        content = SERVER_CFG.read_text(encoding="utf-8")
        m = re.search(r'DOMAIN\s*=\s*\[\s*"([^"]+)"', content)
        return m.group(1) if m else ""
    except Exception:
        return ""


def read_client_config() -> str:
    """Load the version-specific client config template and inject the live domain."""
    version = read_installed_version()
    if not version:
        return ""
    template = _CLIENT_CFG_DIR / f"{version}_client_config.toml"
    if not template.exists():
        return ""
    content = template.read_text(encoding="utf-8")
    domain = _extract_domain()
    if domain:
        content = content.replace("{{DOMAIN}}", domain)
    return content


# ── Delayed restart helper ─────────────────────────────────────────────────────

def _delayed_restart(seconds: float = 2.0) -> None:
    """Restart masterdnsvpn after a short delay so the HTTP response
    reaches the browser before the service bounces."""
    def _run():
        time.sleep(seconds)
        from .service_manager import restart_masterdnsvpn
        restart_masterdnsvpn()

    threading.Thread(target=_run, daemon=True).start()


# ── Write helpers ──────────────────────────────────────────────────────────────

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
