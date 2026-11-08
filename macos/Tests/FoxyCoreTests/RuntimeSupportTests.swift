import Foundation
import Testing
@testable import FoxyCore

struct RuntimeSupportTests {
    @Test func testSessionValidation() {
        #expect(RuntimeSupport.validSessionToken(String(repeating: "a1", count: 32)))
        #expect(!(RuntimeSupport.validSessionToken(String(repeating: "A1", count: 32))))
        #expect(!(RuntimeSupport.validSessionToken(String(repeating: "a1", count: 32) + "\n")))
    }

    @Test func testShellQuoteRoundTrip() throws {
        let original = "quote' dollar$ backtick` newline\n end"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + RuntimeSupport.shellQuote(original)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == original)
    }

    @Test func testSecretsRedacted() {
        let token = String(repeating: "f", count: 64)
        let line = "token \(token) eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyIn0.signature refresh_token=secret"
        let redacted = RuntimeSupport.redact(line)
        #expect(!(redacted.contains(token)))
        #expect(!(redacted.contains("eyJ")))
        #expect(!(redacted.contains("secret")))
    }

    @Test func testBackgroundCommandSurvivesHangupAndRedirectsOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foxyvpn-launch-'" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("helper.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RuntimeSupport.backgroundShellCommand(executable: "/bin/sh",
            arguments: ["-c", "kill -HUP $$; printf 'ready\\n'; printf 'diagnostic\\n' >&2; if read line; then exit 1; fi"],
            logPath: log.path) + "\nwait \"$!\""]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: log, encoding: .utf8) == "ready\ndiagnostic\n")
    }

    @Test func testTokenCacheMustHaveExpectedShape() {
        #expect(!(RuntimeSupport.validTokenCache(Data("{}".utf8))))
        #expect(RuntimeSupport.validTokenCache(Data(#"{"access_token":"secret","obtained_at":"2026-11-08T12:00:00Z","expires_in":3600}"#.utf8)))
    }
}
