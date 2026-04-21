// ═══════════════════════════════════════════════════
//  utils.js — shared helpers, loaded first
// ═══════════════════════════════════════════════════

console.log("[MRVPN] utils.js loaded");

// ── Sync token guard ─────────────────────────────────
const token = localStorage.getItem("access_token");
console.log("[MRVPN] access_token present:", !!token);

if (!token) {
  console.warn("[MRVPN] No access token — redirecting to /login");
  window.location.replace("/login");
}

// ── Async auth verify ────────────────────────────────
async function verifyAuth() {
  console.log("[MRVPN] verifyAuth: calling /api/auth/verify ...");
  try {
    const res = await fetch("/api/auth/verify", {
      headers: { Authorization: `Bearer ${token}` },
    });
    console.log("[MRVPN] verifyAuth: response status =", res.status);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    console.log("[MRVPN] verifyAuth: OK — session is valid");
    return true;
  } catch (err) {
    console.error("[MRVPN] verifyAuth failed:", err.message, "— clearing storage and redirecting to /login");
    localStorage.clear();
    window.location.replace("/login");
    return false;
  }
}

// ── Authenticated fetch ───────────────────────────────
async function apiFetch(url, options = {}) {
  console.log("[MRVPN] apiFetch:", options.method || "GET", url);
  options.headers = { ...(options.headers || {}), Authorization: `Bearer ${token}` };
  let res;
  try {
    res = await fetch(url, options);
  } catch (err) {
    console.error("[MRVPN] apiFetch network error:", url, err.message);
    throw err;
  }
  console.log("[MRVPN] apiFetch response:", url, "→", res.status);
  if (res.status === 401) {
    console.warn("[MRVPN] 401 Unauthorized — session expired, redirecting to /login");
    showToast("Session expired — logging out", "error");
    setTimeout(() => {
      localStorage.clear();
      window.location.replace("/login");
    }, 600);
    throw new Error("unauthorized");
  }
  return res;
}

// ── Logout ────────────────────────────────────────────
function logout() {
  console.log("[MRVPN] logout()");
  localStorage.clear();
  window.location.replace("/login");
}

// ── Toast ─────────────────────────────────────────────
let toastTimer;
function showToast(msg, type = "success") {
  console.log(`[MRVPN] toast [${type}]: ${msg}`);
  const el = document.getElementById("toast");
  if (!el) return;
  el.textContent = msg;
  el.className = `show ${type}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 3000);
}

// ── Modal helpers ─────────────────────────────────────
function openModal(id) {
  console.log("[MRVPN] openModal:", id);
  const el = document.getElementById(id);
  if (el) el.classList.add("open");
  else console.error("[MRVPN] openModal: element not found:", id);
}
function closeModal(id) {
  console.log("[MRVPN] closeModal:", id);
  const el = document.getElementById(id);
  if (el) el.classList.remove("open");
}

// ── Sanitize HTML ─────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}
