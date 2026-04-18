// ═══════════════════════════════════════════════════
//  realtime.js — socket.io + live chart
//  Depends on: utils.js (token, showToast)
//  Socket is NOT auto-connected. main.js calls initSocket() after
//  verifyAuth() succeeds, so no unauthenticated socket connections occur.
// ═══════════════════════════════════════════════════

let socket;

// Called by main.js after auth is confirmed.
function initSocket() {
  // Pass JWT in the handshake so the server can reject unauthenticated sockets.
  socket = io({ auth: { token } });

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
}

// ── Header status indicator ───────────────────────────
function setHdrStatus(text, color) {
  const el = document.getElementById("hdr-status");
  el.textContent = text;
  el.style.color = color;
}

// ── Stat card value updater ───────────────────────────
function setValue(id, val) {
  const el = document.getElementById(id);
  if (el.firstChild && el.firstChild.nodeType === Node.TEXT_NODE) {
    el.firstChild.textContent = val;
  }
}

// ── Chart ─────────────────────────────────────────────
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
