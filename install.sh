#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer (v6)
# MasterDnsVPN installs to /root (matches official installer behaviour).
# Binary keeps its original versioned filename — no renaming.
# Key generation runs BEFORE config restore (April 5 binary writes a default
# config on first run; we overwrite it immediately after).
# Temp backups are tracked by path per-run and cleaned up on exit.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/root"                    # official installer installs here
REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
PANEL_SERVICE="mrvpn-manager-panel"
MASTER_SERVICE="masterdnsvpn"
UNINSTALL_URL="https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/main/uninstall.sh"

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash install.sh"
  exit 1
fi

# ── Per-run backup paths ───────────────────────────────────────────────────────
# Unique per run (PID + timestamp) — eliminates glob ambiguity and stale-file
# collisions if the installer is run multiple times without rebooting.
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
  echo "[*] Running uninstaller..."

  # Prefer a local uninstaller (works even if DNS/network is broken).
  if [[ -f "./uninstall.sh" ]]; then
    bash "./uninstall.sh"
    exit 0
  fi
  if [[ -f "${PANEL_DIR}/uninstall.sh" ]]; then
    bash "${PANEL_DIR}/uninstall.sh"
    exit 0
  fi

  # Fallback to downloading it (add timeouts so we don't hang forever).
  echo "[*] Downloading uninstaller..."
  if curl -fsSL --connect-timeout 10 --max-time 60 "$UNINSTALL_URL" -o /tmp/mrvpn_uninstall.sh; then
    bash /tmp/mrvpn_uninstall.sh
    rm -f /tmp/mrvpn_uninstall.sh
    exit 0
  fi

  echo "[!] Could not download uninstaller (network/DNS issue?)"
  echo "    If the panel is installed, run: sudo bash ${PANEL_DIR}/uninstall.sh"
  exit 1
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

# ── Dependency helpers ───────────────────────────────────────────────────────

ensure_python3_venv() {
  command -v python3 >/dev/null 2>&1 || { echo "[!] python3 not found"; exit 1; }

  # On Debian/Ubuntu this fails when python3-venv (or pythonX.Y-venv) is missing.
  python3 -c 'import venv, ensurepip' >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    echo "[*] Installing Python venv support (python3-venv)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y

    # Prefer the meta-package; fall back to the versioned package if needed.
    if ! apt-get install -y python3-venv; then
      local py_mm
      py_mm="$(python3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')"
      apt-get install -y "python${py_mm}-venv"
    fi

    python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || {
      echo "[!] python venv still unavailable after install; check your apt repositories"
      exit 1
    }
    return 0
  fi

  echo "[!] Missing venv/ensurepip; install python3-venv using your distro package manager"
  exit 1
}

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
# Checks the CWD and the existing service's WorkingDirectory for leftover
# MasterDnsVPN files from previous installs (e.g. old /opt/masterdnsvpn).
# /root is MASTER_DIR and is intentionally never touched here.

