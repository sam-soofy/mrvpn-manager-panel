// ═══════════════════════════════════════════════════
//  config-editor.js — config + key + client editor modal
//  Depends on: utils.js (apiFetch, openModal, closeModal, showToast)
// ═══════════════════════════════════════════════════

console.log("[MRVPN] config-editor.js loaded");

// "server" | "key" | "client"
let currentConfigType = "";

// ── Modal mode helpers ────────────────────────────────
// Server/key mode: show Save button, hide Download button.
// Client mode:     hide Save button, show Download button.
function _setModalMode(type) {
  const saveBtn = document.getElementById("cfg-save-btn");
  const saveRestartBtn = document.getElementById("cfg-save-restart-btn");
  const downloadBtn = document.getElementById("cfg-download-btn");
  if (type === "client") {
    saveBtn.style.display = "";
    saveRestartBtn.style.display = "None";
    downloadBtn.style.display = "";
  } else if (type === "server") {
    saveBtn.style.display = "None";
    saveRestartBtn.style.display = "";
    downloadBtn.style.display = "";
  } else if (type === "key") {
    saveBtn.style.display = "None";
    saveRestartBtn.style.display = "";
    downloadBtn.style.display = "";
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
    const res = await apiFetch(`/api/config/${type}`);
    const data = await res.json();
    console.log(
      "[MRVPN] openConfigEditor: loaded",
      (data.content || "").length,
      "chars",
    );
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
  document.getElementById("cfg-modal-title").textContent =
    "Edit & Download Client Config";
  _setModalMode("client");

  try {
    const res = await apiFetch("/api/config/client");
    const data = await res.json();

    if (!data.available) {
      showToast(
        "No client config available — is MasterDnsVPN installed?",
        "error",
      );
      return;
    }

    const versionLabel =
      data.version === "april5"
        ? "April 5"
        : data.version === "april12"
          ? "April 12"
          : data.version;
    document.getElementById("cfg-modal-title").textContent =
      `Edit & Download Client Config (${versionLabel} build)`;

    document.getElementById("cfg-textarea").value = data.content || "";
    openModal("cfg-modal");
    console.log(
      "[MRVPN] openClientConfigEditor: loaded",
      (data.content || "").length,
      "chars, version:",
      data.version,
    );
  } catch (err) {
    console.error("[MRVPN] openClientConfigEditor error:", err.message);
    showToast("Failed to load client config: " + err.message, "error");
  }
}

// ── Download client config from textarea content ──────
// No round-trip needed — we create a Blob from the textarea content directly.
function downloadConfigFiles() {
  const content = document.getElementById("cfg-textarea").value;
  if (!content.trim()) {
    showToast("Nothing to download — editor is empty", "error");
    return;
  }
  const blob = new Blob([content], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  let filename;

  a.href = url;
  if (currentConfigType === "client") {
    filename = "client_config.toml"; // always this name, regardless of version
  } else if (currentConfigType === "server") {
    filename = "server_config.toml";
  } else if (currentConfigType === "key") {
    filename = "encrypt_key.txt";
  } else {
    showToast("Unkown file requested to download!", "error");
    return;
  }

  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  console.log(`[MRVPN] ${currentConfigType}: triggered download`);
  showToast(`${filename} downloaded ✓`, "success");
}

// ── Save server / key config ──────────────────────────
async function saveConfig() {
  const content = document.getElementById("cfg-textarea").value;
  console.log(
    "[MRVPN] saveConfig: type=%s length=%d",
    currentConfigType,
    content.length,
  );

  try {
    // Step 1: ask server for confirmation prompt
    const r1 = await apiFetch(`/api/config/${currentConfigType}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content, confirmed: false }),
    });
    const d1 = await r1.json();
    console.log("[MRVPN] saveConfig: step1 response:", d1);

    if (d1.requires_confirmation) {
      if (!confirm(d1.message)) {
        console.log("[MRVPN] saveConfig: user cancelled");
        return;
      }
    }

    // Step 2: send with confirmed: true
    const r2 = await apiFetch(`/api/config/${currentConfigType}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content, confirmed: true }),
    });
    const d2 = await r2.json();
    console.log("[MRVPN] saveConfig: step2 response:", d2);

    if (d2.ok) {
      closeModal("cfg-modal");
      if (currentConfigType == "client") {
        showToast("Saved Changes", "success");
      } else {
        showToast("Saved — MasterDnsVPN restarting in ~2s ✓", "success");
      }
    } else {
      showToast("Save failed: " + (d2.message || "unknown error"), "error");
    }
  } catch (err) {
    console.error("[MRVPN] saveConfig error:", err.message);
    showToast("Save failed: " + err.message, "error");
  }
}
