import Foundation
import Testing
@testable import FoxyCore

struct TunnelStagingTests {
    @Test func testPreservesPrivateTmpSpellingForExistingStagingDirectory() throws {
        let path = "/private/tmp/foxyvpn-tunnel." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let directory = try #require(TunnelStaging.directory(forHelperPath: path + "/foxyvpn-tunnel"))
        #expect(directory.path == path)
        #expect(directory.appendingPathComponent("foxyvpn-tunnel").path == path + "/foxyvpn-tunnel")
    }

    @Test func testRejectsPathsOutsideExactStagingLayout() {
        for path in [
            "/tmp/foxyvpn-tunnel.abc123/foxyvpn-tunnel",
            "/private/tmp/foxyvpn-tunnel./foxyvpn-tunnel",
            "/private/tmp/foxyvpn-tunnel.abc123/../foxyvpn-tunnel",
            "/private/tmp/foxyvpn-tunnel.abc123/subdir/foxyvpn-tunnel",
            "/private/tmp/foxyvpn-tunnel.abc123/other",
            "/private/tmp/foxyvpn-tunnel.abc123/foxyvpn-tunnel\n",
            "relative/foxyvpn-tunnel.abc123/foxyvpn-tunnel",
        ] {
            #expect(TunnelStaging.directory(forHelperPath: path) == nil)
        }
    }
}
