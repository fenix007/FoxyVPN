import Darwin
import Foundation

public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case allTraffic
    case selectedSites
}

public struct RoutingSettings: Codable, Equatable, Sendable {
    public var mode: RoutingMode
    public var vpnDomains: [String]
    public var routeCodingClients: Bool

    /// Domain suffixes also cover API, sign-in and asset subdomains.
    public static let codingDomains = [
        "anthropic.com", "chatgpt.com", "claude.ai", "claude.com",
        "claudeusercontent.com", "codotok.sale", "oaistatic.com",
        "oaiusercontent.com", "openai.com",
    ]
    // Never match node or Electron globally: other applications use them too.
    public static let codingProcessNames = [
        "Claude", "Claude Helper", "Claude Helper (Renderer)", "Claude Helper (Plugin)",
        "claude", "Codex", "Codex Helper", "Codex Helper (Renderer)", "codex",
    ]
    // Native Claude updates install executables under versioned filenames.
    public static let codingProcessPathRegex = [
        #"^/Users/[^/]+/\.local/share/claude/versions/[^/]+$"#,
    ]
    public var bypassRussianDomains: Bool
    public var directDomains: [String]
    public var directIPCIDRs: [String]

    public init(bypassRussianDomains: Bool = false, directDomains: [String] = [], directIPCIDRs: [String] = [],
                mode: RoutingMode = .allTraffic, vpnDomains: [String] = [], routeCodingClients: Bool = false) {
        self.mode = mode
        self.vpnDomains = vpnDomains
        self.routeCodingClients = routeCodingClients
        self.bypassRussianDomains = bypassRussianDomains
        self.directDomains = directDomains
        self.directIPCIDRs = directIPCIDRs
    }

    private enum CodingKeys: String, CodingKey {
        case bypassRussianDomains, directDomains, directIPCIDRs, mode, vpnDomains, routeCodingClients
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bypassRussianDomains = try values.decode(Bool.self, forKey: .bypassRussianDomains)
        directDomains = try values.decode([String].self, forKey: .directDomains)
        directIPCIDRs = try values.decode([String].self, forKey: .directIPCIDRs)
        // Existing preferences and helper payloads retain the original full tunnel.
        mode = try values.decodeIfPresent(RoutingMode.self, forKey: .mode) ?? .allTraffic
        vpnDomains = try values.decodeIfPresent([String].self, forKey: .vpnDomains) ?? []
        routeCodingClients = try values.decodeIfPresent(Bool.self, forKey: .routeCodingClients) ?? false
    }

    public var vpnEntriesText: String { vpnDomains.joined(separator: "\n") }

    public var domainSuffixes: [String] {
        Array(Set(directDomains + (bypassRussianDomains ? ["ru", "su", "xn--p1ai"] : []))).sorted()
    }

    public var entriesText: String { (directDomains + directIPCIDRs).joined(separator: "\n") }

    /// A restricted settings schema, never arbitrary sing-box options or paths.
    public func validated() throws -> RoutingSettings {
        guard directDomains.count + directIPCIDRs.count + vpnDomains.count <= 2048 else {
            throw RoutingSettingsError("В списках может быть не более 2048 записей.")
        }
        return try RoutingSettings.parse(entriesText, bypassRussianDomains: bypassRussianDomains,
            mode: mode, vpnDomainsText: vpnEntriesText, routeCodingClients: routeCodingClients)
    }

    public static func parse(_ text: String, bypassRussianDomains: Bool, mode: RoutingMode = .allTraffic,
                             vpnDomainsText: String = "", routeCodingClients: Bool = false) throws -> RoutingSettings {
        guard text.utf8.count + vpnDomainsText.utf8.count <= 32 * 1024 else {
            throw RoutingSettingsError("Списки слишком большие (не более 32 КБ суммарно).")
        }
        func entries(_ source: String) -> [String] {
            source.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let directEntries = entries(text)
        let vpnEntries = entries(vpnDomainsText)
        guard directEntries.count + vpnEntries.count <= 2048 else {
            throw RoutingSettingsError("В списках может быть не более 2048 записей.")
        }
        var domains = Set<String>()
        var networks = Set<String>()
        var vpnDomains = Set<String>()
        for raw in directEntries {
            let entry = raw.hasPrefix("domain:") ? String(raw.dropFirst(7)) : raw
            if let network = ipNetwork(entry) {
                networks.insert(network)
            } else if !entry.contains("/"), let domain = domain(entry) {
                domains.insert(domain)
            } else {
                throw RoutingSettingsError("Некорректное исключение: \(String(entry.prefix(100))). Укажи домен без https://, IP или подсеть CIDR.")
            }
        }
        for raw in vpnEntries {
            let entry = raw.hasPrefix("domain:") ? String(raw.dropFirst(7)) : raw
            guard let domain = domain(entry) else {
                throw RoutingSettingsError("Некорректный домен VPN: \(String(entry.prefix(100))). Укажи домен без https:// и путей.")
            }
            vpnDomains.insert(domain)
        }
        return RoutingSettings(bypassRussianDomains: bypassRussianDomains,
            directDomains: domains.sorted(), directIPCIDRs: networks.sorted(), mode: mode,
            vpnDomains: vpnDomains.sorted(), routeCodingClients: routeCodingClients)
    }

    public func helperArgument() throws -> String {
        try JSONEncoder().encode(validated()).base64EncodedString()
    }

    public static func fromHelperArgument(_ value: String) throws -> RoutingSettings {
        guard value.utf8.count <= 56 * 1024, let data = Data(base64Encoded: value),
              data.count <= 40 * 1024 else {
            throw RoutingSettingsError("Некорректные настройки маршрутизации.")
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    private static func domain(_ raw: String) -> String? {
        var name = raw.lowercased()
        if name.hasPrefix("*.") { name.removeFirst(2) }
        if name.hasSuffix(".") { name.removeLast() }
        // URL.host supplies IDNA ASCII encoding for international domain names.
        guard !name.isEmpty, !name.contains(where: { "/:@?#%\\".contains($0) || $0.isWhitespace }),
              let ascii = URL(string: "https://" + name)?.host?.lowercased(),
              ascii.utf8.count <= 253, ascii.contains(where: { $0.isLetter }) else { return nil }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        // Whole zones are available only through the explicit built-in toggle.
        // A pasted/downloaded list must not silently bypass every .com site.
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) &&
            label.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        }) else { return nil }
        return ascii
    }

    private static func ipNetwork(_ value: String) -> String? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let host = String(parts[0])
        guard !host.isEmpty, host.allSatisfy({ "0123456789abcdefABCDEF:.".contains($0) }) else { return nil }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let bits: Int
        if inet_pton(AF_INET, host, &ipv4) == 1 { bits = 32 }
        else if inet_pton(AF_INET6, host, &ipv6) == 1 { bits = 128 }
        else { return nil }
        let prefix: Int
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsed = Int(parts[1]), (0...bits).contains(parsed) else { return nil }
            prefix = parsed
        } else { prefix = bits }
        return host.lowercased() + "/" + String(prefix)
    }
}

public struct RoutingSettingsError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
