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
    /// Tests turn this off so they never probe the real tailnet.
    var tailnetEnabled = true

    func start(adbURL: URL? = nil) {
        stop()
        let run = UUID(); generation = run
        log = ""; deviceName = nil; phase = .preparing; companion = .unknown; connectedSerial = nil
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
        generation = UUID(); task?.cancel(); task = nil; companionTask?.cancel(); companionTask = nil
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
                try Task.checkCancellation(); finish(model, serial: row.serial); return
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
                    try Task.checkCancellation(); finish(model, serial: row.serial); return
                }
            }
        }
        try Task.checkCancellation()
        if try await reconnectPairedPhone() { return }
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
                    finish(model, serial: connection.endpoint); return
                } catch is CancellationError { throw CancellationError() }
                catch { record("Connection not ready; retrying within the connection deadline.") }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Failure(message: "Pairing succeeded, but the debugging connection was not verified. Keep Wireless debugging enabled and Retry; check that Wi-Fi allows devices to communicate.")
    }

    private func finish(_ model: String, serial: String) {
        deviceName = model; phase = .connected; qrPayload = nil; connectedSerial = serial
        status = "Connected: \(model). You can close this app."
        record("Verified device shell: \(model). ADB remains available after the app closes.")
        if serial.contains(":") { UserDefaults.standard.set(serial, forKey: Self.lastEndpointKey) }
        companionTask?.cancel()
        companionTask = Task { [weak self] in await self?.checkCompanion() }
    }

    // MARK: Phone companion app

    /// The Android companion (same identifier as this app) toggles wireless debugging and keeps it alive.
    /// It needs WRITE_SECURE_SETTINGS, which only an adb shell can grant; this app offers that as one click.
    enum Companion: Equatable { case unknown, notInstalled, needsGrant, granting, granted, failed }
    static let companionPackage = "com.monroestone.connectandroid"
    @Published private(set) var companion: Companion = .unknown
    private var connectedSerial: String?
    private var companionTask: Task<Void, Never>?

    private func checkCompanion() async {
        guard let serial = connectedSerial else { return }
        do {
            let packages = try await adb(["-s", serial, "shell", "pm", "list", "packages", Self.companionPackage], timeout: 8)
            guard Self.listsPackage(packages, Self.companionPackage) else { companion = .notInstalled; return }
            let dump = try await adb(["-s", serial, "shell", "dumpsys", "package", Self.companionPackage], timeout: 8)
            companion = Self.hasSecureSettingsGrant(dump) ? .granted : .needsGrant
            record("Phone companion app: \(companion == .granted ? "controls allowed" : "installed, needs permission").")
        } catch {
            companion = .unknown
        }
    }

    /// Grants the companion WRITE_SECURE_SETTINGS. Only ever runs from an explicit button press.
    func allowPhoneControls() {
        guard let serial = connectedSerial, companion == .needsGrant || companion == .failed else { return }
        companion = .granting
        companionTask?.cancel()
        companionTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.adb(["-s", serial, "shell", "pm", "grant", Self.companionPackage,
                                        "android.permission.WRITE_SECURE_SETTINGS"], timeout: 10)
                self.record("Granted the phone app permission to control wireless debugging.")
                await self.checkCompanion()
            } catch {
                self.companion = .failed
                self.record("Could not grant phone controls: \(error.localizedDescription)")
            }
        }
    }

    static func listsPackage(_ output: String, _ package: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "package:\(package)" }
    }
    static func hasSecureSettingsGrant(_ dumpsys: String) -> Bool {
        dumpsys.contains("android.permission.WRITE_SECURE_SETTINGS: granted=true")
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
    private func adb(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 15, executable: String? = nil) async throws -> String {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure(message: "Unable to create a temporary ADB output file.") }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable ?? adbPath); process.arguments = arguments
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
            throw Failure(message: "\(executable == nil ? "ADB" : "Command") \(arguments.first ?? "command") failed (exit \(process.terminationStatus)). Check the phone and Wi-Fi, then Retry.")
        }
        return text
    }
}

// MARK: Reconnect without a new QR scan

extension PairingEngine {
    static let lastEndpointKey = "lastConnectedEndpoint"

