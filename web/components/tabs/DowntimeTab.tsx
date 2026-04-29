"use client";

import { ScreenTimeConfiguration } from "@/lib/types";

export default function DowntimeTab({
  config,
  update,
  save,
}: {
  config: ScreenTimeConfiguration;
  update: (p: Partial<ScreenTimeConfiguration>) => void;
  save: (c: ScreenTimeConfiguration, command?: string) => Promise<void>;
}) {
  const sched = config.downtimeSchedule;

  function setSched(p: Partial<typeof sched>) {
    update({ downtimeSchedule: { ...sched, ...p } });
  }

  function fmt(h: number, m: number) {
    return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
  }

  function parse(s: string): { h: number; m: number } {
    const [h, m] = s.split(":").map(Number);
    return { h: h || 0, m: m || 0 };
  }

  return (
    <div className="space-y-6">
      <label className="flex cursor-pointer items-center justify-between rounded-lg border border-gray-200 bg-white p-3">
        <div>
          <div className="text-sm font-medium">Enable Downtime</div>
          <div className="text-xs text-gray-500">Block all apps during scheduled hours</div>
        </div>
        <input
          type="checkbox"
          checked={config.downtimeEnabled}
          onChange={(e) => update({ downtimeEnabled: e.target.checked })}
          className="h-5 w-9 cursor-pointer appearance-none rounded-full bg-gray-300 transition-colors checked:bg-blue-600 relative
          before:absolute before:left-0.5 before:top-0.5 before:h-4 before:w-4 before:rounded-full before:bg-white before:transition-transform
          checked:before:translate-x-4"
        />
      </label>

      {config.downtimeEnabled && (
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Start</label>
            <input
              type="time"
              value={fmt(sched.startHour, sched.startMinute)}
              onChange={(e) => {
                const { h, m } = parse(e.target.value);
                setSched({ startHour: h, startMinute: m });
              }}
              className="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700">End</label>
            <input
              type="time"
              value={fmt(sched.endHour, sched.endMinute)}
              onChange={(e) => {
                const { h, m } = parse(e.target.value);
                setSched({ endHour: h, endMinute: m });
              }}
              className="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
            />
          </div>
        </div>
      )}

      <button
        onClick={() => save(config, "updateDowntime")}
        className="w-full rounded-lg bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700"
      >
        Apply Downtime
      </button>
    </div>
  );
}
