import Foundation

@main struct EngineTests {
    @MainActor static func main() async throws {
        let oldADBPath = UserDefaults.standard.string(forKey: "selectedADBPath")
        UserDefaults.standard.removeObject(forKey: PairingEngine.lastEndpointKey)
        defer {
            UserDefaults.standard.removeObject(forKey: PairingEngine.lastEndpointKey)
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
        let existing = PairingEngine(); existing.tailnetEnabled = false; existing.start(adbURL: fake)
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
        let unauthorized = PairingEngine(); unauthorized.tailnetEnabled = false; unauthorized.start(adbURL: fake)
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
        UserDefaults.standard.removeObject(forKey: PairingEngine.lastEndpointKey) // otherwise the remembered address reconnects without a QR
        let fresh = PairingEngine(); fresh.tailnetEnabled = false; fresh.start(adbURL: fake)
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
        let remembered = PairingEngine(); remembered.tailnetEnabled = false; remembered.start(adbURL: fake)
        try await wait { remembered.phase == .connected }
        precondition(remembered.qrPayload == nil && remembered.deviceName == "FreshPhone", "Last working address reconnects without a new QR")
        remembered.stop()
        try install("exit 1\n")
        let failed = PairingEngine(); failed.tailnetEnabled = false; failed.start(adbURL: fake)
        try await wait { failed.phase == .failed }
        precondition(!history().contains("kill-server"), "Failed inventory must never imply empty inventory")
        failed.stop()
        let pidFile = directory.appendingPathComponent("pid")
        try install("echo $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n")
        let hanging = PairingEngine(); hanging.tailnetEnabled = false; hanging.start(adbURL: fake)
        try await wait { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        hanging.stop()
        try await wait { kill(pid, 0) != 0 }
        precondition(!history().contains("kill-server"), "Cancelling an inventory child must not stop the shared server")
        // Companion detection and grant parsing.
        precondition(PairingEngine.listsPackage("package:com.monroestone.connectandroid\n", PairingEngine.companionPackage))
        precondition(!PairingEngine.listsPackage("package:com.monroestone.connectandroid.debug\n", PairingEngine.companionPackage))
        precondition(PairingEngine.hasSecureSettingsGrant("  android.permission.WRITE_SECURE_SETTINGS: granted=true\n"))
        precondition(!PairingEngine.hasSecureSettingsGrant("  android.permission.WRITE_SECURE_SETTINGS: granted=false\n"))
        // Tailnet peers: only my own online Android devices, IPv4 address.
        let status = #"{"Self":{"UserID":1},"Peer":{"a":{"HostName":"fold","OS":"android","Online":true,"UserID":1,"TailscaleIPs":["100.118.229.7","fd7a::1"]},"b":{"HostName":"friend","OS":"android","Online":true,"UserID":2,"TailscaleIPs":["100.67.0.1"]},"c":{"HostName":"pixel","OS":"android","Online":false,"UserID":1,"TailscaleIPs":["100.102.0.1"]},"d":{"HostName":"server","OS":"linux","Online":true,"UserID":1,"TailscaleIPs":["100.108.0.1"]}}}"#
        precondition(PairingEngine.ownAndroidPeers(fromTailscaleStatus: Data(status.utf8)) == [.init(name: "fold", address: "100.118.229.7")])
        precondition(PairingEngine.ownAndroidPeers(fromTailscaleStatus: Data("not json".utf8)).isEmpty)
        // Port scan finds a real local listener and nothing else in a small range.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var bound = sockaddr_in(); bound.sin_family = sa_family_t(AF_INET); bound.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bound.sin_addr.s_addr = inet_addr("127.0.0.1"); bound.sin_port = 0
        _ = withUnsafePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 8)
        var actual = sockaddr_in(); var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &actualLength) } }
        let listening = UInt16(bigEndian: actual.sin_port)
        let low = listening > 200 ? listening - 100 : 1
        let scanned = await PairingEngine.openPorts(host: "127.0.0.1", ports: low...(low + 200))
        precondition(scanned.contains(listening), "Scanner must find the open port")
        close(listener)
        print("PASS: companion detection, own-tailnet peer filter, port scan")
        print("PASS: transport parsing, service port isolation, verified reuse, preservation, secret redaction, QR selection, fresh restart, child cancellation, failed inventory")
    }
}
