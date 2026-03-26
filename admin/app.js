import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getDatabase, ref, onValue, set, push, remove, get } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-database.js";

// ─── Firebase Config ────────────────────────────────────────────────────────
const firebaseConfig = {
  apiKey: "AIzaSyDQ1Om4fjR9Znj885klnTawL3SmOqKLRsk",
  authDomain: "applerestrictions.firebaseapp.com",
  projectId: "applerestrictions",
  storageBucket: "applerestrictions.firebasestorage.app",
  messagingSenderId: "41899200505",
  appId: "1:41899200505:web:b9fde6692b3ed18efd7728",
  databaseURL: "https://applerestrictions-default-rtdb.firebaseio.com",
};

const app = initializeApp(firebaseConfig);
const db  = getDatabase(app);

// ─── App State ───────────────────────────────────────────────────────────────
let selectedDeviceId = null;
let commandLog = [];

// Predefined app categories (mirrors Apple's ActivityCategory)
const APP_CATEGORIES = [
  "Social Networking", "Entertainment", "Games", "Education",
  "Productivity", "Health & Fitness", "Shopping", "News",
  "Music", "Video", "Finance", "Travel",
];

// Common apps for quick blocking
const COMMON_APPS = [
  "Safari", "Instagram", "TikTok", "YouTube", "Snapchat",
  "Twitter / X", "Facebook", "Reddit", "Discord", "Twitch",
  "Netflix", "Spotify", "Messages", "FaceTime",
];

// Which ones are currently selected (blocked)
const selectedCategories = new Set();
const selectedApps       = new Set();

// ─── Init ────────────────────────────────────────────────────────────────────
buildTagGrids();
listenToDevices();
document.getElementById("refresh-btn").addEventListener("click", listenToDevices);

// ─── Firebase Listeners ──────────────────────────────────────────────────────
function listenToDevices() {
  const devicesRef = ref(db, "devices");
  onValue(devicesRef, (snapshot) => {
    const data = snapshot.val() || {};
    renderDeviceList(data);

    // If a device is selected, refresh its panel
    if (selectedDeviceId && data[selectedDeviceId]) {
      loadDeviceSettings(selectedDeviceId, data[selectedDeviceId]);
    }
  });
}

// ─── Device List ─────────────────────────────────────────────────────────────
function renderDeviceList(devicesData) {
  const list = document.getElementById("device-list");
  const ids  = Object.keys(devicesData);

  if (ids.length === 0) {
    list.innerHTML = `<div class="empty-state-small">No devices connected</div>`;
    return;
  }

  list.innerHTML = "";
  ids.forEach((id) => {
    const device = devicesData[id]?.info || {};
    const isOnline = isDeviceOnline(device.lastSeen);

    const item = document.createElement("div");
    item.className = "device-item" + (id === selectedDeviceId ? " active" : "");
    item.dataset.id = id;
    item.innerHTML = `
      <span class="device-item-icon">📱</span>
      <div class="device-item-info">
        <div class="device-item-name">${device.name || "Unknown Device"}</div>
        <div class="device-item-sub">${device.model || ""}</div>
      </div>
      <div class="device-online-dot ${isOnline ? "dot-online" : "dot-offline"}"></div>
    `;
    item.addEventListener("click", () => selectDevice(id, devicesData[id]));
    list.appendChild(item);
  });
}

function isDeviceOnline(lastSeen) {
  if (!lastSeen) return false;
  const last = new Date(lastSeen);
  return Date.now() - last.getTime() < 5 * 60 * 1000; // online within 5 min
}

// ─── Select Device ───────────────────────────────────────────────────────────
function selectDevice(id, deviceData) {
  selectedDeviceId = id;

  // Update sidebar active state
  document.querySelectorAll(".device-item").forEach((el) => {
    el.classList.toggle("active", el.dataset.id === id);
  });

  document.getElementById("empty-panel").classList.add("hidden");
  document.getElementById("device-panel").classList.remove("hidden");

  loadDeviceSettings(id, deviceData);
  listenToCommandLog(id);
}

