const token = localStorage.getItem("access_token");
if (!token) window.location.href = "/login";

const socket = io();

let chart;

function initChart() {
  chart = new Chart(document.getElementById("chart"), {
    type: "line",
    data: {
      labels: [],
      datasets: [
        { label: "CPU %", borderColor: "#5b8cff", data: [] },
        { label: "RAM %", borderColor: "#31c48d", data: [] },
      ],
    },
    options: {
      scales: { y: { beginAtZero: true, max: 100 } },
      animation: false,
    },
  });
}

async function fetchWithToken(url, options = {}) {
  options.headers = options.headers || {};
  options.headers.Authorization = `Bearer ${token}`;
  const res = await fetch(url, options);
  if (res.status === 401) {
    alert("Session expired");
    localStorage.clear();
    window.location.href = "/login";
  }
  return res;
}

async function restartVPN() {
  await fetchWithToken("/api/restart", { method: "POST" });
  alert("Restart command sent");
}

async function showConfigEditor(type) {
  const res = await fetchWithToken(`/api/config/${type}`);
  const data = await res.json();
  const content = prompt(
    "Edit content below (careful with syntax):",
    data.content || "",
  );
  if (content === null) return;

  let confirmRes = await fetchWithToken(`/api/config/${type}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content, confirmed: false }),
  });
  let confirmData = await confirmRes.json();

  if (confirmData.requires_confirmation && confirm(confirmData.message)) {
    const finalRes = await fetchWithToken(`/api/config/${type}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content, confirmed: true }),
    });
    const finalData = await finalRes.json();
    if (finalData.ok) alert("Saved and MasterDnsVPN restarted");
  }
}

socket.on("update", (data) => {
  document.getElementById("status").innerHTML =
    `CPU: ${data.health.cpu.toFixed(1)}% | RAM: ${data.health.ram.toFixed(1)}% | Net: ${data.speed.rx.toFixed(2)} / ${data.speed.tx.toFixed(2)} MB/s`;
  // chart update logic can be extended here
});

initChart();
