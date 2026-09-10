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
        try install("exit 1\n")
        let failed = PairingEngine(); failed.start(adbURL: fake)
        try await wait { failed.phase == .failed }
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
        print("PASS: transport parsing, service port isolation, verified reuse, preservation, secret redaction, QR selection, fresh restart, child cancellation, failed inventory")
    }
}
