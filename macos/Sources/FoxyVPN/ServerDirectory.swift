import Foundation

struct VPNCountry: Identifiable, Equatable, Sendable {
    let code: String
    let name: String

    var id: String { code }
}

enum ServerDirectoryError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case malformedDirectory

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Сервер вернул некорректный ответ."
        case let .httpStatus(status):
            return "Не удалось загрузить список стран (HTTP \(status))."
        case .responseTooLarge:
            return "Список серверов превышает допустимый размер."
        case .malformedDirectory:
            return "В списке серверов нет доступных стран."
        }
    }
}

enum ServerDirectory {
    private static let endpoint = URL(
        string: "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records"
    )!
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    static func load() async throws -> [VPNCountry] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerDirectoryError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ServerDirectoryError.httpStatus(httpResponse.statusCode)
        }
        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw ServerDirectoryError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, max(0, Int(httpResponse.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ServerDirectoryError.responseTooLarge
            }
            data.append(byte)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [VPNCountry] {
        guard data.count <= maximumResponseBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["data"] as? [[String: Any]]
        else {
            throw ServerDirectoryError.malformedDirectory
        }

        var countriesByCode: [String: VPNCountry] = [:]
        for record in records {
            let country = (record["country"] as? [String: Any]) ?? record
            let code = (country["code"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            let name = (country["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !code.isEmpty,
                  !name.isEmpty,
                  name.caseInsensitiveCompare("CatchAll Anycast") != .orderedSame,
                  containsUsableServer(country)
            else { continue }

            countriesByCode[code] = VPNCountry(code: code, name: name)
        }

        let countries = countriesByCode.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.code < $1.code : comparison == .orderedAscending
        }
        guard !countries.isEmpty else {
            throw ServerDirectoryError.malformedDirectory
        }
        return countries
    }

    private static func containsUsableServer(_ country: [String: Any]) -> Bool {
        guard let cities = country["cities"] as? [[String: Any]] else { return false }
        return cities.contains { city in
            guard let servers = city["servers"] as? [[String: Any]] else { return false }
            return servers.contains(where: isUsableServer)
        }
    }

    private static func isUsableServer(_ server: [String: Any]) -> Bool {
        guard (server["quarantined"] as? Bool) != true else { return false }

        let fallbackHost = server["hostname"] as? String ?? ""
        let fallbackPort = integer(server["port"])
        let protocols = server["protocols"] as? [[String: Any]] ?? []

        if protocols.isEmpty {
            return validEndpoint(host: fallbackHost, port: fallbackPort)
        }

        return protocols.contains { item in
            guard (item["name"] as? String) == "connect" else { return false }
            let protocolHost = (item["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = protocolHost?.isEmpty == false ? protocolHost! : fallbackHost
            let protocolPort = integer(item["port"])
            let port = protocolPort == 0 ? fallbackPort : protocolPort
            return validEndpoint(host: host, port: port)
        }
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func validEndpoint(host: String, port: Int) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253, (1...65_535).contains(port) else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
        }
    }
}
