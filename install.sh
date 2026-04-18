#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer (v4)
# Fixes: glob detection, service-dir discovery, config path, backup restore,
#        better stray-file cleanup, credentials display block
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

# ── Service helpers ───────────────────────────────────────────────────────────

stop_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    echo "[*] Stopping + disabling ${svc}"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  fi
}

# Read WorkingDirectory from a systemd service file.
# Returns the path, or empty string if not found.
get_service_workdir() {
  local svc_file="/etc/systemd/system/${1}.service"
  if [[ -f "$svc_file" ]]; then
    grep -E "^WorkingDirectory=" "$svc_file" | cut -d= -f2- | tr -d ' '
  fi
}

# ── MasterDnsVPN file detection ───────────────────────────────────────────────
# Checks whether a directory looks like a MasterDnsVPN install.
# Uses ls-glob instead of [[ -f glob ]] which is unreliable in bash.
looks_like_master() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  # Check for config or key files (version-agnostic)
  [[ -f "${dir}/server_config.toml" ]] && return 0
  [[ -f "${dir}/encrypt_key.txt" ]]    && return 0
  # Check for any MasterDnsVPN binary (plain or versioned name)
  ls "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null | grep -q . && return 0
  return 1
}

# Backup a file to /tmp with a timestamp suffix, print the backup path.
backup_file() {
  local src="$1" tag="$2"
  local dest="/tmp/${tag}_backup_$(date +%s)"
  [[ -f "$src" ]] && cp "$src" "$dest" && echo "$dest"
}

# Restore from the most recent matching backup.
restore_latest_backup() {
  local pattern="$1" dest="$2"
  local latest
  latest=$(ls -t ${pattern} 2>/dev/null | head -1)
  [[ -n "$latest" ]] && cp "$latest" "$dest" && echo "[*] Restored from ${latest}"
}

# ── Stray-file cleanup ────────────────────────────────────────────────────────
# Builds a list of directories to check, including:
#   - the current working directory
#   - /root (common location for official installer)
#   - the WorkingDirectory from the existing masterdnsvpn service (if any)
# Deduplicates against MASTER_DIR (our target) so we never pre-wipe our dest.

cleanup_stray_files() {
  local CWD
  CWD="$(pwd)"

  # Collect candidate dirs (may be the same path; we'll deduplicate)
  declare -a CANDIDATES=("$CWD")

  # Where did the existing service (official or ours) run from?
  local SVC_DIR
  SVC_DIR=$(get_service_workdir "$MASTER_SERVICE")
  if [[ -n "$SVC_DIR" && "$SVC_DIR" != "$MASTER_DIR" ]]; then
    CANDIDATES+=("$SVC_DIR")
  fi

  # /root is where the official installer lands when run as root
  if [[ "/root" != "$CWD" && "/root" != "$MASTER_DIR" ]]; then
    CANDIDATES+=("/root")
  fi

  # Deduplicate and skip our own destination
  declare -A SEEN=()
  for dir in "${CANDIDATES[@]}"; do
    [[ "$dir" == "$MASTER_DIR" ]] && continue   # never pre-wipe our dest
    [[ -n "${SEEN[$dir]+_}" ]]  && continue     # already processed
    SEEN[$dir]=1

    if ! looks_like_master "$dir"; then
      continue
    fi

    echo ""
    echo "[!] Found MasterDnsVPN files in: ${dir}"

    if [[ -f "${dir}/server_config.toml" ]] && ask_yn "    Backup server_config.toml from ${dir}?"; then
      backup_file "${dir}/server_config.toml" "server_config"
      KEEP_CONFIG="y"
    fi
    if [[ -f "${dir}/encrypt_key.txt" ]] && ask_yn "    Backup encrypt_key.txt from ${dir}?"; then
      backup_file "${dir}/encrypt_key.txt" "encrypt_key"
      KEEP_KEY="y"
    fi

    # Remove binary (plain + versioned names), config and key
    rm -f "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null || true
    rm -f "${dir}/server_config.toml" "${dir}/encrypt_key.txt" 2>/dev/null || true
    echo "[✓] Cleaned stray MasterDnsVPN files from ${dir}"
  done
}

# ── Run cleanup before we touch anything ─────────────────────────────────────
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

  # Ask about MASTER_DIR files (separate from the stray-file cleanup above)
  if [[ -f "${MASTER_DIR}/server_config.toml" && "$KEEP_CONFIG" == "n" ]]; then
    if ask_yn "    Keep existing server_config.toml from ${MASTER_DIR}?"; then
      backup_file "${MASTER_DIR}/server_config.toml" "server_config"
      KEEP_CONFIG="y"
    fi
  fi
  if [[ -f "${MASTER_DIR}/encrypt_key.txt" && "$KEEP_KEY" == "n" ]]; then
    if ask_yn "    Keep existing encrypt_key.txt from ${MASTER_DIR}?"; then
      backup_file "${MASTER_DIR}/encrypt_key.txt" "encrypt_key"
      KEEP_KEY="y"
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
  # Kill anything still holding port 53
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

  # Normalize binary name: official latest releases use versioned names like
  # MasterDnsVPN_Server_Linux_AMD64_v2026.xx.xx...
  # Make sure we have the plain name for our service ExecStart.
  if [[ ! -f "$EXECUTABLE" ]]; then
    FOUND=$(ls -t "${EXECUTABLE}"_v* 2>/dev/null | head -1)
    [[ -z "$FOUND" ]] && FOUND=$(find . -maxdepth 1 -name "MasterDnsVPN_Server_Linux_AMD64*" -type f | head -1)
    [[ -n "$FOUND" ]] && cp "$FOUND" "$EXECUTABLE"
  fi
  chmod +x "$EXECUTABLE"

  # ── Restore or generate config ───────────────────────────────────────────────
  if [[ "$KEEP_CONFIG" == "y" ]]; then
    restore_latest_backup "/tmp/server_config_backup_*" server_config.toml \
      || echo "[!] No config backup found — will use tuned default"
  fi

  # If still no config, copy our tuned template
  if [[ ! -f server_config.toml ]]; then
    TUNED="${PANEL_DIR}/${VERSION}_server_config.toml"
    if [[ -f "$TUNED" ]]; then
      cp "$TUNED" server_config.toml
      echo "[*] Using tuned config for ${VERSION}"
    else
      echo "[!] Tuned config not found at ${TUNED} — binary will use defaults"
    fi
  fi
  # Inject domain into config (safe no-op if placeholder not present)
  sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true

  # ── Restore or generate encryption key ──────────────────────────────────────
  if [[ "$KEEP_KEY" == "y" ]]; then
    restore_latest_backup "/tmp/encrypt_key_backup_*" encrypt_key.txt \
      || echo "[!] No key backup found — will generate a new key"
  fi

  if [[ ! -f encrypt_key.txt ]]; then
    echo "[*] Generating encryption key..."
    if [[ "$VERSION" == "april12" ]]; then
      # April 12+ supports -genkey flag for clean key generation
      ./"$EXECUTABLE" -genkey -nowait
    else
      # April 5: run the binary, wait for key file to appear, then kill it
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
