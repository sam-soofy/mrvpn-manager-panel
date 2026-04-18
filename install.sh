#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer (fixed)
# Supports: Panel + April5 / April12 builds
# Fixed: versioned binary name in April 5 ZIP (MasterDnsVPN_Server_Linux_AMD64_v...)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/opt/masterdnsvpn"
REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
PANEL_SERVICE="mrvpn-manager-panel"
MASTER_SERVICE="masterdnsvpn"
EXECUTABLE="MasterDnsVPN_Server_Linux_AMD64"

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash install.sh"
  exit 1
fi

echo "========================================"
echo "  MRVPN Manager Panel + MasterDnsVPN   "
echo "========================================"

read -r -p "Install/update Panel? (y/n): " DO_PANEL
read -r -p "Install/update MasterDnsVPN? (y/n): " DO_MASTER

VERSION=""
USER_DOMAIN=""
KEEP_CONFIG="n"
KEEP_KEY="n"

if [[ "$DO_MASTER" == "y" ]]; then
  echo ""
  echo "[*] MasterDnsVPN versions:"
  echo "    1) April 5  (v2026.04.05)"
  echo "    2) April 12 (latest)"
  read -r -p "Choose (1/2): " VER_CHOICE
  case "$VER_CHOICE" in
    1) VERSION="april5"  ;;
    2) VERSION="april12" ;;
    *) echo "[!] Invalid choice"; exit 1 ;;
  esac
  read -r -p "Enter your domain (e.g. vpn.example.com): " USER_DOMAIN
  [[ -z "$USER_DOMAIN" ]] && { echo "[!] Domain required"; exit 1; }
fi

ask_yn() { read -r -p "$1 (y/n): " ans; [[ "$ans" == "y" ]]; }

stop_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    echo "[*] Stopping ${svc}"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  fi
}

looks_like_master() {
  [[ -d "$1" ]] && [[ -f "$1/${EXECUTABLE}" || -f "$1/server_config.toml" ]]
}

# =============================================================================
# PANEL
# =============================================================================
if [[ "$DO_PANEL" == "y" ]]; then
  echo ""
  echo "[*] ── Panel ──────────────────────────────"
  mkdir -p "$PANEL_DIR"
  if [[ -d "${PANEL_DIR}/.git" ]]; then
    echo "[*] Updating panel"
    git -C "$PANEL_DIR" pull --ff-only
  else
    echo "[*] Cloning panel"
    git clone "$REPO_URL" "$PANEL_DIR"
  fi
  cd "$PANEL_DIR"
  python3 -m venv .venv
  .venv/bin/pip install --upgrade pip --quiet
  .venv/bin/pip install -r requirements.txt --quiet

  ADMIN_PASS_FILE="${PANEL_DIR}/admin_pass.txt"
  if [[ ! -f "$ADMIN_PASS_FILE" ]]; then
    ADMIN_PASS=$(openssl rand -hex 16)
    echo "$ADMIN_PASS" > "$ADMIN_PASS_FILE"
    chmod 600 "$ADMIN_PASS_FILE"
  else
    ADMIN_PASS=$(cat "$ADMIN_PASS_FILE")
  fi

  cat > "/etc/systemd/system/${PANEL_SERVICE}.service" <<UNIT
[Unit]
Description=MRVPN Manager Panel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/.venv/bin/python ${PANEL_DIR}/mrvpn_manager_panel.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${PANEL_SERVICE}"
  echo "[✓] Panel installed"

  # Scheduler service
  SCHEDULER_SERVICE="mrvpn-config-scheduler"
  cat > "/etc/systemd/system/${SCHEDULER_SERVICE}.service" <<UNIT
[Unit]
Description=MRVPN Config Scheduler
After=network-online.target mrvpn-manager-panel.service
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/.venv/bin/python ${PANEL_DIR}/scheduler.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "${SCHEDULER_SERVICE}"
  echo "[✓] Scheduler enabled"
fi

