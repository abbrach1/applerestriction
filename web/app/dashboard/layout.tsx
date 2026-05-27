"use client";

import { useAuth } from "@/lib/auth";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import Link from "next/link";
import { loadUsers } from "@/lib/db";
import { ManagedUser } from "@/lib/types";

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const { user, loading, signOutUser } = useAuth();
  const router = useRouter();
  const pathname = usePathname();
  const [devices, setDevices] = useState<ManagedUser[]>([]);
  const [devicesLoading, setDevicesLoading] = useState(true);

  useEffect(() => {
    if (!loading && !user) router.replace("/login");
  }, [user, loading, router]);

  useEffect(() => {
    if (!user) return;
    loadUsers()
      .then(setDevices)
      .finally(() => setDevicesLoading(false));
  }, [user]);

  if (loading || !user) {
    return (
      <div className="flex min-h-screen items-center justify-center text-slate-500">
        <div className="flex items-center gap-2">
          <Spinner /> Loading…
        </div>
      </div>
    );
  }

  // pathname like "/dashboard", "/dashboard/settings", "/dashboard/<uid>"
  const activeUid = (() => {
    const m = pathname?.match(/^\/dashboard\/([^/]+)$/);
    if (!m) return null;
    const seg = m[1];
    return seg === "settings" ? null : seg;
  })();

  return (
    <div className="flex min-h-screen bg-slate-50">
      <Sidebar
        devices={devices}
        devicesLoading={devicesLoading}
        activeUid={activeUid}
        pathname={pathname ?? ""}
        onSignOut={() => signOutUser().then(() => router.replace("/login"))}
      />
      <div className="flex min-w-0 flex-1 flex-col">
        <TopBar email={user.email ?? ""} />
        <main className="mx-auto w-full max-w-6xl flex-1 px-6 py-6 lg:px-8">{children}</main>
      </div>
    </div>
  );
}

function Sidebar({
  devices,
  devicesLoading,
  activeUid,
  pathname,
  onSignOut,
}: {
  devices: ManagedUser[];
  devicesLoading: boolean;
  activeUid: string | null;
  pathname: string;
  onSignOut: () => void;
}) {
  return (
    <aside className="hidden w-64 shrink-0 border-r border-slate-200 bg-white md:flex md:flex-col">
      <Link
        href="/dashboard"
        className="flex items-center gap-2 px-5 py-4 border-b border-slate-200"
      >
        <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-blue-600 text-white">
          <ShieldIcon />
        </div>
        <div className="flex flex-col leading-tight">
          <span className="font-bold text-slate-900">B-SAFE</span>
          <span className="text-[11px] uppercase tracking-wider text-slate-500">Admin Console</span>
        </div>
      </Link>

      <nav className="sidebar-scroll flex-1 overflow-y-auto px-3 py-4 space-y-6">
        <SidebarSection title="Devices">
          {devicesLoading ? (
            <div className="px-3 py-2 text-sm text-slate-400">Loading devices…</div>
          ) : devices.length === 0 ? (
            <div className="px-3 py-2 text-sm text-slate-400">No devices yet</div>
          ) : (
            devices.map((d) => (
              <Link
                key={d.uid}
                href={`/dashboard/${d.uid}`}
                className={`group flex items-center gap-2 rounded-lg px-3 py-2 text-sm transition-colors ${
                  activeUid === d.uid
                    ? "bg-blue-50 text-blue-900"
                    : "text-slate-700 hover:bg-slate-50"
                }`}
              >
                <span
                  className={`relative flex h-2 w-2 ${d.isOnline ? "" : "opacity-50"}`}
                  aria-label={d.isOnline ? "online" : "offline"}
                >
                  <span
                    className={`absolute inline-flex h-full w-full animate-ping rounded-full ${
                      d.isOnline ? "bg-emerald-400 opacity-75" : "bg-transparent"
                    }`}
                  />
                  <span
                    className={`relative inline-flex h-2 w-2 rounded-full ${
                      d.isOnline ? "bg-emerald-500" : "bg-slate-300"
                    }`}
                  />
                </span>
                <span className="min-w-0 flex-1 truncate font-medium">
                  {d.email || d.deviceName || d.displayName || "Device"}
                </span>
              </Link>
            ))
          )}
        </SidebarSection>

        <SidebarSection title="Workspace">
          <SidebarLink
            href="/dashboard"
            active={pathname === "/dashboard"}
            icon={<DeviceIcon />}
            label="All Devices"
          />
          <SidebarLink
            href="/dashboard/settings"
            active={pathname === "/dashboard/settings"}
            icon={<CogIcon />}
            label="Settings"
          />
        </SidebarSection>
      </nav>

      <button
        onClick={onSignOut}
        className="m-3 flex items-center gap-2 rounded-lg border border-slate-200 px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
      >
        <SignOutIcon /> Sign out
      </button>
    </aside>
  );
}

function SidebarSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="mb-1 px-3 text-[11px] font-semibold uppercase tracking-wider text-slate-400">
        {title}
      </h3>
      <div className="space-y-0.5">{children}</div>
    </div>
  );
}

function SidebarLink({
  href,
  active,
  icon,
  label,
}: {
  href: string;
  active: boolean;
  icon: React.ReactNode;
  label: string;
}) {
  return (
    <Link
      href={href}
      className={`flex items-center gap-2 rounded-lg px-3 py-2 text-sm transition-colors ${
        active ? "bg-blue-50 text-blue-900" : "text-slate-700 hover:bg-slate-50"
      }`}
    >
      <span className={active ? "text-blue-600" : "text-slate-500"}>{icon}</span>
      <span>{label}</span>
    </Link>
  );
}

function TopBar({ email }: { email: string }) {
  return (
    <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/80 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6 lg:px-8">
        {/* Mobile brand (sidebar hidden under md) */}
        <Link href="/dashboard" className="flex items-center gap-2 md:hidden">
          <div className="flex h-7 w-7 items-center justify-center rounded-md bg-blue-600 text-white">
            <ShieldIcon />
          </div>
          <span className="font-semibold text-slate-900">B-SAFE</span>
        </Link>
        <div className="hidden md:block" />

        <div className="flex items-center gap-3 text-sm">
          <span className="hidden text-slate-500 sm:inline">{email}</span>
          <span className="flex h-7 w-7 items-center justify-center rounded-full bg-slate-200 text-xs font-semibold text-slate-600">
            {(email[0] ?? "?").toUpperCase()}
          </span>
        </div>
      </div>
    </header>
  );
}

function Spinner() {
  return (
    <span className="inline-block h-4 w-4 animate-spin rounded-full border-2 border-slate-300 border-t-blue-600" />
  );
}

function ShieldIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
    </svg>
  );
}

function DeviceIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="5" y="2" width="14" height="20" rx="2" />
      <line x1="12" y1="18" x2="12.01" y2="18" />
    </svg>
  );
}

function CogIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

function SignOutIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
      <polyline points="16 17 21 12 16 7" />
      <line x1="21" y1="12" x2="9" y2="12" />
    </svg>
  );
}
