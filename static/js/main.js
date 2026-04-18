// ═══════════════════════════════════════════════════
//  main.js — page-level actions and init
//  Depends on: utils.js, realtime.js, scheduler.js
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
// Verify the JWT server-side first. Only if the token is valid do we:
//   1. Show the dashboard content (header + main are hidden by CSS)
//   2. Connect the socket (so unauthenticated sockets never happen)
//   3. Load the schedule list
(async function init() {
  const ok = await verifyAuth();
  if (!ok) return; // verifyAuth already redirected to /login

  // Reveal the dashboard now that we know the session is valid
  document.getElementById("auth-loading").style.display = "none";
  document.getElementById("page-header").style.display  = "";
  document.getElementById("page-main").style.display    = "";

  initSocket();
  loadSchedules();
})();
