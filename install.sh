#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer
# Supports: Panel install/update, MasterDnsVPN v april5 / april12
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Paths & constants ─────────────────────────────────────────────────────────
PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/opt/masterdnsvpn"
REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
PANEL_SERVICE="mrvpn-manager-panel"
MASTER_SERVICE="masterdnsvpn"
EXECUTABLE="MasterDnsVPN_Server_Linux_AMD64"

# ── Root check ────────────────────────────────────────────────────────────────
if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash install.sh"
  exit 1
fi

echo "========================================"
echo "  MRVPN Manager Panel + MasterDnsVPN   "
echo "========================================"

# ── Top-level choices ─────────────────────────────────────────────────────────
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

# =============================================================================
# Helper: ask yes/no
# Usage: ask_yn "Question?" && <if yes branch>
# =============================================================================
ask_yn() {
  local ans
  read -r -p "$1 (y/n): " ans
  [[ "$ans" == "y" ]]
}

# =============================================================================
# Helper: safely stop + disable a systemd service (no error if not found)
# =============================================================================
stop_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    echo "[*] Stopping service: ${svc}"
    systemctl stop "${svc}"  2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  fi
}

# =============================================================================
# Helper: detect MasterDnsVPN installation in a given directory
# Returns 0 if dir looks like a MasterDnsVPN install, 1 otherwise
# =============================================================================
looks_like_master() {
  local dir="$1"
  [[ -d "$dir" ]] && [[ -f "${dir}/${EXECUTABLE}" || -f "${dir}/server_config.toml" ]]
}

# =============================================================================
# Helper: backup valuable files from a directory
# Sets globals: BACKUP_CONFIG_FILE, BACKUP_KEY_FILE
# =============================================================================
BACKUP_CONFIG_FILE=""
BACKUP_KEY_FILE=""

backup_master_files() {
  local src_dir="$1"
  local ts
  ts=$(date +%s)

  if [[ -f "${src_dir}/server_config.toml" ]]; then
    if ask_yn "    Found server_config.toml in ${src_dir}. Keep it?"; then
      BACKUP_CONFIG_FILE="/tmp/server_config_backup_${ts}.toml"
      cp "${src_dir}/server_config.toml" "$BACKUP_CONFIG_FILE"
      echo "    [✓] Config backed up → ${BACKUP_CONFIG_FILE}"
      KEEP_CONFIG="y"
    fi
  fi

  if [[ -f "${src_dir}/encrypt_key.txt" ]]; then
    if ask_yn "    Found encrypt_key.txt in ${src_dir}. Keep it?"; then
      BACKUP_KEY_FILE="/tmp/encrypt_key_backup_${ts}.txt"
      cp "${src_dir}/encrypt_key.txt" "$BACKUP_KEY_FILE"
      echo "    [✓] Key backed up → ${BACKUP_KEY_FILE}"
      KEEP_KEY="y"
    fi
  fi
}

# =============================================================================
# Helper: fix port 53 conflict with systemd-resolved (common on Ubuntu)
# =============================================================================
fix_port53() {
  if ss -ulnp 2>/dev/null | grep -q ':53 '; then
    echo "[*] Port 53 is occupied — attempting to free it"

    # Disable stub resolver in systemd-resolved
    local RESOLVED_CONF="/etc/systemd/resolved.conf"
    if [[ -f "$RESOLVED_CONF" ]]; then
      if ! grep -q "^DNSStubListener=no" "$RESOLVED_CONF"; then
        sed -i '/^DNSStubListener/d' "$RESOLVED_CONF"
        echo "DNSStubListener=no" >> "$RESOLVED_CONF"
        systemctl restart systemd-resolved 2>/dev/null || true
        echo "[✓] Disabled systemd-resolved stub listener"
      fi
    fi

    # If port is still busy, try stopping known DNS services
    for svc in named bind9 dnsmasq; do
      if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        echo "[✓] Stopped ${svc}"
      fi
    done

    sleep 1
    if ss -ulnp 2>/dev/null | grep -q ':53 '; then
      echo "[!] WARNING: Port 53 may still be in use. MasterDnsVPN might fail to bind."
      echo "    Check with: ss -ulnp | grep :53"
    fi
  fi
}

# =============================================================================
# Helper: create masterdnsvpn systemd service file and start it
# =============================================================================
create_master_service() {
  local bin_path="${MASTER_DIR}/${EXECUTABLE}"

  echo "[*] Creating systemd service: ${MASTER_SERVICE}"

  # Remove old service file if it exists
  rm -f "/etc/systemd/system/${MASTER_SERVICE}.service"

  cat > "/etc/systemd/system/${MASTER_SERVICE}.service" <<UNIT
[Unit]
Description=MasterDnsVPN Server (${VERSION})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${MASTER_DIR}
ExecStart=${bin_path}
Restart=always
RestartSec=5
LimitNOFILE=1000000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "${MASTER_SERVICE}"
  systemctl restart "${MASTER_SERVICE}"
  echo "[✓] Service ${MASTER_SERVICE} enabled and started"
}

