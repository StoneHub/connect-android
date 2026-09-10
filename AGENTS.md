# Connect Android

Keep this an on-demand app: no menu-bar item, login item, persistent helper, or telemetry. Closing the last window quits the app while retaining ADB connectivity.

Preserve existing ADB transports. Never log or persist QR passwords. Validate the selected device with a bounded shell command before reporting connection success. Do not use a pairing port as the debugging connection port.

Use the pinned development-only DevFeedback package per `/Users/monroe/.codex/skills/swiftui-feedback/SKILL.md`. Release builds must exclude feedback runtime and metadata. Build/install using the resolved Xcode product, and verify installed executable identity.
