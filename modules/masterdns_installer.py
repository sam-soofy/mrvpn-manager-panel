import subprocess
from pathlib import Path


def reinstall(version: str, domain: str) -> bool:
    # Called from API for future UI reinstall
    master_dir = Path("/opt/masterdnsvpn")
    if master_dir.exists():
        key = master_dir / "encrypt_key.txt"
        backup = Path(f"/tmp/encrypt_key_{int(time.time())}.txt")
        if key.exists():
            key.rename(backup)
        subprocess.run(["rm", "-rf", str(master_dir)], check=True)
    # Trigger full bash install logic via install.sh --reinstall flag (future)
    # For now returns True – full logic lives in install.sh
    return True
