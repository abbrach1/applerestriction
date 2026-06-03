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
  let bodyForLog = "";
  if (req.method !== "GET" && req.method !== "DELETE") {
    bodyForLog = await req.text();
    init.body = bodyForLog;
  }
  try {
    const res = await fetch(`${BASE}/${path}`, init);
    const text = await res.text();
    if (!res.ok) {
      console.error(`[nextdns-proxy] ${req.method} ${path} → ${res.status}`);
      if (bodyForLog) console.error(`  body sent: ${bodyForLog}`);
      console.error(`  upstream replied: ${text || "(empty body)"}`);
    }
    // The Response constructor forbids a body on null-body statuses
    // (204/205/304). NextDNS returns 204 on successful PATCH/DELETE, so
    // passing the empty string body would throw "Invalid response status code".
    const nullBodyStatus = res.status === 204 || res.status === 205 || res.status === 304;
    return new NextResponse(nullBodyStatus ? null : text, {
      status: res.status,
      headers: { "Content-Type": res.headers.get("Content-Type") || "application/json" },
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[nextdns-proxy] fetch threw for ${req.method} ${path}: ${msg}`);
    return NextResponse.json({ error: `proxy fetch failed: ${msg}` }, { status: 502 });
  }
}

export const GET = proxy;
export const POST = proxy;
export const PATCH = proxy;
export const PUT = proxy;
export const DELETE = proxy;
