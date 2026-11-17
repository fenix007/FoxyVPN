import Darwin
import Foundation

/// A server connection, not an arbitrary sing-box configuration.
/// Persist encoded profiles in Keychain: `password` is a VPN credential.
public struct VPNServerProfile: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var server: String
    public var serverPort: Int
    public var method: String
    public var password: String
    public var routing: RoutingSettings

    public init(version: Int = 1, name: String, server: String, serverPort: Int,
                method: String = "2022-blake3-aes-256-gcm", password: String,
                routing: RoutingSettings = RoutingSettings(bypassRussianDomains: true)) {
        self.version = version
        self.name = name
        self.server = server
        self.serverPort = serverPort
        self.method = method
        self.password = password
        self.routing = routing
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, server, serverPort, method, password, routing
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try values.decode(String.self, forKey: .name)
        server = try values.decode(String.self, forKey: .server)
        serverPort = try values.decode(Int.self, forKey: .serverPort)
        method = try values.decode(String.self, forKey: .method)
        password = try values.decode(String.self, forKey: .password)
        routing = try values.decodeIfPresent(RoutingSettings.self, forKey: .routing)
            ?? RoutingSettings(bypassRussianDomains: true)
    }

    public static func decode(data: Data) throws -> VPNServerProfile {
        guard !data.isEmpty, data.count <= 48 * 1024 else {
            throw VPNServerProfileError("Профиль сервера должен быть не больше 48 КБ.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch is DecodingError {
            throw VPNServerProfileError("Файл не соответствует формату профиля сервера FoxyVPN.")
        }
    }

    public func validated() throws -> VPNServerProfile {
        guard version == 1 else {
            throw VPNServerProfileError("Версия профиля сервера не поддерживается.")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 100,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VPNServerProfileError("Некорректное название VPN-сервера.")
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard server.utf8.count <= 45,
              server.allSatisfy({ "0123456789abcdefABCDEF:.".contains($0) }),
              inet_pton(AF_INET, server, &ipv4) == 1 || inet_pton(AF_INET6, server, &ipv6) == 1 else {
            throw VPNServerProfileError("В профиле нужен IPv4 или IPv6 адрес VPN-сервера без URL и порта.")
        }
        guard (1...65_535).contains(serverPort) else {
            throw VPNServerProfileError("Некорректный порт VPN-сервера.")
        }
        guard method == "2022-blake3-aes-256-gcm" else {
            throw VPNServerProfileError("Поддерживается только шифрование Shadowsocks 2022 AES-256-GCM.")
        }
        guard password.utf8.count == 44, let key = Data(base64Encoded: password), key.count == 32,
              key.base64EncodedString() == password else {
            throw VPNServerProfileError("Некорректный ключ VPN-сервера.")
        }
        return VPNServerProfile(version: version, name: name, server: server.lowercased(),
            serverPort: serverPort, method: method, password: password, routing: try routing.validated())
    }

    /// Only this unprivileged loopback relay receives the server credential.
    /// Bind its remote connection to the physical interface before TUN routes exist.
    public func relayConfiguration(port: Int, interface: String) throws -> Data {
        let profile = try validated()
        guard (1...65_535).contains(port),
              interface.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil else {
            throw VPNServerProfileError("Некорректный локальный порт или сетевой интерфейс.")
        }
        let configuration: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "inbounds": [[
                "type": "socks", "tag": "local-socks", "listen": "127.0.0.1", "listen_port": port,
            ]],
            "outbounds": [[
                "type": "shadowsocks", "tag": "server", "server": profile.server,
                "server_port": profile.serverPort, "method": profile.method,
                "password": profile.password, "network": "tcp", "bind_interface": interface,
            ]],
            "route": ["final": "server"],
        ]
        return try JSONSerialization.data(withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

public struct VPNServerProfileError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
