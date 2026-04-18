// ═══════════════════════════════════════════════════
//  MRVPN Dashboard JS
// ═══════════════════════════════════════════════════

// ── Auth guard ──────────────────────────────────────
const token = localStorage.getItem("access_token");
if (!token) window.location.href = "/login";

// ── Socket ──────────────────────────────────────────
const socket = io();

socket.on("connect",    () => setHdrStatus("Live", "var(--green)"));
socket.on("disconnect", () => setHdrStatus("Disconnected", "var(--red)"));

socket.on("update", (data) => {
  setValue("s-cpu",  data.health.cpu.toFixed(1));
  setValue("s-ram",  data.health.ram.toFixed(1));
  setValue("s-disk", data.health.disk.toFixed(1));
  setValue("s-rx",   data.speed.rx.toFixed(2));
  setValue("s-tx",   data.speed.tx.toFixed(2));
  pushChartPoint(data.health.cpu, data.health.ram);
  setHdrStatus("Live", "var(--green)");
});

function setHdrStatus(text, color) {
  const el = document.getElementById("hdr-status");
  el.textContent = text;
  el.style.color = color;
}

function setValue(id, val) {
  // Keep the <span class="stat-unit"> that lives inside the element
  const el = document.getElementById(id);
  const unit = el.querySelector(".stat-unit");
  el.childNodes[0].textContent = val;
  // If first child is a text node (initial "—"), replace it
  if (el.firstChild.nodeType === Node.TEXT_NODE) {
    el.firstChild.textContent = val;
  }
}

// ── Chart ────────────────────────────────────────────
const MAX_POINTS = 40;
let chart;

(function initChart() {
  const ctx = document.getElementById("chart").getContext("2d");
  chart = new Chart(ctx, {
    type: "line",
    data: {
      labels: [],
      datasets: [
        {
          label: "CPU %",
          borderColor: "#5b8cff",
          backgroundColor: "rgba(91,140,255,0.08)",
          data: [],
          tension: 0.3,
          pointRadius: 0,
          fill: true,
        },
        {
          label: "RAM %",
          borderColor: "#31c48d",
          backgroundColor: "rgba(49,196,141,0.08)",
          data: [],
          tension: 0.3,
          pointRadius: 0,
          fill: true,
        },
      ],
    },
    options: {
      scales: {
        x: { display: false },
        y: { beginAtZero: true, max: 100, grid: { color: "#1e2d50" }, ticks: { color: "#7a8db3" } },
      },
      plugins: { legend: { labels: { color: "#7a8db3" } } },
      animation: false,
    },
  });
})();

function pushChartPoint(cpu, ram) {
  const now = new Date().toLocaleTimeString();
  chart.data.labels.push(now);
  chart.data.datasets[0].data.push(cpu);
  chart.data.datasets[1].data.push(ram);
  if (chart.data.labels.length > MAX_POINTS) {
    chart.data.labels.shift();
    chart.data.datasets.forEach(d => d.data.shift());
  }
  chart.update();
}

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

// ── Restart VPN ───────────────────────────────────────
async function restartVPN() {
  if (!confirm("Restart MasterDnsVPN now?")) return;
  await apiFetch("/api/restart", { method: "POST" });
  showToast("Restart command sent ✓", "success");
}

