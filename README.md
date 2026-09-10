# Connect Android

An on-demand macOS utility for Android wireless debugging. Open the app from your Desktop, scan a QR code if pairing is needed, and close the window after connection. No menu-bar item, login item, or persistent app helper.

Requires macOS 14 or newer, Android 11 or newer with Wireless debugging enabled, and Android SDK platform-tools (`adb`) installed on the Mac. Both devices must be on the same local network. This app does not bundle platform-tools or upload pairing credentials.

## Use

1. Open **Connect Android**.
2. If a QR code appears, open **Developer options → Wireless debugging → Pair device with QR code** on your phone and scan it.
3. Wait for the connected device name. Close the app; ADB retains the connection.

If macOS requests Local Network access, allow it. Network isolation or blocked multicast can prevent discovery. Details contains a bounded local diagnostic log; pairing passwords are excluded. Choose ADB lets you use an SDK installed elsewhere.

## Connection policy

- Verify an existing online device before offering a new pairing session.
- Preserve existing ADB transports. Refresh the server automatically only when none are listed.
- Generate fresh local pairing credentials; discover the exact service requested by the QR code.
- Pair and connect through separate endpoints, then run a device command before reporting success.
- Bound discovery and subprocess work; closing the app cancels its work without stopping the ADB server.

Android documents the protocol in [Architecture of ADB Wifi](https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/dev/adb_wifi.md).

## Development

Use Xcode and XcodeGen. See `scripts/` for build/install commands and `Vendor/` for the pinned development-only feedback dependency. Release packaging must exclude feedback UI and metadata. Development feedback does not add controls to the normal app layout.

Public releases are signed with a Developer ID certificate. Notarization status is stated in each release's notes.

Build and install locally (leaving the app closed):

```sh
python3 scripts/build-install.py --no-launch
```

Run isolated connection tests without touching a phone or the real ADB server:

```sh
mkdir -p .build
swiftc Sources/PairingEngine.swift Tests/EngineTests.swift -parse-as-library -o .build/engine-tests
.build/engine-tests
```

Development dependency provenance: [Vendor/PROVENANCE.md](Vendor/PROVENANCE.md).
