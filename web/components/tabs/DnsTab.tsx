"use client";

import { useEffect, useState } from "react";
import { ScreenTimeConfiguration } from "@/lib/types";
import { pushAdminNotification } from "@/lib/db";
import {
  fetchLogs,
  fetchList,
  addDomain,
  removeDomain,
  applyParentalControl,
  fetchParentalControlState,
  KNOWN_SERVICES,
  KNOWN_CATEGORIES,
  DNSLogEntry,
  DNSListEntry,
} from "@/lib/nextdns";

export default function DnsTab({
  uid,
  config,
  update,
  save,
  globalApiKey,
}: {
  uid: string;
  config: ScreenTimeConfiguration;
  update: (p: Partial<ScreenTimeConfiguration>) => void;
  save: (c: ScreenTimeConfiguration, command?: string) => Promise<void>;
  globalApiKey: string;
}) {
  const [section, setSection] = useState<"logs" | "allow" | "block" | "safety">("logs");
  const [logs, setLogs] = useState<DNSLogEntry[]>([]);
  const [allowList, setAllowList] = useState<DNSListEntry[]>([]);
  const [blockList, setBlockList] = useState<DNSListEntry[]>([]);
  const [newDomain, setNewDomain] = useState("");
  const [loading, setLoading] = useState(false);

  const apiKey = globalApiKey || config.nextDNSApiKey;
  const profileID = config.nextDNSProfileID;
  const configured = !!profileID && !!apiKey;

  async function reload() {
    if (!configured) return;
    setLoading(true);
    try {
      if (section === "logs") setLogs(await fetchLogs(profileID, apiKey, 100));
      if (section === "allow") setAllowList(await fetchList(profileID, apiKey, "allowlist"));
      if (section === "block") setBlockList(await fetchList(profileID, apiKey, "denylist"));
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    reload();
  }, [section, profileID, apiKey]);

  if (!configured) {
    return (
      <div className="space-y-4">
        <div className="rounded-lg border border-yellow-300 bg-yellow-50 p-4 text-sm text-yellow-800">
          Set the NextDNS Profile ID and global API key to enable DNS controls.
        </div>
        <Section title="NextDNS Profile">
          <input
            type="text"
            placeholder="NextDNS Profile ID"
            value={config.nextDNSProfileID}
            onChange={(e) => update({ nextDNSProfileID: e.target.value })}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <Toggle label="Force NextDNS" checked={config.forceDNS} onChange={(v) => update({ forceDNS: v })} />
        </Section>
        <button
          onClick={async () => {
            await save(config);
            // The child can only install the .mobileconfig profile when B-SAFE
            // is foregrounded — UIApplication.open(url) is rejected from a
            // backgrounded app. Nudge the child to open B-SAFE so the existing
            // recheckDNSOnForeground path can run the install. No-op when the
            // child app is killed (no listener); their next manual launch picks
            // it up via recheckDNSOnForeground anyway.
            if (config.forceDNS && config.nextDNSProfileID) {
              await pushAdminNotification(
                uid,
                "Open B-SAFE to finish DNS setup",
                "Tap to install DNS protection on this device."
              );
            }
          }}
          className="w-full rounded-lg bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700"
        >
          Save
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex rounded-lg bg-gray-100 p-1 text-sm">
        {(["logs", "allow", "block", "safety"] as const).map((s) => (
          <button
            key={s}
            onClick={() => setSection(s)}
            className={`flex-1 rounded-md px-3 py-1.5 font-medium capitalize ${
              section === s ? "bg-white shadow" : "text-gray-600"
            }`}
          >
            {s}
          </button>
        ))}
      </div>

      {section === "logs" && (
        <Section title="Recent DNS Queries">
          {loading && <p className="text-sm text-gray-500">Loading…</p>}
          <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
            {logs.map((l, i) => (
              <li key={i} className="flex items-center justify-between px-4 py-2 text-sm">
                <div className="flex items-center gap-2">
                  <span className={`h-2 w-2 rounded-full ${l.blocked ? "bg-red-500" : "bg-green-500"}`} />
                  <span className="font-mono">{l.domain}</span>
                </div>
                <span className="text-xs text-gray-500">{new Date(l.timestamp).toLocaleTimeString()}</span>
              </li>
            ))}
          </ul>
        </Section>
      )}

      {(section === "allow" || section === "block") && (
        <Section title={section === "allow" ? "Allowlist" : "Denylist"}>
          <div className="flex gap-2">
            <input
              type="text"
              placeholder="domain.com"
              value={newDomain}
              onChange={(e) => setNewDomain(e.target.value)}
              className="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
            />
            <button
              onClick={async () => {
                const d = newDomain.trim().toLowerCase();
                if (!d) return;
                await addDomain(profileID, apiKey, section === "allow" ? "allowlist" : "denylist", d);
                setNewDomain("");
                await reload();
              }}
              className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700"
            >
              Add
            </button>
          </div>
          <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
            {(section === "allow" ? allowList : blockList).map((e) => (
              <li key={e.id} className="flex items-center justify-between px-4 py-2 text-sm">
                <span>{e.id}</span>
                <button
                  onClick={async () => {
                    await removeDomain(profileID, apiKey, section === "allow" ? "allowlist" : "denylist", e.id);
                    await reload();
                  }}
                  className="text-xs text-red-600 hover:underline"
                >
                  Remove
                </button>
              </li>
            ))}
          </ul>
        </Section>
      )}

      {section === "safety" && (
        <SafetyView config={config} update={update} save={save} apiKey={apiKey} profileID={profileID} />
      )}
    </div>
  );
}

function SafetyView({
  config,
  update,
  save,
  apiKey,
  profileID,
}: {
  config: ScreenTimeConfiguration;
  update: (p: Partial<ScreenTimeConfiguration>) => void;
  save: (c: ScreenTimeConfiguration, command?: string) => Promise<void>;
  apiKey: string;
  profileID: string;
}) {
  const [applying, setApplying] = useState(false);

  // Match the iOS DNS tab: treat NextDNS as the source of truth on open.
  // Without this the web shows whatever was last saved to Firebase, which
  // may diverge from the live NextDNS profile (e.g. if someone changed it
  // in NextDNS's own dashboard, or if the iOS app hasn't synced yet).
  useEffect(() => {
    if (!profileID || !apiKey) return;
    let cancelled = false;
    fetchParentalControlState(profileID, apiKey).then((state) => {
      if (cancelled) return;
      update({
        safeSearchEnabled:        state.safeSearch,
        youtubeRestrictedEnabled: state.youtubeRestricted,
        blockedDNSServices:       state.services,
        blockedDNSCategories:     state.categories,
      });
    });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profileID, apiKey]);

  function toggleArr(arr: string[], id: string): string[] {
    return arr.includes(id) ? arr.filter((x) => x !== id) : [...arr, id];
  }

  // NextDNS supports dozens of services/categories but our curated chip list
  // is short. Always include items that are currently blocked on NextDNS,
  // even if they aren't in the curated list — otherwise the UI silently
  // omits whatever the admin set in NextDNS's own dashboard.
  function mergeChips(known: { id: string; label: string }[], active: string[]): { id: string; label: string }[] {
    const out = [...known];
    const seen = new Set(known.map((k) => k.id));
    for (const id of active) {
      if (!seen.has(id)) {
        out.push({ id, label: prettyLabel(id) });
        seen.add(id);
      }
    }
    return out;
  }

  function prettyLabel(id: string): string {
    return id
      .split(/[-_]/)
      .map((w) => w.length ? w[0].toUpperCase() + w.slice(1) : w)
      .join(" ");
  }

  return (
    <div className="space-y-6">
      <Section title="Search & Video">
        <Toggle
          label="Force SafeSearch"
          desc="Google, Bing, DuckDuckGo show only filtered results"
          checked={config.safeSearchEnabled}
          onChange={(v) => update({ safeSearchEnabled: v })}
        />
        <Toggle
          label="YouTube Restricted Mode"
          desc="Hides explicit content"
          checked={config.youtubeRestrictedEnabled}
          onChange={(v) => update({ youtubeRestrictedEnabled: v })}
        />
      </Section>

      <Section title="Block Apps">
        <div className="grid grid-cols-2 gap-2">
          {mergeChips(KNOWN_SERVICES, config.blockedDNSServices).map((s) => {
            const blocked = config.blockedDNSServices.includes(s.id);
            return (
              <button
                key={s.id}
                onClick={() => update({ blockedDNSServices: toggleArr(config.blockedDNSServices, s.id) })}
                className={`rounded-lg border px-3 py-2 text-sm font-medium ${
                  blocked ? "border-red-300 bg-red-50 text-red-700" : "border-gray-200 bg-white"
                }`}
              >
                {s.label}
              </button>
            );
          })}
        </div>
      </Section>

      <Section title="Block Categories">
        <div className="grid grid-cols-2 gap-2">
          {mergeChips(KNOWN_CATEGORIES, config.blockedDNSCategories).map((c) => {
            const blocked = config.blockedDNSCategories.includes(c.id);
            return (
              <button
                key={c.id}
                onClick={() => update({ blockedDNSCategories: toggleArr(config.blockedDNSCategories, c.id) })}
                className={`rounded-lg border px-3 py-2 text-sm font-medium ${
                  blocked ? "border-red-300 bg-red-50 text-red-700" : "border-gray-200 bg-white"
                }`}
              >
                {c.label}
              </button>
            );
          })}
        </div>
      </Section>

      <button
        disabled={applying}
        onClick={async () => {
          setApplying(true);
          await save(config);
          await applyParentalControl(
            profileID,
            apiKey,
            config.safeSearchEnabled,
            config.youtubeRestrictedEnabled,
            config.blockedDNSServices,
            config.blockedDNSCategories,
          );
          setApplying(false);
        }}
        className="w-full rounded-lg bg-green-700 py-3 text-sm font-semibold text-white hover:bg-green-800 disabled:opacity-50"
      >
        {applying ? "Applying…" : "Apply Safety Settings"}
      </button>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="space-y-2">
      <h2 className="text-sm font-semibold uppercase text-gray-500">{title}</h2>
      <div className="space-y-2">{children}</div>
    </div>
  );
}

function Toggle({
  label,
  desc,
  checked,
  onChange,
}: {
  label: string;
  desc?: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <label className="flex cursor-pointer items-center justify-between rounded-lg border border-gray-200 bg-white p-3">
      <div>
        <div className="text-sm font-medium">{label}</div>
        {desc && <div className="text-xs text-gray-500">{desc}</div>}
      </div>
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="h-5 w-9 cursor-pointer appearance-none rounded-full bg-gray-300 transition-colors checked:bg-blue-600 relative
        before:absolute before:left-0.5 before:top-0.5 before:h-4 before:w-4 before:rounded-full before:bg-white before:transition-transform
        checked:before:translate-x-4"
      />
    </label>
  );
}
