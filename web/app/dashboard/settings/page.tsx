"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { loadAdminConfigValue, saveAdminConfigValue } from "@/lib/db";

export default function SettingsPage() {
  const [nextDNSApiKey, setNextDNSApiKey] = useState("");
  const [alertEmail, setAlertEmail] = useState("");
  const [sendGridApiKey, setSendGridApiKey] = useState("");
  const [loading, setLoading] = useState(true);
  const [savingKey, setSavingKey] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([
      loadAdminConfigValue("nextDNSApiKey"),
      loadAdminConfigValue("alertEmail"),
      loadAdminConfigValue("sendGridApiKey"),
    ]).then(([n, e, s]) => {
      setNextDNSApiKey(n);
      setAlertEmail(e);
      setSendGridApiKey(s);
      setLoading(false);
    });
  }, []);

  async function saveValue(key: string, value: string) {
    setSavingKey(key);
    await saveAdminConfigValue(key, value.trim());
    setSavingKey(null);
  }

  if (loading) return <p className="text-gray-500">Loading…</p>;

  return (
    <div className="space-y-6">
      <Link href="/dashboard" className="text-sm text-blue-600 hover:underline">
        ← Back to children
      </Link>
      <h1 className="text-2xl font-bold">Global Settings</h1>

      <Section
        title="NextDNS API Key"
        footer="Get this from nextdns.io → Account → API. Used for all child profiles."
      >
        <input
          type="password"
          value={nextDNSApiKey}
          onChange={(e) => setNextDNSApiKey(e.target.value)}
          placeholder="NextDNS API Key"
          className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm font-mono"
        />
        <SaveButton
          loading={savingKey === "nextDNSApiKey"}
          onClick={() => saveValue("nextDNSApiKey", nextDNSApiKey)}
        />
      </Section>

      <Section
        title="Email Alerts"
        footer="When DNS protection is removed on the child device, an email is sent to this address via SendGrid."
      >
        <input
          type="email"
          value={alertEmail}
          onChange={(e) => setAlertEmail(e.target.value)}
          placeholder="alerts@example.com"
          className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
        />
        <SaveButton
          loading={savingKey === "alertEmail"}
          onClick={() => saveValue("alertEmail", alertEmail)}
        />

        <div className="pt-2">
          <input
            type="password"
            value={sendGridApiKey}
            onChange={(e) => setSendGridApiKey(e.target.value)}
            placeholder="SendGrid API Key"
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm font-mono"
          />
          <p className="mt-1 text-xs text-gray-500">
            From sendgrid.com → Settings → API Keys. Sender bsafe.dnslogs@gmail.com must be verified.
          </p>
          <SaveButton
            loading={savingKey === "sendGridApiKey"}
            onClick={() => saveValue("sendGridApiKey", sendGridApiKey)}
          />
        </div>
      </Section>
    </div>
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
    <div className="space-y-2 rounded-xl border border-gray-200 bg-white p-5">
      <h2 className="text-sm font-semibold uppercase text-gray-500">{title}</h2>
      <div className="space-y-2">{children}</div>
      {footer && <p className="text-xs text-gray-500">{footer}</p>}
    </div>
  );
}

function SaveButton({ loading, onClick }: { loading: boolean; onClick: () => void }) {
  const [justSaved, setJustSaved] = useState(false);
  return (
    <button
      onClick={async () => {
        await onClick();
        setJustSaved(true);
        setTimeout(() => setJustSaved(false), 1500);
      }}
      disabled={loading}
      className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
    >
      {loading ? "Saving…" : justSaved ? "Saved ✓" : "Save"}
    </button>
  );
}
