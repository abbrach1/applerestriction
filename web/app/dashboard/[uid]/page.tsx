"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { loadConfig, saveConfig, sendCommand, loadAdminConfigValue } from "@/lib/db";
import { ScreenTimeConfiguration } from "@/lib/types";
import WebsiteTab from "@/components/tabs/WebsiteTab";
import DnsTab from "@/components/tabs/DnsTab";
import DowntimeTab from "@/components/tabs/DowntimeTab";
import RequestsTab from "@/components/tabs/RequestsTab";
import CommandsTab from "@/components/tabs/CommandsTab";

const TABS = ["Websites", "DNS", "Downtime", "Requests", "Commands"];

export default function UserPage() {
  const params = useParams<{ uid: string }>();
  const uid = params.uid;
  const [config, setConfig] = useState<ScreenTimeConfiguration | null>(null);
  const [tab, setTab] = useState(0);
  const [globalApiKey, setGlobalApiKey] = useState("");
  const [saving, setSaving] = useState(false);
  const [savedFlash, setSavedFlash] = useState(false);

  useEffect(() => {
    loadConfig(uid).then(setConfig);
    loadAdminConfigValue("nextDNSApiKey").then(setGlobalApiKey);
  }, [uid]);

  if (!config) return <p className="text-gray-500">Loading config…</p>;

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
    <div>
      <Link href="/dashboard" className="text-sm text-blue-600 hover:underline">← Back to children</Link>
      <h1 className="mt-2 text-2xl font-bold">{config.deviceName || "Device"}</h1>

      <div className="mt-4 flex gap-1 border-b border-gray-200">
        {TABS.map((label, i) => (
          <button
            key={label}
            onClick={() => setTab(i)}
            className={`px-4 py-2 text-sm font-medium ${
              tab === i ? "border-b-2 border-blue-600 text-blue-600" : "text-gray-500 hover:text-gray-900"
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      <div className="mt-6">
        {tab === 0 && <WebsiteTab config={config} update={update} save={save} globalApiKey={globalApiKey} />}
        {tab === 1 && <DnsTab uid={uid} config={config} update={update} save={save} globalApiKey={globalApiKey} />}
        {tab === 2 && <DowntimeTab config={config} update={update} save={save} />}
        {tab === 3 && <RequestsTab uid={uid} config={config} save={save} update={update} />}
        {tab === 4 && <CommandsTab uid={uid} config={config} save={save} update={update} />}
      </div>

      {(saving || savedFlash) && (
        <div className="fixed bottom-6 right-6 rounded-lg bg-gray-900 px-4 py-2 text-sm text-white shadow-lg">
          {saving ? "Saving…" : "Saved ✓"}
        </div>
      )}
    </div>
  );
}
