// B-SAFE Admin Console — web version
//
// Mirrors the iOS AdminDashboardView against the same Firebase Realtime
// Database. Uses Firebase Auth (email/password) so the admin signs in with
// the same credentials as in the iOS app, and reads/writes /users/{uid}/…
// directly. Anything that requires iOS-only APIs (FamilyActivityPicker-based
// selections, installing DNS profiles via MobileConfig, enabling the NEFilter
// extension, etc.) still lives in the iOS admin app; this console focuses on
// the things we can do purely from a browser with the same schema.

import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, signInWithEmailAndPassword, signOut,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import {
  getDatabase, ref, onValue, set, push, remove, get, update, off,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-database.js";

// ─── Firebase config ─────────────────────────────────────────────────────────
const firebaseConfig = {
  apiKey: "AIzaSyDQ1Om4fjR9Znj885klnTawL3SmOqKLRsk",
  authDomain: "applerestrictions.firebaseapp.com",
  projectId: "applerestrictions",
  storageBucket: "applerestrictions.firebasestorage.app",
  messagingSenderId: "41899200505",
  appId: "1:41899200505:web:b9fde6692b3ed18efd7728",
  databaseURL: "https://applerestrictions-default-rtdb.firebaseio.com",
};

const app  = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db   = getDatabase(app);

// ─── State ───────────────────────────────────────────────────────────────────
let selectedUID    = null;
let currentConfig  = defaultConfig();
let usersCache     = {};
let activeRefs     = [];      // [{ ref, cb }] to unsubscribe when switching users

// ─── Default config matches iOS ScreenTimeConfiguration decoder defaults ────
function defaultConfig() {
  return {
    id: crypto.randomUUID(),
    deviceId: "",
    deviceName: "",
    lastUpdated: Date.now(),
    blockedApps: [],
    blockedCategories: [],
    blockedAppsSelectionData: null,
    blockedWebsites: [],
    allowedWebsites: [],
    websiteFilterMode: "blacklist",
    appTimeLimits: [],
    downtimeEnabled: false,
    downtimeSchedule: { startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, activeDays: [1,2,3,4,5,6,7] },
    isLocked: false,
    blockNewApps: false,
    contentBlockerEnabled: true,
    forceDNS: false,
    nextDNSProfileID: "",
    nextDNSApiKey: "",
    dnsAlertOnRemoval: true,
    dnsAutoReapply: true,
    dnsRemovalPassword: "",
    safeSearchEnabled: false,
    youtubeRestrictedEnabled: false,
    blockedDNSServices: [],
    blockedDNSCategories: [],
    browserEnabled: true,
    captiveBypassAllowed: true,
    captiveBypassMinutes: 5,
    captiveBypassUntil: 0,
  };
}

// ─── Auth flow ───────────────────────────────────────────────────────────────
onAuthStateChanged(auth, (user) => {
  if (user) {
    document.getElementById("login-screen").classList.add("hidden");
    document.getElementById("app-shell").classList.remove("hidden");
    document.getElementById("admin-email").textContent = user.email;
    startWatchingUsers();
  } else {
    document.getElementById("login-screen").classList.remove("hidden");
    document.getElementById("app-shell").classList.add("hidden");
    tearDownUserSubscriptions();
    selectedUID = null;
  }
});

document.getElementById("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = document.getElementById("login-email").value.trim();
  const pass  = document.getElementById("login-password").value;
  const err   = document.getElementById("login-error");
  err.classList.add("hidden");
  try {
    await signInWithEmailAndPassword(auth, email, pass);
  } catch (e) {
    err.textContent = e.message || String(e);
    err.classList.remove("hidden");
  }
});

document.getElementById("signout-btn").addEventListener("click", () => signOut(auth));

// ─── User list ───────────────────────────────────────────────────────────────
function startWatchingUsers() {
  const usersRef = ref(db, "users");
  const cb = onValue(usersRef, (snap) => {
    usersCache = snap.val() || {};
    renderUserList();
    if (selectedUID && usersCache[selectedUID]) {
      renderUserPanel();  // keep the open user fresh on change
    }
  });
  activeRefs.push({ ref: usersRef, cb });
}

