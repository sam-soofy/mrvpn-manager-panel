// ═══════════════════════════════════════════════════
//  main.js — page-level actions and init
//  Depends on: utils.js, scheduler.js
// ═══════════════════════════════════════════════════

// ── Restart VPN ───────────────────────────────────────
async function restartVPN() {
  if (!confirm("Restart MasterDnsVPN now?")) return;
  await apiFetch("/api/restart", { method: "POST" });
  showToast("Restart command sent ✓", "success");
}

// ── Close modals on overlay click ─────────────────────
document.querySelectorAll(".modal-overlay").forEach(overlay => {
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) overlay.classList.remove("open");
  });
});

// ── Init ──────────────────────────────────────────────
loadSchedules();