    /// Tries, in order: the last endpoint that worked, the phone's LAN mDNS record, then the
    /// phone's Tailscale address. Wireless debugging picks a new port each time it turns on,
    /// and mDNS does not cross subnets or the tailnet, so the last step finds the port by a
    /// bounded TCP scan of the phone's own tailnet address. Only already-paired phones verify.
    fileprivate func reconnectPairedPhone() async throws -> Bool {
        var tried = Set<String>()
        func attempt(_ endpoint: String, _ why: String) async throws -> Bool {
            guard tried.insert(endpoint).inserted else { return false }
            try Task.checkCancellation()
            record("Trying \(why) \(endpoint).")
            _ = try? await adb(["connect", endpoint], timeout: 6)
            if let model = try? await verify(endpoint) {
                try Task.checkCancellation(); finish(model, serial: endpoint); return true
            }
            return false
        }
        if let last = UserDefaults.standard.string(forKey: Self.lastEndpointKey),
           try await attempt(last, "the last working address") { return true }
        status = "Looking for your phone on this network…"
        for service in try await services() where service.type == "_adb-tls-connect._tcp" {
            if try await attempt(service.endpoint, "the phone's network record") { return true }
        }
        guard tailnetEnabled, let tailscale = Self.tailscaleExecutable() else { return false }
        let json = (try? await adb(["status", "--json"], timeout: 6, executable: tailscale)) ?? ""
        let phones = Self.ownAndroidPeers(fromTailscaleStatus: Data(json.utf8))
        guard !phones.isEmpty else { return false }
        for phone in phones {
            try Task.checkCancellation()
            status = "Looking for \(phone.name) on your tailnet…"
            record("Scanning \(phone.name) (\(phone.address)) for the wireless debugging port.")
            let ports = await Self.openPorts(host: phone.address, ports: Self.adbPortRange)
            record("Found \(ports.count) open port(s) on \(phone.name).")
            for port in ports {
                if try await attempt("\(phone.address):\(port)", "tailnet address") { return true }
            }
        }
        return false
    }

    /// adbd binds wireless debugging to an ephemeral port (Linux 32768–60999).
    static let adbPortRange: ClosedRange<UInt16> = 32768...60999

    struct TailnetPhone: Equatable { let name: String; let address: String }

    static func tailscaleExecutable() -> String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Online Android peers owned by the same Tailscale user, so other people's shared devices are never probed.
    static func ownAndroidPeers(fromTailscaleStatus data: Data) -> [TailnetPhone] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any], let myUser = me["UserID"] as? NSNumber,
              let peers = root["Peer"] as? [String: [String: Any]] else { return [] }
        return peers.values.compactMap { peer in
            guard (peer["OS"] as? String)?.lowercased() == "android", peer["Online"] as? Bool == true,
                  (peer["UserID"] as? NSNumber) == myUser,
                  let ip = (peer["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") }) else { return nil }
            let name = (peer["HostName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ip
            return TailnetPhone(name: name, address: ip)
        }.sorted { $0.name < $1.name }
    }

    /// Non-blocking connect scan in batches on a background thread. Closed ports answer with a
    /// reset almost immediately over a direct tailnet path, so a full sweep takes seconds.
    nonisolated static func openPorts(host: String, ports: ClosedRange<UInt16>, timeoutMs: Int32 = 700) async -> [UInt16] {
        await Task.detached(priority: .userInitiated) { () -> [UInt16] in
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return [] }
            var limit = rlimit(); getrlimit(RLIMIT_NOFILE, &limit)
            if limit.rlim_cur < 4096 { limit.rlim_cur = min(4096, limit.rlim_max); setrlimit(RLIMIT_NOFILE, &limit) }
            getrlimit(RLIMIT_NOFILE, &limit)
            let batchSize = max(64, min(1024, Int(limit.rlim_cur) - 128))
            var open: [UInt16] = []
            var all = Array(ports)[...]
            while !all.isEmpty {
                if Task.isCancelled { break }
                let batch = all.prefix(batchSize); all = all.dropFirst(batch.count)
                var fds: [pollfd] = []; var fdPorts: [UInt16] = []
                for port in batch {
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    guard fd >= 0 else { continue }
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    var target = address; target.sin_port = port.bigEndian
                    let result = withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                    if result == 0 { open.append(port); close(fd); continue }
                    guard errno == EINPROGRESS else { close(fd); continue }
                    fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)); fdPorts.append(port)
                }
                let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
                var pending = Set(fds.indices)
                while !pending.isEmpty, Date() < deadline {
                    var current = pending.map { fds[$0] }; let indices = Array(pending)
                    let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                    guard poll(&current, nfds_t(current.count), remaining) > 0 else { break }
                    for (slot, index) in indices.enumerated() where current[slot].revents != 0 {
                        pending.remove(index)
                        var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fds[index].fd, SOL_SOCKET, SO_ERROR, &error, &length)
                        if error == 0 && current[slot].revents & Int16(POLLOUT) != 0 { open.append(fdPorts[index]) }
                    }
                }
                fds.forEach { close($0.fd) }
            }
            return open.sorted()
        }.value
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
