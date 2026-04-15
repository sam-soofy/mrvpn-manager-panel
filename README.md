# MRVPN Manager Panel

Lightweight web-based monitoring and control panel for the `masterdnsvpn` service.

## Features

- Web dashboard for CPU / RAM / Disk / Network
- Real-time updates via Socket.IO
- Interface traffic statistics
- Restart VPN service from the web UI
- Login system with generated credentials
- Auto-start on reboot using `systemd`

## Installation

```bash
bash <(curl -Ls https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/main/install.sh)
```

## First Login

After installation, the script prints credentials like this:

```text
=== LOGIN ===
User: admin
Pass: xxxxxxxxxxxxxxxx
============
```

Open the panel in your browser:

```text
http://YOUR_SERVER_IP:5000
```

## How It Works

| Part | Role |
|------|------|
| `install.sh` | One-time setup |
| `mrvpn_manager_panel.py` | Main web app |
| `systemd service` | Keeps the app running after reboot |

## Auto Start on Reboot

The panel is started by a `systemd` service.  
This means:

- the installer does **not** run again after reboot
- only the Python panel is started automatically
- the service can also restart the app if it crashes

### Service name

```bash
mrvpn-panel
```

## Service Management

### Check status

```bash
systemctl status mrvpn-panel
```

### Start

```bash
systemctl start mrvpn-panel
```

### Stop

```bash
systemctl stop mrvpn-panel
```

### Restart

```bash
systemctl restart mrvpn-panel
```

### Enable on boot

```bash
systemctl enable mrvpn-panel
```

### Disable on boot

```bash
systemctl disable mrvpn-panel
```

## Debugging

### View live logs

```bash
journalctl -u mrvpn-panel -f
```

This is the most useful command for debugging startup problems, crashes, and Python errors.

### Common issues

#### Port already in use

If you see an error like:

```text
Address already in use
```

Check which process is using the port:

```bash
lsof -i :5000
```

#### Permission problems

The panel needs root privileges because it controls the VPN service.

Run it with:

```bash
sudo systemctl restart mrvpn-panel
```

#### Service not starting after reboot

Check whether it is enabled:

```bash
systemctl is-enabled mrvpn-panel
```

If needed, enable it again:

```bash
systemctl enable mrvpn-panel
```

#### Missing Python packages

Install dependencies with:

```bash
pip install -r requirements.txt
```

## API

The app still supports JSON API usage.

### Login

```bash
POST /login
```

Example JSON:

```json
{
  "username": "admin",
  "password": "your_password"
}
```

### Restart VPN

```bash
POST /api/restart
```

### Status

```bash
GET /api/status
```

## UI Pages

- `/` → Dashboard
- `/login` → Login page
- `/api/status` → Current health snapshot
- `/api/restart` → Restart VPN service

## Notes

- Designed for Ubuntu / Debian-based systems
- Requires `root`
- Uses:
  - Flask
  - Flask-SocketIO
  - psutil

## Mental Model

```text
install.sh  -> setup
systemd     -> keep it alive
web UI      -> monitor + control
```
