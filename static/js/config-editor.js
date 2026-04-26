// ═══════════════════════════════════════════════════
//  config-editor.js — config + key + client editor modal
//  Depends on: utils.js (apiFetch, openModal, closeModal, showToast)
// ═══════════════════════════════════════════════════

console.log("[MRVPN] config-editor.js loaded");

// "server" | "key" | "client"
let currentConfigType = "";

// ── Modal mode helpers ────────────────────────────────
function _setModalMode(type) {
  const saveBtn        = document.getElementById("cfg-save-btn");
  const saveRestartBtn = document.getElementById("cfg-save-restart-btn");
  const downloadBtn    = document.getElementById("cfg-download-btn");
  const resetBtn       = document.getElementById("cfg-reset-btn");

  // Reset: visible for server and client; hidden for key (key is randomly generated)
  resetBtn.style.display = (type === "server" || type === "client") ? "" : "none";

  if (type === "client") {
    saveBtn.style.display        = "";
    saveRestartBtn.style.display = "none";
    downloadBtn.style.display    = "";
  } else if (type === "server") {
    saveBtn.style.display        = "none";
    saveRestartBtn.style.display = "";
    downloadBtn.style.display    = "";
  } else if (type === "key") {
    saveBtn.style.display        = "none";
    saveRestartBtn.style.display = "";
    downloadBtn.style.display    = "";
  }
}

// ── Open server / key editor ──────────────────────────
async function openConfigEditor(type) {
  currentConfigType = type;
  const label = type === "server" ? "server_config.toml" : "encrypt_key.txt";
  console.log("[MRVPN] openConfigEditor:", label);
  document.getElementById("cfg-modal-title").textContent = `Edit ${label}`;
  _setModalMode(type);

  try {
    const res  = await apiFetch(`/api/config/${type}`);
    const data = await res.json();
    console.log("[MRVPN] openConfigEditor: loaded", (data.content || "").length, "chars");
    document.getElementById("cfg-textarea").value = data.content || "";
    openModal("cfg-modal");
  } catch (err) {
    console.error("[MRVPN] openConfigEditor error:", err.message);
    showToast("Failed to load config: " + err.message, "error");
  }
}

// ── Open client config editor ─────────────────────────
async function openClientConfigEditor() {
  currentConfigType = "client";
  console.log("[MRVPN] openClientConfigEditor: fetching /api/config/client");
  document.getElementById("cfg-modal-title").textContent = "Edit & Download Client Config";
  _setModalMode("client");

  try {
    const res  = await apiFetch("/api/config/client");
    const data = await res.json();

    if (!data.available) {
      showToast("No client config available — is MasterDnsVPN installed?", "error");
      return;
    }

    const versionLabel =
      data.version === "april5"  ? "April 5"  :
      data.version === "april12" ? "April 12" : data.version;
    document.getElementById("cfg-modal-title").textContent =
      `Edit & Download Client Config (${versionLabel} build)`;

    document.getElementById("cfg-textarea").value = data.content || "";
    openModal("cfg-modal");
    console.log("[MRVPN] openClientConfigEditor: loaded", (data.content || "").length, "chars, version:", data.version);
  } catch (err) {
    console.error("[MRVPN] openClientConfigEditor error:", err.message);
    showToast("Failed to load client config: " + err.message, "error");
  }
}

// ── Download client config from textarea ──────────────
function downloadConfigFiles() {
  const content = document.getElementById("cfg-textarea").value;
  if (!content.trim()) {
    showToast("Nothing to download — editor is empty", "error");
    return;
  }

  let filename;
  if      (currentConfigType === "client") filename = "client_config.toml";
  else if (currentConfigType === "server") filename = "server_config.toml";
  else if (currentConfigType === "key")    filename = "encrypt_key.txt";
  else { showToast("Unknown file requested to download!", "error"); return; }

  const blob = new Blob([content], { type: "text/plain" });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement("a");
  a.href     = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  console.log(`[MRVPN] ${currentConfigType}: triggered download`);
  showToast(`${filename} downloaded ✓`, "success");
}

// ── Save server / key / client config ─────────────────
async function saveConfig() {
  const content = document.getElementById("cfg-textarea").value;
  console.log("[MRVPN] saveConfig: type=%s length=%d", currentConfigType, content.length);

  try {
    const r1   = await apiFetch(`/api/config/${currentConfigType}`, {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ content, confirmed: false }),
    });
    const d1 = await r1.json();

    if (d1.requires_confirmation) {
      if (!confirm(d1.message)) { console.log("[MRVPN] saveConfig: user cancelled"); return; }
    }

    const r2   = await apiFetch(`/api/config/${currentConfigType}`, {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ content, confirmed: true }),
    });
    const d2 = await r2.json();
    console.log("[MRVPN] saveConfig: step2 response:", d2);

    if (d2.ok) {
      closeModal("cfg-modal");
      showToast(
        currentConfigType === "client"
          ? "Saved Changes ✓"
          : "Saved — MasterDnsVPN restarting in ~2s ✓",
        "success",
      );
    } else {
      showToast("Save failed: " + (d2.message || "unknown error"), "error");
    }
  } catch (err) {
    console.error("[MRVPN] saveConfig error:", err.message);
    showToast("Save failed: " + err.message, "error");
  }
}

// ── Reset config to shipped default ───────────────────
async function resetConfig() {
  const label =
    currentConfigType === "server" ? "server_config.toml" : "client_config.toml";
  const extraNote =
    currentConfigType === "server"
      ? "\n\nYour current domain will be preserved. MasterDnsVPN will restart."
      : "\n\nYour current domain and encryption key will be preserved.";

  if (!confirm(`Reset ${label} to factory defaults? This cannot be undone.${extraNote}`)) return;

  const endpoint =
    currentConfigType === "server" ? "/api/config/server/reset" : "/api/config/client/reset";

  console.log("[MRVPN] resetConfig: POST", endpoint);
  try {
    const res  = await apiFetch(endpoint, { method: "POST" });
    const data = await res.json();
    console.log("[MRVPN] resetConfig: response:", data);

    if (data.ok) {
      closeModal("cfg-modal");
      showToast(
        currentConfigType === "server"
          ? "Reset to default — MasterDnsVPN restarting in ~2s ✓"
          : "Client config reset to default ✓",
        "success",
      );
    } else {
      showToast("Reset failed: " + (data.message || "unknown error"), "error");
    }
  } catch (err) {
    console.error("[MRVPN] resetConfig error:", err.message);
    showToast("Reset failed: " + err.message, "error");
  }
}