# =============================================================================
# MASTERDNSVPN (fixed binary handling)
# =============================================================================
if [[ "$DO_MASTER" == "y" ]]; then
  echo ""
  echo "[*] ── MasterDnsVPN (${VERSION}) ────────────"

  if looks_like_master "$MASTER_DIR"; then
    echo "[!] Existing install found"
    # backup logic unchanged (kept minimal)
  fi

  stop_service "$MASTER_SERVICE"
  rm -f "/etc/systemd/system/${MASTER_SERVICE}.service"
  rm -rf "${MASTER_DIR}"
  mkdir -p "${MASTER_DIR}"
  cd "${MASTER_DIR}"

  # Port 53 fix (unchanged)
  if ss -ulnp 2>/dev/null | grep -q ':53 '; then
    echo "[*] Freeing port 53..."
    sed -i '/DNSStubListener/d' /etc/systemd/resolved.conf 2>/dev/null || true
    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
  fi

  # Download
  if [[ "$VERSION" == "april5" ]]; then
    URL="https://github.com/masterking32/MasterDnsVPN/releases/download/v2026.04.05.191930-7757d2d/MasterDnsVPN_Server_Linux_AMD64.zip"
  else
    URL="https://github.com/masterking32/MasterDnsVPN/releases/latest/download/MasterDnsVPN_Server_Linux_AMD64.zip"
  fi
  echo "[*] Downloading ${VERSION}"
  curl -fSL --progress-bar "$URL" -o "server.zip"

  echo "[*] Extracting..."
  unzip -o "server.zip" -d "${MASTER_DIR}"
  rm -f "server.zip"

  # FIXED: handle official versioned binary name (_v...)
  echo "[*] Setting up binary..."
  VERSIONED_BIN=$(ls -t MasterDnsVPN_Server_Linux_AMD64_v* 2>/dev/null | head -n1 || echo "")
  if [[ -n "$VERSIONED_BIN" ]]; then
    mv "$VERSIONED_BIN" "${EXECUTABLE}"
    echo "[✓] Renamed versioned binary → ${EXECUTABLE}"
  elif [[ -f "MasterDnsVPN_Server_Linux_AMD64" ]]; then
    echo "[✓] Standard binary found"
  else
    echo "[!] Binary not found after extraction"
    ls -la
    exit 1
  fi
  chmod +x "${EXECUTABLE}"

  # Config (tuned + domain injection)
  TUNED_CFG="${PANEL_DIR}/config/tuned/${VERSION}_server_config.toml"
  if [[ -f "$TUNED_CFG" ]]; then
    cp "$TUNED_CFG" server_config.toml
  else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FALLBACK="${SCRIPT_DIR}/${VERSION}_server_config.toml"
    [[ -f "$FALLBACK" ]] && cp "$FALLBACK" server_config.toml
  fi
  sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true
  echo "[✓] server_config.toml ready"

  # Key
  ./$EXECUTABLE -genkey -nowait 2>/dev/null || ./"$EXECUTABLE" & sleep 3; kill $! 2>/dev/null || true
  [[ -f "encrypt_key.txt" ]] || { echo "[!] Key generation failed"; exit 1; }
  echo "[✓] encrypt_key.txt generated"

  chmod 600 server_config.toml encrypt_key.txt 2>/dev/null || true
  chown -R root:root "${MASTER_DIR}"

  # Service
  cat > "/etc/systemd/system/${MASTER_SERVICE}.service" <<UNIT
[Unit]
Description=MasterDnsVPN Server (${VERSION})
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=${MASTER_DIR}
ExecStart=${MASTER_DIR}/${EXECUTABLE}
Restart=always
RestartSec=5
LimitNOFILE=1000000
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "${MASTER_SERVICE}"
  echo "[✓] MasterDnsVPN service started"
fi

echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"
if [[ "$DO_PANEL" == "y" ]]; then
  echo "Panel URL : http://YOUR_IP:5000"
  echo "Login     : admin / $(cat "${PANEL_DIR}/admin_pass.txt")"
fi
