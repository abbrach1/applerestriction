"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { subscribeConfig, saveConfig, sendCommand, loadAdminConfigValue } from "@/lib/db";
import { ScreenTimeConfiguration } from "@/lib/types";
import WebsiteTab from "@/components/tabs/WebsiteTab";
import DnsTab from "@/components/tabs/DnsTab";
import DowntimeTab from "@/components/tabs/DowntimeTab";
import RequestsTab from "@/components/tabs/RequestsTab";
import CommandsTab from "@/components/tabs/CommandsTab";
import AppsTab from "@/components/tabs/AppsTab";

const TABS = [
  { label: "Websites", key: "websites" },
  { label: "DNS",      key: "dns" },
  { label: "Downtime", key: "downtime" },
  { label: "Apps",     key: "apps" },
  { label: "Requests", key: "requests" },
  { label: "Commands", key: "commands" },
];

export default function UserPage() {
  const params = useParams<{ uid: string }>();
  const uid = params.uid;
  const [config, setConfig] = useState<ScreenTimeConfiguration | null>(null);
  const [tab, setTab] = useState(0);
  const [globalApiKey, setGlobalApiKey] = useState("");
  const [saving, setSaving] = useState(false);
  const [savedFlash, setSavedFlash] = useState(false);

  useEffect(() => {
    // Live subscription — any save by the iOS admin (or another web tab)
    // pushes the new config into our state within milliseconds.
    //
    // Safety fields are owned by NextDNS, not Firebase, so we strip them on
    // write. That means incoming snapshots always carry default values for
    // those four fields — preserve whatever the local state has (which is
    // either the user's in-flight edit or the value last fetched from
    // NextDNS via SafetyView's useEffect).
    const unsub = subscribeConfig(uid, (incoming) => {
      setConfig((prev) =>
        prev
          ? {
              ...incoming,
              safeSearchEnabled:        prev.safeSearchEnabled,
              youtubeRestrictedEnabled: prev.youtubeRestrictedEnabled,
              blockedDNSServices:       prev.blockedDNSServices,
              blockedDNSCategories:     prev.blockedDNSCategories,
            }
          : incoming
      );
    });
    loadAdminConfigValue("nextDNSApiKey").then(setGlobalApiKey);
    return () => unsub();
  }, [uid]);

  if (!config) {
    return (
      <div className="space-y-6">
        <div className="h-9 w-64 animate-pulse rounded bg-slate-200" />
        <div className="h-12 w-full animate-pulse rounded-xl bg-slate-200" />
        <div className="h-64 w-full animate-pulse rounded-xl bg-slate-200" />
      </div>
    );
  }

  async function save(c: ScreenTimeConfiguration, command?: string) {
    setSaving(true);
    await saveConfig(uid, c);
    if (command) await sendCommand(uid, command);
    setSaving(false);
    setSavedFlash(true);
    setTimeout(() => setSavedFlash(false), 2000);
  }

  const update = (partial: Partial<ScreenTimeConfiguration>) =>
    setConfig({ ...config, ...partial });

  return (
    <div className="space-y-6">
      <DeviceHeader config={config} />

      <TabBar tabs={TABS.map((t) => t.label)} value={tab} onChange={setTab} />

      <div>
        {tab === 0 && <WebsiteTab  config={config} update={update} save={save} globalApiKey={globalApiKey} />}
        {tab === 1 && <DnsTab      uid={uid} config={config} update={update} save={save} globalApiKey={globalApiKey} />}
        {tab === 2 && <DowntimeTab config={config} update={update} save={save} />}
        {tab === 3 && <AppsTab     uid={uid} config={config} update={update} save={save} />}
        {tab === 4 && <RequestsTab uid={uid} config={config} save={save} update={update} />}
        {tab === 5 && <CommandsTab uid={uid} config={config} save={save} update={update} />}
      </div>

      <SaveToast saving={saving} saved={savedFlash} />
    </div>
  );
}

function DeviceHeader({ config }: { config: ScreenTimeConfiguration }) {
  const restrictionsActive =
    config.isLocked ||
    config.downtimeEnabled ||
    config.forceDNS ||
    config.contentBlockerEnabled ||
    config.websiteFilterMode === "whitelist" ||
    config.blockedWebsites.length > 0 ||
    (config.appTimeLimits?.length ?? 0) > 0;

  return (
    <div className="flex flex-wrap items-end justify-between gap-3 border-b border-slate-200 pb-4">
      <div>
        <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-400">Device</p>
        <h1 className="text-2xl font-bold text-slate-900">{config.deviceName || "Device"}</h1>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        {config.isLocked && <Pill tone="red">Locked</Pill>}
        {config.downtimeEnabled && <Pill tone="purple">Downtime scheduled</Pill>}
        {config.forceDNS && <Pill tone="blue">Forced DNS</Pill>}
        {config.websiteFilterMode === "whitelist" && (
          <Pill tone="amber">Whitelist mode</Pill>
        )}
        {!restrictionsActive && <Pill tone="slate">No active restrictions</Pill>}
      </div>
    </div>
  );
}

function Pill({
  tone,
  children,
}: {
  tone: "slate" | "red" | "blue" | "purple" | "amber" | "emerald";
  children: React.ReactNode;
}) {
  const tones: Record<typeof tone, string> = {
    slate:   "bg-slate-100 text-slate-700",
    red:     "bg-red-50 text-red-700",
    blue:    "bg-blue-50 text-blue-700",
    purple:  "bg-purple-50 text-purple-700",
    amber:   "bg-amber-50 text-amber-700",
    emerald: "bg-emerald-50 text-emerald-700",
  };
  return (
    <span className={`rounded-full px-2.5 py-1 text-xs font-medium ${tones[tone]}`}>
      {children}
    </span>
  );
}

function TabBar({
  tabs,
  value,
  onChange,
}: {
  tabs: string[];
  value: number;
  onChange: (i: number) => void;
}) {
  return (
    <div className="overflow-x-auto">
      <div className="inline-flex min-w-full gap-1 rounded-xl border border-slate-200 bg-white p-1">
        {tabs.map((label, i) => (
          <button
            key={label}
            onClick={() => onChange(i)}
            className={`whitespace-nowrap rounded-lg px-3 py-1.5 text-sm font-medium transition-colors ${
              value === i
                ? "bg-blue-600 text-white shadow-sm"
                : "text-slate-600 hover:bg-slate-100"
            }`}
          >
            {label}
          </button>
        ))}
      </div>
    </div>
  );
}

function SaveToast({ saving, saved }: { saving: boolean; saved: boolean }) {
  if (!saving && !saved) return null;
  return (
    <div className="pointer-events-none fixed bottom-6 right-6 z-20 flex items-center gap-2 rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white shadow-xl">
      {saving ? (
        <>
          <span className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-slate-300 border-t-white" />
          Saving…
        </>
      ) : (
        <>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="20 6 9 17 4 12" />
          </svg>
          Saved
        </>
      )}
    </div>
  );
}
