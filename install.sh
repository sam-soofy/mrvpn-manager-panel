#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer (v5)
# Fixes:
#   - Tracked backup paths (no glob ambiguity, no stale-backup collisions)
#   - Key gen runs BEFORE config restore (April 5 binary creates default config)
#   - Temp backups cleaned up at exit via trap
#   - Uninstall mode (downloads and runs uninstall.sh)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/opt/masterdnsvpn"
REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
PANEL_SERVICE="mrvpn-manager-panel"
MASTER_SERVICE="masterdnsvpn"
EXECUTABLE="MasterDnsVPN_Server_Linux_AMD64"
UNINSTALL_URL="https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/main/uninstall.sh"

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash install.sh"
  exit 1
fi

# ── Per-run backup paths ───────────────────────────────────────────────────────
# Fixed paths keyed by PID+timestamp — no glob ambiguity, no stale collisions.
RUN_ID="$$_$(date +%s)"
CONFIG_BACKUP="/tmp/mrvpn_server_config_${RUN_ID}.toml"
KEY_BACKUP="/tmp/mrvpn_encrypt_key_${RUN_ID}.txt"
HAS_CONFIG_BACKUP=false
HAS_KEY_BACKUP=false

cleanup_temp() {
  $HAS_CONFIG_BACKUP && rm -f "$CONFIG_BACKUP" 2>/dev/null || true
  $HAS_KEY_BACKUP    && rm -f "$KEY_BACKUP"    2>/dev/null || true
}
trap cleanup_temp EXIT

# ── Mode selection ─────────────────────────────────────────────────────────────
echo "========================================"
echo "  MRVPN Manager Panel + MasterDnsVPN   "
echo "========================================"
echo ""
echo "  1) Install / Update"
echo "  2) Uninstall everything"
echo ""
read -r -p "Choose (1/2): " MODE_CHOICE

if [[ "$MODE_CHOICE" == "2" ]]; then
  echo "[*] Downloading uninstaller..."
  curl -fsSL "$UNINSTALL_URL" -o /tmp/mrvpn_uninstall.sh
  bash /tmp/mrvpn_uninstall.sh
  rm -f /tmp/mrvpn_uninstall.sh
  exit 0
fi

[[ "$MODE_CHOICE" != "1" ]] && echo "[!] Invalid choice" && exit 1

echo ""
read -r -p "Install/update Panel? (y/n): " DO_PANEL
read -r -p "Install/update MasterDnsVPN? (y/n): " DO_MASTER

VERSION="" USER_DOMAIN=""

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

# ── Service helpers ───────────────────────────────────────────────────────────

stop_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    echo "[*] Stopping + disabling ${svc}"
    systemctl stop    "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  fi
}

get_service_workdir() {
  local svc_file="/etc/systemd/system/${1}.service"
  [[ -f "$svc_file" ]] && grep -E "^WorkingDirectory=" "$svc_file" | cut -d= -f2- | tr -d ' '
}

# ── MasterDnsVPN file detection ───────────────────────────────────────────────

looks_like_master() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -f "${dir}/server_config.toml" ]] && return 0
  [[ -f "${dir}/encrypt_key.txt" ]]    && return 0
  ls "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null | grep -q . && return 0
  return 1
}

# ── Backup helpers ────────────────────────────────────────────────────────────

do_backup_config() {
  local src="$1"
  cp "$src" "$CONFIG_BACKUP"
  HAS_CONFIG_BACKUP=true
  echo "[*] Config backed up to ${CONFIG_BACKUP}"
}

do_backup_key() {
  local src="$1"
  cp "$src" "$KEY_BACKUP"
  HAS_KEY_BACKUP=true
  echo "[*] Key backed up to ${KEY_BACKUP}"
}

# ── Stray-file cleanup ────────────────────────────────────────────────────────

