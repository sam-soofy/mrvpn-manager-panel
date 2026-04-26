import re
import threading
import time
from pathlib import Path

# MasterDnsVPN files live in /root (matches official installer & our install.sh)
MASTER_DIR = Path("/root")
SERVER_CFG = MASTER_DIR / "server_config.toml"
KEY_FILE = MASTER_DIR / "encrypt_key.txt"

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_VERSION_FILE = _PROJECT_ROOT / "installed_version.txt"
_CLIENT_CFG_DIR = _PROJECT_ROOT / "config" / "client"

# Default template files (shipped with the repo, live in panel root dir)
_DEFAULT_SERVER_TMPL = staticmethod(
    lambda v: _PROJECT_ROOT / f"config/tuned/defaults/{v}_server_config.toml"
)
_DEFAULT_CLIENT_TMPL = staticmethod(
    lambda v: _PROJECT_ROOT / f"config/client/defaults/{v}_client_config.toml"
)

# Maps CONFIG_VERSION values found in server_config.toml → our version strings.
_CONFIG_VERSION_MAP = {"10": "april5", "12": "april12"}


# ── Version ────────────────────────────────────────────────────────────────────


def _detect_version_from_config() -> str:
    """Fallback: read CONFIG_VERSION from the live server_config.toml.

    April 5 build ships with CONFIG_VERSION = "10"
    April 12 build ships with CONFIG_VERSION = "12"
    Returns 'april5', 'april12', or '' on failure.
    """
    try:
        content = SERVER_CFG.read_text(encoding="utf-8")
        m = re.search(r'^CONFIG_VERSION\s*=\s*"(\d+)"', content, re.MULTILINE)
        if not m:
            return ""
        return _CONFIG_VERSION_MAP.get(m.group(1), "")
    except Exception:
        return ""


def read_installed_version() -> str:
    """Return 'april5', 'april12', or '' if version cannot be determined.

    Primary source: installed_version.txt written by install.sh.
    Fallback: CONFIG_VERSION field in live server_config.toml.
    When fallback succeeds the result is persisted so subsequent calls are fast.
    """
    if _VERSION_FILE.exists():
        v = _VERSION_FILE.read_text(encoding="utf-8").strip()
        if v:
            return v
    v = _detect_version_from_config()
    if v:
        try:
            _VERSION_FILE.write_text(v, encoding="utf-8")
        except Exception:
            pass
    return v


# ── Server config ──────────────────────────────────────────────────────────────


def read_config() -> str:
    return SERVER_CFG.read_text(encoding="utf-8") if SERVER_CFG.exists() else ""


def read_key() -> str:
    key = KEY_FILE.read_text(encoding="utf-8") if KEY_FILE.exists() else ""
    return key.strip()


# ── Client config ──────────────────────────────────────────────────────────────


def _extract_domain() -> str:
    """Parse DOMAIN from the live server_config.toml."""
    try:
        content = SERVER_CFG.read_text(encoding="utf-8")
        m = re.search(r'DOMAIN\s*=\s*\[\s*"([^"]+)"', content)
        domain = m.group(1) if m else ""
        return domain.strip()
    except Exception:
        return ""


def read_client_config() -> str:
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
    encryption_key = read_key()
    if encryption_key:
        content = content.replace("{{ENC_KEY}}", encryption_key)
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


def write_client_config(
    content: str, confirmed: bool = False, version: str = ""
) -> bool:
    if not confirmed:
        return False
    if not version:
        return False
    template = _CLIENT_CFG_DIR / f"{version}_client_config.toml"
    if not template.exists():
        return False
    template.write_text(content, encoding="utf-8")
    return True


# ── Reset helpers ──────────────────────────────────────────────────────────────


def reset_config() -> tuple[bool, str]:
    """Reset server_config.toml to the shipped default template with domain injected.

    Domain is read from the *live* config before overwriting it, so the
    currently configured domain is preserved in the reset result.
    """
    version = read_installed_version()
    if not version:
        return False, "Installed version unknown — cannot determine default template"

    default_tmpl = _PROJECT_ROOT / f"config/tuned/defaults/{version}_server_config.toml"
    if not default_tmpl.exists():
        return False, f"Default template not found: {default_tmpl.name}"

    # Read domain BEFORE overwriting the live config
    domain = _extract_domain()
    content = default_tmpl.read_text(encoding="utf-8")
    if domain:
        content = content.replace("{{DOMAIN}}", domain)

    SERVER_CFG.write_text(content, encoding="utf-8")
    _delayed_restart()
    return True, "Reset to default — MasterDnsVPN restarting"


def reset_client_config() -> tuple[bool, str]:
    """Reset the client config template to the shipped default with domain + key injected."""
    version = read_installed_version()
    if not version:
        return False, "Installed version unknown — cannot determine default template"

    default_tmpl = (
        _PROJECT_ROOT / f"config/client/defaults/{version}_client_config.toml"
    )
    if not default_tmpl.exists():
        return False, f"Default template not found: {default_tmpl.name}"

    content = default_tmpl.read_text(encoding="utf-8")
    domain = _extract_domain()
    if domain:
        content = content.replace("{{DOMAIN}}", domain)
    key = read_key()
    if key:
        content = content.replace("{{ENC_KEY}}", key)

    dest = _CLIENT_CFG_DIR / f"{version}_client_config.toml"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(content, encoding="utf-8")
    return True, "Client config reset to default"
