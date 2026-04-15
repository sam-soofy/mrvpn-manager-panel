#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
APP_DIR="/opt/mrvpn-manager-panel"
SESSION_NAME="mrvpn"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Please run this script as root."
  echo "    Example: sudo bash install.sh"
  exit 1
fi

echo "[*] Updating apt index..."
apt-get update -y

echo "[*] Installing required packages..."
apt-get install -y git python3 python3-pip python3-venv screen

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

if screen -ls | grep -q "\.${SESSION_NAME}[[:space:]]"; then
  echo "[*] Screen session '${SESSION_NAME}' already exists. Restarting it..."
  screen -S "${SESSION_NAME}" -X quit || true
fi

echo "[*] Starting MRVPN panel in screen session '${SESSION_NAME}'..."
screen -dmS "${SESSION_NAME}" bash -lc "cd '${APP_DIR}' && exec ./.venv/bin/python mrvpn_manager_panel.py"

echo
echo "[✓] Installed successfully."
echo "[✓] Screen session: ${SESSION_NAME}"
echo "[✓] Attach with: screen -r ${SESSION_NAME}"
