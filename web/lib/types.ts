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
  appToken: string;
  displayName: string;
  timeLimitMinutes: number;
  isCategory: boolean;
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
  lastSeen: string;
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