// ─── Load Settings into Panel ────────────────────────────────────────────────
function loadDeviceSettings(id, deviceData) {
  const info     = deviceData?.info     || {};
  const settings = deviceData?.settings || {};

  // Header
  document.getElementById("device-name").textContent  = info.name    || "Unknown Device";
  document.getElementById("device-model").textContent = info.model   || "";
  document.getElementById("device-os").textContent    = "iOS " + (info.osVersion || "—");

  const isOnline = isDeviceOnline(info.lastSeen);
  const statusEl = document.getElementById("device-status");
  statusEl.textContent  = isOnline ? "Online" : "Offline";
  statusEl.className    = "status-badge " + (isOnline ? "status-online" : "status-offline");

  // Blocked categories / apps
  selectedCategories.clear();
  selectedApps.clear();

  (settings.blockedCategories || []).forEach((c) => selectedCategories.add(c));
  (settings.blockedApps || []).forEach((a) => selectedApps.add(a));

  refreshTagHighlights();

  // Downtime
  const downtimeEnabled = settings.downtimeEnabled || false;
  document.getElementById("downtime-toggle").checked = downtimeEnabled;
  if (settings.downtimeSchedule) {
    const s = settings.downtimeSchedule;
    document.getElementById("downtime-start").value = formatTime(s.startHour, s.startMinute);
    document.getElementById("downtime-end").value   = formatTime(s.endHour,   s.endMinute);

    // Days
    document.querySelectorAll(".day").forEach((btn) => {
      const day = parseInt(btn.dataset.day);
      const activeDays = s.activeDays || [1,2,3,4,5,6,7];
      btn.classList.toggle("active", activeDays.includes(day));
    });
  }

  // Time limit
  if (settings.appTimeLimits?.length > 0) {
    const limit = settings.appTimeLimits[0].timeLimitMinutes || 60;
    document.getElementById("time-limit-slider").value = limit;
    updateTimeLimitLabel(limit);
    document.getElementById("timelimit-toggle").checked = true;
  }
}

// ─── Add Device Modal ────────────────────────────────────────────────────────
let pairWatchUnsubscribe = null;

document.getElementById("add-device-btn").addEventListener("click", () => {
  document.getElementById("modal-overlay").classList.remove("hidden");
  document.getElementById("modal-step-1").classList.remove("hidden");
  document.getElementById("modal-step-2").classList.add("hidden");
  document.getElementById("new-device-label").value = "";
  document.getElementById("paired-success").classList.add("hidden");
  document.getElementById("waiting-indicator").classList.remove("hidden");
});

window.closeAddDeviceModal = function () {
  document.getElementById("modal-overlay").classList.add("hidden");
  if (pairWatchUnsubscribe) { pairWatchUnsubscribe(); pairWatchUnsubscribe = null; }
};

window.closeModal = function (event) {
  if (event.target === document.getElementById("modal-overlay")) {
    closeAddDeviceModal();
  }
};

window.generateAdminPairCode = async function () {
  const label = document.getElementById("new-device-label").value.trim();
  if (!label) {
    document.getElementById("new-device-label").focus();
    return;
  }

  const code = String(Math.floor(100000 + Math.random() * 900000));
  document.getElementById("pairing-code-text").textContent = code;

  // Store the pending pairing entry in Firebase so the iOS app can find it
  await set(ref(db, `pairing/${code}`), {
    adminLabel: label,
    createdAt:  new Date().toISOString(),
    pending:    true,
  });

  // Switch to step 2
  document.getElementById("modal-step-1").classList.add("hidden");
  document.getElementById("modal-step-2").classList.remove("hidden");

  // Watch for the iOS app to register under this code
  watchForPairing(code);

  // Auto-expire code after 10 minutes
  setTimeout(async () => {
    const snap = await get(ref(db, `pairing/${code}`));
    if (snap.exists() && snap.val().pending) {
      await remove(ref(db, `pairing/${code}`));
    }
  }, 10 * 60 * 1000);
};