# =============================================================================
# Helper: generate encryption key
# april5 binary generates key on first run (doesn't have -genkey flag)
# april12 binary has -genkey -nowait
# =============================================================================
generate_key() {
  local ver="$1"

  echo "[*] Generating encryption key..."

  if [[ "$ver" == "april12" ]]; then
    "./${EXECUTABLE}" -genkey -nowait
  else
    # april5: run binary in background, wait for key file to appear, then kill it
    "./${EXECUTABLE}" &
    local BG_PID=$!
    local waited=0
    while [[ ! -f "encrypt_key.txt" ]] && (( waited < 15 )); do
      sleep 0.5
      (( waited++ )) || true
    done
    kill "$BG_PID" 2>/dev/null || true
    wait "$BG_PID"  2>/dev/null || true
  fi

  if [[ -f "encrypt_key.txt" ]]; then
    echo "[✓] encrypt_key.txt generated"
  else
    echo "[!] Key generation failed — encrypt_key.txt not found"
    exit 1
  fi
}

# =============================================================================
# SCAN: Current working directory for stray MasterDnsVPN installs
# =============================================================================
if [[ "$DO_MASTER" == "y" ]]; then
  CWD_DIR="$(pwd)"

  # Avoid double-processing if someone runs from /opt/masterdnsvpn itself
  if [[ "$CWD_DIR" != "$MASTER_DIR" ]] && looks_like_master "$CWD_DIR"; then
    echo ""
    echo "[!] Found a MasterDnsVPN installation in current directory: ${CWD_DIR}"
    echo "    (This is common when the VPN was installed manually before using this panel)"
    backup_master_files "$CWD_DIR"
    echo "[*] Cleaning ${CWD_DIR}..."
    # Remove only the VPN binary and its config files — don't delete the whole dir
    # since the user may have other things there (e.g. this very install.sh)
    rm -f "${CWD_DIR}/${EXECUTABLE}"
    rm -f "${CWD_DIR}/server_config.toml"
    rm -f "${CWD_DIR}/encrypt_key.txt"
    echo "[✓] Cleaned stray MasterDnsVPN files from ${CWD_DIR}"
  fi
fi

# =============================================================================
# PANEL INSTALL / UPDATE
# =============================================================================
if [[ "$DO_PANEL" == "y" ]]; then
  echo ""
  echo "[*] ── Panel ──────────────────────────────"
  mkdir -p "$PANEL_DIR"

  if [[ -d "${PANEL_DIR}/.git" ]]; then
    echo "[*] Panel exists → updating"
    git -C "$PANEL_DIR" pull --ff-only
  else
    echo "[*] Cloning panel from ${REPO_URL}"
    git clone "$REPO_URL" "$PANEL_DIR"
  fi

  cd "$PANEL_DIR"
  python3 -m venv .venv
  .venv/bin/pip install --upgrade pip --quiet
  .venv/bin/pip install -r requirements.txt --quiet

  # Generate a random password for admin on first install
  ADMIN_PASS_FILE="${PANEL_DIR}/admin_pass.txt"
  if [[ ! -f "$ADMIN_PASS_FILE" ]]; then
    ADMIN_PASS=$(openssl rand -hex 16)
    echo "$ADMIN_PASS" > "$ADMIN_PASS_FILE"
    chmod 600 "$ADMIN_PASS_FILE"
  else
    ADMIN_PASS=$(cat "$ADMIN_PASS_FILE")
  fi

  # Write panel systemd service
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
Environment=ADMIN_PASSWORD=${ADMIN_PASS}

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${PANEL_SERVICE}"
  echo "[✓] Panel installed at ${PANEL_DIR}"
fi

