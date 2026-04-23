#!/usr/bin/env bash
# =============================================================================
# MRVPN Manager Panel - Uninstaller (v2)
#
# What this removes:
#   - All three systemd services + service files
#   - /opt/mrvpn-manager-panel  (panel directory)
#   - MasterDnsVPN binary, server_config.toml, encrypt_key.txt from /root
#     and any detected stray install location (old /opt/masterdnsvpn, etc.)
#   - Kernel tuning: /etc/sysctl.d/99-masterdnsvpn.conf
#   - Limits file:   /etc/security/limits.d/99-masterdnsvpn.conf
#   - Installer temp backups in /tmp (mrvpn_* prefix only)
#   - DNSStubListener change in /etc/systemd/resolved.conf
#
# DNS restoration (the tricky part):
#   The installer disabled the systemd-resolved stub listener and switched
#   /etc/resolv.conf to the non-stub resolver file. We must:
#   1. Ensure resolved has an upstream DNS (DNS=8.8.8.8 1.1.1.1) before
#      re-enabling the stub, so the stub actually forwards queries.
#   2. Re-enable the stub listener.
#   3. Restart systemd-resolved and wait for it to come up.
#   4. Switch /etc/resolv.conf back to the stub file (127.0.0.53).
#   5. Verify DNS works; if not, write a static fallback.
#
# Does NOT remove:
#   - .backup, .bak, or other user-created files in /root
#   - /root itself or its general contents
#   - bash history or other user data
# =============================================================================
set -euo pipefail

PANEL_DIR="/opt/mrvpn-manager-panel"
MASTER_DIR="/root"    # where our installer put MasterDnsVPN files

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo bash uninstall.sh"
  exit 1
fi

echo "========================================"
echo "  MRVPN Manager Panel - Uninstaller     "
echo "========================================"
echo ""
echo "This will permanently remove:"
echo "  ▸ mrvpn-manager-panel + mrvpn-config-scheduler services"
echo "  ▸ masterdnsvpn service"
echo "  ▸ ${PANEL_DIR}"
echo "  ▸ MasterDnsVPN binary, server_config.toml, encrypt_key.txt from ${MASTER_DIR}"
echo "  ▸ Kernel tuning files (sysctl.d + limits.d)"
echo "  ▸ Installer temp backups in /tmp (mrvpn_* only)"
echo "  ▸ DNSStubListener change in /etc/systemd/resolved.conf"
echo ""
echo "Will NOT remove:"
echo "  ▸ .backup, .bak, or other user-created files"
echo "  ▸ /root itself or its general contents"
echo ""
read -r -p "Type 'yes' to confirm full uninstall: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "[!] Aborted." && exit 0

echo ""

# ── Helpers ────────────────────────────────────────────────────────────────────

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
# Never touches .backup, .bak, or user-created files.
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

# ── Read metadata BEFORE removing service files ────────────────────────────────
MASTER_SVC_WORKDIR=$(get_service_workdir "masterdnsvpn" 2>/dev/null || true)

# ── Stop and remove all three services ────────────────────────────────────────
echo "[*] Stopping services..."
stop_and_remove_service "mrvpn-manager-panel"
stop_and_remove_service "mrvpn-config-scheduler"
stop_and_remove_service "masterdnsvpn"
systemctl daemon-reload
echo "[✓] All services removed"

# ── Remove panel directory ─────────────────────────────────────────────────────
echo ""
if [[ -d "$PANEL_DIR" ]]; then
  rm -rf "$PANEL_DIR"
  echo "[✓] Removed ${PANEL_DIR}"
else
  echo "[~] ${PANEL_DIR} not found — skipping"
fi

# ── Remove MasterDnsVPN files from /root ──────────────────────────────────────
echo ""
echo "[*] Removing MasterDnsVPN files from ${MASTER_DIR}..."
remove_master_files_from "$MASTER_DIR"

# ── Remove stray files from old install locations ──────────────────────────────
echo ""
echo "[*] Scanning for stray MasterDnsVPN files..."

declare -A SEEN=()
SEEN["$MASTER_DIR"]=1

check_stray_dir() {
  local dir="$1"
  [[ -z "$dir" ]]            && return
  [[ -n "${SEEN[$dir]+_}" ]] && return
  SEEN[$dir]=1

  local is_master=false
  ls "${dir}"/MasterDnsVPN_Server_Linux_AMD64* 2>/dev/null | grep -q . && is_master=true
  [[ -f "${dir}/server_config.toml" ]] && is_master=true
  [[ -f "${dir}/encrypt_key.txt" ]]    && is_master=true

  if $is_master; then
    echo "[*] Found stray installation at: ${dir}"
    remove_master_files_from "$dir"
  fi
}

[[ -n "${MASTER_SVC_WORKDIR:-}" ]] && check_stray_dir "$MASTER_SVC_WORKDIR"
check_stray_dir "/opt/masterdnsvpn"

# ── Remove kernel tuning files ─────────────────────────────────────────────────
echo ""
echo "[*] Removing kernel tuning files..."

SYSCTL_FILE="/etc/sysctl.d/99-masterdnsvpn.conf"
LIMITS_FILE="/etc/security/limits.d/99-masterdnsvpn.conf"

