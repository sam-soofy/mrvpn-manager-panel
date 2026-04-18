// ═══════════════════════════════════════════════════
//  utils.js — shared helpers, loaded first
// ═══════════════════════════════════════════════════

// ── Auth guard ───────────────────────────────────────
const token = localStorage.getItem("access_token");
if (!token) window.location.href = "/login";

// ── Authenticated fetch ───────────────────────────────
async function apiFetch(url, options = {}) {
  options.headers = { ...(options.headers || {}), Authorization: `Bearer ${token}` };
  const res = await fetch(url, options);
  if (res.status === 401) {
    showToast("Session expired — please log in again", "error");
    setTimeout(() => { localStorage.clear(); window.location.href = "/login"; }, 1500);
    throw new Error("unauthorized");
  }
  return res;
}

// ── Logout ────────────────────────────────────────────
function logout() {
  localStorage.clear();
  window.location.href = "/login";
}

// ── Toast ─────────────────────────────────────────────
let toastTimer;
function showToast(msg, type = "success") {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.className = `show ${type}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 3000);
}

// ── Modal helpers ─────────────────────────────────────
function openModal(id) {
  document.getElementById(id).classList.add("open");
}
function closeModal(id) {
  document.getElementById(id).classList.remove("open");
}

// ── Sanitize HTML ─────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}
