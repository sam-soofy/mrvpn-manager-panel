# MRVPN Manager Panel

> 🇮🇷 [فارسی](README_fa.md)

A lightweight web panel to install, manage, and monitor servers running [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN).

**Still in development, be cautious about security.**

---

## What It Does

- **JWT-based authentication** — stateless, easy and secure
- **Version-aware installer** — choose between April 5 and April 12 builds
- **Automatic domain injection** — tuned configs with your domain baked in
- **Web dashboard** — real-time CPU, RAM, disk, and network stats via WebSocket
- **Browser config editor** — view and edit `server_config.toml` and `encrypt_key.txt` directly from the dashboard, with automatic service restart on save
- **Config scheduler** — define multiple server configs for different times of day and have a system service auto-swap them on a schedule
- **One-command reinstall and version switching** — preserves your key and config if you want
- **Systemd-managed** — panel, VPN, and scheduler all run as services, restart on crash and reboot

---

## Installation

- Due to different mighty issues and instablities, it's better to always create a "screen" session and then after that, begin installation to avoid any interuptions or breaks:

```bash
screen -S mrvpn
```

- Now, when ever you got disconnected and got connected back, get back where you left off and see what ever was in ther seesion, or continue easily with:

```bash
screen -r mrvpn
```

- Installtion Command:

```bash
curl -fsSL https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/main/install.sh -o install.sh
sudo bash install.sh
```

The installer will ask you:

1. Whether to install/update the **Panel**
2. Whether to install/update **MasterDnsVPN**
   - Which version: April 5 or April 12
   - Your domain (e.g. `vpn.example.com`)
   - Whether to keep your existing `server_config.toml` and `encrypt_key.txt` if found

---

## First Login

After installation, your credentials are printed in a clearly visible block:

```
╔══════════════════════════════════════════════════════╗
║              ★  SAVE YOUR LOGIN CREDENTIALS  ★      ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  URL  : http://YOUR_SERVER_IP:5000                   ║
║  User : admin                                        ║
║  Pass : xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx             ║
║                                                      ║
╠══════════════════════════════════════════════════════╣
║  Password file : /opt/mrvpn-manager-panel/admin_pass.txt
║                                                      ║
║  TO RESET PASSWORD:                                  ║
║    nano /opt/mrvpn-manager-panel/admin_pass.txt      ║
║    systemctl restart mrvpn-manager-panel             ║
╚══════════════════════════════════════════════════════╝
```

---

## Resetting Your Password

The panel reads the password directly from the file at startup. To reset:

```bash
# 1. Edit the password file (replace with your new password)
nano /opt/mrvpn-manager-panel/admin_pass.txt

# 2. Restart the panel to apply it
systemctl restart mrvpn-manager-panel
```

That's it. No tokens, no scripts, no extra steps.

---

## Config Editor

Click **Edit server_config.toml** or **Edit encrypt_key.txt** on the dashboard to open a full-screen editor. Changes are saved to disk and MasterDnsVPN is restarted automatically after you confirm.

---

## Config Scheduler

The scheduler lets you define multiple server configs that activate at specific times of day. Useful for aggressive ARQ settings at night and lighter settings during peak hours.

### Setting up a schedule

1. Open the dashboard → **Config Scheduler** section → **Add Schedule**
2. Set the name, time (24h), and days of the week
3. Paste your TOML config — or click **Load current config** to start from whatever is running, then tweak it
4. Save — repeat for other time slots

### How it works

A separate systemd service (`mrvpn-config-scheduler`) polls every 30 seconds. When the current `HH:MM` matches a schedule entry for today, it writes the stored TOML to `/opt/masterdnsvpn/server_config.toml` and restarts the VPN service. The same schedule won't trigger more than once per minute.

> **Note:** If two schedules share the same time, only the first one in the list fires.

### Via API

```bash
# Add a schedule
curl -X POST http://localhost:5000/api/schedules \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Night Mode",
    "time": "22:00",
    "days": ["mon","tue","wed","thu","fri","sat","sun"],
    "config": "... full TOML content ..."
  }'

# List schedules
curl http://localhost:5000/api/schedules \
  -H "Authorization: Bearer <token>"

# Delete a schedule
curl -X DELETE http://localhost:5000/api/schedules/<id> \
  -H "Authorization: Bearer <token>"
```

