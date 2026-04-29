"use client";

import { useAuth } from "@/lib/auth";
import { useRouter } from "next/navigation";
import { useEffect } from "react";
import Link from "next/link";

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const { user, loading, signOutUser } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!loading && !user) router.replace("/login");
  }, [user, loading, router]);

  if (loading || !user) {
    return <div className="flex min-h-screen items-center justify-center text-gray-500">Loading…</div>;
  }

  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-10 border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-3">
          <Link href="/dashboard" className="font-bold text-lg">B-SAFE Admin</Link>
          <div className="flex items-center gap-3">
            <Link
              href="/dashboard/settings"
              className="rounded-md border border-gray-300 px-3 py-1 text-sm hover:bg-gray-100"
            >
              Settings
            </Link>
            <span className="text-sm text-gray-500 hidden sm:inline">{user.email}</span>
            <button
              onClick={() => signOutUser().then(() => router.replace("/login"))}
              className="rounded-md border border-gray-300 px-3 py-1 text-sm hover:bg-gray-100"
            >
              Sign Out
            </button>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-6 py-6">{children}</main>
    </div>
  );
}
