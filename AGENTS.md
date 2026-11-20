# Connect Android

Keep this an on-demand app: no menu-bar item, login item, persistent helper, or telemetry. Closing the last window quits the app while retaining ADB connectivity.

`--status` and `--mcp` (`Sources/AgentBridge.swift`) run the same executable without a window. `--status` prints once and exits. `--mcp` is a child of the agent that started it, talks only over stdin/stdout, and exits when stdin closes. That is what keeps it inside the no-persistent-helper rule: do not add a socket, a launch agent, a daemonized process, or anything that outlives its caller. The bridge never runs `kill-server`, `pair` or `disconnect`; pairing stays in the window.

Preserve existing ADB transports. Never log or persist QR passwords. Validate the selected device with a bounded shell command before reporting connection success, on every path (window, `--status`, MCP tools). A device on any transport (Wi-Fi, USB, emulator) that passes counts as connected; one that does not gets a plain reason in Details and in `status`. Do not use a pairing port as the debugging connection port.

Use the pinned development-only DevFeedback package per `/Users/monroe/.codex/skills/swiftui-feedback/SKILL.md`. Release builds must exclude feedback runtime and metadata. Build/install using the resolved Xcode product, and verify installed executable identity. Run the engine tests (command in README) after any change to `PairingEngine.swift` or `AgentBridge.swift`; fixtures for device output are pasted from real captures.
