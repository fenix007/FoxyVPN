import Darwin
import Foundation
import FoxyCore

// Pipe callbacks run outside the main actor. Only byte counters cross that boundary.
private final class DownloadCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private var firstByte: TimeInterval?
    private var lastByte: TimeInterval = 0
    private var ended = false
    private var parser = LocationSpeedResponseParser()
    private var invalidResponse = false

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.isEmpty { ended = true; return }
        let bodyBytes: Int
        do { bodyBytes = try parser.consume(data) }
        catch { invalidResponse = true; return }
        guard bodyBytes > 0 else { return }
        guard received < LocationSpeedMeasurement.maximumBytes else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if firstByte == nil { firstByte = now }
        lastByte = now
        received = min(LocationSpeedMeasurement.maximumBytes, received + bodyBytes)
    }

    func snapshot() -> (bytes: Int, first: TimeInterval?, last: TimeInterval, ended: Bool, headers: String, invalid: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (received, firstByte, lastByte, ended, parser.headers, invalidResponse)
    }
}

@MainActor
final class LocationSpeedDownload {
    private var process: Process?

    func cancel() {
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func measure(port: Int, directory: URL) async throws -> LocationSpeedMeasurement {
        precondition((1...65_535).contains(port))
        try Task.checkCancellation()
        let output = Pipe()
        let counters = DownloadCounters()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            counters.consume(data)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        let child = Process()
        child.currentDirectoryURL = directory
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = ["-q", "--silent", "--show-error", "--fail", "--proto", "=https", "--include", "--no-buffer",
            "--socks5-hostname", "127.0.0.1:\(port)", "--noproxy", "",
            "--connect-timeout", "10", "--max-time", "15", "--max-filesize", "5000000",
            "--header", "Accept-Encoding: identity", "--header", "Cache-Control: no-cache, no-store",
            "https://speed.cloudflare.com/__down?bytes=5000000&cachebust=\(UUID().uuidString)"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        process = child
        defer {
            cancel()
            if child.isRunning { child.waitUntilExit() }
            process = nil
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let started = ProcessInfo.processInfo.systemUptime
        try child.run()
        // Close the parent's writer so that EOF arrives after curl exits.
        try? output.fileHandleForWriting.close()
        var sampleExpired = false
        var byteLimitReached = false
        var stoppedAt: TimeInterval?
        while true {
            try Task.checkCancellation()
            let sample = counters.snapshot()
            if sample.invalid { throw LocationSpeedError.invalidResponse }
            let now = ProcessInfo.processInfo.systemUptime
            if sample.bytes >= LocationSpeedMeasurement.maximumBytes, child.isRunning {
                byteLimitReached = true
                cancel()
            }
            if let first = sample.first,
               now - first >= LocationSpeedMeasurement.sampleSeconds, child.isRunning {
                sampleExpired = true
                stoppedAt = now
                cancel()
            }
            if now - started >= LocationSpeedMeasurement.requestSeconds + 1 {
                throw LocationSpeedError.timedOut
            }
            if !child.isRunning && sample.ended { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        let sample = counters.snapshot()
        if !sampleExpired && !byteLimitReached && child.terminationStatus != 0 {
            if child.terminationStatus == 28 { throw LocationSpeedError.timedOut }
            throw LocationSpeedError.failed
        }
        guard sample.first != nil else { throw LocationSpeedError.incomplete }
        return try LocationSpeedMeasurement.finish(receivedBytes: sample.bytes,
            // Include request setup so even a transfer delivered in one pipe read
            // has a real interval. Estimates conservatively include HTTPS latency.
            elapsedSeconds: (stoppedAt ?? sample.last) - started,
            sampleExpired: sampleExpired, headers: sample.headers)
    }
}