cleanup_stray_files() {
  local CWD
  CWD="$(pwd)"

  declare -a CANDIDATES=("$CWD")

  local SVC_DIR
  SVC_DIR=$(get_service_workdir "$MASTER_SERVICE" || true)
  [[ -n "${SVC_DIR:-}" && "$SVC_DIR" != "$MASTER_DIR" ]] && CANDIDATES+=("$SVC_DIR")
  [[ "/root" != "$CWD" && "/root" != "$MASTER_DIR" ]]    && CANDIDATES+=("/root")

  declare -A SEEN=()
  for dir in "${CANDIDATES[@]}"; do
    [[ "$dir" == "$MASTER_DIR" ]] && continue
    [[ -n "${SEEN[$dir]+_}" ]]    && continue
    SEEN[$dir]=1

    ! looks_like_master "$dir" && continue

    echo ""
    echo "[!] Found MasterDnsVPN files in: ${dir}"

    if [[ -f "${dir}/server_config.toml" ]] && ! $HAS_CONFIG_BACKUP \
        && ask_yn "    Back up server_config.toml from ${dir}?"; then
      do_backup_config "${dir}/server_config.toml"
    fi

    if [[ -f "${dir}/encrypt_key.txt" ]] && ! $HAS_KEY_BACKUP \
        && ask_yn "    Back up encrypt_key.txt from ${dir}?"; then
      do_backup_key "${dir}/encrypt_key.txt"
    fi

    rm -f "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null || true
    rm -f "${dir}/server_config.toml" "${dir}/encrypt_key.txt"  2>/dev/null || true
    rm -f "${dir}/server_config.toml.backup" "${dir}/init_logs.tmp" 2>/dev/null || true
    echo "[✓] Cleaned stray files from ${dir}"
  done
}

# ── Run stray cleanup ─────────────────────────────────────────────────────────
if [[ "$DO_MASTER" == "y" ]]; then
  cleanup_stray_files
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

  [[ ! -f jwt_secret.txt ]] && openssl rand -hex 32 > jwt_secret.txt && chmod 600 jwt_secret.txt
  [[ ! -f admin_pass.txt  ]] && openssl rand -hex 16 > admin_pass.txt  && chmod 600 admin_pass.txt

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

  stop_service "$MASTER_SERVICE"

  # Ask about MASTER_DIR files — only if not already backed up from stray cleanup
  if [[ -f "${MASTER_DIR}/server_config.toml" ]] && ! $HAS_CONFIG_BACKUP; then
    if ask_yn "    Back up existing server_config.toml from ${MASTER_DIR}?"; then
      do_backup_config "${MASTER_DIR}/server_config.toml"
    fi
  fi
  if [[ -f "${MASTER_DIR}/encrypt_key.txt" ]] && ! $HAS_KEY_BACKUP; then
    if ask_yn "    Back up existing encrypt_key.txt from ${MASTER_DIR}?"; then
      do_backup_key "${MASTER_DIR}/encrypt_key.txt"
    fi
  fi

  rm -rf "${MASTER_DIR}"
  mkdir -p "${MASTER_DIR}"
  cd "${MASTER_DIR}"

  # ── Free port 53 ────────────────────────────────────────────────────────────
  echo "[*] Freeing port 53..."
  systemctl stop systemd-resolved 2>/dev/null || true
  sed -i '/DNSStubListener/d' /etc/systemd/resolved.conf 2>/dev/null || true
  echo "DNSStubListener=no" >> /etc/systemd/resolved.conf 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || true

  for svc in named bind9 dnsmasq; do
    stop_service "$svc"
  done
  for pid in $(ss -H -lupn 'sport = :53' 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u); do
    kill -9 "$pid" 2>/dev/null || true
  done

  # ── Download binary ──────────────────────────────────────────────────────────
  if [[ "$VERSION" == "april5" ]]; then
    URL="https://github.com/masterking32/MasterDnsVPN/releases/download/v2026.04.05.191930-7757d2d/MasterDnsVPN_Server_Linux_AMD64.zip"
  else
    URL="https://github.com/masterking32/MasterDnsVPN/releases/latest/download/MasterDnsVPN_Server_Linux_AMD64.zip"
  fi
  echo "[*] Downloading ${VERSION}..."
  curl -fSL --progress-bar "$URL" -o server.zip
  unzip -o server.zip
  rm -f server.zip

  # Normalize binary name (latest releases ship as *_v2026.xx.xx...)
  if [[ ! -f "$EXECUTABLE" ]]; then
    FOUND=$(ls -t "${EXECUTABLE}"_v* 2>/dev/null | head -1)
    [[ -z "$FOUND" ]] && FOUND=$(find . -maxdepth 1 -name "MasterDnsVPN_Server_Linux_AMD64*" -type f | head -1)
    [[ -n "$FOUND" ]] && cp "$FOUND" "$EXECUTABLE"
  fi
  chmod +x "$EXECUTABLE"

  # ── KEY GENERATION — must happen BEFORE config restore ─────────────────────
  # Reason: the April 5 binary creates a default server_config.toml when it
  # starts. If we restore the config first, the binary overwrites it.
  # By generating the key first, we can safely overwrite the default config
  # with our backup in the next step.
  if $HAS_KEY_BACKUP; then
    cp "$KEY_BACKUP" encrypt_key.txt
    echo "[*] Encryption key restored from backup"
  else
    echo "[*] Generating encryption key..."
    if [[ "$VERSION" == "april12" ]]; then
      ./"$EXECUTABLE" -genkey -nowait
    else
      # April 5: run binary, wait for key file to appear, then kill it.
      ./"$EXECUTABLE" > /tmp/mdns_init.log 2>&1 &
      INIT_PID=$!
      for i in {1..10}; do
        [[ -f encrypt_key.txt ]] && break
        sleep 1
      done
      kill "$INIT_PID" 2>/dev/null || true
      wait "$INIT_PID" 2>/dev/null || true
      rm -f /tmp/mdns_init.log
      [[ ! -f encrypt_key.txt ]] && echo "[!] Key generation timed out — check port 53 is free"
    fi
  fi

  # ── CONFIG RESTORE / INSTALL — after key gen ───────────────────────────────
  if $HAS_CONFIG_BACKUP; then
    # Restore user's config. It already has the real domain baked in,
    # but the sed below is safe to run regardless (no-op if no placeholder).
    cp "$CONFIG_BACKUP" server_config.toml
    sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true
    echo "[*] server_config.toml restored from backup"
  else
    # Fresh install — copy our tuned template and inject the domain.
    TUNED="${PANEL_DIR}/${VERSION}_server_config.toml"
    if [[ -f "$TUNED" ]]; then
      cp "$TUNED" server_config.toml
      sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml
      echo "[*] Using tuned config for ${VERSION} with domain ${USER_DOMAIN}"
    else
      echo "[!] Tuned config not found at ${TUNED} — binary default will be used"
      # Binary already wrote a default config during key gen; patch domain in if present.
      [[ -f server_config.toml ]] && sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true
    fi
  fi

  chmod 600 server_config.toml encrypt_key.txt 2>/dev/null || true
  chown -R root:root "${MASTER_DIR}"

  # ── Systemd service ──────────────────────────────────────────────────────────
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
  echo "[✓] MasterDnsVPN (${VERSION}) installed and started"
