# B-SAFE Admin Console (Web)

A browser-based companion to the iOS admin app. Signs in with the same
Firebase Auth email/password, reads and writes `/users/{uid}/…` directly, and
matches the iOS `ScreenTimeConfiguration` schema 1:1.

## What it does

- **Sign in** with your iOS admin email + password (Firebase Auth).
- **Pick a user** from the sidebar — online users float to the top.
- **Websites tab** — blacklist/whitelist mode, edit domain lists, toggle Safari
  Content Blocker and the B-SAFE Browser visibility, hit **Apply**.
- **DNS tab** — turn Force NextDNS on/off, set profile ID, set removal
  password, enable SafeSearch / YouTube Restricted.
- **Downtime tab** — daily window + active-days picker.
- **Apps & Limits tab** — block new app installs, adjust / pause / delete
  existing daily time limits. (Creating a new time limit still requires the
  iOS admin app because Apple's `FamilyActivityPicker` only runs on iOS.)
- **Requests tab** — approve or deny unlock / website requests from the child.
  Approved websites land on the allowed list and flip the device to whitelist
  mode; the child gets a push either way.
- **Send tab** — push a titled notification to the child's device.
- **Lock All / Unlock All / Refresh** quick actions in the header.
- **Tamper alerts** banner above the tabs, dismissible.

## What still requires the iOS admin app

These use iOS-only APIs that have no browser equivalent:

- Picking specific apps via `FamilyActivityPicker` (for Block Specific Apps or
  creating a new per-app time limit). Web can only edit existing selections.
- Installing the NextDNS `.mobileconfig` profile on the admin's phone.

## Running locally

It's a static page — any local HTTP server works:

```sh
cd admin
python3 -m http.server 8080
# open http://localhost:8080
```

## Deploying to Firebase Hosting

From the repo root:

```sh
firebase login
firebase use applerestrictions
firebase deploy --only hosting
```

`firebase.json` at the repo root already points at the `admin/` directory.
After deploy it's live at `https://applerestrictions.web.app` (and
`https://applerestrictions.firebaseapp.com`).

## Security

The console relies on Firebase's Realtime Database rules to gate access.
Make sure `/users/{uid}` is only readable/writable by the authenticated
admin account — the same restriction the iOS admin already depends on.
