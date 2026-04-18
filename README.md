# MRVPN Manager Panel

A lightweight web panel to install, manage, and monitor servers running [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN).

---

## What It Does

This panel sits on top of MasterDnsVPN and adds:

- **JWT-based authentication** — stateless, no sessions
- **Version-aware installer** — choose between April 5 and April 12 builds
- **Automatic domain injection** — tuned configs with your domain baked in
- **Web dashboard** — real-time CPU, RAM, disk, and network stats via WebSocket
- **One-command reinstall and version switching** — preserves your key and config if you want
- **Systemd-managed** — panel and VPN both run as services, restart on crash and reboot

---

## Installation

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

After installation the credentials are printed:

```
========================================
  Panel URL   : http://YOUR_SERVER_IP:5000
  Panel Login :
    User: admin
    Pass: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
========================================
```

The password is also saved at `/opt/mrvpn-manager-panel/admin_pass.txt`.

---

## How It Works

```
install.sh   →  sets up everything, handles reinstalls and version switching
systemd      →  keeps panel and VPN alive across reboots and crashes
web UI       →  monitor server health and control the VPN
```

| File | Role |
|------|------|
| `install.sh` | Installer, version manager, upgrade tool |
| `mrvpn_manager_panel.py` | Main Flask + SocketIO web app |
| `auth.py` | JWT token creation and verification |
| `config_editor.py` | Read/write MasterDnsVPN config and key files |
| `service_manager.py` | Restart MasterDnsVPN via systemd |
| `april5_server_config.toml` | Tuned config for the April 5 build |
| `april12_server_config.toml` | Tuned config for the April 12 build |

---

## Installer Smart Behaviours

- **Detects existing installs** in both `/opt/masterdnsvpn` and the current working directory. This handles the common case where someone installed MasterDnsVPN manually before using this panel.
- **Backs up your files** before wiping anything. For each of `server_config.toml` and `encrypt_key.txt`, it asks whether to keep or regenerate.
- **Frees port 53** automatically by disabling the `systemd-resolved` stub listener if needed.
- **Versioned systemd service** — `systemctl status masterdnsvpn` shows which build is running (e.g. `MasterDnsVPN Server (april12)`).
- **Reinstall / version swap** — re-run `install.sh` at any time to switch versions or reset the installation.

---

## Service Management

### Panel service

```bash
# Status
systemctl status mrvpn-manager-panel

# Logs (live)
journalctl -u mrvpn-manager-panel -f

# Start / Stop / Restart
systemctl start   mrvpn-manager-panel
systemctl stop    mrvpn-manager-panel
systemctl restart mrvpn-manager-panel

# Enable / Disable on boot
systemctl enable  mrvpn-manager-panel
systemctl disable mrvpn-manager-panel
```

### MasterDnsVPN service

```bash
# Status (also shows which version is installed)
systemctl status masterdnsvpn

# Logs (live)
journalctl -u masterdnsvpn -f

# Start / Stop / Restart
systemctl start   masterdnsvpn
systemctl stop    masterdnsvpn
systemctl restart masterdnsvpn
```

---

## API

The panel exposes a small JSON API.

### Auth

```
POST /api/auth/login
Body: { "username": "admin", "password": "..." }
Returns: { "ok": true, "access_token": "...", "refresh_token": "..." }

POST /api/auth/refresh
Body: { "refresh_token": "..." }
Returns: { "ok": true, "access_token": "...", "refresh_token": "..." }
```

### VPN Control

```
POST /api/restart          — restart MasterDnsVPN service
GET  /api/status           — current health snapshot (CPU, RAM, disk, network)
```

### Config (implemented, UI coming)

```
GET  /api/config/server    — read server_config.toml
POST /api/config/server    — write server_config.toml and restart VPN
GET  /api/config/key       — read encrypt_key.txt
POST /api/config/key       — write encrypt_key.txt and restart VPN
```

All `/api/config` writes require `"confirmed": true` in the request body. A first call without it returns a confirmation prompt message.

---

## UI Pages

| Route | Description |
|-------|-------------|
| `/` | Dashboard — real-time stats, restart button |
| `/login` | Login page |
| `/api/status` | Raw health JSON |

---

## Roadmap

These features are planned and will be added in upcoming releases:

- **Browser-based config and key editor** — view and edit `server_config.toml` and `encrypt_key.txt` directly from the dashboard, with automatic service restart on save. The API endpoints are already implemented; the UI editor is coming.

- **Scheduled config switching** — define multiple server configs for different times of day (e.g. aggressive ARQ settings at night, conservative ones during the day) and have a system service auto-swap them on a schedule.

---

## Debugging

### Common issues

**Port already in use**

```bash
ss -ulnp | grep :53
```

The installer handles this automatically by disabling the `systemd-resolved` stub listener. If it persists, check for other DNS daemons (`named`, `dnsmasq`).

**Panel not starting**

```bash
journalctl -u mrvpn-manager-panel -n 50 --no-pager
```

**VPN not starting after reboot**

```bash
systemctl is-enabled masterdnsvpn
# If not enabled:
systemctl enable masterdnsvpn
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
- Port 53 (UDP) open (MasterDnsVPN)

---

## Dependencies

```
flask
flask-socketio
psutil
werkzeug
PyJWT
```
