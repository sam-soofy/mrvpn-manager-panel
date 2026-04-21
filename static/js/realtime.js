// ═══════════════════════════════════════════════════
//  realtime.js — socket.io + live chart
//  Depends on: utils.js (token, showToast)
//  Socket is NOT auto-connected. main.js calls initSocket() after
//  verifyAuth() succeeds, so no unauthenticated socket connections occur.
// ═══════════════════════════════════════════════════

console.log("[MRVPN] realtime.js loaded");

let socket;

// Called by main.js after auth is confirmed.
function initSocket() {
  console.log("[MRVPN] initSocket: connecting with JWT auth...");
  socket = io({ auth: { token } });

  socket.on("connect", () => {
    console.log("[MRVPN] socket connected, id:", socket.id);
    setHdrStatus("Live", "var(--green)");
  });

  socket.on("disconnect", (reason) => {
    console.warn("[MRVPN] socket disconnected:", reason);
    setHdrStatus("Disconnected", "var(--red)");
  });

  socket.on("connect_error", (err) => {
    console.error("[MRVPN] socket connect_error:", err.message);
    setHdrStatus("Connection error", "var(--red)");
  });

  socket.on("update", (data) => {
    setValue("s-cpu",  data.health.cpu.toFixed(1));
    setValue("s-ram",  data.health.ram.toFixed(1));
    setValue("s-disk", data.health.disk.toFixed(1));
    setValue("s-rx",   data.speed.rx.toFixed(2));
    setValue("s-tx",   data.speed.tx.toFixed(2));
    pushChartPoint(data.health.cpu, data.health.ram);
    setHdrStatus("Live", "var(--green)");
  });
}

// ── Header status indicator ───────────────────────────
function setHdrStatus(text, color) {
  const el = document.getElementById("hdr-status");
  if (!el) return;
  el.textContent = text;
  el.style.color = color;
}

// ── Stat card value updater ───────────────────────────
// Each stat element has a text node first, then a <span class="stat-unit"> child.
function setValue(id, val) {
  const el = document.getElementById(id);
  if (!el) { console.warn("[MRVPN] setValue: element not found:", id); return; }
  if (el.firstChild && el.firstChild.nodeType === Node.TEXT_NODE) {
    el.firstChild.textContent = val;
  }
}

// ── Chart ─────────────────────────────────────────────
// NOTE: Chart is initialised lazily inside initChart() which is called by
// main.js after auth succeeds — NOT as an immediate IIFE at script-load time.
// This prevents a CDN failure from blocking all subsequent JS execution.

const MAX_POINTS = 40;
let chart = null;

function initChart() {
  console.log("[MRVPN] initChart: initialising Chart.js canvas...");
  const canvas = document.getElementById("chart");
  if (!canvas) {
    console.error("[MRVPN] initChart: #chart canvas not found in DOM");
    return;
  }
  if (typeof Chart === "undefined") {
    console.error("[MRVPN] initChart: Chart.js not loaded (CDN failure?). Live chart disabled.");
    return;
  }
  try {
    const ctx = canvas.getContext("2d");
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
          y: {
            beginAtZero: true,
            max: 100,
            grid: { color: "#1e2d50" },
            ticks: { color: "#7a8db3" },
          },
        },
        plugins: { legend: { labels: { color: "#7a8db3" } } },
        animation: false,
      },
    });
    console.log("[MRVPN] initChart: Chart.js ready");
  } catch (err) {
    console.error("[MRVPN] initChart: failed to create chart:", err.message);
  }
}

function pushChartPoint(cpu, ram) {
  if (!chart) return;
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
