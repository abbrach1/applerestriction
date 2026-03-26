# Screen Time Control

An iOS app for remotely controlling Apple Screen Time settings using the FamilyControls, ManagedSettings, and DeviceActivity frameworks.

## Features

- **App Blocking** — Select specific apps or categories to block with Apple's native shield UI
- **Downtime Scheduling** — Set daily blocked time windows (e.g., 10 PM – 7 AM)
- **Time Limits** — Set daily usage limits for selected apps
- **Remote Control** — Pair devices and send commands remotely via a REST API
- **Custom Shield** — Branded block screen when restricted apps are opened
- **Quick Actions** — One-tap lock/unlock all apps from the dashboard

## Architecture

```
ScreenTimeControl/          # Main app target
├── App/                    # App entry point
├── Models/                 # Data models (ScreenTimeConfiguration, RemoteCommand)
├── Services/               # Business logic
│   ├── AuthorizationManager       # FamilyControls auth
│   ├── ScreenTimeSettingsManager  # ManagedSettings + DeviceActivity
│   └── RemoteSyncService          # REST API sync & polling
└── Views/                  # SwiftUI views
    ├── Dashboard/          # Status overview + quick actions
    ├── AppPicker/          # FamilyActivityPicker integration
    ├── Schedule/           # Downtime & time limits
    └── Settings/           # Remote control pairing + settings

DeviceActivityMonitor/      # Extension: enforces downtime & time limits
ShieldConfiguration/        # Extension: custom blocked-app screen
```

## Requirements

- iOS 16.0+
- Xcode 15+
- Apple Developer account with **Family Controls** capability enabled
- A backend server for remote control features (see below)

## Setup

1. Open `ScreenTimeControl.xcodeproj` in Xcode
2. Set your development team under Signing & Capabilities
3. Enable the **Family Controls** capability in your Apple Developer account
4. Build and run on a physical device (Screen Time APIs don't work in the simulator)

## Remote Control Backend

The app expects a simple REST API. You need to deploy your own backend. Set the server URL in the app's Settings tab.

### Required API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/devices/register` | Register a device with a pairing code |
| POST | `/api/devices/pair` | Pair a parent device with a child |
| GET | `/api/devices/:id/settings` | Get settings for a device |
| POST | `/api/devices/:id/settings` | Push settings to a device |
| POST | `/api/devices/:id/commands` | Send a command to a device |
| GET | `/api/devices/:id/commands/pending` | Get pending commands |
| POST | `/api/devices/:id/commands/:cmdId/executed` | Mark command as executed |

## How It Works

1. **Authorization**: The app requests FamilyControls authorization (individual or parent mode)
2. **App Selection**: Uses Apple's `FamilyActivityPicker` to select apps/categories
3. **Enforcement**: `ManagedSettingsStore` applies shields to blocked apps
4. **Monitoring**: `DeviceActivityMonitor` extension handles downtime and time limit events
5. **Remote**: Parent device pushes settings to server; child device polls for commands

## Important Notes

- Screen Time APIs require a **physical device** — they do not work in the iOS Simulator
- The Family Controls entitlement requires approval from Apple for App Store distribution
- Remote features require you to deploy and configure your own backend server
