import Darwin
import Foundation

private var terminationRequested: sig_atomic_t = 0

private struct RelayError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private struct Arguments {
    let appPID: Int32
    let core: URL
    let config: URL

    static func parse() throws -> Arguments {
        let raw = Array(CommandLine.arguments.dropFirst())
        guard raw.count == 6 else { throw RelayError(text: "Invalid relay arguments.") }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: raw.count, by: 2) {
            let key = raw[index]
            guard ["--app-pid", "--core", "--config"].contains(key), values[key] == nil else {
                throw RelayError(text: "Invalid relay arguments.")
            }
            values[key] = raw[index + 1]
        }
        guard let rawPID = values["--app-pid"], let appPID = Int32(rawPID), appPID > 1,
              appPID == getppid(), kill(appPID, 0) == 0,
              let corePath = values["--core"], corePath.hasPrefix("/"), !corePath.contains("\0"),
              let configPath = values["--config"], configPath.hasPrefix("/"), !configPath.contains("\0"),
              FileManager.default.isExecutableFile(atPath: corePath) else {
            throw RelayError(text: "The FoxyVPN parent or relay files are unavailable.")
        }
        var info = stat()
        guard lstat(configPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= 64 * 1024 else {
            throw RelayError(text: "The relay configuration is not a private regular file.")
        }
        return Arguments(appPID: appPID, core: URL(fileURLWithPath: corePath), config: URL(fileURLWithPath: configPath))
    }
}

private func stop(_ child: Process) {
    guard child.isRunning else { return }
    child.terminate()
    for _ in 0..<30 {
        guard child.isRunning else { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    // The Process still owns this child PID; it has not been reaped/reused.
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    child.waitUntilExit()
}

signal(SIGTERM) { _ in terminationRequested = 1 }
signal(SIGINT) { _ in terminationRequested = 1 }
signal(SIGHUP) { _ in terminationRequested = 1 }

do {
    let arguments = try Arguments.parse()
    let child = Process()
    child.executableURL = arguments.core
    child.arguments = ["run", "-c", arguments.config.path]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    try child.run()
    while child.isRunning {
        if terminationRequested != 0 || getppid() != arguments.appPID || kill(arguments.appPID, 0) != 0 {
            stop(child)
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    child.waitUntilExit()
    exit(child.terminationStatus == 0 ? 0 : 1)
} catch {
    // Config contents and credentials must never appear in diagnostics.
    fputs("FoxyVPN relay could not start: \(error.localizedDescription)\n", stderr)
    exit(1)
}
