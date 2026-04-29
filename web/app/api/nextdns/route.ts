import { NextRequest, NextResponse } from "next/server";

const BASE = "https://api.nextdns.io";

async function proxy(req: NextRequest) {
  const path = req.nextUrl.searchParams.get("path");
  const apiKey = req.headers.get("X-Forward-Api-Key");
  if (!path || !apiKey) {
    return NextResponse.json({ error: "missing path or apiKey" }, { status: 400 });
  }
  const headers: Record<string, string> = { "X-Api-Key": apiKey };
  const ct = req.headers.get("Content-Type");
  if (ct) headers["Content-Type"] = ct;

  const init: RequestInit = { method: req.method, headers };
  if (req.method !== "GET" && req.method !== "DELETE") {
    init.body = await req.text();
  }
  const res = await fetch(`${BASE}/${path}`, init);
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { "Content-Type": res.headers.get("Content-Type") || "application/json" },
  });
}

export const GET = proxy;
export const POST = proxy;
export const PATCH = proxy;
export const PUT = proxy;
export const DELETE = proxy;
