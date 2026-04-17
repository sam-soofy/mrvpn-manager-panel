import subprocess


def restart_masterdnsvpn() -> bool:
    try:
        subprocess.run(["systemctl", "restart", "masterdnsvpn"], check=True)
        return True
    except:
        return False


def get_status() -> dict:
    try:
        out = subprocess.run(
            ["systemctl", "is-active", "masterdnsvpn"], capture_output=True, text=True
        )
        return {"running": out.stdout.strip() == "active"}
    except:
        return {"running": False}