// ══════════════════════════════════════════════════════
//  Config Editor Modal
// ══════════════════════════════════════════════════════
let currentConfigType = "";  // "server" | "key"

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

  // Step 1: send without confirmed — server responds with a confirmation message
  const r1   = await apiFetch(`/api/config/${currentConfigType}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content, confirmed: false }),
  });
  const d1 = await r1.json();

  if (d1.requires_confirmation) {
    if (!confirm(d1.message)) return;
  }

  // Step 2: send with confirmed: true
  const r2   = await apiFetch(`/api/config/${currentConfigType}`, {
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

// ══════════════════════════════════════════════════════
//  Scheduler
// ══════════════════════════════════════════════════════

const DAY_LABELS = { mon:"Mon", tue:"Tue", wed:"Wed", thu:"Thu", fri:"Fri", sat:"Sat", sun:"Sun" };
const ALL_DAYS   = Object.keys(DAY_LABELS);

async function loadSchedules() {
  const listEl = document.getElementById("schedule-list");
  try {
    const res  = await apiFetch("/api/schedules");
    const data = await res.json();

    if (!data.length) {
      listEl.innerHTML = '<div class="empty-msg">No schedules yet. Add one to auto-switch configs.</div>';
      return;
    }

    listEl.innerHTML = data.map(s => `
      <div class="schedule-item" id="si-${s.id}">
        <div class="schedule-time">${s.time}</div>
        <div class="schedule-info">
          <div class="schedule-name">${escHtml(s.name)}</div>
          <div class="schedule-days">${formatDays(s.days)}</div>
        </div>
        <div class="schedule-actions">
          <button class="btn btn-neutral btn-sm" onclick="editSchedule('${s.id}')">Edit</button>
          <button class="btn btn-danger  btn-sm" onclick="deleteSchedule('${s.id}')">Delete</button>
        </div>
      </div>
    `).join("");
  } catch (_) {
    listEl.innerHTML = '<div class="empty-msg" style="color:var(--red)">Failed to load schedules.</div>';
  }
}

function formatDays(days) {
  if (!days || days.length === 0) return "No days selected";
  if (days.length === 7) return "Every day";
  const weekdays = ["mon","tue","wed","thu","fri"];
  const weekend  = ["sat","sun"];
  if (weekdays.every(d => days.includes(d)) && !days.includes("sat") && !days.includes("sun"))
    return "Weekdays";
  if (weekend.every(d => days.includes(d)) && days.length === 2)
    return "Weekends";
  return days.map(d => DAY_LABELS[d] || d).join(", ");
}

// ── Open Add form (empty) ─────────────────────────────
function openAddSchedule() {
  document.getElementById("sched-modal-title").textContent = "Add Schedule";
  document.getElementById("sched-id").value      = "";
  document.getElementById("sched-name").value    = "";
  document.getElementById("sched-time").value    = "22:00";
  document.getElementById("sched-config").value  = "";
  ALL_DAYS.forEach(d => { document.getElementById(`d-${d}`).checked = true; });
  openModal("sched-modal");
}

// ── Open Edit form (prefilled from server) ────────────
async function editSchedule(id) {
  document.getElementById("sched-modal-title").textContent = "Edit Schedule";
  const res  = await apiFetch(`/api/schedules/${id}`);
  const s    = await res.json();

  document.getElementById("sched-id").value     = s.id;
  document.getElementById("sched-name").value   = s.name;
  document.getElementById("sched-time").value   = s.time;
  document.getElementById("sched-config").value = s.config || "";
  ALL_DAYS.forEach(d => {
    document.getElementById(`d-${d}`).checked = (s.days || []).includes(d);
  });
  openModal("sched-modal");
}

// ── Load current live config into schedule textarea ───
async function loadCurrentConfigIntoSchedule() {
  const res  = await apiFetch("/api/config/server");
  const data = await res.json();
  document.getElementById("sched-config").value = data.content || "";
  showToast("Current config loaded ✓", "success");
}

// ── Save (create or update) ───────────────────────────
async function saveSchedule() {
  const id     = document.getElementById("sched-id").value;
  const name   = document.getElementById("sched-name").value.trim();
  const time   = document.getElementById("sched-time").value;
  const config = document.getElementById("sched-config").value.trim();
  const days   = ALL_DAYS.filter(d => document.getElementById(`d-${d}`).checked);

  if (!time)   { showToast("Please set a time", "error"); return; }
  if (!config) { showToast("Config content is required", "error"); return; }
  if (!days.length) { showToast("Select at least one day", "error"); return; }

  const body = JSON.stringify({ name: name || "Unnamed", time, days, config });
  const headers = { "Content-Type": "application/json" };

  let res;
  if (id) {
    // Update existing
    res = await apiFetch(`/api/schedules/${id}`, { method: "PUT", headers, body });
  } else {
    // Create new
    res = await apiFetch("/api/schedules", { method: "POST", headers, body });
  }

  const data = await res.json();
  if (data.ok) {
    closeModal("sched-modal");
    showToast(id ? "Schedule updated ✓" : "Schedule added ✓", "success");
    loadSchedules();
  } else {
    showToast("Error: " + (data.error || "unknown"), "error");
  }
}

// ── Delete ────────────────────────────────────────────
async function deleteSchedule(id) {
  if (!confirm("Delete this schedule?")) return;
  const res  = await apiFetch(`/api/schedules/${id}`, { method: "DELETE" });
  const data = await res.json();
  if (data.ok) {
    showToast("Schedule deleted", "success");
    loadSchedules();
  }
}

// ══════════════════════════════════════════════════════
//  Modal helpers
// ══════════════════════════════════════════════════════
function openModal(id) {
  document.getElementById(id).classList.add("open");
}
function closeModal(id) {
  document.getElementById(id).classList.remove("open");
}

// Close on overlay click
document.querySelectorAll(".modal-overlay").forEach(overlay => {
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) overlay.classList.remove("open");
  });
});

// ── Toast ─────────────────────────────────────────────
let toastTimer;
function showToast(msg, type = "success") {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.className = `show ${type}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 3000);
}

// ── Sanitize ──────────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"
  }[c]));
}

// ── Init ──────────────────────────────────────────────
loadSchedules();