function watchForPairing(code) {
  if (pairWatchUnsubscribe) pairWatchUnsubscribe();

  const pairRef = ref(db, `pairing/${code}`);
  pairWatchUnsubscribe = onValue(pairRef, async (snap) => {
    const data = snap.val();
    if (!data) return;

    // iOS app fills in device info; once 'pending' is gone or device info appears
    if (data.id || data.name) {
      // Device registered — mark as paired
      document.getElementById("waiting-indicator").classList.add("hidden");
      document.getElementById("paired-success").classList.remove("hidden");
      showToast("✅ Device connected!");

      // Clean up pairing entry
      await remove(pairRef);

      if (pairWatchUnsubscribe) { pairWatchUnsubscribe(); pairWatchUnsubscribe = null; }
    }
  });
}

// ─── Tag Grids ───────────────────────────────────────────────────────────────
function buildTagGrids() {
  const catGrid = document.getElementById("category-grid");
  APP_CATEGORIES.forEach((cat) => {
    const tag = document.createElement("button");
    tag.className    = "tag";
    tag.textContent  = cat;
    tag.dataset.name = cat;
    tag.addEventListener("click", () => toggleTag(tag, selectedCategories, cat));
    catGrid.appendChild(tag);
  });

  const appGrid = document.getElementById("app-grid");
  COMMON_APPS.forEach((appName) => {
    const tag = document.createElement("button");
    tag.className    = "tag";
    tag.textContent  = appName;
    tag.dataset.name = appName;
    tag.addEventListener("click", () => toggleTag(tag, selectedApps, appName));
    appGrid.appendChild(tag);
  });
}

function toggleTag(el, set_, value) {
  if (set_.has(value)) {
    set_.delete(value);
    el.classList.remove("selected");
  } else {
    set_.add(value);
    el.classList.add("selected");
  }
}

function refreshTagHighlights() {
  document.querySelectorAll("#category-grid .tag").forEach((tag) => {
    tag.classList.toggle("selected", selectedCategories.has(tag.dataset.name));
  });
  document.querySelectorAll("#app-grid .tag").forEach((tag) => {
    tag.classList.toggle("selected", selectedApps.has(tag.dataset.name));
  });
}

// ─── Apply Actions ───────────────────────────────────────────────────────────
window.applyRestrictions = async function () {
  if (!selectedDeviceId) return;

  const settings = await getCurrentSettings();
  settings.blockedCategories = Array.from(selectedCategories);
  settings.blockedApps       = Array.from(selectedApps);
  settings.lastUpdated       = new Date().toISOString();

  await pushSettings(settings);
  await sendCommand("updateBlockedApps");
  showToast("App restrictions applied ✓");
};

window.applyDowntime = async function () {
  if (!selectedDeviceId) return;

  const startParts = document.getElementById("downtime-start").value.split(":");
  const endParts   = document.getElementById("downtime-end").value.split(":");

  const activeDays = [];
  document.querySelectorAll(".day.active").forEach((btn) => {
    activeDays.push(parseInt(btn.dataset.day));
  });

  const settings = await getCurrentSettings();
  settings.downtimeEnabled  = document.getElementById("downtime-toggle").checked;
  settings.downtimeSchedule = {
    startHour:   parseInt(startParts[0]),
    startMinute: parseInt(startParts[1]),
    endHour:     parseInt(endParts[0]),
    endMinute:   parseInt(endParts[1]),
    activeDays,
  };
  settings.lastUpdated = new Date().toISOString();

  await pushSettings(settings);
  await sendCommand("updateDowntime");
  showToast("Downtime schedule applied ✓");
};

window.applyTimeLimit = async function () {
  if (!selectedDeviceId) return;

  const minutes  = parseInt(document.getElementById("time-limit-slider").value);
  const enabled  = document.getElementById("timelimit-toggle").checked;

  const settings = await getCurrentSettings();
  settings.appTimeLimits = enabled
    ? [{ id: "daily-limit", displayName: "Daily Limit", timeLimitMinutes: minutes }]
    : [];
  settings.lastUpdated = new Date().toISOString();

  await pushSettings(settings);
  await sendCommand("updateTimeLimits");
  showToast(`Time limit set to ${minutes} min ✓`);
};

window.toggleDowntime = function (checkbox) {
  document.getElementById("downtime-config").style.opacity = checkbox.checked ? "1" : "0.4";
};