function renderUserList() {
  const list = document.getElementById("user-list");
  const ids  = Object.keys(usersCache);
  if (ids.length === 0) {
    list.innerHTML = `<div class="empty-state-small">No users yet</div>`;
    return;
  }
  const rows = ids.map((uid) => {
    const info = usersCache[uid]?.info || {};
    const online = !!info.isOnline;
    const name = info.displayName || info.deviceName || info.email || uid.slice(0, 8);
    return { uid, name, sub: info.deviceName || info.email || "", online };
  }).sort((a, b) => (a.online === b.online ? a.name.localeCompare(b.name) : (a.online ? -1 : 1)));

  list.innerHTML = rows.map((r) => `
    <div class="device-item ${r.uid === selectedUID ? "active" : ""}" data-uid="${r.uid}">
      <span class="device-item-icon">📱</span>
      <div class="device-item-info">
        <div class="device-item-name">${escapeHtml(r.name)}</div>
        <div class="device-item-sub">${escapeHtml(r.sub)}</div>
      </div>
      <div class="device-online-dot ${r.online ? "dot-online" : "dot-offline"}"></div>
    </div>
  `).join("");

  list.querySelectorAll(".device-item").forEach((el) => {
    el.addEventListener("click", () => selectUser(el.dataset.uid));
  });
}

document.getElementById("refresh-btn").addEventListener("click", () => {
  if (selectedUID) renderUserPanel();
});

// ─── Select user ─────────────────────────────────────────────────────────────
function selectUser(uid) {
  if (selectedUID === uid) return;
  selectedUID = uid;
  document.getElementById("empty-panel").classList.add("hidden");
  document.getElementById("user-panel").classList.remove("hidden");
  renderUserList();
  renderUserPanel();
  subscribeUserStreams(uid);
}

function subscribeUserStreams(uid) {
  tearDownUserSubscriptions();

  const settingsRef = ref(db, `users/${uid}/settings`);
  const sCb = onValue(settingsRef, (snap) => {
    currentConfig = { ...defaultConfig(), ...(snap.val() || {}) };
    applyConfigToUI(currentConfig);
  });
  activeRefs.push({ ref: settingsRef, cb: sCb });

  const tamperRef = ref(db, `users/${uid}/tamperAlerts`);
  const tCb = onValue(tamperRef, (snap) => renderTamperAlerts(snap.val() || {}));
  activeRefs.push({ ref: tamperRef, cb: tCb });

  const unlockRef = ref(db, `users/${uid}/unlockRequests`);
  const uCb = onValue(unlockRef, (snap) => renderUnlockRequests(snap.val() || {}));
  activeRefs.push({ ref: unlockRef, cb: uCb });

  const webReqRef = ref(db, `users/${uid}/websiteRequests`);
  const wCb = onValue(webReqRef, (snap) => renderWebsiteRequests(snap.val() || {}));
  activeRefs.push({ ref: webReqRef, cb: wCb });
}

function tearDownUserSubscriptions() {
  activeRefs.forEach(({ ref: r }) => off(r));
  activeRefs = [];
}

// ─── Render user panel ───────────────────────────────────────────────────────
function renderUserPanel() {
  const info = usersCache[selectedUID]?.info || {};
  document.getElementById("user-name").textContent     = info.displayName || info.email || "User";
  document.getElementById("user-device").textContent   = info.deviceName || "—";
  const online = !!info.isOnline;
  const s = document.getElementById("user-status");
  s.textContent = online ? "Online" : "Offline";
  s.className   = "status-badge " + (online ? "status-online" : "status-offline");
  document.getElementById("user-lastseen").textContent = info.lastSeen ? `last seen ${formatRelative(info.lastSeen)}` : "";
}

