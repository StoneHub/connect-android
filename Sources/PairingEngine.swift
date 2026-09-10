import Foundation
import Combine
import Security
import Darwin

@MainActor
final class PairingEngine: NSObject, ObservableObject {
    enum Phase: String { case idle, preparing, scanning, pairing, connecting, connected, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Ready to connect your Android phone."
    @Published private(set) var qrPayload: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var log = ""
    @Published private(set) var adbPath = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var discovery: BonjourDiscovery?

    func start(adbURL: URL? = nil) {
        stop()
        let run = UUID(); generation = run
        log = ""; deviceName = nil; phase = .preparing
        status = "Checking Android Debug Bridge…"
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.connect(adbURL: adbURL) }
            catch is CancellationError { }
            catch {
                if self.generation == run {
                    self.qrPayload = nil; self.phase = .failed
                    self.status = error.localizedDescription
                    self.record("Stopped: \(error.localizedDescription)")
                }
            }
            if self.generation == run { self.discovery?.stop(); self.discovery = nil }
        }
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        discovery?.stop(); discovery = nil; qrPayload = nil
        if phase != .connected { phase = .idle; status = "Ready to connect your Android phone." }
    }

    private func record(_ message: String) {
        log += "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        if log.count > 32_000 { log = String(log.suffix(24_000)) }
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private func connect(adbURL: URL?) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let adbURL { UserDefaults.standard.set(adbURL.path, forKey: "selectedADBPath") }
        let candidates = [adbURL?.path, UserDefaults.standard.string(forKey: "selectedADBPath"), ProcessInfo.processInfo.environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" }, ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"].map { $0 + "/platform-tools/adb" }, home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(message: "ADB was not found. Install Android SDK Platform-Tools, then choose its adb executable.")
        }
        adbPath = path; record("Using \(path)")
        // A failed inventory is not evidence that no transports exist: never kill blindly.
        let inventory = try await adb(["devices", "-l"])
        let rows = Self.deviceRows(inventory)
        for row in rows where row.state == "device" && Self.isNetworkSerial(row.serial) {
            if let model = try? await verify(row.serial) {
                try Task.checkCancellation(); finish(model); return
            }
        }
        try Task.checkCancellation()
        let latestRows = rows.isEmpty ? Self.deviceRows(try await adb(["devices", "-l"])) : rows
        if latestRows.isEmpty {
            record("No existing transports; refreshing the ADB server once.")
            _ = try await adb(["kill-server"])
            _ = try await adb(["start-server"])
        } else {
            record("Preserving \(latestRows.count) existing ADB transport(s).")
        }
        // Give ADB's known-device auto-connect a brief window before asking for another scan.
        status = "Looking for a previously paired phone…"
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let current = Self.deviceRows(try await adb(["devices", "-l"]))
            for row in current where row.state == "device" && Self.isNetworkSerial(row.serial) {
                if let model = try? await verify(row.serial) {
                    try Task.checkCancellation(); finish(model); return
                }
            }
        }
        try Task.checkCancellation()
        let service = "studio-" + (try Self.randomHex(count: 8))
        let password = try Self.randomHex(count: 16)
        let browser = BonjourDiscovery(); discovery = browser; browser.start()
        qrPayload = "WIFI:T:ADB;S:\(service);P:\(password);;"
        phase = .scanning; status = "On your phone, open Wireless debugging → Pair device with QR code."
        record("QR ready. Waiting up to five minutes for the scanned phone.")
        let deadline = Date().addingTimeInterval(300)
        var pairing: Service?
        while Date() < deadline {
            try Task.checkCancellation()
            let services = try await services()
            pairing = services.first { $0.name == service && $0.type == "_adb-tls-pairing._tcp" }
            if pairing != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let pairing else { throw Failure(message: "QR expired. Keep both devices on the same Wi-Fi, open the phone’s QR pairing scanner, and Retry. Check Local Network permission if discovery is blocked.") }
        phase = .pairing; status = "Pairing with your phone…"; record("Discovered the scanned phone; pairing.")
        let result = try await adb(["pair", pairing.endpoint], input: password + "\n", timeout: 30)
        guard result.contains("Successfully paired") else { throw Failure(message: "The phone did not confirm pairing. Retry with a fresh QR code.") }
        qrPayload = nil; phase = .connecting; status = "Paired. Verifying the debugging connection…"
        record("Pairing confirmed. Looking for the separate debugging service.")
        let guid = result.range(of: "guid=").map { String(result[$0.upperBound...]).components(separatedBy: CharacterSet(charactersIn: "] \r\n")).first ?? "" }
        let connectionDeadline = Date().addingTimeInterval(45)
        while Date() < connectionDeadline {
            try Task.checkCancellation()
            let found = try await services()
            let matches = found.filter { item in
                item.type == "_adb-tls-connect._tcp" && ((guid.map { !$0.isEmpty && item.name.hasPrefix($0) } ?? false) || item.host == pairing.host)
            }
            for connection in matches {
                do {
                    _ = try await adb(["connect", connection.endpoint], timeout: 10)
                    let model = try await verify(connection.endpoint)
                    finish(model); return
                } catch is CancellationError { throw CancellationError() }
                catch { record("Connection not ready; retrying within the connection deadline.") }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Failure(message: "Pairing succeeded, but the debugging connection was not verified. Keep Wireless debugging enabled and Retry; check that Wi-Fi allows devices to communicate.")
    }

    private func finish(_ model: String) {
        deviceName = model; phase = .connected; qrPayload = nil
        status = "Connected: \(model). You can close this app."
        record("Verified device shell: \(model). ADB remains available after the app closes.")
    }
    private func verify(_ serial: String) async throws -> String {
        let state = try await adb(["-s", serial, "get-state"], timeout: 5)
        guard state.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else { throw Failure(message: "Device is not ready.") }
        let model = try await adb(["-s", serial, "shell", "getprop", "ro.product.model"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw Failure(message: "Device shell returned no identity.") }
        return model
    }
    static func isNetworkSerial(_ serial: String) -> Bool {
        !serial.hasPrefix("emulator-") && (serial.contains(":") || serial.contains("._adb-tls-connect._tcp"))
    }
    struct DeviceRow { let serial: String; let state: String }
    static func deviceRows(_ output: String) -> [DeviceRow] {
        output.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"), !line.hasPrefix("adb:") else { return nil }
            return DeviceRow(serial: words[0], state: words[1])
        }
    }
    struct Service { let name: String; let type: String; let endpoint: String; let host: String }
    static func parseServices(_ output: String) -> [Service] {
        output.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count == 3, words[1].hasPrefix("_adb-tls-"), let colon = words[2].lastIndex(of: ":") else { return nil }
            return Service(name: words[0], type: words[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")), endpoint: words[2], host: String(words[2][..<colon]))
        }
    }
    private func services() async throws -> [Service] {
        var result = discovery?.services ?? []
        do { result += Self.parseServices(try await adb(["mdns", "services"], timeout: 3)) }
        catch is CancellationError { throw CancellationError() }
        catch { /* Native Bonjour remains available when ADB discovery is unhealthy. */ }
        return result
    }
    private static func randomHex(count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure(message: "Could not generate secure pairing credentials.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // File-backed output avoids pipe deadlocks, including on unusually verbose ADB failures.
    private func adb(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 15) async throws -> String {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure(message: "Unable to create a temporary ADB output file.") }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: adbPath); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["ADB_MDNS_OPENSCREEN"] = "1"
        process.environment = environment
        let stdin = Pipe(); process.standardInput = stdin
        try process.run()
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw Failure(message: "ADB \(arguments.first ?? "command") timed out. Retry to check the connection again.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning { process.terminate() }
            // Give TERM a short grace period, then reap this child only (never the server).
            for _ in 0..<10 where process.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        try Task.checkCancellation()
        let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            // Pairing output is never copied to logs because it may contain credentials.
            throw Failure(message: "ADB \(arguments.first ?? "command") failed (exit \(process.terminationStatus)). Check the phone and Wi-Fi, then Retry.")
        }
        return text
    }
}

@MainActor
private final class BonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []
    private(set) var services: [PairingEngine.Service] = []
    func start() {
        for type in ["_adb-tls-pairing._tcp.", "_adb-tls-connect._tcp."] {
            let browser = NetServiceBrowser(); browser.delegate = self
            browsers.append(browser); browser.searchForServices(ofType: type, inDomain: "local.")
        }
    }
    func stop() {
        browsers.forEach { $0.stop(); $0.delegate = nil }
        pending.forEach { $0.stop(); $0.delegate = nil }
        browsers.removeAll(); pending.removeAll(); services.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pending.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name && $0.type == service.type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName, sender.port > 0 else { return }
        // Prefer numeric IPv4 to avoid a second hostname-resolution dependency in ADB.
        let numericHost: String? = sender.addresses?.compactMap { data -> String? in
            data.withUnsafeBytes { buffer -> String? in
                guard let pointer = buffer.baseAddress, data.count >= MemoryLayout<sockaddr>.size else { return nil }
                let address = pointer.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == AF_INET else { return nil }
                var output = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &output, socklen_t(output.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }.first
        let host = numericHost ?? hostName
        let type = sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        services.removeAll { $0.name == sender.name && $0.type == type }
        services.append(.init(name: sender.name, type: type, endpoint: "\(host):\(sender.port)", host: host))
    }
}