window.sendCommand = async function (type) {
  if (!selectedDeviceId) return;

  const command = {
    id:        crypto.randomUUID(),
    type,
    timestamp: new Date().toISOString(),
    executed:  false,
    payload:   {},
  };

  await push(ref(db, `devices/${selectedDeviceId}/commands`), command);

  // Local log
  commandLog.unshift(command);
  renderCommandLog();

  const labels = {
    lockDevice:      "🔒 Lock All",
    unlockAll:       "🔓 Unlock All",
    refreshSettings: "↺ Refresh",
    updateBlockedApps: "🛡 Update Blocked Apps",
    updateDowntime:  "🌙 Update Downtime",
    updateTimeLimits: "⏱ Update Time Limits",
  };
  showToast(`${labels[type] || type} sent ✓`);
};

// ─── Settings Helpers ────────────────────────────────────────────────────────
async function getCurrentSettings() {
  const snap = await get(ref(db, `devices/${selectedDeviceId}/settings`));
  return snap.val() || {
    id:               crypto.randomUUID(),
    deviceId:         selectedDeviceId,
    blockedApps:      [],
    blockedCategories: [],
    appTimeLimits:    [],
    downtimeEnabled:  false,
    downtimeSchedule: { startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, activeDays: [1,2,3,4,5,6,7] },
    shieldApps:       true,
    shieldWebDomains: true,
  };
}

async function pushSettings(settings) {
  await set(ref(db, `devices/${selectedDeviceId}/settings`), settings);
}

// ─── Command Log ─────────────────────────────────────────────────────────────
function listenToCommandLog(deviceId) {
  onValue(ref(db, `devices/${deviceId}/commands`), (snap) => {
    const data = snap.val() || {};
    commandLog = Object.values(data)
      .sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp))
      .slice(0, 20);
    renderCommandLog();
  });
}

function renderCommandLog() {
  const el = document.getElementById("command-log");

  if (commandLog.length === 0) {
    el.innerHTML = `<div class="empty-state-small">No commands sent yet</div>`;
    return;
  }

  const icons = {
    lockDevice:        "🔒",
    unlockAll:         "🔓",
    refreshSettings:   "↺",
    updateBlockedApps: "🛡",
    updateDowntime:    "🌙",
    updateTimeLimits:  "⏱",
  };

  const labels = {
    lockDevice:        "Lock All Apps",
    unlockAll:         "Unlock All Apps",
    refreshSettings:   "Refresh Settings",
    updateBlockedApps: "Update Blocked Apps",
    updateDowntime:    "Update Downtime",
    updateTimeLimits:  "Update Time Limits",
  };

  el.innerHTML = commandLog.map((cmd) => `
    <div class="command-entry">
      <span class="command-entry-icon">${icons[cmd.type] || "•"}</span>
      <span class="command-entry-type">${labels[cmd.type] || cmd.type}</span>
      <span class="command-entry-time">${relativeTime(cmd.timestamp)}</span>
      <span style="font-size:11px;color:${cmd.executed ? "#22c55e" : "#888"}">${cmd.executed ? "done" : "pending"}</span>
    </div>
  `).join("");
}

window.clearCommands = async function () {
  if (!selectedDeviceId) return;
  await remove(ref(db, `devices/${selectedDeviceId}/commands`));
  commandLog = [];
  renderCommandLog();
};

// ─── Day Buttons ─────────────────────────────────────────────────────────────
document.querySelectorAll(".day").forEach((btn) => {
  btn.addEventListener("click", () => btn.classList.toggle("active"));
});

// ─── Helpers ─────────────────────────────────────────────────────────────────
window.updateTimeLimitLabel = function (val) {
  const mins = parseInt(val);
  const label = mins >= 60
    ? `${Math.floor(mins / 60)}h ${mins % 60 > 0 ? (mins % 60) + "m" : ""}`.trim()
    : `${mins} min`;
  document.getElementById("time-limit-label").textContent = label;
};

function formatTime(hour, minute) {
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function relativeTime(isoString) {
  const diff = Date.now() - new Date(isoString).getTime();
  const sec  = Math.floor(diff / 1000);
  if (sec < 60)  return `${sec}s ago`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m ago`;
  return `${Math.floor(sec / 3600)}h ago`;
}

let toastTimer;
function showToast(msg) {
  const toast = document.getElementById("toast");
  toast.textContent = msg;
  toast.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.add("hidden"), 2500);
}
