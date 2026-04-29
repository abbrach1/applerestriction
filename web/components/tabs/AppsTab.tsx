"use client";

import { useEffect, useState } from "react";
import { ScreenTimeConfiguration, RecommendedApp } from "@/lib/types";
import { searchApps, AppSearchResult } from "@/lib/itunes";
import {
  pushRecommendedApp,
  subscribePendingApps,
  removePendingApp,
  loadAppListReport,
  markAppListReviewed,
  setEmergencyBypassCode,
  pushAdminNotification,
} from "@/lib/db";

export default function AppsTab({
  uid,
  config,
  update,
  save,
}: {
  uid: string;
  config: ScreenTimeConfiguration;
  update: (p: Partial<ScreenTimeConfiguration>) => void;
  save: (c: ScreenTimeConfiguration, command?: string) => Promise<void>;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<AppSearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState("");
  const [pending, setPending] = useState<{ pushKey: string; app: RecommendedApp }[]>([]);
  const [pushingId, setPushingId] = useState<string | null>(null);
  const [report, setReport] = useState<{
    appCount: number;
    categoryCount: number;
    timestamp: number;
    reviewed: boolean;
  } | null>(null);

  useEffect(() => {
    const unsub = subscribePendingApps(uid, setPending);
    loadAppListReport(uid).then(setReport);
    return () => unsub();
  }, [uid]);

  async function doSearch() {
    if (!query.trim()) return;
    setSearching(true);
    setSearchError("");
    try {
      const r = await searchApps(query);
      setResults(r);
      if (r.length === 0) setSearchError(`No apps found for "${query}".`);
    } catch {
      setSearchError("Search failed. Check your connection.");
    } finally {
      setSearching(false);
    }
  }

  async function send(app: AppSearchResult) {
    if (pending.some((p) => p.app.appStoreID === app.id)) return;
    setPushingId(app.id);
    await pushRecommendedApp(uid, {
      appStoreID: app.id,
      appName: app.name,
      iconURL: app.iconURL,
      category: app.category,
      sellerName: app.sellerName,
    });
    setPushingId(null);
  }

  return (
    <div className="space-y-6">
      <Section
        title="Recommend an App"
        footer="Search the App Store and send apps directly to this device. The child can install with one tap inside B-SAFE."
      >
        <div className="flex gap-2">
          <input
            type="text"
            placeholder="Search App Store…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && doSearch()}
            className="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <button
            onClick={doSearch}
            disabled={!query.trim() || searching}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {searching ? "…" : "Search"}
          </button>
        </div>
        {searchError && <p className="text-sm text-red-600">{searchError}</p>}

        <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
          {results.map((r) => {
            const isPending = pending.some((p) => p.app.appStoreID === r.id);
            return (
              <li key={r.id} className="flex items-center gap-3 px-3 py-2">
                {r.iconURL && <img src={r.iconURL} alt="" className="h-10 w-10 rounded-md" />}
                <div className="flex-1 min-w-0">
                  <div className="truncate text-sm font-medium">{r.name}</div>
                  <div className="truncate text-xs text-gray-500">{r.category}</div>
                </div>
                <button
                  onClick={() => send(r)}
                  disabled={pushingId === r.id || isPending}
                  className={`rounded-md px-3 py-1 text-xs font-semibold ${
                    isPending
                      ? "bg-green-100 text-green-700"
                      : "bg-blue-100 text-blue-700 hover:bg-blue-200"
                  } disabled:opacity-50`}
                >
                  {isPending ? "✓ Sent" : pushingId === r.id ? "…" : "Send"}
                </button>
              </li>
            );
          })}
        </ul>

        {pending.length > 0 && (
          <div>
            <h3 className="mb-2 text-xs font-semibold uppercase text-gray-500">Pending on device</h3>
            <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
              {pending.map(({ pushKey, app }) => (
                <li key={pushKey} className="flex items-center gap-3 px-3 py-2">
                  {app.iconURL && <img src={app.iconURL} alt="" className="h-8 w-8 rounded-md" />}
                  <div className="flex-1 min-w-0">
                    <div className="truncate text-sm">{app.appName}</div>
                    <div className="text-xs text-orange-600">Pending</div>
                  </div>
                  <button
                    onClick={() => removePendingApp(uid, pushKey)}
                    className="text-xs text-red-600 hover:underline"
                  >
                    Remove
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
      </Section>

      {report && (
        <Section title="App Review Request">
          <div className="rounded-lg border border-gray-200 bg-white p-3">
            <div className="text-sm font-medium">
              {report.reviewed ? "✓ App List Reviewed" : "⏰ Pending App Review"}
            </div>
            <div className="text-xs text-gray-500">
              {report.appCount} apps · {report.categoryCount} categories
            </div>
            {!report.reviewed && (
              <button
                onClick={async () => {
                  await markAppListReviewed(uid);
                  setReport({ ...report, reviewed: true });
                }}
                className="mt-2 rounded-md bg-green-600 px-3 py-1 text-xs font-semibold text-white hover:bg-green-700"
              >
                Mark as Reviewed
              </button>
            )}
          </div>
        </Section>
      )}

      <Section title="App Installations">
        <Toggle
          label="Block New App Installs"
          desc="Prevents the device from installing any new apps"
          checked={config.blockNewApps}
          onChange={(v) => update({ blockNewApps: v })}
        />
      </Section>

      <button
        onClick={() => save(config, config.isLocked ? "lockDevice" : "updateBlockedApps")}
        className="w-full rounded-lg bg-orange-500 py-3 text-sm font-semibold text-white hover:bg-orange-600"
      >
        Apply App Settings
      </button>

      <EmergencyBypass uid={uid} />
      <PushNotificationSection uid={uid} />
    </div>
  );
}

function EmergencyBypass({ uid }: { uid: string }) {
  const [duration, setDuration] = useState(30);
  const [code, setCode] = useState("");
  const [sending, setSending] = useState(false);
  const durations = [
    { mins: 15, label: "15 min" },
    { mins: 30, label: "30 min" },
    { mins: 60, label: "1 hour" },
    { mins: 120, label: "2 hours" },
  ];

  async function generate() {
    setSending(true);
    const c = String(Math.floor(Math.random() * 1000000)).padStart(6, "0");
    await setEmergencyBypassCode(uid, c, duration);
    setCode(c);
    setSending(false);
  }

  return (
    <Section
      title="Emergency Bypass Code"
      footer="Give the child this code for emergencies. It unlocks the device for the selected duration. One-time use."
    >
      {code && (
        <div className="rounded-lg bg-purple-50 p-4 text-center">
          <div className="text-xs uppercase text-purple-700">Emergency Code</div>
          <div className="my-2 font-mono text-3xl font-bold tracking-widest text-purple-900">
            {code.slice(0, 3)} {code.slice(3)}
          </div>
          <div className="text-xs text-purple-700">
            Valid for {durations.find((d) => d.mins === duration)?.label} · One-time use
          </div>
        </div>
      )}
      <select
        value={duration}
        onChange={(e) => setDuration(Number(e.target.value))}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
      >
        {durations.map((d) => (
          <option key={d.mins} value={d.mins}>
            {d.label}
          </option>
        ))}
      </select>
      <button
        disabled={sending}
        onClick={generate}
        className="w-full rounded-lg bg-purple-600 py-3 text-sm font-semibold text-white hover:bg-purple-700 disabled:opacity-50"
      >
        {sending ? "…" : code ? "Generate New Code" : "Generate Emergency Code"}
      </button>
    </Section>
  );
}

function PushNotificationSection({ uid }: { uid: string }) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [sent, setSent] = useState(false);
  const [sending, setSending] = useState(false);

  async function send() {
    if (!title.trim()) return;
    setSending(true);
    await pushAdminNotification(uid, title.trim(), body.trim());
    setSent(true);
    setTitle("");
    setBody("");
    setSending(false);
    setTimeout(() => setSent(false), 2000);
  }

  return (
    <Section title="Send Notification to Child">
      <input
        type="text"
        placeholder="Title"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
      />
      <textarea
        placeholder="Message"
        value={body}
        onChange={(e) => setBody(e.target.value)}
        rows={3}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
      />
      <button
        onClick={send}
        disabled={!title.trim() || sending}
        className="w-full rounded-lg bg-indigo-600 py-3 text-sm font-semibold text-white hover:bg-indigo-700 disabled:opacity-50"
      >
        {sending ? "Sending…" : sent ? "Sent ✓" : "Send Notification"}
      </button>
    </Section>
  );
}

function Section({
  title,
  footer,
  children,
}: {
  title: string;
  footer?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-2">
      <h2 className="text-sm font-semibold uppercase text-gray-500">{title}</h2>
      <div className="space-y-2">{children}</div>
      {footer && <p className="text-xs text-gray-500">{footer}</p>}
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