if [[ -f "$SYSCTL_FILE" ]]; then
  rm -f "$SYSCTL_FILE"
  echo "[✓] Removed ${SYSCTL_FILE}"
  # Reload sysctl so the removed settings no longer apply (persists until reboot;
  # a reboot is recommended anyway at the end of uninstall).
  sysctl --system >/dev/null 2>&1 || echo "[~] Could not reload sysctl (non-fatal)"
else
  echo "[~] ${SYSCTL_FILE} not found — skipping"
fi

if [[ -f "$LIMITS_FILE" ]]; then
  rm -f "$LIMITS_FILE"
  echo "[✓] Removed ${LIMITS_FILE}"
else
  echo "[~] ${LIMITS_FILE} not found — skipping"
fi

# ── Remove installer temp backups from /tmp ────────────────────────────────────
echo ""
echo "[*] Removing installer temp backups from /tmp..."
REMOVED_TMP=false
for f in /tmp/mrvpn_server_config_*.toml /tmp/mrvpn_encrypt_key_*.txt /tmp/mrvpn_keygen_*.log; do
  [[ -f "$f" ]] || continue
  rm -f "$f"
  REMOVED_TMP=true
done
$REMOVED_TMP && echo "[✓] Temp backups removed" || echo "[~] No temp backups found"

# ── Restore systemd-resolved and fix DNS ──────────────────────────────────────
# This is the most critical part. After install, the system has:
#   - DNSStubListener=no in resolved.conf  (disables 127.0.0.53 stub)
#   - /etc/resolv.conf → /run/systemd/resolve/resolv.conf  (non-stub path)
#
# We must:
#   1. Remove DNSStubListener=no (re-enable stub)
#   2. Keep DNS=8.8.8.8 1.1.1.1 so the stub has an upstream after restart
#   3. Restart systemd-resolved and wait for it
#   4. Point resolv.conf back to stub-resolv.conf
#   5. If DNS still broken, write a static /etc/resolv.conf as hard fallback
echo ""
echo "[*] Restoring systemd-resolved configuration..."
RESOLVED_CONF="/etc/systemd/resolved.conf"
DNS_RESTORED=false

if [[ -f "$RESOLVED_CONF" ]] && grep -q "^DNSStubListener=no" "$RESOLVED_CONF"; then

  # Remove DNSStubListener=no to restore the default (stub enabled)
  sed -i '/^DNSStubListener=no/d' "$RESOLVED_CONF"
  echo "[*] Removed DNSStubListener=no from ${RESOLVED_CONF}"

  # Ensure an upstream DNS exists so the re-enabled stub can forward queries.
  # Without this, the stub comes back but resolves nothing → system loses DNS.
  if ! grep -q '^DNS=' "$RESOLVED_CONF"; then
    echo 'DNS=8.8.8.8 1.1.1.1' >> "$RESOLVED_CONF"
    echo "[*] Added DNS=8.8.8.8 1.1.1.1 to ${RESOLVED_CONF} (stub upstream)"
  fi

  # Restart resolved and wait up to 8 seconds for it to come up
  systemctl restart systemd-resolved 2>/dev/null || true
  echo "[*] Waiting for systemd-resolved to restart..."
  for i in 1 2 3 4 5 6 7 8; do
    systemctl is-active --quiet systemd-resolved 2>/dev/null && break
    sleep 1
  done

  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    # Give it a moment to bind the stub listener on 127.0.0.53
    sleep 1

    # Switch resolv.conf back to the stub file
    if [[ -L /etc/resolv.conf ]]; then
      RESOLV_TARGET="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
      # Was on non-stub → switch back to stub
      if [[ "$RESOLV_TARGET" == "/run/systemd/resolve/resolv.conf" ]] \
         && [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        echo "[*] Switched /etc/resolv.conf back to stub (127.0.0.53)"
      fi
    fi

    # Verify DNS actually works now
    if command -v nslookup >/dev/null 2>&1; then
      if nslookup google.com 2>/dev/null | grep -q "Address:"; then
        echo "[✓] DNS verified working (nslookup google.com OK)"
        DNS_RESTORED=true
      fi
    elif command -v dig >/dev/null 2>&1; then
      if dig +short google.com @127.0.0.53 2>/dev/null | grep -q '[0-9]'; then
        echo "[✓] DNS verified working (dig google.com OK)"
        DNS_RESTORED=true
      fi
    else
      # No verification tool — assume OK
      DNS_RESTORED=true
    fi
  fi

  if ! $DNS_RESTORED; then
    echo "[~] DNS verification failed or systemd-resolved didn't start cleanly."
    echo "[*] Writing static /etc/resolv.conf as hard fallback..."
    # Static file always works regardless of systemd-resolved state.
    # This is the safest fallback when everything else fails.
    cat > /etc/resolv.conf <<'RESOLV'
# Fallback DNS written by mrvpn-manager-panel uninstaller
# Replace this file with your provider's symlink if needed, e.g.:
#   ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV
    echo "[✓] Static /etc/resolv.conf written (8.8.8.8 / 1.1.1.1)"
    echo "    Reboot or run: systemctl restart systemd-resolved"
    echo "    to restore full systemd-resolved integration."
  fi

else
  echo "[~] No DNSStubListener=no found in ${RESOLVED_CONF} — skipping DNS restore"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Uninstall complete.                   "
echo "========================================"
echo ""
echo "  ⚠  Please reboot to fully apply all"
echo "     kernel, network, and service changes."
echo ""
echo "    sudo reboot"
echo ""
echo "========================================"
