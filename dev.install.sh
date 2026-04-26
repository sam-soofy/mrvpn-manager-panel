#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel + MasterDnsVPN Installer (v7)
#
# Key conventions (learned from official MasterDnsVPN installers):
#   - MasterDnsVPN installs to /root  (binary, server_config.toml, encrypt_key.txt)
#   - Service name: masterdnsvpn  (must match official naming exactly)
#   - April 5  key gen: run binary in background, wait for "Active Encryption Key" log
#   - April 12 key gen: binary supports -genkey -nowait  (synchronous, clean)
#   - April 12 service:  ExecStart must include -nowait flag
#   - DNS: always add DNS=8.8.8.8 to resolved.conf when disabling stub listener,
#          so the system has an upstream even if DHCP provides none
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/root"                    # matches official installer convention
REPO_URL="https://github.com/sam-soofy/mrvpn-manager-panel.git"
PANEL_SERVICE="mrvpn-manager-panel"
MASTER_SERVICE="masterdnsvpn"
UNINSTALL_URL="https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/dev/uninstall.sh"

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash install.sh"
  exit 1
fi

# ── Per-run temp backup paths ─────────────────────────────────────────────────
# Using PID + timestamp avoids collisions across concurrent/repeated runs.
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
  if [[ -f "./uninstall.sh" ]]; then
    bash "./uninstall.sh"; exit 0
  fi
  if [[ -f "${PANEL_DIR}/uninstall.sh" ]]; then
    bash "${PANEL_DIR}/uninstall.sh"; exit 0
  fi
  echo "[*] Downloading uninstaller..."
  if curl -fL --progress-bar --show-error --connect-timeout 10 --max-time 60 "$UNINSTALL_URL" -o /tmp/mrvpn_uninstall.sh; then
    bash /tmp/mrvpn_uninstall.sh
    rm -f /tmp/mrvpn_uninstall.sh
    exit 0
  fi
  echo "[!] Could not download uninstaller."
  echo "    Try: sudo bash ${PANEL_DIR}/uninstall.sh"
  exit 1
fi

[[ "$MODE_CHOICE" != "1" ]] && echo "[!] Invalid choice" && exit 1

echo ""
read -r -p "Install/update Panel? (y/n): " DO_PANEL
read -r -p "Install/update MasterDnsVPN? (y/n): " DO_MASTER

VERSION="" USER_DOMAIN=""