function applyConfigToUI(c) {
  // Filter mode
  setFilterMode(c.websiteFilterMode || "blacklist");
  renderDomainList("blocked-list",  c.blockedWebsites || [], "blockedWebsites");
  renderDomainList("allowed-list",  c.allowedWebsites || [], "allowedWebsites");
  document.getElementById("blocked-count").textContent = (c.blockedWebsites || []).length;
  document.getElementById("allowed-count").textContent = (c.allowedWebsites || []).length;

  // Toggles
  document.getElementById("toggle-content-blocker").checked  = !!c.contentBlockerEnabled;
  document.getElementById("toggle-browser-enabled").checked  = c.browserEnabled !== false;
  document.getElementById("toggle-block-new-apps").checked   = !!c.blockNewApps;

  // Captive portal bypass
  document.getElementById("toggle-captive-allowed").checked  = c.captiveBypassAllowed !== false;
  document.getElementById("captive-minutes").value           = c.captiveBypassMinutes || 5;
  document.getElementById("captive-duration-field").classList.toggle("hidden", c.captiveBypassAllowed === false);
  renderCaptiveCountdown(c.captiveBypassUntil || 0);

  // DNS
  document.getElementById("toggle-force-dns").checked         = !!c.forceDNS;
  document.getElementById("dns-profile-id").value             = c.nextDNSProfileID || "";
  document.getElementById("dns-removal-password").value       = c.dnsRemovalPassword || "";
  document.getElementById("toggle-dns-alert").checked         = c.dnsAlertOnRemoval !== false;
  document.getElementById("toggle-safesearch").checked        = !!c.safeSearchEnabled;
  document.getElementById("toggle-youtube-restricted").checked = !!c.youtubeRestrictedEnabled;
  document.getElementById("dns-config").classList.toggle("hidden", !c.forceDNS);

  // Downtime
  document.getElementById("downtime-toggle").checked = !!c.downtimeEnabled;
  const s = c.downtimeSchedule || defaultConfig().downtimeSchedule;
  document.getElementById("downtime-start").value = formatTime(s.startHour, s.startMinute);
  document.getElementById("downtime-end").value   = formatTime(s.endHour,   s.endMinute);
  document.querySelectorAll(".day").forEach((btn) => {
    const day = parseInt(btn.dataset.day);
    const active = (s.activeDays || [1,2,3,4,5,6,7]).includes(day);
    btn.classList.toggle("active", active);
  });

  // Time limits
  renderLimits(c.appTimeLimits || []);
}

// ─── Filter mode ─────────────────────────────────────────────────────────────
function setFilterMode(mode) {
  const bl = document.getElementById("mode-blacklist");
  const wl = document.getElementById("mode-whitelist");
  bl.classList.toggle("active", mode === "blacklist");
  wl.classList.toggle("active", mode === "whitelist");
  document.getElementById("blocked-sites-card").classList.toggle("hidden", mode !== "blacklist");
  document.getElementById("allowed-sites-card").classList.toggle("hidden", mode !== "whitelist");
  document.getElementById("filter-mode-hint").textContent = mode === "blacklist"
    ? "Listed sites are blocked. Empty list = unrestricted."
    : "Only listed sites are allowed. Everything else is blocked.";
  currentConfig.websiteFilterMode = mode;
}
document.getElementById("mode-blacklist").addEventListener("click", () => setFilterMode("blacklist"));
document.getElementById("mode-whitelist").addEventListener("click", () => setFilterMode("whitelist"));

// ─── Domain lists ────────────────────────────────────────────────────────────
function renderDomainList(elID, domains, fieldName) {
  const ul = document.getElementById(elID);
  ul.innerHTML = domains.map((d, i) => `
    <li>
      <span>${escapeHtml(d)}</span>
      <button class="btn-chip" data-field="${fieldName}" data-index="${i}">Remove</button>
    </li>
  `).join("");
  ul.querySelectorAll("button.btn-chip").forEach((b) => {
    b.addEventListener("click", () => {
      currentConfig[fieldName].splice(parseInt(b.dataset.index), 1);
      applyConfigToUI(currentConfig);
    });
  });
}

function normalizeDomain(raw) {
  return raw.trim().toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/^www\./, "")
    .split("/")[0];
}

document.getElementById("blocked-add").addEventListener("click", () => {
  const d = normalizeDomain(document.getElementById("blocked-input").value);
  if (!d) return;
  if (!(currentConfig.blockedWebsites || []).includes(d)) {
    currentConfig.blockedWebsites = [...(currentConfig.blockedWebsites || []), d];
  }
  document.getElementById("blocked-input").value = "";
  applyConfigToUI(currentConfig);
});
document.getElementById("allowed-add").addEventListener("click", () => {
  const d = normalizeDomain(document.getElementById("allowed-input").value);
  if (!d) return;
  if (!(currentConfig.allowedWebsites || []).includes(d)) {
    currentConfig.allowedWebsites = [...(currentConfig.allowedWebsites || []), d];
  }
  document.getElementById("allowed-input").value = "";
  applyConfigToUI(currentConfig);
});

