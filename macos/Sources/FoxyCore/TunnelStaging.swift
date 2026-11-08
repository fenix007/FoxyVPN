import Foundation

public enum TunnelStaging {
    public static func directory(forHelperPath path: String) -> URL? {
        guard path.range(
            of: #"^/private/tmp/foxyvpn-tunnel\.[A-Za-z0-9]+/foxyvpn-tunnel\z"#,
            options: .regularExpression
        ) != nil else { return nil }

        // standardizedFileURL rewrites /private/tmp to /tmp on macOS. Keep the
        // validated spelling; the helper checks ownership and modes with lstat.
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }
}
