#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel - Uninstaller
#
# Removes:
#   - mrvpn-manager-panel and mrvpn-config-scheduler services + /opt/mrvpn-manager-panel
#   - masterdnsvpn service
#   - MasterDnsVPN binary files from /root and the old service WorkingDirectory
#   - Exactly: server_config.toml, encrypt_key.txt, init_logs.tmp
#     (does NOT touch server_config.toml.backup or any other user files)
#   - Our installer temp backups from /tmp
#   - Undoes the DNSStubListener change made to /etc/systemd/resolved.conf
#
# Does NOT remove:
#   - Any .backup or .bak files the user may have created
#   - /root itself or its general contents
#   - bash history or other user data
# =============================================================================
set -euo pipefail

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/root"           # where our installer puts MasterDnsVPN files

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash uninstall.sh"
  exit 1
fi

echo "========================================"
echo "  MRVPN Manager Panel - Uninstaller     "
echo "========================================"
echo ""
echo "This will permanently remove:"
echo "  ▸ mrvpn-manager-panel service + ${PANEL_DIR}"
echo "  ▸ mrvpn-config-scheduler service"
echo "  ▸ masterdnsvpn service"
echo "  ▸ MasterDnsVPN binary files from ${MASTER_DIR}"
echo "  ▸ server_config.toml and encrypt_key.txt from ${MASTER_DIR}"
echo "  ▸ MasterDnsVPN files from any other detected install location"
echo "  ▸ Installer temp backups in /tmp (mrvpn_* prefix only)"
echo "  ▸ DNSStubListener change in /etc/systemd/resolved.conf"
echo ""
echo "Will NOT remove:"
echo "  ▸ Any .backup, .bak, or other user-created files"
echo "  ▸ /root itself or its general contents"
echo ""
read -r -p "Type 'yes' to confirm full uninstall: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "[!] Aborted." && exit 0

echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────

get_service_workdir() {
  local svc_file="/etc/systemd/system/${1}.service"
  [[ -f "$svc_file" ]] && grep -E "^WorkingDirectory=" "$svc_file" | cut -d= -f2- | tr -d ' '
}

stop_and_remove_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    echo "[*] Stopping + disabling ${svc}..."
    systemctl stop    "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  fi
  if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
    rm -f "/etc/systemd/system/${svc}.service"
    echo "[✓] Removed service file: ${svc}.service"
  fi
}

# Remove exactly the MasterDnsVPN files we own from a directory.
# Binary: wildcard is fine — all variants start with the fixed prefix.
# Config + key: exact names only. No .backup, no .bak, no other variants.
remove_master_files_from() {
  local dir="$1"
  [[ -d "$dir" ]] || return

  local found=false

  if ls "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null | grep -q .; then
    rm -f "${dir}"/MasterDnsVPN_Server_Linux_AMD64*
    echo "[✓] Removed binary files from ${dir}"
    found=true
  fi

  if [[ -f "${dir}/server_config.toml" ]]; then
    rm -f "${dir}/server_config.toml"
    echo "[✓] Removed ${dir}/server_config.toml"
    found=true
  fi

  if [[ -f "${dir}/encrypt_key.txt" ]]; then
    rm -f "${dir}/encrypt_key.txt"
    echo "[✓] Removed ${dir}/encrypt_key.txt"
    found=true
  fi

  if [[ -f "${dir}/init_logs.tmp" ]]; then
    rm -f "${dir}/init_logs.tmp"
    found=true
  fi

  $found || echo "[~] No MasterDnsVPN files found in ${dir}"
}

# ── Read service metadata BEFORE removing service files ───────────────────────
# We need the WorkingDirectory of the masterdnsvpn service to find stray files
# from old installs (e.g. a previous /opt/masterdnsvpn install).
MASTER_SVC_WORKDIR=$(get_service_workdir "masterdnsvpn" 2>/dev/null || true)