// ─── Time limits ─────────────────────────────────────────────────────────────
function renderLimits(limits) {
  const ul = document.getElementById("limits-list");
  document.getElementById("limits-count").textContent = limits.length;
  if (limits.length === 0) {
    ul.innerHTML = `<li class="empty-state-small">No time limits. Create them from the iOS admin app.</li>`;
    return;
  }
  ul.innerHTML = limits.map((l) => `
    <li class="limit-row">
      <div class="limit-info">
        <strong>${escapeHtml(l.displayName || "Untitled")}</strong>
        <small>${l.enabled === false ? "Paused" : "Active"}</small>
      </div>
      <input type="number" min="1" max="480" step="1" value="${l.timeLimitMinutes || 30}" data-id="${l.id}" class="limit-minutes" />
      <span class="limit-unit">min</span>
      <label class="limit-toggle"><input type="checkbox" ${l.enabled === false ? "" : "checked"} data-id="${l.id}" class="limit-enabled" /> on</label>
      <button class="btn-chip danger" data-id="${l.id}">Delete</button>
    </li>
  `).join("");

  ul.querySelectorAll(".limit-minutes").forEach((el) => {
    el.addEventListener("change", () => {
      const i = currentConfig.appTimeLimits.findIndex((l) => l.id === el.dataset.id);
      if (i >= 0) currentConfig.appTimeLimits[i].timeLimitMinutes = Math.max(1, parseInt(el.value) || 1);
    });
  });
  ul.querySelectorAll(".limit-enabled").forEach((el) => {
    el.addEventListener("change", () => {
      const i = currentConfig.appTimeLimits.findIndex((l) => l.id === el.dataset.id);
      if (i >= 0) currentConfig.appTimeLimits[i].enabled = el.checked;
    });
  });
  ul.querySelectorAll(".btn-chip.danger").forEach((el) => {
    el.addEventListener("click", () => {
      currentConfig.appTimeLimits = currentConfig.appTimeLimits.filter((l) => l.id !== el.dataset.id);
      renderLimits(currentConfig.appTimeLimits);
    });
  });
}

// ─── Apply handlers ──────────────────────────────────────────────────────────
async function pushSettings() {
  if (!selectedUID) return;
  currentConfig.lastUpdated = Date.now();
  await set(ref(db, `users/${selectedUID}/settings`), currentConfig);
}

async function sendCommand(type, payload = {}) {
  if (!selectedUID) return;
  const cmd = {
    id: crypto.randomUUID(),
    timestamp: Date.now(),
    type, payload, executed: false,
  };
  await push(ref(db, `users/${selectedUID}/commands`), cmd);
}

document.getElementById("apply-websites").addEventListener("click", async () => {
  currentConfig.contentBlockerEnabled = document.getElementById("toggle-content-blocker").checked;
  currentConfig.browserEnabled        = document.getElementById("toggle-browser-enabled").checked;
  currentConfig.captiveBypassAllowed  = document.getElementById("toggle-captive-allowed").checked;
  currentConfig.captiveBypassMinutes  = Math.max(1, Math.min(15,
    parseInt(document.getElementById("captive-minutes").value) || 5));
  await pushSettings();
  await sendCommand("updateWebsites");
  toast("Website settings applied");
});

document.getElementById("toggle-captive-allowed").addEventListener("change", (e) => {
  document.getElementById("captive-duration-field").classList.toggle("hidden", !e.target.checked);
});

document.getElementById("captive-close-now").addEventListener("click", async () => {
  currentConfig.captiveBypassUntil = 0;
  await pushSettings();
  await sendCommand("updateWebsites");
  toast("Captive bypass closed");
});

// Re-render the countdown once a second so the admin sees it tick down.
setInterval(() => {
  if (currentConfig && currentConfig.captiveBypassUntil) {
    renderCaptiveCountdown(currentConfig.captiveBypassUntil);
  }
}, 1000);

function renderCaptiveCountdown(until) {
  const active = document.getElementById("captive-active");
  if (!until) { active.classList.add("hidden"); return; }
  const remaining = Math.max(0, until - Date.now() / 1000);
  if (remaining <= 0) { active.classList.add("hidden"); return; }
  active.classList.remove("hidden");
  const m = Math.floor(remaining / 60);
  const s = Math.floor(remaining % 60);
  document.getElementById("captive-countdown").textContent = `${m}m ${s}s remaining`;
}

