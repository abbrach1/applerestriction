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
  if (!res.ok) {
    // Surface NextDNS's error body so 500s don't show up as opaque "NextDNS error: 500".
    let body = "";
    try { body = await res.text(); } catch {}
    console.error("[NextDNS]", init?.method || "GET", path, "→", res.status, body);
    throw new Error(`NextDNS error: ${res.status}${body ? ` — ${body.slice(0, 300)}` : ""}`);
  }
  // 204 No Content has no body — guard against res.json() throwing.
  if (res.status === 204) return null;
  const ct = res.headers.get("Content-Type") || "";
  return ct.includes("json") ? res.json() : res.text();
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

/// Read the current parental-control state from the NextDNS profile.
/// Mirrors `NextDNSService.fetchParentalControlState` on iOS. The iOS DNS
/// tab calls this on open and treats NextDNS as the source of truth — the
/// web should do the same so both clients show the same values.
export async function fetchParentalControlState(
  profileID: string,
  apiKey: string,
): Promise<{
  safeSearch: boolean;
  youtubeRestricted: boolean;
  services: string[];
  categories: string[];
}> {
  const empty = { safeSearch: false, youtubeRestricted: false, services: [], categories: [] };
  try {
    const root = await call(`profiles/${profileID}/parentalControl`, {
      headers: { "X-Forward-Api-Key": apiKey },
    });
    const services = await call(`profiles/${profileID}/parentalControl/services`, {
      headers: { "X-Forward-Api-Key": apiKey },
    });
    const categories = await call(`profiles/${profileID}/parentalControl/categories`, {
      headers: { "X-Forward-Api-Key": apiKey },
    });
    // NextDNS wraps the root parentalControl response in { data: { safeSearch, … } }.
    // The /services and /categories sub-endpoints are also wrapped: { data: [...] }.
    const r =
      root && typeof root === "object" && "data" in root && root.data
        ? (root as { data: Record<string, unknown> }).data
        : (root as Record<string, unknown>);

    return {
      safeSearch:        !!r?.safeSearch,
      youtubeRestricted: !!r?.youtubeRestrictedMode,
      // NextDNS's /services and /categories endpoints return only the currently-active items,
      // not the full catalog. Filtering for `active` is defensive in case that ever changes.
      services:   (services?.data || []).filter((d: { active?: boolean }) => d.active).map((d: { id: string }) => d.id),
      categories: (categories?.data || []).filter((d: { active?: boolean }) => d.active).map((d: { id: string }) => d.id),
    };
  } catch (e) {
    console.error("[B-SAFE] fetchParentalControlState failed:", e);
    return empty;
  }
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
  await syncPC(profileID, apiKey, "services", blockedServices);
  await syncPC(profileID, apiKey, "categories", blockedCategories);
}

async function syncPC(profileID: string, apiKey: string, listPath: string, activeIDs: string[]) {
  const data = await call(`profiles/${profileID}/parentalControl/${listPath}`, {
    headers: { "X-Forward-Api-Key": apiKey },
  });
  const currently: string[] = (data.data || []).filter((d: { active?: boolean }) => d.active).map((d: { id: string }) => d.id);
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
  // Remove any currently-blocked item the admin no longer wants active.
  // No "known IDs" guard — the UI renders the union of curated + currently-
  // blocked, so admins can deliberately toggle off any chip they see.
  for (const id of currently) {
    if (!active.has(id)) {
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
