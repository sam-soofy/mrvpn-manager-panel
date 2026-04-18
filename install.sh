#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer (FULL REWRITE — v2)
# Fixed: CWD stray installs • systemd service cleanup • separate keep prompts
# Port 53 aggressive cleanup (inspired by official server_linux_install.sh)
# Supports: Panel + April5 / April12
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

VERSION="" USER_DOMAIN="" KEEP_CONFIG="n" KEEP_KEY="n"

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
    echo "[*] Stopping + disabling ${svc}"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  fi
}

looks_like_master() {
  local dir="$1"
  [[ -d "$dir" ]] && [[ -f "${dir}/${EXECUTABLE}" || -f "${dir}/server_config.toml" || -f "${dir}/encrypt_key.txt" ]]
}

# ── CWD stray cleanup (official installer installs in pwd) ───────────────────
if [[ "$DO_MASTER" == "y" ]]; then
  CWD="$(pwd)"
  if [[ "$CWD" != "$MASTER_DIR" ]] && looks_like_master "$CWD"; then
    echo ""
    echo "[!] Found stray MasterDnsVPN files in current directory: ${CWD}"
    echo "    (common when official install.sh was used before)"
    if ask_yn "    Backup server_config.toml?"; then
      cp "${CWD}/server_config.toml" "/tmp/server_config_backup_$(date +%s).toml" 2>/dev/null || true
      KEEP_CONFIG="y"
    fi
    if ask_yn "    Backup encrypt_key.txt?"; then
      cp "${CWD}/encrypt_key.txt" "/tmp/encrypt_key_backup_$(date +%s).txt" 2>/dev/null || true
      KEEP_KEY="y"
    fi
    rm -f "${CWD}/${EXECUTABLE}" "${CWD}/server_config.toml" "${CWD}/encrypt_key.txt" 2>/dev/null || true
    echo "[✓] Cleaned stray files from ${CWD}"
  fi
fi

# ── PANEL ─────────────────────────────────────────────────────────────────────
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

  # JWT secret
  [[ ! -f jwt_secret.txt ]] && openssl rand -hex 32 > jwt_secret.txt && chmod 600 jwt_secret.txt

  # Admin pass
  ADMIN_PASS_FILE="admin_pass.txt"
  [[ ! -f "$ADMIN_PASS_FILE" ]] && openssl rand -hex 16 > "$ADMIN_PASS_FILE" && chmod 600 "$ADMIN_PASS_FILE"

  # Services
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

  cat > "/etc/systemd/system/mrvpn-config-scheduler.service" <<UNIT
[Unit]
Description=MRVPN Config Scheduler
After=network-online.target ${PANEL_SERVICE}.service
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
  systemctl enable --now "${PANEL_SERVICE}" mrvpn-config-scheduler
  echo "[✓] Panel + scheduler installed"
fi

# ── MASTERDNSVPN ──────────────────────────────────────────────────────────────
if [[ "$DO_MASTER" == "y" ]]; then
  echo ""
  echo "[*] ── MasterDnsVPN (${VERSION}) ────────────"

  # Stop any existing service (our or official)
  stop_service "$MASTER_SERVICE"

  # Backup if exists in /opt
  if [[ -f "${MASTER_DIR}/server_config.toml" ]] && ask_yn "    Keep existing server_config.toml?"; then
    cp "${MASTER_DIR}/server_config.toml" "/tmp/server_config_backup_$(date +%s).toml"
    KEEP_CONFIG="y"
  fi
  if [[ -f "${MASTER_DIR}/encrypt_key.txt" ]] && ask_yn "    Keep existing encrypt_key.txt?"; then
    cp "${MASTER_DIR}/encrypt_key.txt" "/tmp/encrypt_key_backup_$(date +%s).txt"
    KEEP_KEY="y"
  fi

  # Clean target
  rm -rf "${MASTER_DIR}"
  mkdir -p "${MASTER_DIR}"
  cd "${MASTER_DIR}"

  # Aggressive port 53 cleanup (from official installer logic)
  echo "[*] Freeing port 53..."
  systemctl stop systemd-resolved 2>/dev/null || true
  sed -i '/DNSStubListener/d' /etc/systemd/resolved.conf 2>/dev/null || true
  echo "DNSStubListener=no" >> /etc/systemd/resolved.conf 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || true

  for svc in named bind9 dnsmasq masterdnsvpn; do
    stop_service "$svc"
  done

  # Kill any lingering processes on 53
  for pid in $(ss -H -lupn 'sport = :53' 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u); do
    kill -9 "$pid" 2>/dev/null || true
  done

  # Download
  if [[ "$VERSION" == "april5" ]]; then
    URL="https://github.com/masterking32/MasterDnsVPN/releases/download/v2026.04.05.191930-7757d2d/MasterDnsVPN_Server_Linux_AMD64.zip"
  else
    URL="https://github.com/masterking32/MasterDnsVPN/releases/latest/download/MasterDnsVPN_Server_Linux_AMD64.zip"
  fi
  echo "[*] Downloading ${VERSION}..."
  curl -fSL --progress-bar "$URL" -o server.zip
  unzip -o server.zip
  rm -f server.zip

  # Handle versioned binary
  if [[ ! -f "$EXECUTABLE" ]]; then
    FOUND=$(find . -name "MasterDnsVPN_Server_Linux_AMD64*" -type f | head -1)
    [[ -n "$FOUND" ]] && mv "$FOUND" "$EXECUTABLE"
  fi
  chmod +x "$EXECUTABLE"

  # Config
  if [[ "$KEEP_CONFIG" == "y" && -f "/tmp/server_config_backup_"* ]]; then
    cp /tmp/server_config_backup_* server_config.toml 2>/dev/null || true
  else
    TUNED="${PANEL_DIR}/config/tuned/${VERSION}_server_config.toml"
    [[ -f "$TUNED" ]] && cp "$TUNED" server_config.toml || echo "[!] No tuned config — using default"
  fi
  sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true

  # Key
  if [[ "$KEEP_KEY" == "y" && -f "/tmp/encrypt_key_backup_"* ]]; then
    cp /tmp/encrypt_key_backup_* encrypt_key.txt
  else
    echo "[*] Generating key..."
    if [[ "$VERSION" == "april12" ]]; then
      ./"$EXECUTABLE" -genkey -nowait
    else
      ./"$EXECUTABLE" & pid=$!; sleep 3; kill $pid 2>/dev/null || true
    fi
  fi

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
[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${MASTER_SERVICE}"
  echo "[✓] MasterDnsVPN installed and started"
fi

echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"
if [[ "$DO_PANEL" == "y" ]]; then
  echo "Panel   → http://YOUR_IP:5000"
  echo "Login   → admin / $(cat "${PANEL_DIR}/admin_pass.txt" 2>/dev/null || echo "see admin_pass.txt")"
fi
if [[ "$DO_MASTER" == "y" ]]; then
  echo "VPN dir → ${MASTER_DIR}"
  echo "Domain  → ${USER_DOMAIN}"
fi
echo "========================================"