document.getElementById("apply-dns").addEventListener("click", async () => {
  currentConfig.forceDNS                  = document.getElementById("toggle-force-dns").checked;
  currentConfig.nextDNSProfileID          = document.getElementById("dns-profile-id").value.trim();
  currentConfig.dnsRemovalPassword        = document.getElementById("dns-removal-password").value;
  currentConfig.dnsAlertOnRemoval         = document.getElementById("toggle-dns-alert").checked;
  currentConfig.safeSearchEnabled         = document.getElementById("toggle-safesearch").checked;
  currentConfig.youtubeRestrictedEnabled  = document.getElementById("toggle-youtube-restricted").checked;
  await pushSettings();
  await sendCommand("refreshSettings");
  toast("DNS settings applied");
});

document.getElementById("apply-downtime").addEventListener("click", async () => {
  const startParts = document.getElementById("downtime-start").value.split(":");
  const endParts   = document.getElementById("downtime-end").value.split(":");
  const activeDays = [];
  document.querySelectorAll(".day.active").forEach((btn) => activeDays.push(parseInt(btn.dataset.day)));
  currentConfig.downtimeEnabled  = document.getElementById("downtime-toggle").checked;
  currentConfig.downtimeSchedule = {
    startHour:   parseInt(startParts[0]),
    startMinute: parseInt(startParts[1]),
    endHour:     parseInt(endParts[0]),
    endMinute:   parseInt(endParts[1]),
    activeDays,
  };
  await pushSettings();
  await sendCommand("updateDowntime");
  toast("Downtime applied");
});

document.getElementById("apply-apps").addEventListener("click", async () => {
  currentConfig.blockNewApps = document.getElementById("toggle-block-new-apps").checked;
  await pushSettings();
  await sendCommand("updateBlockedApps");
  toast("App settings applied");
});

document.getElementById("lock-btn").addEventListener("click", async () => {
  currentConfig.isLocked = true;
  await pushSettings();
  await sendCommand("lockDevice");
  toast("Locked");
});
document.getElementById("unlock-btn").addEventListener("click", async () => {
  currentConfig.isLocked = false;
  await pushSettings();
  await sendCommand("unlockAll");
  toast("Unlocked");
});
document.getElementById("refresh-settings-btn").addEventListener("click", async () => {
  await sendCommand("refreshSettings");
  toast("Refresh command sent");
});

document.getElementById("toggle-force-dns").addEventListener("change", (e) => {
  document.getElementById("dns-config").classList.toggle("hidden", !e.target.checked);
});

// Day buttons
document.querySelectorAll(".day").forEach((btn) => {
  btn.addEventListener("click", () => btn.classList.toggle("active"));
});

// Tab switching
document.querySelectorAll(".tab").forEach((t) => {
  t.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((x) => x.classList.toggle("active", x === t));
    const page = t.dataset.tab;
    document.querySelectorAll(".tab-page").forEach((p) => {
      p.classList.toggle("hidden", p.dataset.page !== page);
    });
  });
});

// ─── Tamper alerts ───────────────────────────────────────────────────────────
function renderTamperAlerts(dict) {
  const container = document.getElementById("tamper-banners");
  const entries = Object.entries(dict)
    .filter(([_, a]) => a && !a.dismissed)
    .sort((a, b) => (b[1].timestamp || 0) - (a[1].timestamp || 0));
  if (entries.length === 0) { container.innerHTML = ""; return; }
  container.innerHTML = entries.map(([key, a]) => `
    <div class="tamper-banner">
      <div>
        <strong>⚠️ Tamper detected</strong>
        <div>${escapeHtml(a.message || a.type || "")}</div>
        <small>${formatRelative(a.timestamp)}</small>
      </div>
      <button class="btn-chip" data-key="${key}">Dismiss</button>
    </div>
  `).join("");
  container.querySelectorAll("button.btn-chip").forEach((b) => {
    b.addEventListener("click", async () => {
      await remove(ref(db, `users/${selectedUID}/tamperAlerts/${b.dataset.key}`));
    });
  });
}

