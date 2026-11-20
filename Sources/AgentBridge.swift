import Foundation
import ImageIO

/// Command-line and MCP access to the connection this app sets up.
///
/// Nothing here outlives its caller: `--status` prints once and exits, and `--mcp` serves one
/// agent over stdin/stdout and exits when that agent closes the pipe. No socket, no launch agent.
struct AgentBridge {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { (String(data: stdout, encoding: .utf8) ?? "") + stderr }
    }
    struct Device: Encodable {
        let serial: String
        let state: String
        let transport: String
        let usable: Bool
        let model: String?
        let reason: String?
    }
    struct Status: Encodable {
        var version = 1
        let adb: String
        let ready: Bool
        let devices: [Device]
    }

    /// Commands that would drop transports other tools rely on, or that carry pairing secrets.
    static let blockedCommands: Set<String> = ["kill-server", "pair", "disconnect", "tcpip", "usb", "reconnect"]
    /// Commands that address the ADB server, not one device, so they take no `-s`.
    static let serverCommands: Set<String> = ["devices", "version", "help", "mdns", "connect", "start-server", "host-features"]
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let outputLimit = 200_000
    static let blockedServer = "The phone is on this network, but the ADB server on this Mac got “No route to host” reaching it. macOS reports that when the app that started the ADB server lacks Local Network permission. Allow that app under System Settings → Privacy & Security → Local Network, then restart the server once with adb kill-server."

    var adbOverride: String?
    /// Opens the app window with `--result-file`; replaced in tests.
    var openWindow: (URL) throws -> Void = AgentBridge.openInstalledWindow
    /// Finds debugging services on the local network; replaced in tests.
    var discover: () async -> [PairingEngine.Service] = { await AgentBridge.browseBonjour() }

    // MARK: ADB

    func adbPath() throws -> String {
        guard let path = PairingEngine.resolveADB(explicit: adbOverride) else {
            throw Failure(message: "ADB was not found. Install Android SDK Platform-Tools, or open Connect Android and choose its adb executable.")
        }
        return path
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> Output {
        let path = try adbPath()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("connect-android-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("out"), errURL = directory.appendingPathComponent("err")
        for url in [outURL, errURL] {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Failure(message: "Unable to create a temporary ADB output file.")
            }
        }
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["ADB_MDNS_OPENSCREEN"] = "1"
        process.environment = environment
        try process.run()
        // Reap only this child. The ADB server it talks to keeps running.
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else {
                throw Failure(message: "adb \(arguments.first { !$0.hasPrefix("-") } ?? "command") did not finish within \(Int(timeout)) seconds and was stopped.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return Output(status: process.terminationStatus, stdout: try Data(contentsOf: outURL),
                      stderr: String(data: try Data(contentsOf: errURL), encoding: .utf8) ?? "")
    }

    /// A device counts only after it answers a bounded shell command.
    func verify(_ serial: String) async -> String? {
        guard let state = try? await run(["-s", serial, "get-state"], timeout: 5), state.status == 0,
              state.text.trimmingCharacters(in: .whitespacesAndNewlines) == "device",
              let model = try? await run(["-s", serial, "shell", "getprop", "ro.product.model"], timeout: 5),
              model.status == 0 else { return nil }
        let name = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func status() async throws -> Status {
        let inventory = try await run(["devices", "-l"], timeout: 10)
        guard inventory.status == 0 else { throw Failure(message: "adb devices failed: \(inventory.text)") }
        var devices: [Device] = []
        for row in PairingEngine.deviceRows(inventory.text) {
            let transport = PairingEngine.transport(of: row.serial)
            if row.state != "device" {
                devices.append(Device(serial: row.serial, state: row.state, transport: transport, usable: false,
                                      model: nil, reason: PairingEngine.unusableReason(state: row.state)))
            } else if let model = await verify(row.serial) {
                devices.append(Device(serial: row.serial, state: row.state, transport: transport, usable: true,
                                      model: model, reason: nil))
            } else {
                devices.append(Device(serial: row.serial, state: row.state, transport: transport, usable: false,
                                      model: nil, reason: PairingEngine.unansweredReason))
            }
        }
        return Status(adb: try adbPath(), ready: devices.contains { $0.usable }, devices: devices)
    }

    func target(_ serial: String?) async throws -> String {
        if let serial, !serial.isEmpty { return serial }
        let devices = try await status().devices
        let usable = devices.filter(\.usable)
        if usable.count == 1 { return usable[0].serial }
        if usable.isEmpty {
            let reasons = devices.map { "\($0.serial): \($0.reason ?? $0.state)" }.joined(separator: " ")
            throw Failure(message: "No usable Android device. Call connect first." + (reasons.isEmpty ? "" : " " + reasons))
        }
        // ADB can list one phone twice, once by address and once by its Bonjour name.
        var hardware = Set<String>()
        for device in usable {
            var id = device.serial
            if let output = try? await run(["-s", device.serial, "shell", "getprop", "ro.serialno"], timeout: 5), output.status == 0 {
                let reported = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reported.isEmpty { id = reported }
            }
            hardware.insert(id)
        }
        if hardware.count == 1 { return usable[0].serial }
        throw Failure(message: "Several devices are connected. Pass serial, one of: " + usable.map(\.serial).joined(separator: ", "))
    }

    // MARK: Tools

    func connect(endpoint: String?, timeout: TimeInterval, window: Bool) async throws -> Device {
        func usable(_ serial: String? = nil) async throws -> Device? {
            try await status().devices.first { $0.usable && (serial == nil || $0.serial == serial) }
        }
        if let endpoint, !endpoint.isEmpty {
            guard endpoint.range(of: #"^[A-Za-z0-9._\-\[\]:]+:[0-9]{1,5}$"#, options: .regularExpression) != nil else {
                throw Failure(message: "endpoint must be host:port, the IP address and port on the phone's Wireless debugging screen.")
            }
            if let device = try await usable(endpoint) { return device }
            let attempt = try await run(["connect", endpoint], timeout: 10)
            if let device = try await usable(endpoint) { return device }
            if attempt.text.contains("No route to host") { throw Failure(message: Self.blockedServer) }
            throw Failure(message: "\(endpoint) did not answer a shell command. Use the IP address and port from the Wireless debugging screen. The port under “Pair device” is for pairing only and is not the debugging port.")
        }
        if let device = try await usable() { return device }
        // A phone paired earlier advertises its debugging service; no new pairing is needed.
        // ADB's own discovery can miss it, so macOS Bonjour is asked as well.
        var services: [PairingEngine.Service] = []
        if let listed = try? await run(["mdns", "services"], timeout: 5), listed.status == 0 {
            services = PairingEngine.parseServices(listed.text)
        }
        services += await discover()
        var tried = Set<String>(), blocked = false
        for service in services where service.type == "_adb-tls-connect._tcp" && tried.insert(service.endpoint).inserted {
            let attempt = try? await run(["connect", service.endpoint], timeout: 10)
            if let device = try await usable(service.endpoint) { return device }
            if attempt?.text.contains("No route to host") == true { blocked = true }
        }
        // The phone is advertising, yet the ADB server cannot open a socket to it.
        if blocked { throw Failure(message: Self.blockedServer) }
        guard window else {
            throw Failure(message: "No usable Android device, and none paired earlier is advertising on this network.")
        }
        return try await connectThroughWindow(timeout: timeout)
    }

    private func connectThroughWindow(timeout: TimeInterval) async throws -> Device {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("connect-android-result-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let result = directory.appendingPathComponent("result.json")
        try openWindow(result)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let data = try? Data(contentsOf: result),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = value["state"] as? String else { continue }
            switch state {
            case "ready":
                guard let serial = value["serial"] as? String else { continue }
                return Device(serial: serial, state: "device", transport: PairingEngine.transport(of: serial),
                              usable: true, model: value["device"] as? String, reason: nil)
            case "failed":
                throw Failure(message: (value["message"] as? String) ?? "Connect Android could not connect.")
            case "cancelled":
                throw Failure(message: "The Connect Android window was closed before a phone connected.")
            default: continue
            }
        }
        throw Failure(message: "No phone connected within \(Int(timeout)) seconds. The Connect Android window may still be showing a QR code: scan it from Developer options → Wireless debugging → Pair device with QR code, then call status.")
    }

    @MainActor static func browseBonjour() async -> [PairingEngine.Service] {
        let browser = BonjourDiscovery()
        browser.start()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let found = browser.services
        browser.stop()
        return found
    }

    static func openInstalledWindow(resultFile: URL) throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            throw Failure(message: "The pairing window is only available from the installed Connect Android app.")
        }
        var arguments = ["-n", "-a", bundle.path]
        if let socket = ProcessInfo.processInfo.environment["ADB_SERVER_SOCKET"] {
            arguments += ["--env", "ADB_SERVER_SOCKET=" + socket]
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments + ["--args", "--result-file", resultFile.path]
        open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
        try open.run(); open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw Failure(message: "Could not open the Connect Android window.") }
    }

    func adb(_ arguments: [String], serial: String?, timeout: TimeInterval) async throws -> Output {
        var index = 0
        var addressed = false
        while index < arguments.count, arguments[index].hasPrefix("-") {
            if ["-s", "-t", "-d", "-e"].contains(arguments[index]) { addressed = true }
            index += ["-s", "-t", "-H", "-P", "-L"].contains(arguments[index]) ? 2 : 1
        }
        guard index < arguments.count else { throw Failure(message: "args needs an adb command, for example [\"shell\", \"getprop\"].") }
        let command = arguments[index]
        if Self.blockedCommands.contains(command) {
            throw Failure(message: "adb \(command) is not available here: it would drop connections other tools rely on, or needs a pairing code. Use the Connect Android window for pairing.")
        }
        if command == "shell", index == arguments.count - 1 {
            throw Failure(message: "An interactive shell cannot run here. Pass the command, for example [\"shell\", \"ls\", \"/sdcard\"].")
        }
        var full = arguments
        if !addressed, !Self.serverCommands.contains(command) { full = ["-s", try await target(serial)] + arguments }
        return try await run(full, timeout: timeout)
    }

    func install(path: String, serial: String?) async throws -> String {
        guard path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path) else {
            throw Failure(message: "path must be an absolute path to a readable .apk file.")
        }
        let device = try await target(serial)
        let output = try await run(["-s", device, "install", "-r", path], timeout: 300)
        guard output.status == 0, output.text.contains("Success") else {
            throw Failure(message: "Install failed on \(device): \(output.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return "Installed \(URL(fileURLWithPath: path).lastPathComponent) on \(device)."
    }

    struct Screenshot { let data: Data; let mimeType: String; let note: String }

    /// The display that is switched on, from `dumpsys display` (a folded phone lists two).
    static func activeDisplayID(_ dumpsys: String) -> String? {
        for line in dumpsys.split(separator: "\n") where line.contains("DisplayDeviceInfo{") && line.contains(", state ON,") {
            guard let start = line.range(of: "uniqueId=\"local:") else { continue }
            let id = line[start.upperBound...].prefix { $0.isNumber }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }

    private func screencap(_ device: String) async throws -> Data {
        let magic = Data([0x89, 0x50, 0x4E, 0x47])
        let first = try await run(["-s", device, "exec-out", "screencap", "-p"], timeout: 20)
        if first.status == 0, first.stdout.starts(with: magic) { return first.stdout }
        // With several displays screencap prints a warning ahead of the image and may pick the one that is off.
        if let displays = try? await run(["-s", device, "shell", "dumpsys", "display"], timeout: 10), displays.status == 0,
           let id = Self.activeDisplayID(displays.text),
           let chosen = try? await run(["-s", device, "exec-out", "screencap", "-p", "-d", id], timeout: 20),
           chosen.status == 0, chosen.stdout.starts(with: magic) { return chosen.stdout }
        if first.status == 0, let start = first.stdout.range(of: magic) { return Data(first.stdout[start.lowerBound...]) }
        throw Failure(message: "The device did not return a screenshot. \(first.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    func screenshot(serial: String?, maxDimension: Int, savePath: String?) async throws -> Screenshot {
        let device = try await target(serial)
        let png = try await screencap(device)
        var note = "Screenshot of \(device)."
        if let savePath {
            guard savePath.hasPrefix("/") else { throw Failure(message: "save_path must be absolute.") }
            try png.write(to: URL(fileURLWithPath: savePath), options: .atomic)
            note += " Full-size PNG saved to \(savePath)."
        }
        guard maxDimension > 0, let source = CGImageSourceCreateWithData(png as CFData, nil) else {
            return Screenshot(data: png, mimeType: "image/png", note: note)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxDimension]
        let encoded = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
            return Screenshot(data: png, mimeType: "image/png", note: note)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return Screenshot(data: png, mimeType: "image/png", note: note)
        }
        return Screenshot(data: encoded as Data, mimeType: "image/jpeg", note: note + " Shown at \(image.width)×\(image.height).")
    }

    // MARK: MCP

    static let tools: [[String: Any]] = {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        let serial: [String: Any] = ["type": "string", "description": "Device serial from status. Optional when exactly one device is usable."]
        return [
            tool("status", "List the Android devices ADB knows on this Mac (Wi-Fi, USB, emulator), whether each answers a shell command, and why a listed device is not usable."),
            tool("connect", "Make sure a device is connected and answering. Reuses any usable device, then tries a phone paired earlier, then opens the Connect Android window so the user can scan a QR code.", [
                "endpoint": ["type": "string", "description": "host:port from the phone's Wireless debugging screen. Not the pairing port."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait for the pairing window. Default 120, at most 330."],
                "open_window": ["type": "boolean", "description": "Open the pairing window if nothing else works. Default true."]]),
            tool("adb", "Run one adb command against the connected device and return its output. kill-server, pair, disconnect, tcpip, usb and reconnect are refused.", [
                "args": ["type": "array", "items": ["type": "string"], "description": "Arguments after adb, for example [\"shell\", \"pm\", \"list\", \"packages\"]."],
                "serial": serial,
                "timeout_seconds": ["type": "integer", "description": "Default 30, at most 300."]], required: ["args"]),
            tool("install", "Install or update an APK on the connected device.", [
                "path": ["type": "string", "description": "Absolute path to the .apk on this Mac."], "serial": serial], required: ["path"]),
            tool("screenshot", "Capture the device screen as an image.", [
                "serial": serial,
                "max_dimension": ["type": "integer", "description": "Longest side in pixels of the returned JPEG. Default 1600. 0 returns the full PNG."],
                "save_path": ["type": "string", "description": "Absolute path to also save the full-size PNG."]]),
        ]
    }()

    static func text(_ string: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": isError]
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        func seconds(_ fallback: Int, limit: Int) -> TimeInterval {
            TimeInterval(min(max((arguments["timeout_seconds"] as? Int) ?? fallback, 1), limit))
        }
        let serial = arguments["serial"] as? String
        do {
            switch name {
            case "status":
                return Self.text(Self.json(try await status()))
            case "connect":
                let device = try await connect(endpoint: arguments["endpoint"] as? String, timeout: seconds(120, limit: 330),
                                               window: (arguments["open_window"] as? Bool) ?? true)
                return Self.text(Self.json(device))
            case "adb":
                guard let args = arguments["args"] as? [String], !args.isEmpty else { throw Failure(message: "args must be a non-empty array of strings.") }
                let output = try await adb(args, serial: serial, timeout: seconds(30, limit: 300))
                var body = output.text
                if body.count > Self.outputLimit { body = String(body.prefix(Self.outputLimit)) + "\n[output truncated]" }
                if output.status != 0 { body += "\n[adb exited \(output.status)]" }
                return Self.text(body, isError: output.status != 0)
            case "install":
                guard let path = arguments["path"] as? String else { throw Failure(message: "path is required.") }
                return Self.text(try await install(path: path, serial: serial))
            case "screenshot":
                let shot = try await screenshot(serial: serial, maxDimension: (arguments["max_dimension"] as? Int) ?? 1600,
                                                savePath: arguments["save_path"] as? String)
                return ["content": [["type": "image", "data": shot.data.base64EncodedString(), "mimeType": shot.mimeType],
                                    ["type": "text", "text": shot.note]], "isError": false]
            default:
                return Self.text("Unknown tool: \(name)", isError: true)
            }
        } catch {
            return Self.text(error.localizedDescription, isError: true)
        }
    }

    /// One JSON-RPC message in, at most one out. Notifications get no reply.
    func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        func reply(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        let parameters = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            let requested = parameters["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return reply(["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "connect-android", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                          "instructions": "Android devices connected to this Mac over ADB. Call status first; call connect if no device is usable."])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": Self.tools])
        case "tools/call":
            guard let name = parameters["name"] as? String else {
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Missing tool name"]]
            }
            return reply(await call(name, parameters["arguments"] as? [String: Any] ?? [:]))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    /// Serves until the agent closes stdin, then returns so the process can exit.
    func serve() async {
        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                    continue
                }
                if let response = await handle(message) { send(response) }
            }
        } catch { }
    }

    /// Entry for `--status` and `--mcp`. Returns the process exit code.
    static func runCommandLine(_ arguments: [String]) async -> Int32 {
        let bridge = AgentBridge()
        if arguments.contains("--mcp") { await bridge.serve(); return 0 }
        do {
            let status = try await bridge.status()
            print(json(status))
            return status.ready ? 0 : 1
        } catch {
            struct Problem: Encodable { var version = 1; var ready = false; let message: String }
            print(json(Problem(message: error.localizedDescription)))
            return 2
        }
    }
}
