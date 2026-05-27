"use client";

import { useEffect, useState } from "react";
import { ScreenTimeConfiguration, RecommendedApp, InstalledApp } from "@/lib/types";
import { searchApps, AppSearchResult } from "@/lib/itunes";
import {
  pushRecommendedApp,
  subscribePendingApps,
  removePendingApp,
  loadAppListReport,
  markAppListReviewed,
  setEmergencyBypassCode,
  pushAdminNotification,
  subscribeInstalledApps,
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
  const [library, setLibrary] = useState<{ pushKey: string; app: InstalledApp }[]>([]);
  const [showAddLimit, setShowAddLimit] = useState(false);
  const [pickedLibraryKey, setPickedLibraryKey] = useState<string | null>(null);
  const [newLimitMinutes, setNewLimitMinutes] = useState(60);

  useEffect(() => {
    const unsub = subscribePendingApps(uid, setPending);
    const unsubLib = subscribeInstalledApps(uid, setLibrary);
    loadAppListReport(uid).then(setReport);
    return () => { unsub(); unsubLib(); };
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

      <Section
        title="Daily Time Limits"
        footer="Each limit covers an app from the child's labeled library. When the daily budget runs out, the apps shield until midnight."
      >
        <div className="flex items-center justify-between">
          <span className="text-xs text-slate-500">
            {library.length === 0
              ? "Child hasn't submitted their app library yet — open B-SAFE on the device → My Apps."
              : `${library.length} app${library.length === 1 ? "" : "s"} in the child's library.`}
          </span>
          <button
            onClick={() => {
              setPickedLibraryKey(null);
              setNewLimitMinutes(60);
              setShowAddLimit(true);
            }}
            disabled={library.length === 0}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            + Add Time Limit
          </button>
        </div>
        {config.appTimeLimits.length === 0 ? (
          <p className="text-sm text-gray-400">
            No daily limits set. Open the iOS admin app → Apps tab → Add Time Limit.
          </p>
        ) : (
          <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
            {config.appTimeLimits.map((limit, idx) => (
              <li key={limit.id || idx} className="flex items-center gap-3 px-3 py-2">
                <div className="flex-1 min-w-0">
                  <div className="truncate text-sm font-medium">{limit.displayName || "Untitled limit"}</div>
                  <div className="text-xs text-gray-500">{limit.timeLimitMinutes} min/day</div>
                </div>
                <input
                  type="number"
                  min={5}
                  max={720}
                  step={5}
                  value={limit.timeLimitMinutes}
                  onChange={(e) => {
                    const v = Math.max(5, Math.min(720, Number(e.target.value) || 5));
                    const next = [...config.appTimeLimits];
                    next[idx] = { ...next[idx], timeLimitMinutes: v };
                    update({ appTimeLimits: next });
                  }}
                  className="w-20 rounded-md border border-gray-300 px-2 py-1 text-sm"
                  aria-label="Minutes per day"
                />
                <button
                  onClick={() => {
                    const next = config.appTimeLimits.filter((_, i) => i !== idx);
                    update({ appTimeLimits: next });
                  }}
                  className="text-xs text-red-600 hover:underline"
                >
                  Delete
                </button>
              </li>
            ))}
          </ul>
        )}
      </Section>

      <button
        onClick={() => save(config, config.isLocked ? "lockDevice" : "updateBlockedApps")}
        className="w-full rounded-lg bg-orange-500 py-3 text-sm font-semibold text-white hover:bg-orange-600"
      >
        Apply App Settings
      </button>

      <EmergencyBypass uid={uid} />
      <PushNotificationSection uid={uid} />

      {showAddLimit && (
        <AddTimeLimitModal
          library={library}
          pickedKey={pickedLibraryKey}
          setPickedKey={setPickedLibraryKey}
          minutes={newLimitMinutes}
          setMinutes={setNewLimitMinutes}
          onCancel={() => setShowAddLimit(false)}
          onSave={() => {
            const entry = library.find((l) => l.pushKey === pickedLibraryKey);
            if (!entry) return;
            update({
              appTimeLimits: [
                ...config.appTimeLimits,
                {
                  id: crypto.randomUUID(),
                  selectionData: entry.app.selectionData,
                  displayName: entry.app.name,
                  timeLimitMinutes: newLimitMinutes,
                  isCategory: !!entry.app.isCategory,
                },
              ],
            });
            setShowAddLimit(false);
            setPickedLibraryKey(null);
          }}
        />
      )}
    </div>
  );
}

function AddTimeLimitModal({
  library,
  pickedKey,
  setPickedKey,
  minutes,
  setMinutes,
  onCancel,
  onSave,
}: {
  library: { pushKey: string; app: InstalledApp }[];
  pickedKey: string | null;
  setPickedKey: (k: string | null) => void;
  minutes: number;
  setMinutes: (n: number) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-slate-900/40 p-4" onClick={onCancel}>
      <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-slate-900">New Time Limit</h2>
          <button onClick={onCancel} className="text-slate-400 hover:text-slate-700" aria-label="Close">
            ×
          </button>
        </div>
        <div className="space-y-3">
          <div>
            <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
              App from child&apos;s library
            </div>
            <div className="max-h-60 overflow-auto rounded-lg border border-slate-200 bg-white">
              {library.map((item) => (
                <button
                  key={item.pushKey}
                  onClick={() => setPickedKey(item.pushKey)}
                  className={`flex w-full items-center justify-between px-3 py-2 text-left text-sm transition-colors ${
                    pickedKey === item.pushKey ? "bg-blue-50 text-blue-900" : "hover:bg-slate-50"
                  }`}
                >
                  <span>{item.app.name || "(unnamed)"}</span>
                  {item.app.isCategory && (
                    <span className="text-xs text-slate-400">category</span>
                  )}
                </button>
              ))}
            </div>
          </div>
          <div>
            <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
              Minutes per day
            </div>
            <input
              type="number"
              min={5}
              max={720}
              step={5}
              value={minutes}
              onChange={(e) => setMinutes(Math.max(5, Math.min(720, Number(e.target.value) || 60)))}
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-100"
            />
          </div>
          <div className="mt-4 flex justify-end gap-2">
            <button
              onClick={onCancel}
              className="rounded-md border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50"
            >
              Cancel
            </button>
            <button
              onClick={onSave}
              disabled={!pickedKey}
              className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              Add
            </button>
          </div>
        </div>
      </div>
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
