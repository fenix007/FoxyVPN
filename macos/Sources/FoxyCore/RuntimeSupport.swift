import Foundation

public enum RuntimeSupport {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    public static func backgroundShellCommand(executable: String, arguments: [String], logPath: String) -> String {
        let invocation = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        // macOS nohup can fail to detach from the administrator shell's console.
        // An ignored HUP disposition is inherited across exec without opening /dev/tty.
        return """
        trap '' HUP
        \(invocation) >\(shellQuote(logPath)) 2>&1 </dev/null &
        """
    }

    public static func redact(_ value: String) -> String {
        var result = value
        for pattern in [
            #"(?i)\b[0-9a-f]{64}\b"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"(?i)(access_token|refresh_token|sessionToken|authorization|password)([\s\"':=]+)[^\s,\"}]+"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[скрыто]", options: .regularExpression)
        }
        return String(result.prefix(2_000))
    }

    public static func validSessionToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    public static func validTokenCache(_ data: Data) -> Bool {
        guard data.count < 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty,
              object["obtained_at"] is String,
              object["expires_in"] is NSNumber else { return false }
        return true
    }
}
