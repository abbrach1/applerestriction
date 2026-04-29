"use client";

import { useEffect, useState } from "react";
import { ScreenTimeConfiguration, UnlockRequest, WebsiteRequest, TamperAlert } from "@/lib/types";
import {
  subscribeUnlockRequests,
  subscribeWebsiteRequests,
  subscribeTamperAlerts,
  deleteUnlockRequest,
  deleteWebsiteRequest,
  dismissTamperAlert,
  saveConfig,
  sendCommand,
} from "@/lib/db";

export default function RequestsTab({
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
  const [unlocks, setUnlocks] = useState<{ pushKey: string; req: UnlockRequest }[]>([]);
  const [websites, setWebsites] = useState<{ pushKey: string; req: WebsiteRequest }[]>([]);
  const [alerts, setAlerts] = useState<{ pushKey: string; alert: TamperAlert }[]>([]);

  useEffect(() => {
    const u1 = subscribeUnlockRequests(uid, setUnlocks);
    const u2 = subscribeWebsiteRequests(uid, setWebsites);
    const u3 = subscribeTamperAlerts(uid, setAlerts);
    return () => {
      u1();
      u2();
      u3();
    };
  }, [uid]);

  async function approveUnlock(pk: string) {
    const newConfig = { ...config, isLocked: false };
    update({ isLocked: false });
    await saveConfig(uid, newConfig);
    await sendCommand(uid, "unlockAll");
    await deleteUnlockRequest(uid, pk);
  }

  async function approveWebsite(pk: string, domain: string) {
    if (!config.allowedWebsites.includes(domain)) {
      const newConfig = { ...config, allowedWebsites: [...config.allowedWebsites, domain] };
      update({ allowedWebsites: newConfig.allowedWebsites });
      await save(newConfig, "updateWebsites");
    }
    await deleteWebsiteRequest(uid, pk);
  }

  return (
    <div className="space-y-8">
      <Section title={`Unlock Requests (${unlocks.length})`}>
        {unlocks.length === 0 && <p className="text-sm text-gray-400">No pending requests</p>}
        {unlocks.map(({ pushKey, req }) => (
          <Card key={pushKey}>
            <div className="text-sm font-medium">{req.deviceName || "Device"} wants to unlock</div>
            {req.reason && <div className="mt-1 text-xs text-gray-500">"{req.reason}"</div>}
            <div className="mt-3 flex gap-2">
              <button
                onClick={() => approveUnlock(pushKey)}
                className="rounded-md bg-green-600 px-3 py-1 text-xs font-semibold text-white hover:bg-green-700"
              >
                Unlock Device
              </button>
              <button
                onClick={() => deleteUnlockRequest(uid, pushKey)}
                className="rounded-md border border-gray-300 px-3 py-1 text-xs hover:bg-gray-100"
              >
                Dismiss
              </button>
            </div>
          </Card>
        ))}
      </Section>

      <Section title={`Website Requests (${websites.length})`}>
        {websites.length === 0 && <p className="text-sm text-gray-400">No pending requests</p>}
        {websites.map(({ pushKey, req }) => (
          <Card key={pushKey}>
            <div className="text-sm font-medium">{req.domain}</div>
            {req.reason && <div className="mt-1 text-xs text-gray-500">"{req.reason}"</div>}
            <div className="mt-1 text-xs text-gray-400">{req.deviceName}</div>
            <div className="mt-3 flex gap-2">
              <button
                onClick={() => approveWebsite(pushKey, req.domain)}
                className="rounded-md bg-green-600 px-3 py-1 text-xs font-semibold text-white hover:bg-green-700"
              >
                Allow Site
              </button>
              <button
                onClick={() => deleteWebsiteRequest(uid, pushKey)}
                className="rounded-md border border-gray-300 px-3 py-1 text-xs hover:bg-gray-100"
              >
                Deny
              </button>
            </div>
          </Card>
        ))}
      </Section>

      <Section title={`Tamper Alerts (${alerts.filter((a) => !a.alert.dismissed).length})`}>
        {alerts.filter((a) => !a.alert.dismissed).length === 0 && (
          <p className="text-sm text-gray-400">No new alerts</p>
        )}
        {alerts
          .filter((a) => !a.alert.dismissed)
          .map(({ pushKey, alert }) => (
            <Card key={pushKey}>
              <div className="text-sm font-medium text-red-700">⚠ {alert.type}</div>
              <div className="mt-1 text-xs text-gray-700">{alert.message}</div>
              <div className="mt-3">
                <button
                  onClick={() => dismissTamperAlert(uid, pushKey)}
                  className="rounded-md border border-gray-300 px-3 py-1 text-xs hover:bg-gray-100"
                >
                  Dismiss
                </button>
              </div>
            </Card>
          ))}
      </Section>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="space-y-3">
      <h2 className="text-sm font-semibold uppercase text-gray-500">{title}</h2>
      <div className="space-y-2">{children}</div>
    </div>
  );
}

function Card({ children }: { children: React.ReactNode }) {
  return <div className="rounded-lg border border-gray-200 bg-white p-3">{children}</div>;
}
