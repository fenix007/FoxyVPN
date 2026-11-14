import Darwin
import Foundation
import FoxyCore

private var terminationRequested: sig_atomic_t = 0

private struct HelperError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

private struct Arguments {
    let appPID: Int32
    let backendPID: Int32
    let port: Int
    let routing: RoutingSettings

    static func parse() throws -> Arguments {
        let raw = Array(CommandLine.arguments.dropFirst())
        guard raw.count == 6 || raw.count == 8 else {
            throw HelperError("Usage: foxyvpn-tunnel --app-pid PID --backend-pid PID --port PORT [--routing BASE64]")
        }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: raw.count, by: 2) {
            let key = raw[index]
            guard ["--app-pid", "--backend-pid", "--port", "--routing"].contains(key),
                  values[key] == nil else {
                throw HelperError("Invalid or repeated helper argument.")
            }
            values[key] = raw[index + 1]
        }
        guard let appText = values["--app-pid"],
              let backendText = values["--backend-pid"],
              let portText = values["--port"],
              let appPID = Int32(appText), appPID > 1,
              let backendPID = Int32(backendText), backendPID > 1,
              appPID != backendPID,
              let port = Int(portText), (1...65_535).contains(port) else {
            throw HelperError("Invalid helper process or port value.")
        }
        let routing = try values["--routing"].map(RoutingSettings.fromHelperArgument) ?? RoutingSettings()
        return Arguments(appPID: appPID, backendPID: backendPID, port: port, routing: routing)
    }
}

private struct ProcessIdentity: Equatable {
    let pid: Int32
    let uid: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let name: String

    static func read(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard actualSize == MemoryLayout<proc_bsdinfo>.size else { return nil }
        let nameCapacity = MemoryLayout.size(ofValue: info.pbi_name)
        let name = withUnsafePointer(to: &info.pbi_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                String(cString: $0)
            }
        }
        return ProcessIdentity(
            pid: pid,
            uid: info.pbi_uid,
            startedSeconds: info.pbi_start_tvsec,
            startedMicroseconds: info.pbi_start_tvusec,
            name: name
        )
    }

    var isStillRunning: Bool { ProcessIdentity.read(pid) == self }
}

private struct Status: Encodable {
    let phase: String
    let message: String
}

private final class TunnelHelper {
    private let arguments: Arguments
    private let directory: URL
    private let helperURL: URL
    private let singBoxURL: URL
    private let configURL: URL
    private let logURL: URL
    private let statusURL: URL
    private let appIdentity: ProcessIdentity
    private let backendIdentity: ProcessIdentity
    private var singBox: Process?

    init(arguments: Arguments) throws {
        guard getuid() == 0, geteuid() == 0 else {
            throw HelperError("The VPN tunnel helper must run as root.")
        }
        guard let directory = TunnelStaging.directory(forHelperPath: CommandLine.arguments[0]) else {
            throw HelperError("The VPN tunnel helper is outside its protected staging directory.")
        }

        let helperURL = directory.appendingPathComponent("foxyvpn-tunnel")

        self.arguments = arguments
        self.directory = directory
        self.helperURL = helperURL
        self.singBoxURL = directory.appendingPathComponent("sing-box")
        self.configURL = directory.appendingPathComponent("config.json")
        self.logURL = directory.appendingPathComponent("sing-box.log")
        self.statusURL = directory.appendingPathComponent("status.json")

        try Self.validateProtectedDirectory(directory.path)
        try Self.validateProtectedExecutable(helperURL.path)
        try Self.validateProtectedExecutable(singBoxURL.path)

        guard let app = ProcessIdentity.read(arguments.appPID),
              let backend = ProcessIdentity.read(arguments.backendPID) else {
            throw HelperError("FoxyVPN closed before the tunnel could start.")
        }
        guard app.uid != 0, app.uid == backend.uid else {
            throw HelperError("The FoxyVPN processes do not have the same non-root owner.")
        }
        guard app.name == "FoxyVPN", ["foxyvpn-proxy", "foxyvpn-relay"].contains(backend.name) else {
            throw HelperError("The requested tunnel process identity is invalid.")
        }
        self.appIdentity = app
        self.backendIdentity = backend

        let helperLog = directory.appendingPathComponent("helper.log").path
        if lchmod(helperLog, S_IRUSR | S_IWUSR) != 0 && errno != ENOENT {
            throw HelperError("Could not protect the tunnel helper log.")
        }
    }

