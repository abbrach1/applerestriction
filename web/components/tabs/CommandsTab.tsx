"use client";

import { ScreenTimeConfiguration } from "@/lib/types";
import { sendCommand } from "@/lib/db";
import { useState } from "react";

export default function CommandsTab({
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
  const [working, setWorking] = useState<string | null>(null);

  async function action(label: string, fn: () => Promise<void>) {
    setWorking(label);
    try {
      await fn();
    } finally {
      setWorking(null);
    }
  }

  return (
    <div className="space-y-3">
      <Action
        label={config.isLocked ? "Unlock All Apps" : "Lock All Apps"}
        color={config.isLocked ? "green" : "red"}
        loading={working === "lock"}
        onClick={() =>
          action("lock", async () => {
            const next = { ...config, isLocked: !config.isLocked };
            update({ isLocked: next.isLocked });
            await save(next, next.isLocked ? "lockDevice" : "unlockAll");
          })
        }
      />
      <Action
        label="Refresh Settings on Device"
        color="blue"
        loading={working === "refresh"}
        onClick={() => action("refresh", () => sendCommand(uid, "refreshSettings"))}
      />
      <Action
        label="Block Installation of New Apps"
        color={config.blockNewApps ? "red" : "gray"}
        loading={working === "blockNew"}
        onClick={() =>
          action("blockNew", async () => {
            const next = { ...config, blockNewApps: !config.blockNewApps };
            update({ blockNewApps: next.blockNewApps });
            await save(next);
          })
        }
      />
    </div>
  );
}

function Action({
  label,
  color,
  loading,
  onClick,
}: {
  label: string;
  color: "blue" | "red" | "green" | "gray";
  loading?: boolean;
  onClick: () => void;
}) {
  const colors: Record<string, string> = {
    blue: "bg-blue-600 hover:bg-blue-700",
    red: "bg-red-600 hover:bg-red-700",
    green: "bg-green-600 hover:bg-green-700",
    gray: "bg-gray-500 hover:bg-gray-600",
  };
  return (
    <button
      disabled={loading}
      onClick={onClick}
      className={`w-full rounded-lg py-3 text-sm font-semibold text-white disabled:opacity-50 ${colors[color]}`}
    >
      {loading ? "Working…" : label}
    </button>
  );
}
