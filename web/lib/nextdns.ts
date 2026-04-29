// NextDNS API client (mirrors NextDNSService.swift)
// Note: NextDNS API blocks browser requests via CORS, so all calls go through
// a Next.js API route at /api/nextdns/*  (defined in app/api/nextdns/route.ts)

export interface DNSLogEntry {
  timestamp: number;
  domain: string;
  blocked: boolean;
  deviceName: string;
  reason: string;
}

export interface DNSListEntry {
  id: string;
  active: boolean;
}

async function call(path: string, init?: RequestInit) {
  const res = await fetch(`/api/nextdns?path=${encodeURIComponent(path)}`, init);
  if (!res.ok) throw new Error(`NextDNS error: ${res.status}`);
  return res.json();
}

export async function fetchLogs(profileID: string, apiKey: string, limit = 100): Promise<DNSLogEntry[]> {
  const data = await call(`profiles/${profileID}/logs?limit=${limit}`, {
    headers: { "X-Forward-Api-Key": apiKey },
  });
  return (data.data || []).map((e: any) => ({
    timestamp: new Date(e.timestamp || Date.now()).getTime(),
    domain: e.domain || "",
    blocked: !!e.blocked,
    deviceName: e.device?.name || "",
    reason: e.reason?.name || "",
  }));
}

export async function fetchList(profileID: string, apiKey: string, endpoint: "allowlist" | "denylist"): Promise<DNSListEntry[]> {
  const data = await call(`profiles/${profileID}/${endpoint}`, {
    headers: { "X-Forward-Api-Key": apiKey },
  });
  return (data.data || []).map((d: any) => ({ id: d.id, active: !!d.active }));
}

export async function addDomain(profileID: string, apiKey: string, endpoint: "allowlist" | "denylist", domain: string) {
  return call(`profiles/${profileID}/${endpoint}`, {
    method: "POST",
    headers: { "X-Forward-Api-Key": apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({ id: domain.toLowerCase(), active: true }),
  });
}

export async function removeDomain(profileID: string, apiKey: string, endpoint: "allowlist" | "denylist", domain: string) {
  return call(`profiles/${profileID}/${endpoint}/${encodeURIComponent(domain)}`, {
    method: "DELETE",
    headers: { "X-Forward-Api-Key": apiKey },
  });
}

export async function applyParentalControl(
  profileID: string,
  apiKey: string,
  safeSearch: boolean,
  youtubeRestricted: boolean,
  blockedServices: string[],
  blockedCategories: string[],
) {
  // PATCH safeSearch + youtubeRestrictedMode
  await call(`profiles/${profileID}/parentalControl`, {
    method: "PATCH",
    headers: { "X-Forward-Api-Key": apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({ safeSearch, youtubeRestrictedMode: youtubeRestricted }),
  });
  await syncPC(profileID, apiKey, "services", blockedServices, KNOWN_SERVICES.map((s) => s.id));
  await syncPC(profileID, apiKey, "categories", blockedCategories, KNOWN_CATEGORIES.map((s) => s.id));
}

async function syncPC(profileID: string, apiKey: string, listPath: string, activeIDs: string[], knownIDs: string[]) {
  const data = await call(`profiles/${profileID}/parentalControl/${listPath}`, {
    headers: { "X-Forward-Api-Key": apiKey },
  });
  const currently: string[] = (data.data || []).filter((d: any) => d.active).map((d: any) => d.id);
  const active = new Set(activeIDs);
  const cur = new Set(currently);
  for (const id of activeIDs) {
    if (!cur.has(id)) {
      await call(`profiles/${profileID}/parentalControl/${listPath}`, {
        method: "POST",
        headers: { "X-Forward-Api-Key": apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({ id, active: true }),
      });
    }
  }
  for (const id of currently) {
    if (knownIDs.includes(id) && !active.has(id)) {
      await call(`profiles/${profileID}/parentalControl/${listPath}/${id}`, {
        method: "DELETE",
        headers: { "X-Forward-Api-Key": apiKey },
      });
    }
  }
}

export const KNOWN_SERVICES = [
  { id: "tiktok", label: "TikTok" },
  { id: "instagram", label: "Instagram" },
  { id: "snapchat", label: "Snapchat" },
  { id: "facebook", label: "Facebook" },
  { id: "discord", label: "Discord" },
  { id: "whatsapp", label: "WhatsApp" },
  { id: "twitch", label: "Twitch" },
  { id: "youtube", label: "YouTube" },
];

export const KNOWN_CATEGORIES = [
  { id: "porn", label: "Adult Content" },
  { id: "gambling", label: "Gambling" },
  { id: "dating", label: "Dating" },
  { id: "piracy", label: "Piracy" },
  { id: "social-networks", label: "Social Networks" },
  { id: "video-streaming", label: "Video Streaming" },
];
