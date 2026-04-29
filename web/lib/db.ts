import { ref, get, set, update, onValue, off, remove, push, DataSnapshot } from "firebase/database";
import { db } from "./firebase";
import { ManagedUser, ScreenTimeConfiguration, defaultConfig, TamperAlert, UnlockRequest, WebsiteRequest, RecommendedApp } from "./types";

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
        lastSeen: info.lastSeen || "",
      });
    }
    return false;
  });
  return out.sort((a, b) => {
    if (a.isOnline !== b.isOnline) return a.isOnline ? -1 : 1;
    return (b.lastSeen || "").localeCompare(a.lastSeen || "");
  });
}

export async function loadConfig(uid: string): Promise<ScreenTimeConfiguration> {
  const snap = await get(ref(db, `users/${uid}/config`));
  return { ...defaultConfig, ...(snap.val() || {}) } as ScreenTimeConfiguration;
}

export async function saveConfig(uid: string, config: ScreenTimeConfiguration): Promise<void> {
  await set(ref(db, `users/${uid}/config`), { ...config, lastUpdated: Date.now() });
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

export async function loadAdminConfigValue(key: string): Promise<string> {
  const snap = await get(ref(db, `adminConfig/${key}`));
  return (snap.val() as string) || "";
}

export async function saveAdminConfigValue(key: string, value: string) {
  await set(ref(db, `adminConfig/${key}`), value);
}