fi

# ── Final output ──────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"

if [[ "$DO_MASTER" == "y" ]]; then
  echo "VPN dir → ${MASTER_DIR}"
  echo "Version → ${VERSION}"
  echo "Domain  → ${USER_DOMAIN}"
  echo ""
fi

if [[ "$DO_PANEL" == "y" ]]; then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_SERVER_IP")
  ADMIN_PASS=$(cat "${PANEL_DIR}/admin_pass.txt" 2>/dev/null || echo "see admin_pass.txt")

  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║          ★  SAVE YOUR LOGIN CREDENTIALS  ★          ║"
  echo "╠══════════════════════════════════════════════════════╣"
  echo "║                                                      ║"
  printf "║  URL  : http://%-36s║\n" "${SERVER_IP}:5000 "
  echo "║  User : admin                                        ║"
  printf "║  Pass : %-43s║\n" "${ADMIN_PASS} "
  echo "║                                                      ║"
  echo "╠══════════════════════════════════════════════════════╣"
  printf "║  Password file: %-35s║\n" "${PANEL_DIR}/admin_pass.txt "
  echo "║                                                      ║"
  echo "║  TO RESET PASSWORD:                                  ║"
  printf "║    nano %-44s║\n" "${PANEL_DIR}/admin_pass.txt "
  echo "║    systemctl restart mrvpn-manager-panel             ║"
  echo "╚══════════════════════════════════════════════════════╝"
fi
echo "========================================"
