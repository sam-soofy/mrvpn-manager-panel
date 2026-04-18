#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel - Uninstaller
# Removes: panel, scheduler, masterdnsvpn (ours and official), temp backups
# =============================================================================
set -euo pipefail

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/opt/masterdnsvpn"

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
echo "  ▸ masterdnsvpn service + ${MASTER_DIR}"
echo "  ▸ MasterDnsVPN files found in common locations (/root, cwd)"
echo "  ▸ All temp backups created by the installer (/tmp)"
echo ""
read -r -p "Type 'yes' to confirm full uninstall: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "[!] Aborted." && exit 0

echo ""

# ── Helper ────────────────────────────────────────────────────────────────────

get_service_workdir() {
  local svc_file="/etc/systemd/system/${1}.service"
  [[ -f "$svc_file" ]] && grep -E "^WorkingDirectory=" "$svc_file" | cut -d= -f2- | tr -d ' '
}

stop_and_remove_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    echo "[*] Stopping + disabling ${svc}"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  fi
  if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
    rm -f "/etc/systemd/system/${svc}.service"
    echo "[✓] Removed service file: ${svc}.service"
  fi
}

looks_like_master() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -f "${dir}/server_config.toml" ]] && return 0
  [[ -f "${dir}/encrypt_key.txt" ]]    && return 0
  ls "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null | grep -q . && return 0
  return 1
}

# ── Read WorkingDirectory before removing service files ───────────────────────
MASTER_SVC_DIR=$(get_service_workdir "masterdnsvpn" || true)

# ── Stop services ─────────────────────────────────────────────────────────────
echo "[*] Stopping services..."
stop_and_remove_service "mrvpn-manager-panel"
stop_and_remove_service "mrvpn-config-scheduler"
stop_and_remove_service "masterdnsvpn"

systemctl daemon-reload
echo "[✓] Services removed"

# ── Remove panel directory ────────────────────────────────────────────────────
if [[ -d "$PANEL_DIR" ]]; then
  rm -rf "$PANEL_DIR"
  echo "[✓] Removed ${PANEL_DIR}"
else
  echo "[~] ${PANEL_DIR} not found — skipping"
fi

# ── Remove our masterdnsvpn directory ─────────────────────────────────────────
if [[ -d "$MASTER_DIR" ]]; then
  rm -rf "$MASTER_DIR"
  echo "[✓] Removed ${MASTER_DIR}"
else
  echo "[~] ${MASTER_DIR} not found — skipping"
fi

# ── Remove stray MasterDnsVPN files from other locations ──────────────────────
echo ""
echo "[*] Scanning for stray MasterDnsVPN files..."

declare -A SEEN=()

check_and_clean_dir() {
  local dir="$1"
  [[ -z "$dir" ]] && return
  [[ "$dir" == "$MASTER_DIR" ]] && return   # already handled above
  [[ -n "${SEEN[$dir]+_}" ]] && return
  SEEN[$dir]=1

  if looks_like_master "$dir"; then
    echo "[*] Found stray files in: ${dir}"
    rm -f "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null || true
    rm -f "${dir}/server_config.toml" "${dir}/encrypt_key.txt" 2>/dev/null || true
    rm -f "${dir}/server_config.toml.backup" "${dir}/init_logs.tmp" 2>/dev/null || true
    echo "[✓] Cleaned ${dir}"
  fi
}

check_and_clean_dir "$(pwd)"
check_and_clean_dir "/root"
[[ -n "${MASTER_SVC_DIR:-}" ]] && check_and_clean_dir "$MASTER_SVC_DIR"

# ── Remove temp backups ────────────────────────────────────────────────────────
echo ""
echo "[*] Removing installer temp backups from /tmp..."
rm -f /tmp/mrvpn_server_config_*.toml  2>/dev/null || true
rm -f /tmp/mrvpn_encrypt_key_*.txt     2>/dev/null || true
# Legacy patterns from older installer versions
rm -f /tmp/server_config_backup_*      2>/dev/null || true
rm -f /tmp/encrypt_key_backup_*        2>/dev/null || true
echo "[✓] Temp backups cleaned"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Uninstall complete. System is clean.  "
echo "========================================"
