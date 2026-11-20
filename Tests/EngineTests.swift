import Foundation

@main struct EngineTests {
    @MainActor static func main() async throws {
        let oldADBPath = UserDefaults.standard.string(forKey: "selectedADBPath")
        defer {
            if let oldADBPath { UserDefaults.standard.set(oldADBPath, forKey: "selectedADBPath") }
            else { UserDefaults.standard.removeObject(forKey: "selectedADBPath") }
        }
        let rows = PairingEngine.deviceRows("List of devices attached\nphone device product:a\nother unauthorized\nstale offline\nusb no permissions\n")
        precondition(rows.count == 4, "Transport inventory must retain unready transports")
        let services = PairingEngine.parseServices("List of discovered mdns services\nstudio-selected _adb-tls-pairing._tcp. 192.168.1.2:37111\nadb-phone _adb-tls-connect._tcp 192.168.1.2:38222\nother _adb._tcp 192.168.1.3:5555\n")
        precondition(services.count == 2)
        precondition(services[0].endpoint != services[1].endpoint, "Pairing and connection ports are distinct")
        precondition(services[0].host == services[1].host)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connect-android-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("adb")
        let calls = directory.appendingPathComponent("calls")
        func install(_ body: String) throws {
            try ("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + calls.path + "'\n" + body).write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            try? FileManager.default.removeItem(at: calls)
        }
        func history() -> String { (try? String(contentsOf: calls, encoding: .utf8)) ?? "" }
        func wait(_ predicate: () -> Bool, seconds: Double = 8) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(predicate(), "Timed out waiting for engine state")
        }
        try install("""
        case "$*" in
          'devices -l') printf 'List of devices attached\\n192.168.1.2:38222 device\\n';;
          '-s 192.168.1.2:38222 get-state') echo device;;
          '-s 192.168.1.2:38222 shell getprop ro.product.model') echo TestPhone;;
          *) exit 7;;
        esac
        """)
        let existing = PairingEngine(); existing.start(adbURL: fake)
        try await wait { existing.phase == .connected }
        precondition(existing.deviceName == "TestPhone")
        precondition(!history().contains("kill-server"), "Existing verified connection must preserve server")
        existing.stop()
        try install("""
        case "$*" in
          'devices -l') printf 'List of devices attached\\nphone unauthorized\\n';;
          'mdns services') echo 'List of discovered mdns services';;
          *) exit 7;;
        esac
        """)
        let unauthorized = PairingEngine(); unauthorized.start(adbURL: fake)
        try await wait { unauthorized.phase == .scanning }
        precondition(!history().contains("kill-server"), "Unauthorized transport still protects server")
        precondition(unauthorized.qrPayload?.hasPrefix("WIFI:T:ADB;S:studio-") == true)
        let password = unauthorized.qrPayload!.components(separatedBy: "P:")[1].components(separatedBy: ";")[0]
        precondition(!unauthorized.log.contains(password), "QR secret must never enter log")
        unauthorized.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(unauthorized.qrPayload == nil && unauthorized.phase == .idle)
        let nameFile = directory.appendingPathComponent("service")
        try install("""
        case "$*" in
          'devices -l') echo 'List of devices attached';;
          'kill-server'|'start-server') exit 0;;
          'mdns services')
            if test -f '\(nameFile.path)'; then
              name=$(cat '\(nameFile.path)')
              printf '%s _adb-tls-pairing._tcp 192.168.1.2:37111\\n' "$name"
              echo 'studio-wrong _adb-tls-pairing._tcp 192.168.1.3:39999'
              echo 'adb-phone _adb-tls-connect._tcp 192.168.1.2:38222'
            fi;;
          'pair 192.168.1.2:37111') read secret; echo 'Successfully paired to 192.168.1.2:37111 [guid=adb-phone]';;
          'connect 192.168.1.2:38222') echo 'connected to 192.168.1.2:38222';;
          '-s 192.168.1.2:38222 get-state') echo device;;
          '-s 192.168.1.2:38222 shell getprop ro.product.model') echo FreshPhone;;
          *) exit 9;;
        esac
        """)
        let fresh = PairingEngine(); fresh.start(adbURL: fake)
        try await wait { fresh.phase == .scanning }
        let selectedName = fresh.qrPayload!.components(separatedBy: "S:")[1].components(separatedBy: ";")[0]
        try selectedName.write(to: nameFile, atomically: true, encoding: .utf8)
        try await wait { fresh.phase == .connected }
        precondition(fresh.deviceName == "FreshPhone")
        precondition(history().components(separatedBy: "kill-server").count == 2, "Empty inventory refreshes exactly once")
        precondition(history().contains("pair 192.168.1.2:37111"))
        precondition(history().contains("connect 192.168.1.2:38222"))
        precondition(!history().contains("39999"), "Unrelated pairing services must not be selected")
        fresh.stop()

        let resultFile = directory.appendingPathComponent("result.json")
        let transportFile = directory.appendingPathComponent("transport")
        func result() -> [String: Any] {
            guard let data = try? Data(contentsOf: resultFile),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return value
        }
        try "{\"state\":\"ready\"}".write(to: resultFile, atomically: true, encoding: .utf8)
        try "offline".write(to: transportFile, atomically: true, encoding: .utf8)
        try install("""
        case "$*" in
          'devices -l') printf 'List of devices attached\\n192.168.1.2:38222 %s\\n' "$(cat '\(transportFile.path)')";;
          'mdns services') echo 'List of discovered mdns services';;
          '-s 192.168.1.2:38222 get-state') echo device;;
          '-s 192.168.1.2:38222 shell getprop ro.product.model') echo RecoveredPhone;;
          *) exit 9;;
        esac
        """)
        let recovered = PairingEngine(resultURL: resultFile); recovered.start(adbURL: fake)
        try await wait { recovered.phase == .scanning }
        precondition(result()["state"] as? String == "pending", "Offline transport must not report ready")
        precondition(!history().contains("kill-server"))
        try "device".write(to: transportFile, atomically: true, encoding: .utf8)
        try await wait { recovered.phase == .connected }
        precondition(result()["state"] as? String == "ready")
        precondition(result()["serial"] as? String == "192.168.1.2:38222")
        precondition(result()["device"] as? String == "RecoveredPhone")
        let permissions = try FileManager.default.attributesOfItem(atPath: resultFile.path)[.posixPermissions] as? Int
        precondition(permissions == 0o600)
        recovered.stop()
        precondition(result()["state"] as? String == "ready")
        try "offline".write(to: transportFile, atomically: true, encoding: .utf8)
        recovered.start(adbURL: fake)
        try await wait { recovered.phase == .scanning }
        recovered.stop()
        precondition(result()["state"] as? String == "cancelled")

        try install("exit 1\n")
        let failed = PairingEngine(resultURL: resultFile); failed.start(adbURL: fake)
        try await wait { failed.phase == .failed }
        precondition(result()["state"] as? String == "failed")
        precondition(!history().contains("kill-server"), "Failed inventory must never imply empty inventory")
        failed.stop()
        let pidFile = directory.appendingPathComponent("pid")
        try install("echo $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n")
        let hanging = PairingEngine(); hanging.start(adbURL: fake)
        try await wait { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        hanging.stop()
        try await wait { kill(pid, 0) != 0 }
        precondition(!history().contains("kill-server"), "Cancelling an inventory child must not stop the shared server")

        // Any transport that answers counts: USB and emulator, not only Wi-Fi.
        for (serial, kind) in [("R5CX123ABC", "usb"), ("emulator-5554", "emulator")] {
            try install("""
            case "$*" in
              'devices -l') printf 'List of devices attached\\n\(serial) device\\n';;
              '-s \(serial) get-state') echo device;;
              '-s \(serial) shell getprop ro.product.model') echo WiredPhone;;
              *) exit 7;;
            esac
            """)
            precondition(PairingEngine.transport(of: serial) == kind)
            let wired = PairingEngine(); wired.start(adbURL: fake)
            try await wait { wired.phase == .connected }
            precondition(wired.deviceName == "WiredPhone", "\(kind) device that answers must be accepted")
            precondition(!history().contains("kill-server"))
            wired.stop()
        }
        precondition(PairingEngine.transport(of: "192.168.1.2:38222") == "wifi")

        // Details says why each listed device cannot be used.
        let mixedInventory = """
        case "$*" in
          'devices -l') printf 'List of devices attached\\n192.168.1.2:38222 device\\nR5CX123ABC unauthorized\\nemulator-5554 device\\nstale:5555 offline\\n';;
          'mdns services') echo 'List of discovered mdns services';;
          '-s 192.168.1.2:38222 get-state') echo device;;
          '-s 192.168.1.2:38222 shell getprop ro.product.model') echo BridgePhone;;
          '-s 192.168.1.2:38222 shell echo hi') echo hi;;
          '-s 192.168.1.2:38222 shell false') exit 1;;
          '-s 192.168.1.2:38222 install -r \(fake.path)') echo Success;;
          '-s 192.168.1.2:38222 exec-out screencap -p') cat '\(directory.path)/screen.png';;
          'connect 10.0.0.9:5555') echo 'failed to connect';;
          'connect 10.0.0.8:5555') echo "failed to connect to '10.0.0.8:5555': No route to host";;
          *) exit 7;;
        esac
        """
        try install("""
        case "$*" in
          'devices -l') printf 'List of devices attached\\nR5CX123ABC unauthorized\\nemulator-5554 device\\nstale:5555 offline\\n';;
          'mdns services') echo 'List of discovered mdns services';;
          *) exit 7;;
        esac
        """)
        let explained = PairingEngine(); explained.start(adbURL: fake)
        try await wait { explained.phase == .scanning }
        precondition(explained.log.contains("R5CX123ABC is listed but not usable: this Mac is not authorized"))
        precondition(explained.log.contains("stale:5555 is listed but not usable: the phone is not responding"))
        precondition(explained.log.contains("emulator-5554 is listed but not usable: ADB lists it as ready, but it did not answer"))
        precondition(!history().contains("kill-server"))
        explained.stop()

        // --status: the same inventory as data.
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
            .write(to: directory.appendingPathComponent("screen.png"))
        try install(mixedInventory)
        var bridge = AgentBridge(adbOverride: fake.path)
        bridge.discover = { [] }
        let status = try await bridge.status()
        precondition(status.ready && status.devices.count == 4)
        precondition(status.devices[0].usable && status.devices[0].model == "BridgePhone" && status.devices[0].transport == "wifi")
        precondition(!status.devices[1].usable && status.devices[1].reason?.contains("not authorized") == true && status.devices[1].transport == "usb")
        precondition(!status.devices[2].usable && status.devices[2].reason?.contains("did not answer") == true && status.devices[2].transport == "emulator")
        precondition(!status.devices[3].usable && status.devices[3].state == "offline")
        precondition(AgentBridge.json(status).contains("\"serial\" : \"192.168.1.2:38222\""))

        // MCP: one message in, one out, and nothing that drops transports.
        func check(_ passed: Bool, _ why: String = "", line: UInt = #line) { precondition(passed, "line \(line) \(why)") }
        func rpc(_ method: String, _ params: [String: Any] = [:], id: Any? = 1) async -> [String: Any]? {
            var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if let id { message["id"] = id }
            return await bridge.handle(message)
        }
        func tool(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool, content: [[String: Any]]) {
            let result = await rpc("tools/call", ["name": name, "arguments": arguments])?["result"] as? [String: Any] ?? [:]
            let content = result["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined()
            return (text, result["isError"] as? Bool ?? true, content)
        }
        let hello = await rpc("initialize", ["protocolVersion": "2025-03-26"])?["result"] as? [String: Any]
        precondition(hello?["protocolVersion"] as? String == "2025-03-26")
        check(await rpc("notifications/initialized", id: nil) == nil, "Notifications get no reply")
        let listed = (await rpc("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        precondition(listed.compactMap { $0["name"] as? String } == ["status", "connect", "adb", "install", "screenshot"])
        check((await rpc("nope")?["error"] as? [String: Any])?["code"] as? Int == -32601)
        check(await tool("status").text.contains("BridgePhone"))
        check(await tool("connect").text.contains("192.168.1.2:38222"), "connect reuses a device that already answers")
        let echoed = await tool("adb", ["args": ["shell", "echo", "hi"]])
        precondition(echoed.text == "hi\n" && !echoed.isError)
        precondition(history().contains("-s 192.168.1.2:38222 shell echo hi"), "The single usable device is addressed by serial")
        check(await tool("adb", ["args": ["shell", "false"]]).isError)
        for refused in ["kill-server", "pair", "disconnect", "tcpip", "usb", "reconnect"] {
            check(await tool("adb", ["args": [refused]]).isError)
        }
        check(await tool("adb", ["args": ["-s", "x", "kill-server"]]).isError)
        check(await tool("adb", ["args": ["shell"]]).isError, "No interactive shell")
        precondition(!history().contains("kill-server") && !history().contains("pair") && !history().contains("disconnect"))
        check(await tool("install", ["path": fake.path]).text.hasPrefix("Installed adb on 192.168.1.2:38222"))
        check(await tool("install", ["path": "relative.apk"]).isError)
        let full = directory.appendingPathComponent("full.png")
        let shot = await tool("screenshot", ["max_dimension": 0, "save_path": full.path])
        precondition(!shot.isError && shot.content.first?["mimeType"] as? String == "image/png")
        check(try Data(base64Encoded: shot.content.first?["data"] as? String ?? "") == Data(contentsOf: full))
        check(await tool("screenshot").content.first?["mimeType"] as? String == "image/jpeg")

        // A folded phone: two displays, one phone listed under two serials. The display lines are
        // trimmed from a real `dumpsys display` capture; the warning is screencap's real first line.
        let displays = directory.appendingPathComponent("displays")
        try """
          DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4630946722019192211", 2256 x 2504, modeId 1, renderFrameRate 60.00001, type INTERNAL, state OFF, committedState OFF, installOrientation 3}
          DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4630946379103915412", 1080 x 2520, modeId 3, renderFrameRate 60.00001, type INTERNAL, state ON, committedState ON, installOrientation 0}
        """.write(to: displays, atomically: true, encoding: .utf8)
        check(try AgentBridge.activeDisplayID(String(contentsOf: displays, encoding: .utf8)) == "4630946379103915412")
        try install("""
        case "$*" in
          'devices -l') printf 'List of devices attached\\n192.168.1.2:38222 device\\nadb-phone._adb-tls-connect._tcp device\\n';;
          *' get-state') echo device;;
          *' shell getprop ro.product.model') echo FoldPhone;;
          *' shell getprop ro.serialno') echo SAMEPHONE;;
          *' shell dumpsys display') cat '\(displays.path)';;
          *' exec-out screencap -p') echo '[Warning] Multiple displays were found, but no display id was specified!';;
          *' exec-out screencap -p -d 4630946379103915412') cat '\(directory.path)/screen.png';;
          *) exit 7;;
        esac
        """)
        let folded = await tool("screenshot", ["max_dimension": 0])
        check(try Data(base64Encoded: folded.content.first?["data"] as? String ?? "") == Data(contentsOf: full), "The display that is on is captured")
        precondition(history().contains("-s 192.168.1.2:38222 exec-out screencap -p -d 4630946379103915412"), "One phone under two serials needs no serial argument")
        try install(mixedInventory)
        let wrongPort = await tool("connect", ["endpoint": "10.0.0.9:5555"])
        precondition(wrongPort.isError && wrongPort.text.contains("not the debugging port"))
        check(await tool("connect", ["endpoint": "not an endpoint"]).isError)
        check(await tool("connect", ["endpoint": "10.0.0.8:5555"]).text.contains("Local Network permission"), "A blocked ADB server is named as the cause")

        // With nothing connected, connect opens the window and reads its result file.
        try install("""
        case "$*" in
          'devices -l') echo 'List of devices attached';;
          'mdns services') echo 'List of discovered mdns services';;
          *) exit 7;;
        esac
        """)
        check(await tool("connect", ["open_window": false]).isError)
        // A phone paired earlier that only macOS Bonjour can see is connected without a window.
        try install("""
        case "$*" in
          'devices -l') if test -f '\(directory.path)/joined'; then printf 'List of devices attached\\n192.168.1.8:40002 device\\n'; else echo 'List of devices attached'; fi;;
          'mdns services') echo 'List of discovered mdns services';;
          'connect 192.168.1.8:40002') touch '\(directory.path)/joined'; echo connected;;
          '-s 192.168.1.8:40002 get-state') echo device;;
          '-s 192.168.1.8:40002 shell getprop ro.product.model') echo BonjourPhone;;
          *) exit 7;;
        esac
        """)
        bridge.discover = {
            [.init(name: "adb-x", type: "_adb-tls-pairing._tcp", endpoint: "192.168.1.8:37000", host: "192.168.1.8"),
             .init(name: "adb-x", type: "_adb-tls-connect._tcp", endpoint: "192.168.1.8:40002", host: "192.168.1.8")]
        }
        check(await tool("connect", ["open_window": false]).text.contains("BonjourPhone"))
        precondition(!history().contains("37000"), "A pairing port is never used as the debugging port")
        bridge.discover = { [] }
        try install("""
        case "$*" in
          'devices -l') echo 'List of devices attached';;
          'mdns services') echo 'List of discovered mdns services';;
          *) exit 7;;
        esac
        """)
        check(await tool("adb", ["args": ["shell", "ls"]]).text.contains("Call connect first"))
        bridge.openWindow = { url in
            try "{\"state\":\"ready\",\"device\":\"WindowPhone\",\"serial\":\"192.168.1.7:40001\"}".write(to: url, atomically: true, encoding: .utf8)
        }
        check(await tool("connect", ["timeout_seconds": 5]).text.contains("WindowPhone"))
        bridge.openWindow = { url in try "{\"state\":\"cancelled\"}".write(to: url, atomically: true, encoding: .utf8) }
        check(await tool("connect", ["timeout_seconds": 5]).isError)
        bridge.openWindow = { _ in }
        check(await tool("connect", ["timeout_seconds": 1]).text.contains("within 1 seconds"))
        precondition(!history().contains("kill-server"), "The bridge never restarts the shared server")

        print("PASS: transport parsing, service port isolation, verified reuse, preservation, secret redaction, QR selection, fresh restart, QR auto-connect recovery, automation results, child cancellation, failed inventory, USB and emulator reuse, unusable-device reasons, status, MCP tools")
    }
}
