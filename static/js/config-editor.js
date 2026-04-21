// ═══════════════════════════════════════════════════
//  config-editor.js — config + key editor modal
//  Depends on: utils.js (apiFetch, openModal, closeModal, showToast)
// ═══════════════════════════════════════════════════

console.log("[MRVPN] config-editor.js loaded");

let currentConfigType = ""; // "server" | "key"

async function openConfigEditor(type) {
  currentConfigType = type;
  const label = type === "server" ? "server_config.toml" : "encrypt_key.txt";
  console.log("[MRVPN] openConfigEditor:", label);
  document.getElementById("cfg-modal-title").textContent = `Edit ${label}`;

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

async function saveConfig() {
  const content = document.getElementById("cfg-textarea").value;
  console.log("[MRVPN] saveConfig: type=%s length=%d", currentConfigType, content.length);

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
      showToast("Saved and MasterDnsVPN restarted ✓", "success");
    } else {
      showToast("Save failed: " + (d2.message || "unknown error"), "error");
    }
  } catch (err) {
    console.error("[MRVPN] saveConfig error:", err.message);
    showToast("Save failed: " + err.message, "error");
  }
}