# =============================================================================
# MASTERDNSVPN INSTALL / VERSION SWAP
# =============================================================================
if [[ "$DO_MASTER" == "y" ]]; then
  echo ""
  echo "[*] ── MasterDnsVPN (${VERSION}) ────────────"

  # ── Step 1: Check /opt/masterdnsvpn for existing install ──────────────────
  if looks_like_master "$MASTER_DIR"; then
    echo "[!] Existing MasterDnsVPN found at ${MASTER_DIR}"
    backup_master_files "$MASTER_DIR"
  fi

  # ── Step 2: Stop existing service ─────────────────────────────────────────
  stop_service "$MASTER_SERVICE"

  # ── Step 3: Remove old service file + wipe directory ──────────────────────
  rm -f "/etc/systemd/system/${MASTER_SERVICE}.service"
  rm -rf "${MASTER_DIR}"
  mkdir -p "${MASTER_DIR}"
  cd "${MASTER_DIR}"

  # ── Step 4: Free port 53 if needed ────────────────────────────────────────
  fix_port53

  # ── Step 5: Download correct version ──────────────────────────────────────
  if [[ "$VERSION" == "april5" ]]; then
    URL="https://github.com/masterking32/MasterDnsVPN/releases/download/v2026.04.05.191930-7757d2d/MasterDnsVPN_Server_Linux_AMD64.zip"
  else
    URL="https://github.com/masterking32/MasterDnsVPN/releases/latest/download/MasterDnsVPN_Server_Linux_AMD64.zip"
  fi

  echo "[*] Downloading from: ${URL}"
  curl -fSL --progress-bar "$URL" -o "MasterDnsVPN_Server_Linux_AMD64.zip"

  echo "[*] Extracting..."
  unzip -o "MasterDnsVPN_Server_Linux_AMD64.zip" -d "${MASTER_DIR}"
  rm -f "MasterDnsVPN_Server_Linux_AMD64.zip"

  # Make binary executable (handle both bare file and nested dir in zip)
  if [[ ! -f "${EXECUTABLE}" ]]; then
    # Some releases put the binary one folder deep
    FOUND_BIN=$(find "${MASTER_DIR}" -name "${EXECUTABLE}" -type f | head -1)
    if [[ -n "$FOUND_BIN" ]]; then
      mv "$FOUND_BIN" "${MASTER_DIR}/${EXECUTABLE}"
    else
      echo "[!] Binary '${EXECUTABLE}' not found after extraction"
      exit 1
    fi
  fi
  chmod +x "${EXECUTABLE}"

  # ── Step 6: Restore or generate server_config.toml ────────────────────────
  echo ""
  if [[ "$KEEP_CONFIG" == "y" && -f "$BACKUP_CONFIG_FILE" ]]; then
    cp "$BACKUP_CONFIG_FILE" server_config.toml
    echo "[✓] Restored server_config.toml from backup"
    # Still inject domain in case domain changed
    sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml
  else
    # Use tuned config from panel
    TUNED_CFG="${PANEL_DIR}/config/tuned/${VERSION}_server_config.toml"
    if [[ -f "$TUNED_CFG" ]]; then
      cp "$TUNED_CFG" server_config.toml
    else
      # Fallback: copy from alongside install.sh (for when panel was not installed)
      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      FALLBACK="${SCRIPT_DIR}/${VERSION}_server_config.toml"
      if [[ -f "$FALLBACK" ]]; then
        cp "$FALLBACK" server_config.toml
      else
        echo "[!] No tuned config found. You will need to create server_config.toml manually."
      fi
    fi
    sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml
    echo "[✓] Fresh server_config.toml written (domain: ${USER_DOMAIN})"
  fi

  # ── Step 7: Restore or generate encrypt_key.txt ───────────────────────────
  if [[ "$KEEP_KEY" == "y" && -f "$BACKUP_KEY_FILE" ]]; then
    cp "$BACKUP_KEY_FILE" encrypt_key.txt
    echo "[✓] Restored encrypt_key.txt from backup"
  else
    generate_key "$VERSION"
  fi

  # ── Step 8: Set permissions ────────────────────────────────────────────────
  chmod 600 server_config.toml encrypt_key.txt 2>/dev/null || true
  chown -R root:root "${MASTER_DIR}"

  # ── Step 9: Create fresh systemd service + start ──────────────────────────
  systemctl daemon-reload
  create_master_service

  # ── Step 10: Verify service started OK ────────────────────────────────────
  sleep 2
  if systemctl is-active --quiet "${MASTER_SERVICE}"; then
    echo "[✓] MasterDnsVPN is running"
  else
    echo "[!] MasterDnsVPN service did not start. Check logs:"
    echo "    journalctl -u ${MASTER_SERVICE} -n 30 --no-pager"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"

if [[ "$DO_PANEL" == "y" ]]; then
  echo ""
  echo "  Panel URL   : http://YOUR_SERVER_IP:5000"
  echo "  Panel Login :"
  echo "    User: admin"
  echo "    Pass: ${ADMIN_PASS:-<see ${PANEL_DIR}/admin_pass.txt>}"
  echo ""
  echo "  Panel service commands:"
  echo "    systemctl status  ${PANEL_SERVICE}"
  echo "    systemctl restart ${PANEL_SERVICE}"
  echo "    journalctl -u ${PANEL_SERVICE} -f"
fi

if [[ "$DO_MASTER" == "y" ]]; then
  echo ""
  echo "  MasterDnsVPN version : ${VERSION}"
  echo "  Install dir          : ${MASTER_DIR}"
  echo "  Domain               : ${USER_DOMAIN}"
  echo ""
  echo "  VPN service commands:"
  echo "    systemctl status  ${MASTER_SERVICE}"
  echo "    systemctl restart ${MASTER_SERVICE}"
  echo "    journalctl -u ${MASTER_SERVICE} -f"
fi

echo "========================================"
