import { ref, get, set, update, onValue, off, remove, push, DataSnapshot } from "firebase/database";
import { db } from "./firebase";
import { ManagedUser, ScreenTimeConfiguration, defaultConfig, TamperAlert, UnlockRequest, WebsiteRequest, RecommendedApp, AppRequest, InstalledApp } from "./types";

export async function loadUsers(): Promise<ManagedUser[]> {
  const snap = await get(ref(db, "users"));
  if (!snap.exists()) return [];
  const out: ManagedUser[] = [];
  snap.forEach((child: DataSnapshot) => {
    const info = child.child("info").val() || {};
    if (info.email) {
      out.push({
        uid: child.key!,
        email: info.email,
        displayName: info.displayName || "",
        deviceName: info.deviceName || "Unknown Device",
        isOnline: !!info.isOnline,
        lastSeen: Number(info.lastSeen) || 0,
      });
    }
    return false;
  });
  return out.sort((a, b) => {
    if (a.isOnline !== b.isOnline) return a.isOnline ? -1 : 1;
    // Most-recently-seen first; lastSeen is Unix ms.
    return (b.lastSeen || 0) - (a.lastSeen || 0);
  });
}

export async function loadConfig(uid: string): Promise<ScreenTimeConfiguration> {
  const snap = await get(ref(db, `users/${uid}/settings`));
  return { ...defaultConfig, ...(snap.val() || {}) } as ScreenTimeConfiguration;
}

export async function saveConfig(uid: string, config: ScreenTimeConfiguration): Promise<void> {
  // Safety fields are owned by the NextDNS profile, not Firebase — strip them
  // on write so applyParentalControl is the only path that changes them and
  // both clients always read fresh state from NextDNS instead of a stale cache.
  const forFirebase: ScreenTimeConfiguration = {
    ...config,
    safeSearchEnabled:        false,
    youtubeRestrictedEnabled: false,
    blockedDNSServices:       [],
    blockedDNSCategories:     [],
    lastUpdated: Date.now(),
  };
  await set(ref(db, `users/${uid}/settings`), forFirebase);
}

