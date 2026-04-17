from pathlib import Path

MASTER_DIR = Path("/opt/masterdnsvpn")
SERVER_CFG = MASTER_DIR / "server_config.toml"
KEY_FILE = MASTER_DIR / "encrypt_key.txt"


def read_config() -> str:
    return SERVER_CFG.read_text(encoding="utf-8") if SERVER_CFG.exists() else ""


def read_key() -> str:
    return KEY_FILE.read_text(encoding="utf-8") if KEY_FILE.exists() else ""


def write_config(content: str, confirmed: bool = False) -> bool:
    if not confirmed:
        return False
    SERVER_CFG.write_text(content, encoding="utf-8")
    from .service_manager import restart_masterdnsvpn

    restart_masterdnsvpn()
    return True


def write_key(content: str, confirmed: bool = False) -> bool:
    if not confirmed:
        return False
    KEY_FILE.write_text(content.strip(), encoding="utf-8")
    from .service_manager import restart_masterdnsvpn

    restart_masterdnsvpn()
    return True
