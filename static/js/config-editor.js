// ═══════════════════════════════════════════════════
//  config-editor.js — config + key editor modal
//  Depends on: utils.js (apiFetch, openModal, closeModal, showToast)
// ═══════════════════════════════════════════════════

let currentConfigType = ""; // "server" | "key"

async function openConfigEditor(type) {
  currentConfigType = type;
  const label = type === "server" ? "server_config.toml" : "encrypt_key.txt";
  document.getElementById("cfg-modal-title").textContent = `Edit ${label}`;

  const res  = await apiFetch(`/api/config/${type}`);
  const data = await res.json();
  document.getElementById("cfg-textarea").value = data.content || "";
  openModal("cfg-modal");
}

async function saveConfig() {
  const content = document.getElementById("cfg-textarea").value;

  // Step 1: ask server for confirmation prompt
  const r1 = await apiFetch(`/api/config/${currentConfigType}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content, confirmed: false }),
  });
  const d1 = await r1.json();

  if (d1.requires_confirmation) {
    if (!confirm(d1.message)) return;
  }

  // Step 2: send with confirmed: true
  const r2 = await apiFetch(`/api/config/${currentConfigType}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content, confirmed: true }),
  });
  const d2 = await r2.json();

  if (d2.ok) {
    closeModal("cfg-modal");
    showToast("Saved and MasterDnsVPN restarted ✓", "success");
  } else {
    showToast("Save failed: " + (d2.message || "unknown error"), "error");
  }
}
