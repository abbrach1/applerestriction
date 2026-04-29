"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { loadUsers } from "@/lib/db";
import { ManagedUser } from "@/lib/types";

export default function DashboardPage() {
  const [users, setUsers] = useState<ManagedUser[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadUsers().then((u) => {
      setUsers(u);
      setLoading(false);
    });
  }, []);

  if (loading) return <p className="text-gray-500">Loading children…</p>;
  if (users.length === 0) return <p className="text-gray-500">No child devices registered yet.</p>;

  return (
    <div className="space-y-3">
      <h1 className="text-2xl font-bold">Child Devices</h1>
      <div className="grid gap-3">
        {users.map((u) => (
          <Link
            key={u.uid}
            href={`/dashboard/${u.uid}`}
            className="flex items-center justify-between rounded-xl border border-gray-200 bg-white p-4 hover:border-blue-400 hover:shadow-sm"
          >
            <div>
              <div className="flex items-center gap-2">
                <span className={`h-2 w-2 rounded-full ${u.isOnline ? "bg-green-500" : "bg-gray-300"}`} />
                <span className="font-semibold">{u.deviceName}</span>
              </div>
              <p className="text-sm text-gray-500">{u.email}</p>
            </div>
            <span className="text-gray-400">›</span>
          </Link>
        ))}
      </div>
    </div>
  );
}
