# B-SAFE Admin Web Portal

Next.js 15 admin dashboard. Reads/writes Firebase Realtime Database used by the iOS app.

## Local setup

```bash
cd web
cp .env.local.example .env.local
# fill in NEXT_PUBLIC_FIREBASE_APP_ID after creating a Web app in Firebase Console
npm install
npm run dev          # http://localhost:3000
```

### Get the Web App ID

1. Go to [Firebase Console](https://console.firebase.google.com/) → project `applerestrictions`
2. Project Settings → "Your apps" → click `</>` to add a Web app (skip if one exists)
3. Copy the `appId` value into `NEXT_PUBLIC_FIREBASE_APP_ID` in `.env.local`

## Deploy to Vercel

1. Push the repo to GitHub
2. [vercel.com/new](https://vercel.com/new) → Import the repo
3. **Root Directory**: `web`
4. Add the same env vars (NEXT_PUBLIC_FIREBASE_*) under Environment Variables
5. Deploy

Future pushes to the branch auto-deploy.

## Auth

Sign in with the same admin Firebase Auth credentials you use in the iOS app. Make sure the admin user has read/write access to `/users/*` in Realtime Database rules.

## Features

- Login (Firebase Auth)
- List of child devices (online status, device name)
- Per-device tabs:
  - **Websites** — block/allow domains, content blocker toggle, browser toggle
  - **DNS** — Logs / Allow / Block / Safety (NextDNS via API proxy at `/api/nextdns`)
  - **Downtime** — schedule
  - **Apps** — App Store search + recommendations, app review, block-new-apps toggle, emergency bypass codes, send admin notifications
  - **Requests** — unlock requests, website requests, tamper alerts (live)
  - **Commands** — lock/unlock all, refresh, block new apps
- **Settings page** (`/dashboard/settings`) — global NextDNS API key, alert email, SendGrid key
