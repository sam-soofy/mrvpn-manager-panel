// ═══════════════════════════════════════════════════
//  main.js — page-level actions and init
//  Depends on: utils.js, realtime.js, scheduler.js
// ═══════════════════════════════════════════════════

console.log("[MRVPN] main.js loaded");

// ── Restart VPN ───────────────────────────────────────
async function restartVPN() {
  if (!confirm("Restart MasterDnsVPN now?")) return;
  console.log("[MRVPN] restartVPN: sending POST /api/restart");
  try {
    const res = await apiFetch("/api/restart", { method: "POST" });
    const data = await res.json();
    console.log("[MRVPN] restartVPN: response:", data);
    showToast(
      data.ok ? "Restart command sent ✓" : "Restart failed",
      data.ok ? "success" : "error",
    );
  } catch (err) {
    console.error("[MRVPN] restartVPN error:", err.message);
    showToast("Restart failed: " + err.message, "error");
  }
}

// ── Update Panel ──────────────────────────────────────
async function updatePanel() {
  if (
    !confirm(
      "Update panel to the latest version?\n\n" +
        "This will pull from GitHub (main branch) and restart the panel.\n" +
        "The page will reload automatically after ~5 seconds.",
    )
  )
    return;

  console.log("[MRVPN] updatePanel: sending POST /api/panel/update");
  try {
    const res = await apiFetch("/api/panel/update", { method: "POST" });
    const data = await res.json();
    console.log("[MRVPN] updatePanel: response:", data);

    if (data.ok) {
      showToast("Panel updated — reloading in ~5s ✓", "success");
      setTimeout(() => window.location.reload(), 5000);
    } else {
      showToast("Update failed: " + (data.error || "unknown error"), "error");
    }
  } catch (err) {
    console.error("[MRVPN] updatePanel error:", err.message);
    // Network error is expected if the panel restarted before sending the response.
    // Treat it as success and reload anyway.
    showToast("Panel restarting — reloading in ~5s", "success");
    setTimeout(() => window.location.reload(), 5000);
  }
}

// ── Close modals on overlay click ─────────────────────
document.querySelectorAll(".modal-overlay").forEach((overlay) => {
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) overlay.classList.remove("open");
  });
});

// ── Init ──────────────────────────────────────────────
(async function init() {
  console.log("[MRVPN] init: starting...");

  const ok = await verifyAuth();
  if (!ok) {
    console.warn("[MRVPN] init: auth failed — staying on login");
    return;
  }

  console.log("[MRVPN] init: auth OK — revealing dashboard");
  document.getElementById("auth-loading").style.display = "none";
  document.getElementById("page-header").style.display = "flex"; // header { display: flex }
  document.getElementById("page-main").style.display = "grid"; // main { display: grid }

  console.log("[MRVPN] init: initialising chart");
  initChart();

  console.log("[MRVPN] init: initialising socket");
  initSocket();

  console.log("[MRVPN] init: loading schedules");
  loadSchedules();

  console.log("[MRVPN] init: complete");
})();
