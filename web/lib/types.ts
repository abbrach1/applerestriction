// Mirrors ScreenTimeControl/Models/ScreenTimeSettings.swift

export type WebFilterMode = "blacklist" | "whitelist";

export interface DowntimeSchedule {
  startHour: number;
  startMinute: number;
  endHour: number;
  endMinute: number;
  activeDays: number[];
}

export interface AppTimeLimit {
  id: string;
  selectionData: string;   // base64 JSON of FamilyActivitySelection (was `appToken` in legacy data)
  displayName: string;
  timeLimitMinutes: number;
  isCategory: boolean;
}

/// Child-submitted "I have this app, here's what it's called." The selectionData
/// is opaque (base64 JSON of a single-token iOS FamilyActivitySelection), but
/// the web doesn't need to decode it — it passes the blob through to the
/// AppTimeLimit when admin picks this entry.
export interface InstalledApp {
  id: string;
  name: string;
  selectionData: string;
  isCategory: boolean;
  createdAt: string | number;
}

export interface AppRequest {
  id: string;
  appStoreID: string;
  appName: string;
  iconURL: string;
  category: string;
  sellerName: string;
  reason: string;
  timestamp: string | number;
  deviceName: string;
}

export interface ScreenTimeConfiguration {
  id: string;
  deviceId: string;
  deviceName: string;
  lastUpdated: string | number;
  blockedApps: string[];
  blockedCategories: string[];
  blockedAppsSelectionData?: string | null;
  blockedWebsites: string[];
  allowedWebsites: string[];
  websiteFilterMode: WebFilterMode;
  appTimeLimits: AppTimeLimit[];
  downtimeEnabled: boolean;
  downtimeSchedule: DowntimeSchedule;
  isLocked: boolean;
  blockNewApps: boolean;
  contentBlockerEnabled: boolean;
  forceDNS: boolean;
  nextDNSProfileID: string;
  nextDNSApiKey: string;
  dnsAlertOnRemoval: boolean;
  dnsAutoReapply: boolean;
  dnsRemovalPassword: string;
  safeSearchEnabled: boolean;
  youtubeRestrictedEnabled: boolean;
  blockedDNSServices: string[];
  blockedDNSCategories: string[];
  browserEnabled: boolean;
}

export interface ManagedUser {
  uid: string;
  email: string;
  displayName: string;
  deviceName: string;
  isOnline: boolean;
  lastSeen: number;   // Unix ms — Firebase server timestamp written by the iOS app
}

export interface TamperAlert {
  id: string;
  type: string;
  message: string;
  timestamp: string | number;
  dismissed: boolean;
}

export interface UnlockRequest {
  id: string;
  reason: string;
  timestamp: string | number;
  deviceName: string;
}

export interface WebsiteRequest {
  id: string;
  domain: string;
  reason: string;
  timestamp: string | number;
  deviceName: string;
}

export interface RecommendedApp {
  id: string;
  appStoreID: string;
  appName: string;
  iconURL: string;
  category: string;
  sellerName: string;
  timestamp: string | number;
}

export interface AdminNotification {
  id: string;
  title: string;
  body: string;
  timestamp: string | number;
}

export const defaultConfig: ScreenTimeConfiguration = {
  id: "",
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
  downtimeSchedule: { startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, activeDays: [1, 2, 3, 4, 5, 6, 7] },
  isLocked: false,
  blockNewApps: false,
  contentBlockerEnabled: false,
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
};
