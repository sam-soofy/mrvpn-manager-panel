#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
APP_DIR="/opt/mrvpn-manager-panel"
SERVICE_NAME="mrvpn-manager-panel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Please run this script as root."
  echo "    Example: sudo bash install.sh"
  exit 1
fi

echo "[*] Updating apt index..."
apt-get update -y

echo "[*] Installing required packages..."
apt-get install -y git python3 python3-pip python3-venv

if [[ -d "${APP_DIR}/.git" ]]; then
  echo "[*] Repository already exists. Updating..."
  git -C "${APP_DIR}" pull --ff-only
else
  echo "[*] Cloning repository..."
  rm -rf "${APP_DIR}"
  git clone "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}"

if [[ ! -f "requirements.txt" ]]; then
  echo "[!] requirements.txt not found."
  exit 1
fi

echo "[*] Creating virtual environment..."
python3 -m venv .venv

echo "[*] Installing Python requirements into venv..."
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt

echo "[*] Installing systemd service for auto-start on boot..."
cat > "${SERVICE_FILE}" <<UNIT
[Unit]
Description=MRVPN Manager Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/python ${APP_DIR}/mrvpn_manager_panel.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
  echo "[*] Restarting existing service..."
  systemctl restart "${SERVICE_NAME}.service"
else
  echo "[*] Starting service..."
  systemctl start "${SERVICE_NAME}.service"
fi

echo

echo "[✓] Installed successfully."
echo "[✓] Service: ${SERVICE_NAME}.service"
echo "[✓] Auto-start on boot: enabled"
echo "[✓] Check status: systemctl status ${SERVICE_NAME}.service"
echo "[✓] View logs: journalctl -u ${SERVICE_NAME}.service -f"
echo "[✓] Web panel should be available on the configured port inside mrvpn_manager_config.json"