/// Real-time subscription to the config node. The iOS app already does this —
/// without it the web shows a snapshot taken at page load and never sees
/// changes the iOS admin (or another tab) makes.
export function subscribeConfig(uid: string, cb: (config: ScreenTimeConfiguration) => void) {
  const r = ref(db, `users/${uid}/settings`);
  const handler = (snap: DataSnapshot) => {
    cb({ ...defaultConfig, ...(snap.val() || {}) } as ScreenTimeConfiguration);
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export async function sendCommand(uid: string, type: string, payload: Record<string, string> = {}) {
  const cmdRef = push(ref(db, `users/${uid}/commands`));
  await set(cmdRef, {
    id: cmdRef.key,
    type,
    payload,
    timestamp: Date.now(),
    executed: false,
  });
}

export function subscribeUnlockRequests(uid: string, cb: (items: { pushKey: string; req: UnlockRequest }[]) => void) {
  const r = ref(db, `users/${uid}/unlockRequests`);
  const handler = (snap: DataSnapshot) => {
    const items: { pushKey: string; req: UnlockRequest }[] = [];
    snap.forEach((c) => {
      items.push({ pushKey: c.key!, req: c.val() as UnlockRequest });
      return false;
    });
    cb(items.reverse());
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export function subscribeWebsiteRequests(uid: string, cb: (items: { pushKey: string; req: WebsiteRequest }[]) => void) {
  const r = ref(db, `users/${uid}/websiteRequests`);
  const handler = (snap: DataSnapshot) => {
    const items: { pushKey: string; req: WebsiteRequest }[] = [];
    snap.forEach((c) => {
      items.push({ pushKey: c.key!, req: c.val() as WebsiteRequest });
      return false;
    });
    cb(items.reverse());
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export function subscribeTamperAlerts(uid: string, cb: (items: { pushKey: string; alert: TamperAlert }[]) => void) {
  const r = ref(db, `users/${uid}/tamperAlerts`);
  const handler = (snap: DataSnapshot) => {
    const items: { pushKey: string; alert: TamperAlert }[] = [];
    snap.forEach((c) => {
      items.push({ pushKey: c.key!, alert: c.val() as TamperAlert });
      return false;
    });
    cb(items.reverse());
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export async function deleteUnlockRequest(uid: string, pushKey: string) {
  await remove(ref(db, `users/${uid}/unlockRequests/${pushKey}`));
}
export async function deleteWebsiteRequest(uid: string, pushKey: string) {
  await remove(ref(db, `users/${uid}/websiteRequests/${pushKey}`));
}
export async function dismissTamperAlert(uid: string, pushKey: string) {
  await update(ref(db, `users/${uid}/tamperAlerts/${pushKey}`), { dismissed: true });
}

export async function pushRecommendedApp(uid: string, app: Omit<RecommendedApp, "id" | "timestamp">) {
  const r = push(ref(db, `users/${uid}/pendingApps`));
  await set(r, { ...app, id: r.key, timestamp: Date.now() });
}

export function subscribePendingApps(
  uid: string,
  cb: (items: { pushKey: string; app: RecommendedApp }[]) => void,
) {
  const r = ref(db, `users/${uid}/pendingApps`);
  const handler = (snap: DataSnapshot) => {
    const items: { pushKey: string; app: RecommendedApp }[] = [];
    snap.forEach((c) => {
      items.push({ pushKey: c.key!, app: c.val() as RecommendedApp });
      return false;
    });
    cb(items);
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export async function removePendingApp(uid: string, pushKey: string) {
  await remove(ref(db, `users/${uid}/pendingApps/${pushKey}`));
}

// MARK: - App Requests (child → admin)

export function subscribeAppRequests(
  uid: string,
  cb: (items: { pushKey: string; req: AppRequest }[]) => void,
) {
  const r = ref(db, `users/${uid}/appRequests`);
  const handler = (snap: DataSnapshot) => {
    const items: { pushKey: string; req: AppRequest }[] = [];
    snap.forEach((c) => {
      items.push({ pushKey: c.key!, req: c.val() as AppRequest });
      return false;
    });
    cb(items.reverse());
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export async function deleteAppRequest(uid: string, pushKey: string) {
  await remove(ref(db, `users/${uid}/appRequests/${pushKey}`));
}

/// Approve a child's app request: push it onto pendingApps (the existing
/// SKOverlay-installable list, which works even with App Store access blocked)
/// and delete the original request.
// MARK: - Installed App Library (child labels their apps for the admin)

export function subscribeInstalledApps(
  uid: string,
  cb: (items: { pushKey: string; app: InstalledApp }[]) => void,
) {
  const r = ref(db, `users/${uid}/installedApps`);
  const handler = (snap: DataSnapshot) => {
    const items: { pushKey: string; app: InstalledApp }[] = [];
    snap.forEach((c) => {
      items.push({ pushKey: c.key!, app: c.val() as InstalledApp });
      return false;
    });
    items.sort((a, b) => (a.app.name || "").toLowerCase().localeCompare((b.app.name || "").toLowerCase()));
    cb(items);
  };
  onValue(r, handler);
  return () => off(r, "value", handler);
}

export async function approveAppRequest(uid: string, pushKey: string, req: AppRequest) {
  await pushRecommendedApp(uid, {
    appStoreID: req.appStoreID,
    appName:    req.appName,
    iconURL:    req.iconURL,
    category:   req.category,
    sellerName: req.sellerName,
  });
  await remove(ref(db, `users/${uid}/appRequests/${pushKey}`));
}

export async function loadAppListReport(uid: string): Promise<{
  appCount: number;
  categoryCount: number;
  timestamp: number;
  reviewed: boolean;
} | null> {
  const snap = await get(ref(db, `users/${uid}/appList`));
  if (!snap.exists()) return null;
  const v = snap.val();
  return {
    appCount: v.appCount || 0,
    categoryCount: v.categoryCount || 0,
    timestamp: v.timestamp || 0,
    reviewed: !!v.reviewed,
  };
}

export async function markAppListReviewed(uid: string) {
  await update(ref(db, `users/${uid}/appList`), { reviewed: true });
}

export async function setEmergencyBypassCode(uid: string, code: string, durationMinutes: number) {
  await set(ref(db, `users/${uid}/emergencyBypass`), {
    code,
    durationMinutes,
    createdAt: Date.now(),
    used: false,
  });
}

export async function pushAdminNotification(uid: string, title: string, body: string) {
  const r = push(ref(db, `users/${uid}/notifications`));
  await set(r, { id: r.key, title, body, timestamp: Date.now() });
}

export async function loadAdminConfigValue(key: string): Promise<string> {
  const snap = await get(ref(db, `adminConfig/${key}`));
  return (snap.val() as string) || "";
}

export async function saveAdminConfigValue(key: string, value: string) {
  await set(ref(db, `adminConfig/${key}`), value);
}
