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
    private let resultURL: URL?

    init(resultURL: URL? = nil) {
        self.resultURL = resultURL
        super.init()
    }

    func start(adbURL: URL? = nil) {
        stop()
        let run = UUID(); generation = run
        log = ""; deviceName = nil; phase = .preparing
        status = "Checking Android Debug Bridge…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try self.writeResult("pending")
                try await self.connect(adbURL: adbURL)
            }
            catch is CancellationError { }
            catch {
                if self.generation == run {
                    self.qrPayload = nil; self.phase = .failed
                    self.status = error.localizedDescription
                    self.record("Stopped: \(error.localizedDescription)")
                    self.recordTerminalResult("failed", message: self.status)
                }
            }
            if self.generation == run { self.discovery?.stop(); self.discovery = nil }
        }
    }

    func stop() {
        switch phase {
        case .preparing, .scanning, .pairing, .connecting: recordTerminalResult("cancelled")
        default: break
        }
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

    private struct Result: Encodable {
        let version = 1
        let state: String
        let device: String?
        let serial: String?
        let message: String?
    }

    private func writeResult(_ state: String, device: String? = nil,
                             serial: String? = nil, message: String? = nil) throws {
        guard let resultURL else { return }
        let files = FileManager.default
        let staging = resultURL.deletingLastPathComponent()
            .appendingPathComponent(".connect-android-" + UUID().uuidString, isDirectory: true)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: staging) }
            let temporary = staging.appendingPathComponent("result.json")
            let data = try JSONEncoder().encode(Result(state: state, device: device,
                                                       serial: serial, message: message))
            guard files.createFile(atPath: temporary.path, contents: data,
                                   attributes: [.posixPermissions: 0o600]),
                  Darwin.rename(temporary.path, resultURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            throw Failure(message: "Could not write the automation result. Use a writable result path.")
        }
    }

    private func recordTerminalResult(_ state: String, message: String? = nil) {
        do { try writeResult(state, message: message) }
        catch { record(error.localizedDescription) }
    }

    // Wi-Fi, USB and emulator transports all count once they answer a shell command.
    private func onlineDevices() async throws -> [DeviceRow] {
        Self.deviceRows(try await adb(["devices", "-l"], timeout: 3)).filter { $0.state == "device" }
    }

    private func verifiedDevice(_ serial: String) async throws -> String? {
        do { return try await verify(serial) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }
    private func connect(adbURL: URL?) async throws {
        if let adbURL { UserDefaults.standard.set(adbURL.path, forKey: "selectedADBPath") }
        guard let path = Self.resolveADB(explicit: adbURL?.path) else {
            throw Failure(message: "ADB was not found. Install Android SDK Platform-Tools, then choose its adb executable.")
        }
        adbPath = path; record("Using \(path)")
        // A failed inventory is not evidence that no transports exist: never kill blindly.
        let inventory = try await adb(["devices", "-l"])
        let rows = Self.deviceRows(inventory)
        for row in rows where row.state == "device" {
            if let model = try await verifiedDevice(row.serial) {
                try finish(model, serial: row.serial); return
            }
            record("\(row.serial) is listed but not usable: \(Self.unansweredReason)")
        }
        for row in rows where row.state != "device" {
            record("\(row.serial) is listed but not usable: \(Self.unusableReason(state: row.state))")
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
        var beforeQR = Set(rows.filter { $0.state == "device" }.map(\.serial))
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            for row in try await onlineDevices() {
                beforeQR.insert(row.serial)
                if let model = try await verifiedDevice(row.serial) {
                    try finish(model, serial: row.serial); return
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
            // ADB may auto-connect while its Bonjour advertisements are still missing.
            if let online = try? await onlineDevices() {
                let new = online.filter { !beforeQR.contains($0.serial) }
                if new.count == 1, let device = new.first,
                   let model = try await verifiedDevice(device.serial) {
                    try finish(model, serial: device.serial); return
                }
            }
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
            if let online = try? await onlineDevices() {
                for device in online where Self.matchesPairedDevice(device.serial, host: pairing.host, guid: guid) {
                    if let model = try await verifiedDevice(device.serial) {
                        try finish(model, serial: device.serial); return
                    }
                }
            }
            let found = try await services()
            let matches = found.filter { item in
                item.type == "_adb-tls-connect._tcp" && ((guid.map { !$0.isEmpty && item.name.hasPrefix($0) } ?? false) || item.host == pairing.host)
            }
            var tried = Set<String>()
            for connection in matches where tried.insert(connection.endpoint).inserted {
                let model: String
                do {
                    _ = try await adb(["connect", connection.endpoint], timeout: 10)
                    model = try await verify(connection.endpoint)
                } catch is CancellationError { throw CancellationError() }
                catch { record("Connection not ready; retrying within the connection deadline."); continue }
                try finish(model, serial: connection.endpoint); return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Failure(message: "Pairing succeeded, but the debugging connection was not verified. Keep Wireless debugging enabled and Retry; check that Wi-Fi allows devices to communicate.")
    }

    private func finish(_ model: String, serial: String) throws {
        try Task.checkCancellation()
        try writeResult("ready", device: model, serial: serial)
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
    nonisolated static func isNetworkSerial(_ serial: String) -> Bool {
        !serial.hasPrefix("emulator-") && (serial.contains(":") || serial.contains("._adb-tls-connect._tcp"))
    }
    nonisolated static func transport(of serial: String) -> String {
        serial.hasPrefix("emulator-") ? "emulator" : isNetworkSerial(serial) ? "wifi" : "usb"
    }
    nonisolated static func resolveADB(explicit: String? = nil) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [explicit, UserDefaults.standard.string(forKey: "selectedADBPath"),
                          environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" },
                          environment["ANDROID_SDK_ROOT"].map { $0 + "/platform-tools/adb" },
                          home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    nonisolated static let unansweredReason = "ADB lists it as ready, but it did not answer a shell command within 5 seconds. Wake the phone and check it is still on this network or cable."
    // Why a transport that `adb devices` lists cannot be used yet, in words for the Details log.
    nonisolated static func unusableReason(state: String) -> String {
        switch state {
        case "unauthorized": return "this Mac is not authorized. Unlock the phone and accept the debugging prompt, or pair again."
        case "authorizing": return "authorization is still in progress. Check the phone for a prompt."
        case "offline": return "the phone is not responding. Wake it, check it is on the same Wi-Fi, or turn Wireless debugging off and on."
        case "connecting": return "ADB is still connecting to it."
        case "no": return "ADB has no permission to open this USB device. Replug it and accept the prompt on the phone."
        case "recovery", "sideload", "bootloader", "rescue": return "it is in \(state) mode, not running Android."
        default: return "ADB reports it as \(state), which does not accept shell commands."
        }
    }
    static func matchesPairedDevice(_ serial: String, host: String, guid: String?) -> Bool {
        if let guid, !guid.isEmpty, serial.hasPrefix(guid), serial.contains("._adb-tls-connect._tcp") {
            return true
        }
        guard let port = serial.lastIndex(of: ":") else { return false }
        let address = serial[..<port].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return address == host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
    struct DeviceRow { let serial: String; let state: String }
    nonisolated static func deviceRows(_ output: String) -> [DeviceRow] {
        output.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"), !line.hasPrefix("adb:") else { return nil }
            return DeviceRow(serial: words[0], state: words[1])
        }
    }
    struct Service { let name: String; let type: String; let endpoint: String; let host: String }
    nonisolated static func parseServices(_ output: String) -> [Service] {
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
final class BonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
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
