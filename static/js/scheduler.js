// ═══════════════════════════════════════════════════
//  scheduler.js — schedule CRUD
//  Depends on: utils.js (apiFetch, openModal, closeModal, showToast, escHtml)
// ═══════════════════════════════════════════════════

const DAY_LABELS = { mon:"Mon", tue:"Tue", wed:"Wed", thu:"Thu", fri:"Fri", sat:"Sat", sun:"Sun" };
const ALL_DAYS   = Object.keys(DAY_LABELS);

// ── Load & render list ────────────────────────────────
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
  document.getElementById("sched-id").value     = "";
  document.getElementById("sched-name").value   = "";
  document.getElementById("sched-time").value   = "22:00";
  document.getElementById("sched-config").value = "";
  ALL_DAYS.forEach(d => { document.getElementById(`d-${d}`).checked = true; });
  openModal("sched-modal");
}

// ── Open Edit form (prefilled from server) ────────────
async function editSchedule(id) {
  document.getElementById("sched-modal-title").textContent = "Edit Schedule";
  const res = await apiFetch(`/api/schedules/${id}`);
  const s   = await res.json();

  document.getElementById("sched-id").value     = s.id;
  document.getElementById("sched-name").value   = s.name;
  document.getElementById("sched-time").value   = s.time;
  document.getElementById("sched-config").value = s.config || "";
  ALL_DAYS.forEach(d => {
    document.getElementById(`d-${d}`).checked = (s.days || []).includes(d);
  });
  openModal("sched-modal");
}

// ── Load live config into schedule textarea ───────────
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

  const body    = JSON.stringify({ name: name || "Unnamed", time, days, config });
  const headers = { "Content-Type": "application/json" };

  const res  = id
    ? await apiFetch(`/api/schedules/${id}`, { method: "PUT",  headers, body })
    : await apiFetch("/api/schedules",        { method: "POST", headers, body });
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