cleanup_stray_files() {
  local CWD
  CWD="$(pwd)"

  declare -a CANDIDATES=()

  # Only include CWD if it is not our install target
  [[ "$CWD" != "$MASTER_DIR" ]] && CANDIDATES+=("$CWD")

  # Check where an existing service was running from (covers old /opt/masterdnsvpn)
  local SVC_DIR
  SVC_DIR=$(get_service_workdir "$MASTER_SERVICE" || true)
  [[ -n "${SVC_DIR:-}" && "$SVC_DIR" != "$MASTER_DIR" ]] && CANDIDATES+=("$SVC_DIR")

  # /root is MASTER_DIR — never added to stray candidates

  declare -A SEEN=()
  for dir in "${CANDIDATES[@]}"; do
    [[ -n "${SEEN[$dir]+_}" ]] && continue
    SEEN[$dir]=1

    ! looks_like_master "$dir" && continue

    echo ""
    echo "[!] Found MasterDnsVPN files in stray location: ${dir}"

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
    rm -f "${dir}/init_logs.tmp" 2>/dev/null || true
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
  ensure_python3_venv
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

  # Read service binary path BEFORE stopping the service
  # (we need the old binary name to know what to remove)
  OLD_EXEC=""
  OLD_SVC_FILE="/etc/systemd/system/${MASTER_SERVICE}.service"
  if [[ -f "$OLD_SVC_FILE" ]]; then
    OLD_EXEC=$(grep -E "^ExecStart=" "$OLD_SVC_FILE" | cut -d= -f2- | awk '{print $1}' | xargs basename 2>/dev/null || true)
  fi

  stop_service "$MASTER_SERVICE"

  # Ask about existing /root files — only if not already backed up from stray cleanup
  if [[ -f "${MASTER_DIR}/server_config.toml" ]] && ! $HAS_CONFIG_BACKUP; then
    if ask_yn "    Back up existing server_config.toml?"; then
      do_backup_config "${MASTER_DIR}/server_config.toml"
    fi
  fi
  if [[ -f "${MASTER_DIR}/encrypt_key.txt" ]] && ! $HAS_KEY_BACKUP; then
    if ask_yn "    Back up existing encrypt_key.txt?"; then
      do_backup_key "${MASTER_DIR}/encrypt_key.txt"
    fi
  fi

  # Remove old binary files from /root only — NEVER rm -rf /root
  echo "[*] Removing old MasterDnsVPN binary files from ${MASTER_DIR}..."
  rm -f "${MASTER_DIR}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null || true
  rm -f "${MASTER_DIR}/init_logs.tmp" 2>/dev/null || true
  # Remove old config/key only if we did NOT back them up
  # (if we backed them up, we will restore them after key gen)
  if ! $HAS_CONFIG_BACKUP; then
    rm -f "${MASTER_DIR}/server_config.toml" 2>/dev/null || true
  fi
  if ! $HAS_KEY_BACKUP; then
    rm -f "${MASTER_DIR}/encrypt_key.txt" 2>/dev/null || true
  fi

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
    DL_URL="https://github.com/masterking32/MasterDnsVPN/releases/download/v2026.04.05.191930-7757d2d/MasterDnsVPN_Server_Linux_AMD64.zip"
  else
    DL_URL="https://github.com/masterking32/MasterDnsVPN/releases/latest/download/MasterDnsVPN_Server_Linux_AMD64.zip"
  fi
  echo "[*] Downloading ${VERSION}..."
  curl -fSL --progress-bar "$DL_URL" -o server.zip
  unzip -o server.zip
  rm -f server.zip

  # Find the extracted binary — keep its original versioned name, do not rename.
  # Latest releases ship as MasterDnsVPN_Server_Linux_AMD64_v2026.xx.xx
  # April 5 may ship as the plain name MasterDnsVPN_Server_Linux_AMD64
  MASTER_BINARY=$(ls -t MasterDnsVPN_Server_Linux_AMD64_v* 2>/dev/null | head -1)
  if [[ -z "$MASTER_BINARY" ]]; then
    MASTER_BINARY=$(find . -maxdepth 1 -name "MasterDnsVPN_Server_Linux_AMD64*" -type f | head -1)
  fi
  if [[ -z "$MASTER_BINARY" ]]; then
    echo "[!] Could not find MasterDnsVPN binary after extraction"
    exit 1
  fi
  MASTER_BINARY=$(basename "$MASTER_BINARY")
  chmod +x "$MASTER_BINARY"
  echo "[*] Binary: ${MASTER_BINARY}"

  # ── KEY GENERATION — must happen BEFORE config restore ─────────────────────
  # April 5 binary writes a default server_config.toml on first start.
  # Generating the key first lets us safely overwrite that default below.
  if $HAS_KEY_BACKUP; then
    cp "$KEY_BACKUP" encrypt_key.txt
    echo "[*] Encryption key restored from backup"
  else
    echo "[*] Generating encryption key..."
    if [[ "$VERSION" == "april12" ]]; then
      # April 12 supports a clean non-daemonised key-gen flag
      ./"$MASTER_BINARY" -genkey -nowait
    else
      # April 5: start the binary, wait for the key file to appear, then kill it.
      # The binary also writes a default server_config.toml here — we overwrite it next.
      ./"$MASTER_BINARY" > /tmp/mdns_init.log 2>&1 &
      INIT_PID=$!
      for i in {1..10}; do
        [[ -f encrypt_key.txt ]] && break
        sleep 1
      done
      kill "$INIT_PID" 2>/dev/null || true
      wait "$INIT_PID" 2>/dev/null || true
      rm -f /tmp/mdns_init.log
      if [[ ! -f encrypt_key.txt ]]; then
        echo "[!] Key generation timed out — verify port 53 is free and try again"
        exit 1
      fi
    fi
  fi

  # ── CONFIG RESTORE / INSTALL — after key gen ───────────────────────────────
  if $HAS_CONFIG_BACKUP; then
    # User's real config — domain is already baked in from a previous install.
    # The sed is a no-op if there is no placeholder; safe to run regardless.
    cp "$CONFIG_BACKUP" server_config.toml
    sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true
    echo "[*] server_config.toml restored from backup"
  else
    # Fresh install — use our tuned template and inject the domain.
    TUNED="${PANEL_DIR}/${VERSION}_server_config.toml"
    if [[ -f "$TUNED" ]]; then
      cp "$TUNED" server_config.toml
      sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml
      echo "[*] Using tuned config for ${VERSION} with domain ${USER_DOMAIN}"
    else
      echo "[!] Tuned config not found at ${TUNED} — binary default will be used"
      # Binary already wrote a default config during key gen; try to patch the domain in.
      [[ -f server_config.toml ]] && sed -i "s|{{DOMAIN}}|${USER_DOMAIN}|g" server_config.toml 2>/dev/null || true
    fi
  fi

  chmod 600 server_config.toml encrypt_key.txt 2>/dev/null || true

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
ExecStart=${MASTER_DIR}/${MASTER_BINARY}
Restart=always
RestartSec=5
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "${MASTER_SERVICE}"

  # Give config a moment to settle, then do a clean start
  echo "[*] Starting MasterDnsVPN (waiting 3s for config to settle)..."
  sleep 3
  systemctl restart "${MASTER_SERVICE}"
  echo "[✓] MasterDnsVPN (${VERSION}) installed and started"
fi

# ── Final output ──────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"

if [[ "$DO_MASTER" == "y" ]]; then
  echo "VPN dir   → ${MASTER_DIR}"
  echo "Binary    → ${MASTER_BINARY}"
  echo "Version   → ${VERSION}"
  echo "Domain    → ${USER_DOMAIN}"
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
