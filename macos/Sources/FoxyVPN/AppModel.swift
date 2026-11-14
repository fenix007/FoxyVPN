import AppKit
import Combine
import Darwin
import Foundation
import FoxyCore

private struct CommandResult {
    let status: Int32
    let output: String
}

private func command(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(status: process.terminationStatus,
                    output: String(decoding: data.prefix(64 * 1024), as: UTF8.self)))
            } catch { continuation.resume(throwing: error) }
        }
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Phase { case idle, starting, connected, stopping }
    enum Provider: String, CaseIterable { case firefox, custom }
    @Published private(set) var provider: Provider = .firefox
    @Published private(set) var customServer: VPNServerProfile?
    @Published var phase: Phase = .idle
    @Published var status = "VPN отключён"
    @Published var errorMessage: String?
    @Published var logs: [String] = []
    @Published var signedIn = false
    @Published var showLogin = false
    @Published var countries: [VPNCountry] = []
    @Published var countryCode = UserDefaults.standard.string(forKey: "country") ?? "DE"
    @Published var directoryError: String?
    @Published var exitIP = ""
    @Published var showDiagnostics = false
    @Published var showRouting = false
    @Published private(set) var routing = RoutingSettings()
    @Published private(set) var traffic = TrafficStatistics()
    @Published private(set) var receivedPerSecond: Double = 0
    @Published private(set) var sentPerSecond: Double = 0
    @Published private(set) var trafficAvailable = false

    private var pendingSession: String?
    private var backend: Process?
    private var pipe: Pipe?
    private var runDirectory: URL?
    private var tunnelDirectory: URL?
    private var startup: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var lastSavedTokens: Data?
    private var outputBuffer = ""
    private var instanceLock: Int32 = -1
    private let tokenName = ".firefox-vpn-tokens.json"
    private var trafficMeter = TrafficMeter()
    private let trafficKey = "trafficStatistics.v1"
    private let routingKey = "routingSettings.v1"
    private let providerKey = "vpnProvider.v1"
    private let serverKeychainAccount = "custom-vpn-server"

    var busy: Bool { phase == .starting || phase == .stopping }
    var canConnect: Bool {
        if provider == .custom { return customServer != nil }
        return signedIn && !countries.isEmpty && countries.contains { $0.code == countryCode }
    }
    var serverSummary: String {
        guard let server = customServer else { return "Импортируй профиль своего VPN-сервера." }
        let address = server.server.contains(":") ? "[\(server.server)]" : server.server
        return "\(server.name) · \(address):\(server.serverPort)"
    }
    var transportSummary: String {
        let base = "Через VPN доступны TCP и DNS. UDP и QUIC через VPN не поддерживаются."
        return provider == .firefox ? base + " Доступ и квота зависят от Mozilla." : base
    }

    init() {
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .firefox
        do {
            if let data = try KeychainStore.load(account: serverKeychainAccount) {
                customServer = try VPNServerProfile.decode(data: data)
            }
        } catch { errorMessage = "Не удалось загрузить профиль своего сервера. Импортируй его заново." }
        if let data = UserDefaults.standard.data(forKey: routingKey) {
            do { routing = try JSONDecoder().decode(RoutingSettings.self, from: data).validated() }
            catch { errorMessage = "Не удалось загрузить исключения: \(error.localizedDescription)" }
        }
        if let data = UserDefaults.standard.data(forKey: trafficKey),
           let saved = try? JSONDecoder().decode(TrafficStatistics.self, from: data) {
            trafficMeter = TrafficMeter(statistics: saved)
            traffic = saved
        }
        do { signedIn = try KeychainStore.load().map(RuntimeSupport.validTokenCache) ?? false }
        catch { errorMessage = error.localizedDescription }
    }

    func selectProvider(_ selected: Provider) {
        guard phase == .idle else { return }
        provider = selected
        UserDefaults.standard.set(selected.rawValue, forKey: providerKey)
        errorMessage = nil
        if selected == .firefox && countries.isEmpty {
            Task { await loadCountries() }
        }
    }

    func importServerProfile(from url: URL) throws {
        guard phase == .idle else { throw AppFailure("Сначала отключи VPN.") }
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true, let size = metadata.fileSize, size > 0, size <= 48 * 1024 else {
            throw AppFailure("Нужен JSON-профиль сервера размером не более 48 КБ.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 48 * 1024 + 1) ?? Data()
        let profile: VPNServerProfile
        do { profile = try VPNServerProfile.decode(data: data) }
        catch { throw AppFailure("Некорректный профиль сервера. Проверь, что выбран профиль подключения FoxyVPN.") }
        let checkedRouting = try profile.routing.validated()
        let routingData = try JSONEncoder().encode(checkedRouting)
        let profileData = try JSONEncoder().encode(profile)
        // Validate and encode everything before changing any saved or visible state.
        try KeychainStore.save(profileData, account: serverKeychainAccount)
        UserDefaults.standard.set(routingData, forKey: routingKey)
        UserDefaults.standard.set(Provider.custom.rawValue, forKey: providerKey)
        customServer = profile
        routing = checkedRouting
        provider = .custom
        errorMessage = nil
        status = "Сервер добавлен. Подключи VPN."
    }

    func saveRouting(_ settings: RoutingSettings) throws {
        let checked = try settings.validated()
        let data = try JSONEncoder().encode(checked)
        UserDefaults.standard.set(data, forKey: routingKey)
        routing = checked
    }

    var routingSummary: String {
        if routing.mode == .selectedSites {
            let clients = routing.routeCodingClients ? " · Claude и Codex" : ""
            return "Через VPN: доменов \(routing.vpnDomains.count)" + clients
        }
        let count = routing.directDomains.count + routing.directIPCIDRs.count
        if routing.bypassRussianDomains { return "Весь трафик · .ru, .su, .рф без VPN · исключений: \(count)" }
        return count == 0 ? "Весь трафик, кроме локальной сети" : "Весь трафик · без VPN: \(count)"
    }

    func loadCountries() async {
        guard provider == .firefox else { return }
        do {
            let fetched = try await ServerDirectory.load()
            countries = fetched
            if !fetched.contains(where: { $0.code == countryCode }), let first = fetched.first {
                countryCode = first.code
            }
            directoryError = nil
        } catch { directoryError = "Не удалось загрузить страны: \(error.localizedDescription)" }
    }

    func acceptSession(_ token: String) {
        guard RuntimeSupport.validSessionToken(token), phase == .idle else { return }
        pendingSession = token
        signedIn = true
        showLogin = false
        errorMessage = nil
        status = "Вход выполнен. Выбери страну и подключись."
    }

    func signOut() {
        guard phase == .idle else { return }
        do {
            try KeychainStore.delete()
            pendingSession = nil
            lastSavedTokens = nil
            signedIn = false
            status = "VPN отключён"
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func connect() {
        guard phase == .idle, canConnect else { return }
        phase = .starting
        errorMessage = nil
        exitIP = ""
        trafficMeter.beginSession()
        publishTraffic()
        trafficAvailable = false
        status = provider == .custom ? "Подключение к своему VPN-серверу…" : "Подключение к Firefox VPN…"
        logs = []
        generation = UUID()
        let attempt = generation
        UserDefaults.standard.set(countryCode, forKey: "country")
        let connectionRouting = routing
        let connectionServer = provider == .custom ? customServer : nil
        startup = Task {
            do { try await start(attempt: attempt, routing: connectionRouting, server: connectionServer) }
            catch {
                guard attempt == generation else { return }
                let detail = RuntimeSupport.redact(error.localizedDescription)
                startup = nil
                await stop(reason: detail)
            }
        }
    }

    private func resource(_ name: String) throws -> URL {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AppFailure("Не найден \(name). Собери приложение командой macos/scripts/build-app.sh.")
        }
        return url
    }

    private func start(attempt: UUID, routing: RoutingSettings, server: VPNServerProfile?) async throws {
        let routingArgument = try routing.helperArgument()
        let core = try resource("sing-box")
        _ = try resource("foxyvpn-tunnel")
        let directory = try makeRunDirectory()
        runDirectory = directory
        let port = try availablePort()
        let process = Process()
        if let server {
            let interface = try await physicalInterface()
            try Task.checkCancellation()
            guard attempt == generation else { throw CancellationError() }
            let configuration = try server.relayConfiguration(port: port, interface: interface)
            let configFile = directory.appendingPathComponent("relay.json")
            try writePrivate(configuration, to: configFile)
            process.executableURL = try resource("foxyvpn-relay")
            process.arguments = ["--app-pid", String(ProcessInfo.processInfo.processIdentifier),
                "--core", core.path, "--config", configFile.path]
        } else {
            process.executableURL = try resource("foxyvpn-proxy")
            let tokenFile = directory.appendingPathComponent(tokenName)
            var arguments = ["-country", countryCode, "-verify-exit=false",
                "-status-file", directory.appendingPathComponent("proxy-status.json").path]
            if let session = pendingSession {
                let path = directory.appendingPathComponent("session.txt")
                try writePrivate(Data((session + "\n").utf8), to: path)
                arguments += ["-session-token", path.path]
            } else if let tokens = try KeychainStore.load(), RuntimeSupport.validTokenCache(tokens) {
                try writePrivate(tokens, to: tokenFile)
            } else { throw AppFailure("Войди в Firefox Account заново.") }
            arguments += ["-listen", "127.0.0.1:\(port)"]
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["FOXYVPN_STATE_DIR"] = directory.path
            environment["FOXYVPN_NONINTERACTIVE"] = "1"
            environment["FOXYVPN_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        outputBuffer = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                self.consume(text)
            }
        }
        backend = process
        pipe = output
        try process.run()
        var ready = false
        for _ in 0..<(server == nil ? 900 : 50) {
            try Task.checkCancellation()
            guard attempt == generation else { throw CancellationError() }
            guard process.isRunning else {
                // Pipe delivery can trail process exit; retain the primary auth error.
                try await Task.sleep(for: .milliseconds(100))
                if server == nil && logs.contains(where: { $0.contains("errno 138") || $0.contains("Unconfirmed session") }) {
                    throw AppFailure("Mozilla ещё не подтвердила вход. Выйди из аккаунта в FoxyVPN, войди заново и заверши подтверждение в окне входа или по письму Mozilla.")
                }
                if server != nil { throw AppFailure("Не удалось запустить подключение к своему серверу. \(logs.last ?? "Проверь профиль подключения.")") }
                throw AppFailure("Не удалось подключиться к Firefox VPN. \(logs.last ?? "Проверь учётную запись и подключение к сети.")")
            }
            try saveTokens()
            if logs.contains(where: { $0.contains("SOCKS5 proxy started") || (server != nil && $0.contains("sing-box started")) }) {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard ready else {
            throw AppFailure(server == nil ? "Сервер Firefox VPN не ответил за 3 минуты." : "Локальное подключение к своему серверу не запустилось за 10 секунд.")
        }
        status = "Проверка соединения…"
        let probe = try await command("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--max-time", "25",
            "--socks5-hostname", "127.0.0.1:\(port)", "https://www.cloudflare.com/cdn-cgi/trace"])
        try Task.checkCancellation()
        guard probe.status == 0, let ip = probe.output.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) else {
            throw AppFailure("Проверка VPN-соединения не прошла: \(probe.output)")
        }
        exitIP = String(ip.dropFirst(3))
        status = "macOS запросит пароль администратора для создания VPN-туннеля…"
        let tunnel = try await launchTunnel(backendPID: process.processIdentifier, port: port, routingArgument: routingArgument)
        try Task.checkCancellation()
        guard attempt == generation else { throw CancellationError() }
        tunnelDirectory = tunnel
        status = "Создание VPN-туннеля…"
        var tunnelReady = false
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard process.isRunning else { throw AppFailure("Соединение с VPN-сервером завершилось.") }
            updateTraffic()
            if let state = readTunnelStatus() {
                if state.phase == "running" { tunnelReady = true; break }
                if state.phase == "error" || state.phase == "stopped" {
                    throw AppFailure(state.message.isEmpty ? "Не удалось создать VPN-туннель." : state.message)
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard tunnelReady else { throw AppFailure("macOS не подтвердила запуск VPN-туннеля за 60 секунд.") }
        try saveTokens()
        phase = .connected
        status = "VPN подключён"
        startup = nil
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.updateTraffic()
                do { try self.saveTokens() }
                catch { self.monitor = nil; await self.stop(reason: error.localizedDescription); return }
                if !process.isRunning {
                    self.monitor = nil
                    await self.stop(reason: "Соединение с VPN-сервером завершилось. \(self.logs.last ?? "")")
                    return
                }
                if let state = self.readTunnelStatus(), state.phase != "running" {
                    self.monitor = nil
                    await self.stop(reason: state.message.isEmpty ? "VPN-туннель остановлен." : state.message)
                    return
                }
            }
        }
    }

    func disconnect() {
        guard phase != .idle && phase != .stopping else { return }
        Task { await stop(reason: nil) }
    }

    private func stop(reason: String?) async {
        guard phase != .stopping else { return }
        updateTraffic()
        phase = .stopping
        status = "Отключение VPN…"
        generation = UUID()
        startup?.cancel()
        startup = nil
        monitor?.cancel()
        monitor = nil
        try? saveTokens()
        let process = backend
        if process?.isRunning == true { process?.terminate() }
        // Allow the relay to finish its own 3-second child shutdown first.
        for _ in 0..<50 {
            if process?.isRunning != true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? saveTokens()
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        backend = nil
        // The privileged helper watches both processes and exits when the proxy dies.
        for _ in 0..<50 {
            updateTraffic()
            guard let state = readTunnelStatus(), state.phase == "running" || state.phase == "starting" else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let directory = runDirectory { try? FileManager.default.removeItem(at: directory) }
        runDirectory = nil
        tunnelDirectory = nil
        trafficMeter.stopSpeed()
        publishTraffic()
        phase = .idle
        status = "VPN отключён"
        errorMessage = reason
        exitIP = ""
    }

    func shutdown() {
        updateTraffic()
        trafficMeter.stopSpeed()
        publishTraffic()
        generation = UUID()
        startup?.cancel()
        monitor?.cancel()
        try? saveTokens()
        if backend?.isRunning == true { backend?.terminate() }
        // Temporary credential files are removed on next launch if termination interrupts cleanup.
    }

    private func updateTraffic() {
        guard tunnelDirectory != nil else { return }
        if let sample = TunnelTraffic.read() {
            trafficMeter.sample(sample.bytes, interface: sample.index, at: ProcessInfo.processInfo.systemUptime)
            trafficAvailable = true
        } else {
            trafficMeter.stopSpeed()
            trafficAvailable = false
        }
        publishTraffic()
    }

    private func publishTraffic() {
        traffic = trafficMeter.statistics
        receivedPerSecond = trafficMeter.receivedPerSecond
        sentPerSecond = trafficMeter.sentPerSecond
        if let data = try? JSONEncoder().encode(traffic) {
            UserDefaults.standard.set(data, forKey: trafficKey)
        }
    }

    private func consume(_ text: String) {
        outputBuffer += text
        if outputBuffer.utf8.count > 128 * 1024 { outputBuffer = String(outputBuffer.suffix(8_192)) }
        while let newline = outputBuffer.firstIndex(of: "\n") {
            var line = String(outputBuffer[..<newline])
            if let password = customServer?.password, !password.isEmpty {
                line = line.replacingOccurrences(of: password, with: "[скрыто]")
            }
            line = RuntimeSupport.redact(line)
            outputBuffer.removeSubrange(...newline)
            if !line.isEmpty { logs.append(line) }
        }
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }

    private func saveTokens() throws {
        guard let directory = runDirectory else { return }
        let file = directory.appendingPathComponent(tokenName)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size < 64 * 1024,
              let data = try? Data(contentsOf: file), RuntimeSupport.validTokenCache(data) else { return }
        if data != lastSavedTokens {
            try KeychainStore.save(data)
            lastSavedTokens = data
        }
        pendingSession = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("session.txt"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("session.txt.state"))
    }

    private func makeRunDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FoxyVPN", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        if instanceLock < 0 {
            let fd = open(base.appendingPathComponent("instance.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw AppFailure("Не удалось открыть файл блокировки приложения.") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw AppFailure("FoxyVPN уже запущен. Открой существующее окно приложения.")
            }
            instanceLock = fd
        }
        // A single application instance owns this directory; no runtime credentials survive a restart.
        for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("run-") {
            try? fm.removeItem(at: old)
        }
        let directory = base.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppFailure("Не удалось создать защищённый файл учётных данных.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func physicalInterface() async throws -> String {
        let result = try await command("/sbin/route", ["-n", "get", "default"])
        guard result.status == 0,
              let line = result.output.split(separator: "\n").first(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:")
              }), let separator = line.firstIndex(of: ":") else {
            throw AppFailure("Не удалось определить сетевой интерфейс для VPN-сервера.")
        }
        let interface = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard interface.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil else {
            throw AppFailure("Некорректный сетевой интерфейс для VPN-сервера.")
        }
        return interface
    }

    private func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure("Не удалось открыть локальный сокет.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw AppFailure("Не удалось выбрать локальный порт.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { throw AppFailure("Не удалось прочитать локальный порт.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func launchTunnel(backendPID: Int32, port: Int, routingArgument: String) async throws -> URL {
        let helper = try resource("foxyvpn-tunnel")
        let core = try resource("sing-box")
        let quote = RuntimeSupport.shellQuote
        // Resolve the helper to an absolute path inside the protected working directory.
        let launch = RuntimeSupport.backgroundShellCommand(executable: "/bin/sh",
            arguments: ["-c", "exec \"$PWD/foxyvpn-tunnel\" \"$@\"", "foxyvpn-tunnel",
                "--app-pid", String(ProcessInfo.processInfo.processIdentifier),
                "--backend-pid", String(backendPID), "--port", String(port),
                "--routing", routingArgument], logPath: "helper.log")
        // Only fixed executables are elevated. The helper validates the restricted
        // routing settings and generates its own config; no arbitrary config is accepted.
        let script = """
        set -eu
        umask 022
        d=$(/usr/bin/mktemp -d /private/tmp/foxyvpn-tunnel.XXXXXX)
        /bin/chmod 755 "$d"
        /usr/bin/install -o root -g wheel -m 755 \(quote(helper.path)) "$d/foxyvpn-tunnel"
        /usr/bin/install -o root -g wheel -m 755 \(quote(core.path)) "$d/sing-box"
        cd "$d"
        \(launch)
        helper_pid=$!
        attempts=0
        while [ ! -f "$d/status.json" ]; do
          if ! /bin/kill -0 "$helper_pid" 2>/dev/null || [ "$attempts" -ge 100 ]; then
            /bin/kill "$helper_pid" 2>/dev/null || true
            /usr/bin/printf '%s\\n' 'VPN tunnel helper failed to initialize.' >&2
            /bin/cat "$d/helper.log" >&2
            exit 1
          fi
          /bin/sleep 0.1
          attempts=$((attempts + 1))
        done
        /usr/bin/printf '%s\\n' "$d"
        """
        let appleScript = "do shell script " + RuntimeSupport.appleScriptString(script) + " with administrator privileges"
        let result = try await command("/usr/bin/osascript", ["-e", appleScript])
        guard result.status == 0 else {
            throw AppFailure("Не удалось запустить помощник VPN. \(result.output)")
        }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.range(of: #"^/private/tmp/foxyvpn-tunnel\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
            throw AppFailure("Некорректный ответ помощника VPN.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private struct TunnelStatus: Decodable { let phase: String; let message: String }
    private func readTunnelStatus() -> TunnelStatus? {
        guard let directory = tunnelDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")), data.count < 16 * 1024 else { return nil }
        return try? JSONDecoder().decode(TunnelStatus.self, from: data)
    }
}