# ── Domain helpers ─────────────────────────────────────────────────────────────
normalize_domain() {
  local d="$1"
  d="${d,,}"
  d="${d#"${d%%[![:space:]]*}"}"
  d="${d%"${d##*[![:space:]]}"}"
  [[ "$d" == *"." ]] && d="${d%.}"
  printf '%s' "$d"
}

is_valid_domain() {
  local d="$1"
  [[ -n "$d" ]] || return 1
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" != *".."* ]] || return 1
  local IFS='.'
  read -r -a parts <<<"$d"
  [[ ${#parts[@]} -ge 3 ]] || return 1
  local label
  for label in "${parts[@]}"; do
    [[ -n "$label" ]] || return 1
    [[ ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

prompt_for_domain() {
  local d
  while true; do
    read -r -p "Enter your NS record domain (e.g. vpn.example.com): " d
    d="$(normalize_domain "$d")"
    if is_valid_domain "$d"; then
      printf '%s' "$d"
      return 0
    fi
    echo "[!] Invalid domain. Expected pattern: subdomain.domain.tld" >&2
  done
}

escape_sed_replacement() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

set_domain_in_config() {
  local file="$1"
  local domain="$2"
  [[ -f "$file" ]] || return 1
  local esc
  esc="$(escape_sed_replacement "$domain")"
  if grep -q '{{DOMAIN}}' "$file" 2>/dev/null; then
    sed -i "s|{{DOMAIN}}|${esc}|g" "$file"
    return 0
  fi
  if grep -Eq '^[[:space:]]*DOMAIN[[:space:]]*=' "$file" 2>/dev/null; then
    sed -i -E "s|^([[:space:]]*)DOMAIN[[:space:]]*=.*$|\\1DOMAIN = [\"${esc}\"]|g" "$file"
    return 0
  fi
  return 2
}

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
  USER_DOMAIN="$(prompt_for_domain)"
fi

ask_yn() { read -r -p "$1 (y/n): " ans; [[ "$ans" == "y" ]]; }

# ── Package manager detection ──────────────────────────────────────────────────
APT_UPDATED=false

apt_update_once() {
  $APT_UPDATED && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  APT_UPDATED=true
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 || return 1
  apt_update_once
  apt-get install -y --no-install-recommends "$@"
}

install_apt_deps() {
  command -v apt-get >/dev/null 2>&1 || return 0
  [[ "$DO_PANEL" == "y" || "$DO_MASTER" == "y" ]] || return 0

  declare -a pkgs=(ca-certificates curl git)

  if [[ "$DO_PANEL" == "y" ]]; then
    pkgs+=(python3 python3-venv openssl)
  fi

  if [[ "$DO_MASTER" == "y" ]]; then
    # lsof, iproute2, procps: needed for port 53 management (same as official installer)
    pkgs+=(unzip iproute2 lsof procps irqbalance)
  fi

  declare -A seen=()
  declare -a uniq=()
  for p in "${pkgs[@]}"; do
    [[ -n "${seen[$p]+_}" ]] && continue
    seen[$p]=1
    uniq+=("$p")
  done

  echo ""
  echo "[*] Installing required packages..."
  apt_install "${uniq[@]}"
  echo "[✓] System packages installed"
  echo ""
}

ensure_python3_venv() {
  if ! command -v python3 >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || { echo "[!] python3 not found"; exit 1; }
    echo "[*] Installing python3..."
    apt_install python3
  fi
  python3 -c 'import venv, ensurepip' >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    echo "[*] Installing Python venv support..."
    if ! apt_install python3-venv; then
      local py_mm
      py_mm="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
      apt_install "python${py_mm}-venv"
    fi
    python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || { echo "[!] Python venv unavailable"; exit 1; }
    return 0
  fi
  echo "[!] Missing venv/ensurepip; install python3-venv manually"
  exit 1
}

install_apt_deps

# ── Service helpers ────────────────────────────────────────────────────────────
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

# ── Port 53 management ────────────────────────────────────────────────────────
# Mirrors official installer logic: proper teardown of DNS services + stub listener.

check_port53() {
  ss -H -lun "sport = :53" 2>/dev/null | grep -q ':53' && return 0
  ss -H -ltn "sport = :53" 2>/dev/null | grep -q ':53' && return 0
  return 1
}

get_port53_pids() {
  local pids_udp pids_tcp pids
  pids_udp="$(ss -H -lupn "sport = :53" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
  pids_tcp="$(ss -H -ltpn "sport = :53" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
  pids="$(printf '%s\n%s\n' "$pids_udp" "$pids_tcp" | sed '/^$/d' | sort -u)"
  if [[ -n "$pids" ]]; then echo "$pids"; return 0; fi
  lsof -ti :53 2>/dev/null || true
}

terminate_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || return 0
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 1
}

stop_service_if_present() {
  local unit="$1"
  if systemctl list-unit-files --type=service --all 2>/dev/null | awk '{print $1}' | grep -qx "$unit"; then
    systemctl stop    "$unit" 2>/dev/null || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  fi
}

stop_socket_if_present() {
  local unit="$1"
  if systemctl list-unit-files --type=socket --all 2>/dev/null | awk '{print $1}' | grep -qx "$unit"; then
    systemctl stop    "$unit" 2>/dev/null || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  fi
}

free_port53() {
  echo "[*] Freeing port 53..."

  # Stop any existing masterdnsvpn first
  if systemctl list-unit-files --all 2>/dev/null | grep -q "^${MASTER_SERVICE}\.service"; then
    echo "[*] Stopping existing ${MASTER_SERVICE}..."
    systemctl stop "${MASTER_SERVICE}" 2>/dev/null || true
    systemctl reset-failed "${MASTER_SERVICE}" 2>/dev/null || true
  fi

  check_port53 || { echo "[✓] Port 53 already free"; return 0; }

  # Disable systemd-resolved stub listener (the most common culprit on Ubuntu)
  # Critical: also add DNS upstream so resolved keeps working without the stub.
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "[*] Configuring systemd-resolved: disabling stub listener..."

    # Replace or append DNSStubListener
    if grep -q '^#\?DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
      sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    else
      echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
    fi

    # Ensure an upstream DNS is configured so the system stays online.
    # (Official installer always does this step too.)
    if ! grep -q '^DNS=' /etc/systemd/resolved.conf 2>/dev/null; then
      echo 'DNS=8.8.8.8 1.1.1.1' >> /etc/systemd/resolved.conf
      echo "[*] Added DNS=8.8.8.8 1.1.1.1 to resolved.conf as upstream fallback"
    fi

    systemctl restart systemd-resolved 2>/dev/null || true
  fi

  # Switch resolv.conf from stub symlink to real-resolver file so the server
  # itself can still do DNS after the stub is gone.
  if [[ -L /etc/resolv.conf ]]; then
    local RESOLV_TARGET
    RESOLV_TARGET="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    if [[ "$RESOLV_TARGET" == "/run/systemd/resolve/stub-resolv.conf" ]] \
       && [[ -f /run/systemd/resolve/resolv.conf ]]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      echo "[*] Switched /etc/resolv.conf to non-stub resolver"
    fi
  fi

  # Stop other known DNS services
  stop_socket_if_present systemd-resolved.socket
  stop_socket_if_present dnsmasq.socket
  for srv in bind9 bind9.service named named.service dnsmasq dnsmasq.service \
             unbound unbound.service pdns pdns.service coredns coredns.service \
             pihole-FTL pihole-FTL.service; do
    stop_service_if_present "$srv"
  done

  # Kill remaining processes on port 53
  if check_port53; then
    local pid
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      terminate_pid "$pid"
    done <<< "$(get_port53_pids)"
  fi

  # fuser fallback
  if command -v fuser >/dev/null 2>&1 && check_port53; then
    fuser -k 53/udp 2>/dev/null || true
    fuser -k 53/tcp 2>/dev/null || true
    sleep 1
  fi

  if check_port53; then
    echo "[!] Port 53 still occupied after cleanup. Check manually: ss -ulnp | grep :53"
    exit 1
  fi

  echo "[✓] Port 53 is free"
}

# ── Kernel tuning (mirrors official installer) ─────────────────────────────────
apply_kernel_tuning() {
  echo "[*] Applying kernel and file descriptor limits..."

  cat > /etc/sysctl.d/99-masterdnsvpn.conf <<'EOF'
# MasterDnsVPN high-load tuning — managed by mrvpn-manager-panel installer
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.core.optmem_max = 25165824
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.ipv4.ip_local_port_range = 10240 65535
EOF

  cat > /etc/security/limits.d/99-masterdnsvpn.conf <<'EOF'
# MasterDnsVPN — managed by mrvpn-manager-panel installer
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  sysctl --system >/dev/null 2>&1 || echo "[~] Could not fully apply sysctl (non-fatal)"
  echo "[✓] Kernel tuning applied"
}

# ── irqbalance (helps multi-core DNS packet distribution) ─────────────────────
enable_irqbalance() {
  if systemctl list-unit-files --type=service --all 2>/dev/null | awk '{print $1}' | grep -qx 'irqbalance.service'; then
    systemctl enable --now irqbalance >/dev/null 2>&1 || true
  fi
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

# ── Backup helpers ─────────────────────────────────────────────────────────────
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
  declare -a CANDIDATES=()
  [[ "$CWD" != "$MASTER_DIR" ]] && CANDIDATES+=("$CWD")
  local SVC_DIR
  SVC_DIR=$(get_service_workdir "$MASTER_SERVICE" 2>/dev/null || true)
  [[ -n "${SVC_DIR:-}" && "$SVC_DIR" != "$MASTER_DIR" ]] && CANDIDATES+=("$SVC_DIR")

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

if [[ "$DO_MASTER" == "y" ]]; then
  cleanup_stray_files
fi

# ═════════════════════════════════════════════════════════════════════════════
# PANEL INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$DO_PANEL" == "y" ]]; then
  echo ""
  echo "[*] ── Panel ──────────────────────────────"
  mkdir -p "$PANEL_DIR"
  if [[ -d "${PANEL_DIR}/.git" ]]; then
    echo "[*] Updating panel (forced reset to origin/dev)"
    git -C "$PANEL_DIR" fetch origin
    git -C "$PANEL_DIR" checkout dev
    git -C "$PANEL_DIR" reset --hard origin/dev
  else
    echo "[*] Cloning panel (branch: dev)"
    git clone --branch dev "$REPO_URL" "$PANEL_DIR"
  fi
  cd "$PANEL_DIR"
  ensure_python3_venv
  echo "[*] Creating Python virtual environment..."
  python3 -m venv .venv
  echo "[*] Installing panel Python requirements..."
  .venv/bin/pip install --upgrade pip --disable-pip-version-check --timeout 30 --retries 3 -q
  .venv/bin/pip install -r requirements.txt --disable-pip-version-check --timeout 30 --retries 3 -q

  [[ ! -f jwt_secret.txt ]] && openssl rand -hex 32 > jwt_secret.txt && chmod 600 jwt_secret.txt
  [[ ! -f admin_pass.txt  ]] && openssl rand -hex 16 > admin_pass.txt  && chmod 600 admin_pass.txt

  cat > "/etc/systemd/system/${PANEL_SERVICE}.service" <<UNIT
[Unit]
Description=MRVPN Manager Panel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/.venv/bin/python ${PANEL_DIR}/mrvpn_manager_panel.py
Restart=always
RestartSec=3
TimeoutStopSec=15
KillMode=control-group
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

  cat > "/etc/systemd/system/mrvpn-config-scheduler.service" <<UNIT
[Unit]
Description=MRVPN Config Scheduler
After=network-online.target ${PANEL_SERVICE}.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/.venv/bin/python ${PANEL_DIR}/scheduler.py
Restart=always
RestartSec=5
TimeoutStopSec=15
KillMode=control-group
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "${PANEL_SERVICE}" mrvpn-config-scheduler
  echo "[*] Starting panel + scheduler (non-blocking)..."
  systemctl restart --no-block "${PANEL_SERVICE}" 2>/dev/null || true
  systemctl restart --no-block mrvpn-config-scheduler 2>/dev/null || true
  echo "[✓] Panel + scheduler installed"
fi

# ═════════════════════════════════════════════════════════════════════════════
# MASTERDNSVPN INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$DO_MASTER" == "y" ]]; then
  echo ""
  echo "[*] ── MasterDnsVPN (${VERSION}) ────────────"

  # ── Locate bundled zip ───────────────────────────────────────────────────────
  BUNDLED_ZIP=""
  if [[ "$VERSION" == "april5" ]]; then
    BUNDLED_ZIP="${PANEL_DIR}/mrvpn_binaries/MasterDnsVPN_Server_April_05_Linux_AMD64.zip"
  else
    BUNDLED_ZIP="${PANEL_DIR}/mrvpn_binaries/MasterDnsVPN_Server_April_12_Linux_AMD64.zip"
  fi

  if [[ ! -f "$BUNDLED_ZIP" ]]; then
    echo "[*] Bundled zip not found; fetching panel repo..."
    mkdir -p "$PANEL_DIR"
    if [[ -d "${PANEL_DIR}/.git" ]]; then
      git -C "$PANEL_DIR" fetch origin
      git -C "$PANEL_DIR" checkout dev
      git -C "$PANEL_DIR" reset --hard origin/dev
    else
      [[ -n "$(ls -A "$PANEL_DIR" 2>/dev/null || true)" ]] \
        && { echo "[!] ${PANEL_DIR} exists but is not a git repo"; exit 1; }
      git clone --branch dev "$REPO_URL" "$PANEL_DIR"
    fi
  fi
  [[ -f "$BUNDLED_ZIP" ]] || { echo "[!] Bundled zip missing: ${BUNDLED_ZIP}"; exit 1; }
  echo "[*] Using bundled zip: ${BUNDLED_ZIP}"

  # ── Stop existing service ────────────────────────────────────────────────────
  stop_service "$MASTER_SERVICE"

  # ── Ask about existing /root files ──────────────────────────────────────────
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

  # ── Clean up old binary and volatile files from /root ───────────────────────
  echo "[*] Removing old MasterDnsVPN binary files from ${MASTER_DIR}..."
  rm -f "${MASTER_DIR}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null || true
  rm -f "${MASTER_DIR}/init_logs.tmp" 2>/dev/null || true
  # Remove old config/key only if NOT backed up (backed-up ones will be restored below)
  $HAS_CONFIG_BACKUP || rm -f "${MASTER_DIR}/server_config.toml" 2>/dev/null || true
  $HAS_KEY_BACKUP    || rm -f "${MASTER_DIR}/encrypt_key.txt"    2>/dev/null || true

  # ── Port 53 + kernel tuning ──────────────────────────────────────────────────
  free_port53
  apply_kernel_tuning
  enable_irqbalance

  # ── Extract bundled binary ───────────────────────────────────────────────────
  cd "${MASTER_DIR}"
  echo "[*] Extracting ${VERSION}..."
  rm -f server.zip 2>/dev/null || true
  cp -f "$BUNDLED_ZIP" server.zip
  command -v unzip >/dev/null 2>&1 || { echo "[!] unzip not found"; exit 1; }
  unzip -o server.zip
  rm -f server.zip

  # Find the extracted binary (keep original versioned name — no renaming)
  MASTER_BINARY=$(ls -t MasterDnsVPN_Server_Linux_AMD64_v* 2>/dev/null | head -1 || true)
  if [[ -z "$MASTER_BINARY" ]]; then
    MASTER_BINARY=$(find . -maxdepth 1 -name "MasterDnsVPN_Server_Linux_AMD64*" -type f | head -1 || true)
  fi
  [[ -z "$MASTER_BINARY" ]] && { echo "[!] Binary not found after extraction"; exit 1; }
  MASTER_BINARY=$(basename "$MASTER_BINARY")
  chmod +x "$MASTER_BINARY"
  echo "[*] Binary: ${MASTER_BINARY}"

  # ── KEY GENERATION — must run BEFORE config restore ───────────────────────
  # Why before config: April 5 binary writes a default server_config.toml when
  # it starts for the first time. Running key gen first, then overwriting config
  # ensures our tuned/backed-up config wins.

  if $HAS_KEY_BACKUP; then
    cp "$KEY_BACKUP" encrypt_key.txt
    rm -f "$KEY_BACKUP"; HAS_KEY_BACKUP=false  # consumed — clear immediately
    echo "[*] Encryption key restored from backup"
  else
    echo "[*] Generating encryption key..."

    if [[ "$VERSION" == "april12" ]]; then
      # April 12: synchronous key generation via dedicated flag.
      # Fails with non-zero exit if anything goes wrong.
      TMP_KEYGEN_LOG="/tmp/mrvpn_keygen_${RUN_ID}.log"
      if ! ./"$MASTER_BINARY" -genkey -nowait > "$TMP_KEYGEN_LOG" 2>&1; then
        echo "[!] Key generation failed. Log:"
        tail -n 20 "$TMP_KEYGEN_LOG" || true
        rm -f "$TMP_KEYGEN_LOG"
        exit 1
      fi
      rm -f "$TMP_KEYGEN_LOG"

    else
      # April 5: no -genkey flag. Run binary in background, wait for the
      # "Active Encryption Key" message in its output (same approach as official
      # April 5 installer). This is more reliable than checking file existence
      # because the log message means the key is fully written and initialized.
      TMP_KEYGEN_LOG="/tmp/mrvpn_keygen_${RUN_ID}.log"
      ./"$MASTER_BINARY" > "$TMP_KEYGEN_LOG" 2>&1 &
      INIT_PID=$!
      READY=false
      for _ in {1..15}; do
        if grep -q "Active Encryption Key" "$TMP_KEYGEN_LOG" 2>/dev/null; then
          READY=true
          break
        fi
        sleep 1
      done
      kill "$INIT_PID" 2>/dev/null || true
      wait "$INIT_PID" 2>/dev/null || true
      rm -f "$TMP_KEYGEN_LOG"

      if [[ "$READY" != true ]] || [[ ! -f encrypt_key.txt ]]; then
        echo "[!] Key generation timed out — verify port 53 is free and try again"
        exit 1
      fi
    fi

    echo "[✓] Encryption key generated"
  fi

  # ── CONFIG RESTORE / INSTALL — after key gen ──────────────────────────────
  if $HAS_CONFIG_BACKUP; then
    cp "$CONFIG_BACKUP" server_config.toml
    rm -f "$CONFIG_BACKUP"; HAS_CONFIG_BACKUP=false  # consumed — clear immediately
    if ! set_domain_in_config server_config.toml "$USER_DOMAIN"; then
      echo "[~] Warning: could not patch domain into restored server_config.toml"
    fi
    echo "[*] server_config.toml restored from backup"
  else
    # Fresh install — use our tuned template
    TUNED="${PANEL_DIR}/config/tuned/${VERSION}_server_config.toml"
    if [[ -f "$TUNED" ]]; then
      cp "$TUNED" server_config.toml
      if ! set_domain_in_config server_config.toml "$USER_DOMAIN"; then
        echo "[~] Warning: could not patch domain into tuned config"
      fi
      echo "[*] Using tuned config for ${VERSION} with domain ${USER_DOMAIN}"
    else
      echo "[~] Tuned config not found at ${TUNED} — using binary default"
      # April 5 binary wrote a default config during key gen; patch domain in
      if [[ -f server_config.toml ]]; then
        set_domain_in_config server_config.toml "$USER_DOMAIN" || true
      fi
    fi
  fi

  chmod 600 server_config.toml encrypt_key.txt 2>/dev/null || true

  # ── Systemd service ──────────────────────────────────────────────────────────
  # April 12 REQUIRES -nowait flag in ExecStart (so binary doesn't re-init key
  # on every service restart). April 5 does not have this flag.
  if [[ "$VERSION" == "april12" ]]; then
    EXEC_START="${MASTER_DIR}/${MASTER_BINARY} -nowait"
  else
    EXEC_START="${MASTER_DIR}/${MASTER_BINARY}"
  fi

  cat > "/etc/systemd/system/${MASTER_SERVICE}.service" <<UNIT
[Unit]
Description=MasterDnsVPN Server (${VERSION})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${MASTER_DIR}
ExecStart=${EXEC_START}
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=65535
TasksMax=infinity
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "${MASTER_SERVICE}"

  echo "[*] Starting MasterDnsVPN (waiting 3s for config to settle)..."
  sleep 3
  systemctl restart "${MASTER_SERVICE}"

  # Verify service started
  for _ in 1 2 3 4 5; do
    systemctl is-active --quiet "${MASTER_SERVICE}" && break
    sleep 2
  done
  if ! systemctl is-active --quiet "${MASTER_SERVICE}"; then
    echo "[!] Service failed to start. Logs:"
    journalctl -u "${MASTER_SERVICE}" -n 30 --no-pager || true
    exit 1
  fi

  echo "[✓] MasterDnsVPN (${VERSION}) installed and running"

  # Record installed version so the panel's config_editor.py can auto-select configs
  [[ -d "$PANEL_DIR" ]] && echo "$VERSION" > "${PANEL_DIR}/installed_version.txt" || true
fi

# ═════════════════════════════════════════════════════════════════════════════
# FINAL OUTPUT
# ═════════════════════════════════════════════════════════════════════════════
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