# ── Stop and remove all three services ───────────────────────────────────────
echo "[*] Stopping services..."
stop_and_remove_service "mrvpn-manager-panel"
stop_and_remove_service "mrvpn-config-scheduler"
stop_and_remove_service "masterdnsvpn"
systemctl daemon-reload
echo "[✓] All services removed"

# ── Remove panel directory ────────────────────────────────────────────────────
echo ""
if [[ -d "$PANEL_DIR" ]]; then
  rm -rf "$PANEL_DIR"
  echo "[✓] Removed ${PANEL_DIR}"
else
  echo "[~] ${PANEL_DIR} not found — skipping"
fi

# ── Remove MasterDnsVPN files from /root (our install location) ──────────────
# We do targeted removal only — never rm -rf /root.
echo ""
echo "[*] Removing MasterDnsVPN files from ${MASTER_DIR}..."
remove_master_files_from "$MASTER_DIR"

# ── Remove stray files from old install locations ─────────────────────────────
# Covers: the service's WorkingDirectory (handles old /opt/masterdnsvpn installs
# from a previous version of our installer).
echo ""
echo "[*] Scanning for stray MasterDnsVPN files in other locations..."

declare -A SEEN=()
SEEN["$MASTER_DIR"]=1   # already handled above

check_stray_dir() {
  local dir="$1"
  [[ -z "$dir" ]]          && return
  [[ -n "${SEEN[$dir]+_}" ]] && return
  SEEN[$dir]=1

  # Only clean directories that look like MasterDnsVPN installs
  local is_master=false
  ls "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null | grep -q . && is_master=true
  [[ -f "${dir}/server_config.toml" ]] && is_master=true
  [[ -f "${dir}/encrypt_key.txt" ]]    && is_master=true

  if $is_master; then
    echo "[*] Found stray installation at: ${dir}"
    remove_master_files_from "$dir"
  fi
}

# Check the old service WorkingDirectory (if it differs from our MASTER_DIR)
[[ -n "${MASTER_SVC_WORKDIR:-}" ]] && check_stray_dir "$MASTER_SVC_WORKDIR"

# Check if there is an old /opt/masterdnsvpn directory from a previous installer version
check_stray_dir "/opt/masterdnsvpn"

# ── Remove our installer temp backups from /tmp ───────────────────────────────
# Only removes files with our specific prefix — does not touch other /tmp files.
echo ""
echo "[*] Removing installer temp backups from /tmp..."
REMOVED_TMP=false

for f in /tmp/mrvpn_server_config_*.toml /tmp/mrvpn_encrypt_key_*.txt; do
  # The glob may not match anything; skip silently
  [[ -f "$f" ]] || continue
  rm -f "$f"
  REMOVED_TMP=true
done

$REMOVED_TMP && echo "[✓] Temp backups removed" || echo "[~] No temp backups found"

# ── Undo DNSStubListener change ───────────────────────────────────────────────
# The installer appends "DNSStubListener=no" to /etc/systemd/resolved.conf.
# We remove exactly that line and restart resolved so port 53 stub is restored
# to its default state (enabled), allowing DNS to work normally again.
echo ""
echo "[*] Restoring systemd-resolved configuration..."
RESOLVED_CONF="/etc/systemd/resolved.conf"

if [[ -f "$RESOLVED_CONF" ]] && grep -q "^DNSStubListener=no" "$RESOLVED_CONF"; then
  sed -i '/^DNSStubListener=no/d' "$RESOLVED_CONF"
  systemctl restart systemd-resolved 2>/dev/null || true
  echo "[✓] DNSStubListener restored to default (stub re-enabled on 127.0.0.53)"
else
  echo "[~] No DNSStubListener change found — skipping"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Uninstall complete.                   "
echo "========================================"
echo ""
echo "  ⚠  Please reboot to ensure all network"
echo "     and service changes take full effect."
echo ""
echo "    sudo reboot"
echo ""
echo "========================================"
