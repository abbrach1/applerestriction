"use client";

import { useState } from "react";
import { ScreenTimeConfiguration } from "@/lib/types";

function clean(d: string) {
  return d.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/^www\./, "").split("/")[0];
}

export default function WebsiteTab({
  config,
  update,
  save,
}: {
  config: ScreenTimeConfiguration;
  update: (p: Partial<ScreenTimeConfiguration>) => void;
  save: (c: ScreenTimeConfiguration, command?: string) => Promise<void>;
  globalApiKey: string;
}) {
  const [newDomain, setNewDomain] = useState("");

  const isBlacklist = config.websiteFilterMode === "blacklist";
  const list = isBlacklist ? config.blockedWebsites : config.allowedWebsites;
  const setList = (v: string[]) =>
    update(isBlacklist ? { blockedWebsites: v } : { allowedWebsites: v });

  return (
    <div className="space-y-6">
      <Section title="Filter Mode">
        <div className="flex rounded-lg bg-gray-100 p-1">
          {(["blacklist", "whitelist"] as const).map((mode) => (
            <button
              key={mode}
              onClick={() => update({ websiteFilterMode: mode })}
              className={`flex-1 rounded-md px-3 py-1.5 text-sm font-medium ${
                config.websiteFilterMode === mode ? "bg-white shadow" : "text-gray-600"
              }`}
            >
              {mode === "blacklist" ? "Block Listed Sites" : "Allow Only Listed Sites"}
            </button>
          ))}
        </div>
      </Section>

      <Section title={isBlacklist ? "Blocked Sites" : "Allowed Sites"}>
        <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
          {list.length === 0 && <li className="px-4 py-3 text-sm text-gray-400">No sites yet</li>}
          {list.map((d) => (
            <li key={d} className="flex items-center justify-between px-4 py-2 text-sm">
              <span>{d}</span>
              <button
                onClick={() => setList(list.filter((x) => x !== d))}
                className="text-red-600 hover:underline text-xs"
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
        <div className="flex gap-2">
          <input
            type="text"
            placeholder="domain.com"
            value={newDomain}
            onChange={(e) => setNewDomain(e.target.value)}
            className="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
          />
          <button
            onClick={() => {
              const d = clean(newDomain);
              if (d && !list.includes(d)) setList([...list, d]);
              setNewDomain("");
            }}
            disabled={!newDomain.trim()}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            Add
          </button>
        </div>
      </Section>

      <Section title="Browser & Protection">
        <Toggle
          label="Safari Content Blocker"
          desc="Enforces allow/block list inside Safari"
          checked={config.contentBlockerEnabled}
          onChange={(v) => update({ contentBlockerEnabled: v })}
        />
        <Toggle
          label="B-SAFE Browser"
          desc="Show the built-in browser tab on the child's device"
          checked={config.browserEnabled}
          onChange={(v) => update({ browserEnabled: v })}
        />
      </Section>

      <button
        onClick={() => save(config, "updateWebsites")}
        className="w-full rounded-lg bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700"
      >
        Apply Website Settings
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
