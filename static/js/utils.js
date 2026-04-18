// ═══════════════════════════════════════════════════
//  utils.js — shared helpers, loaded first
// ═══════════════════════════════════════════════════

// ── Sync token guard ─────────────────────────────────
// If there's no token at all, redirect immediately before any other
// script even runs. This is synchronous so the redirect fires before
// the socket or any apiFetch call is attempted.
const token = localStorage.getItem("access_token");
if (!token) {
  window.location.replace("/login");
}

// ── Async auth verify ────────────────────────────────
// Called by main.js on page load. Verifies the stored token is still
// valid server-side. On failure: clears storage, redirects immediately.
// On success: reveals the dashboard and kicks off init.
async function verifyAuth() {
  try {
    const res = await fetch("/api/auth/verify", {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) throw new Error("invalid");
    return true;
  } catch (_) {
    localStorage.clear();
    window.location.replace("/login");
    return false;
  }
}

// ── Authenticated fetch ───────────────────────────────
async function apiFetch(url, options = {}) {
  options.headers = { ...(options.headers || {}), Authorization: `Bearer ${token}` };
  const res = await fetch(url, options);
  if (res.status === 401) {
    // Token expired mid-session — clear and redirect without delay
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
  localStorage.clear();
  window.location.replace("/login");
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