---

## How It Works

```
install.sh   →  sets up everything, handles reinstalls and version switching
systemd      →  keeps panel, VPN, and scheduler alive across reboots and crashes
web UI       →  monitor server health, edit configs, manage schedules
scheduler    →  auto-applies timed configs even when the dashboard isn't open
```

| File | Role |
|------|------|
| `install.sh` | Installer, version manager, upgrade tool |
| `mrvpn_manager_panel.py` | Main Flask + SocketIO web app |
| `scheduler.py` | Systemd daemon that auto-applies timed configs |
| `auth.py` | JWT token creation and verification |
| `config_editor.py` | Read/write MasterDnsVPN config and key files |
| `service_manager.py` | Restart MasterDnsVPN via systemd |
| `april5_server_config.toml` | Tuned config for the April 5 build |
| `april12_server_config.toml` | Tuned config for the April 12 build |

---

## Installer Smart Behaviours

- **Detects existing installs** in both `/opt/masterdnsvpn` and the current working directory
- **Backs up your files** before wiping anything — asks per file whether to keep or regenerate
- **Frees port 53** automatically by disabling the `systemd-resolved` stub listener if needed
- **Versioned systemd service** — `systemctl status masterdnsvpn` shows which build is running
- **Reinstall / version swap** — re-run `install.sh` at any time

---

## Service Management

### Panel

```bash
systemctl status  mrvpn-manager-panel
systemctl restart mrvpn-manager-panel
journalctl -u mrvpn-manager-panel -f
```

### Config Scheduler

```bash
systemctl status  mrvpn-config-scheduler
systemctl restart mrvpn-config-scheduler
journalctl -u mrvpn-config-scheduler -f
```

### MasterDnsVPN

```bash
systemctl status  masterdnsvpn
systemctl restart masterdnsvpn
journalctl -u masterdnsvpn -f
```

---

## API

### Auth

```
POST /api/auth/login
Body: { "username": "admin", "password": "..." }
Returns: { "ok": true, "access_token": "...", "refresh_token": "..." }

POST /api/auth/refresh
Body: { "refresh_token": "..." }
Returns: { "ok": true, "access_token": "...", "refresh_token": "..." }
```

All other endpoints require `Authorization: Bearer <access_token>`.

### VPN Control

```
POST /api/restart          — restart MasterDnsVPN service
GET  /api/status           — current health snapshot (CPU, RAM, disk, network)
```

### Config

```
GET  /api/config/server    — read server_config.toml
POST /api/config/server    — write server_config.toml and restart VPN
GET  /api/config/key       — read encrypt_key.txt
POST /api/config/key       — write encrypt_key.txt and restart VPN
```

All config writes require `"confirmed": true` in the body. A first call without it returns a confirmation prompt.

### Scheduler

```
GET    /api/schedules           — list all schedules (config content excluded)
POST   /api/schedules           — create a schedule
GET    /api/schedules/<id>      — fetch one schedule including full config
PUT    /api/schedules/<id>      — update a schedule
DELETE /api/schedules/<id>      — delete a schedule
```

---

## UI Pages

| Route | Description |
|-------|-------------|
| `/` | Dashboard — real-time stats, config editor, scheduler |
| `/login` | Login page |
| `/api/status` | Raw health JSON |

---

## Debugging

**Panel not starting**
```bash
journalctl -u mrvpn-manager-panel -n 50 --no-pager
```

**Scheduler not applying configs**
```bash
journalctl -u mrvpn-config-scheduler -f
```

**Port 53 already in use**
```bash
ss -ulnp | grep :53
```
The installer handles this automatically. If it persists, check for other DNS daemons (`named`, `dnsmasq`).

**VPN not starting after reboot**
```bash
systemctl is-enabled masterdnsvpn
systemctl enable masterdnsvpn   # if not enabled
```

**Missing Python packages**
```bash
cd /opt/mrvpn-manager-panel
.venv/bin/pip install -r requirements.txt
```

---

## Requirements

- Ubuntu / Debian-based Linux
- Root access
- Python 3.8+
- Port 5000 open (panel)
- Port 53 UDP open (MasterDnsVPN)

---

## Dependencies

```
flask
flask-socketio
psutil
werkzeug
PyJWT
```