// ─── Requests ────────────────────────────────────────────────────────────────
function renderUnlockRequests(dict) {
  const ul = document.getElementById("unlock-requests");
  const entries = Object.entries(dict);
  if (entries.length === 0) {
    ul.innerHTML = `<li class="empty-state-small">No pending unlock requests.</li>`;
    return;
  }
  ul.innerHTML = entries.map(([key, r]) => `
    <li class="request-row">
      <div>
        <strong>${escapeHtml(r.deviceName || "Device")}</strong>
        <div>${escapeHtml(r.reason || "(no reason given)")}</div>
        <small>${formatRelative(r.timestamp)}</small>
      </div>
      <div class="request-actions">
        <button class="btn btn-success" data-action="approve-unlock"  data-key="${key}">Approve</button>
        <button class="btn btn-danger"  data-action="deny-unlock"     data-key="${key}">Deny</button>
      </div>
    </li>
  `).join("");
  ul.querySelectorAll("button").forEach((b) => {
    b.addEventListener("click", async () => {
      const key = b.dataset.key;
      if (b.dataset.action === "approve-unlock") {
        currentConfig.isLocked = false;
        await pushSettings();
        await sendCommand("unlockAll");
        await pushNotification("✅ Unlock Approved", "Your device has been unlocked.");
      } else {
        await pushNotification("❌ Unlock Denied", "Your request was denied.");
      }
      await remove(ref(db, `users/${selectedUID}/unlockRequests/${key}`));
    });
  });
}

function renderWebsiteRequests(dict) {
  const ul = document.getElementById("website-requests");
  const entries = Object.entries(dict);
  if (entries.length === 0) {
    ul.innerHTML = `<li class="empty-state-small">No pending website requests.</li>`;
    return;
  }
  ul.innerHTML = entries.map(([key, r]) => `
    <li class="request-row">
      <div>
        <strong>${escapeHtml(r.domain || "")}</strong>
        <div>${escapeHtml(r.reason || "(no reason given)")}</div>
        <small>${escapeHtml(r.deviceName || "")} · ${formatRelative(r.timestamp)}</small>
      </div>
      <div class="request-actions">
        <button class="btn btn-success" data-action="approve-site" data-key="${key}" data-domain="${escapeAttr(r.domain || "")}">Approve</button>
        <button class="btn btn-danger"  data-action="deny-site"    data-key="${key}">Deny</button>
      </div>
    </li>
  `).join("");
  ul.querySelectorAll("button").forEach((b) => {
    b.addEventListener("click", async () => {
      const key = b.dataset.key;
      if (b.dataset.action === "approve-site") {
        const domain = b.dataset.domain;
        if (domain && !(currentConfig.allowedWebsites || []).includes(domain)) {
          currentConfig.allowedWebsites = [...(currentConfig.allowedWebsites || []), domain];
        }
        currentConfig.websiteFilterMode = "whitelist";
        await pushSettings();
        await sendCommand("updateWebsites");
        await pushNotification("✅ Website Approved", `${domain} has been added to your allowed list.`);
      } else {
        await pushNotification("❌ Website Denied", "Your website request was denied.");
      }
      await remove(ref(db, `users/${selectedUID}/websiteRequests/${key}`));
    });
  });
}

// ─── Push notification to child (writes to /notifications; iOS turns it into a local UN) ─
async function pushNotification(title, body) {
  if (!selectedUID) return;
  const payload = {
    id: crypto.randomUUID(),
    title, body,
    timestamp: Date.now(),
  };
  await push(ref(db, `users/${selectedUID}/notifications`), payload);
}

document.getElementById("notify-send").addEventListener("click", async () => {
  const t = document.getElementById("notify-title").value.trim();
  const b = document.getElementById("notify-body").value.trim();
  if (!b) return;
  await pushNotification(t, b);
  document.getElementById("notify-title").value = "";
  document.getElementById("notify-body").value = "";
  toast("Notification sent");
});

// ─── Helpers ─────────────────────────────────────────────────────────────────
function formatTime(hour, minute) {
  return `${String(hour || 0).padStart(2, "0")}:${String(minute || 0).padStart(2, "0")}`;
}

function formatRelative(ts) {
  if (!ts) return "";
  const when = typeof ts === "number" ? ts : Date.parse(ts);
  if (!when) return "";
  const diff = Math.max(0, Date.now() - when);
  const sec  = Math.floor(diff / 1000);
  if (sec < 60)    return `${sec}s ago`;
  if (sec < 3600)  return `${Math.floor(sec / 60)}m ago`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ago`;
  return `${Math.floor(sec / 86400)}d ago`;
}

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}
function escapeAttr(s) { return escapeHtml(s).replace(/`/g, "&#96;"); }

let toastTimer;
function toast(msg) {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add("hidden"), 2500);
}