    func run() {
        do {
            try writeStatus(phase: "starting", message: "Creating the macOS VPN tunnel.")
            let interface = try defaultRouteInterface()
            let configuration = try TunnelConfiguration.data(port: arguments.port, interface: interface, routing: arguments.routing)
            try writeNewPrivateFile(configuration, to: configURL)
            try startSingBox()
            try waitUntilReady()
            try writeStatus(phase: "running", message: "VPN tunnel is running.")
            monitor()
        } catch {
            stopSingBox()
            let message = error.localizedDescription.isEmpty ? "The VPN tunnel failed." : error.localizedDescription
            try? writeStatus(phase: "error", message: message)
        }
        removePrivilegedArtifacts()
    }

    private static func validateProtectedDirectory(_ path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw HelperError("The VPN tunnel staging directory is not protected.")
        }
    }

    private static func validateProtectedExecutable(_ path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw HelperError("A VPN tunnel executable is not a protected regular file.")
        }
    }

    private func defaultRouteInterface() throws -> String {
        for arguments in [["-n", "get", "default"], ["-n", "get", "-inet6", "default"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = arguments
            process.environment = ["LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, data.count < 64 * 1_024 else { continue }
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let fields = line.split(separator: ":", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    if fields.count == 2, fields[0] == "interface",
                       fields[1].range(
                        of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#,
                        options: .regularExpression
                       ) != nil {
                        return fields[1]
                    }
                }
            } catch {
                continue
            }
        }
        throw HelperError("Could not determine the default macOS network interface.")
    }

    private func startSingBox() throws {
        let logDescriptor = open(
            logURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard logDescriptor >= 0 else {
            throw HelperError("Could not create the protected tunnel log.")
        }
        let logHandle = FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = singBoxURL
        process.arguments = ["run", "-c", configURL.path]
        process.environment = [
            "HOME": "/var/empty",
            "LANG": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": directory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw HelperError("Could not start the VPN tunnel engine: \(error.localizedDescription)")
        }
        try? logHandle.close()
        singBox = process
    }

    private func waitUntilReady() throws {
        guard let process = singBox else { throw HelperError("The VPN tunnel engine did not start.") }
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if terminationRequested != 0 || !appIdentity.isStillRunning || !backendIdentity.isStillRunning {
                throw HelperError("FoxyVPN closed while the VPN tunnel was starting.")
            }
            if !process.isRunning {
                throw HelperError("The VPN tunnel engine exited during startup. \(lastLogMessage())")
            }
            if let data = try? Data(contentsOf: logURL), data.count < 2 * 1_024 * 1_024,
               String(decoding: data, as: UTF8.self).contains("sing-box started") {
                return
            }
            usleep(100_000)
        }
        throw HelperError("The VPN tunnel engine did not become ready within 45 seconds.")
    }

    private func monitor() {
        guard let process = singBox else { return }
        while terminationRequested == 0,
              appIdentity.isStillRunning,
              backendIdentity.isStillRunning,
              process.isRunning {
            usleep(250_000)
        }
        let engineFailed = !process.isRunning && appIdentity.isStillRunning && backendIdentity.isStillRunning
        stopSingBox()
        if engineFailed {
            try? writeStatus(
                phase: "error",
                message: "The VPN tunnel engine stopped unexpectedly. \(lastLogMessage())"
            )
        } else {
            try? writeStatus(phase: "stopped", message: "VPN tunnel stopped.")
        }
    }

    private func stopSingBox() {
        guard let process = singBox else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(100_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        singBox = nil
    }

    private func writeStatus(phase: String, message: String) throws {
        let data = try JSONEncoder().encode(Status(phase: phase, message: String(message.prefix(2_000))))
        let temporary = directory.appendingPathComponent("status.tmp")
        unlink(temporary.path)
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard descriptor >= 0 else { throw HelperError("Could not write tunnel status.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, statusURL.path) == 0 else {
            unlink(temporary.path)
            throw HelperError("Could not publish tunnel status.")
        }
    }

    private func writeNewPrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw HelperError("Could not create the tunnel configuration.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(url.path)
            throw error
        }
    }

    private func lastLogMessage() -> String {
        guard let data = try? Data(contentsOf: logURL), data.count <= 2 * 1_024 * 1_024 else { return "" }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .suffix(3)
            .joined(separator: " ")
        return String(lines.prefix(800))
    }

    private func removePrivilegedArtifacts() {
        // Leave only the tiny status and launcher log so the app can report the
        // final state. Large privileged binaries and the root config never
        // accumulate in /private/tmp.
        for url in [configURL, logURL, singBoxURL, helperURL] {
            unlink(url.path)
        }
    }
}

signal(SIGTERM) { _ in terminationRequested = 1 }
signal(SIGINT) { _ in terminationRequested = 1 }

do {
    let arguments = try Arguments.parse()
    let helper = try TunnelHelper(arguments: arguments)
    helper.run()
} catch {
    fputs("foxyvpn-tunnel: \(error.localizedDescription)\n", stderr)
    exit(1)
}
