import Foundation

// curl includes response headers in its output so they survive an interrupted sample.
// Header bytes can be split across pipe reads and must never count as downloaded data.
public struct LocationSpeedResponseParser: Sendable {
    private var buffer = Data()
    private var readingHeaders = true
    public private(set) var headers = ""

    public init() { }

    public mutating func consume(_ data: Data) throws -> Int {
        if !readingHeaders { return data.count }
        buffer.append(data)
        let terminator = Data([13, 10, 13, 10])
        while let range = buffer.range(of: terminator) {
            let count = buffer.distance(from: buffer.startIndex, to: range.upperBound)
            guard count <= 64 * 1024,
                  let block = String(data: buffer.prefix(count), encoding: .utf8),
                  block.hasPrefix("HTTP/"),
                  let statusText = block.replacingOccurrences(of: "\r\n", with: "\n")
                    .split(separator: "\n").first?.split(separator: " ").dropFirst().first,
                  let status = Int(String(statusText).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw LocationSpeedError.invalidResponse
            }
            if (100..<200).contains(status) {
                buffer.removeFirst(count)
                continue
            }
            headers = block
            readingHeaders = false
            let bodyBytes = buffer.count - count
            buffer.removeAll()
            return bodyBytes
        }
        guard buffer.count <= 64 * 1024 else { throw LocationSpeedError.invalidResponse }
        return 0
    }
}

public struct LocationSpeedMeasurement: Equatable, Sendable {
    public static let maximumBytes = 5_000_000
    public static let sampleSeconds: TimeInterval = 5
    public static let requestSeconds: TimeInterval = 15

    public let receivedBytes: Int
    public let elapsedSeconds: TimeInterval
    public var megabitsPerSecond: Double { Double(receivedBytes) * 8 / elapsedSeconds / 1_000_000 }

    public static func finish(receivedBytes: Int, elapsedSeconds: TimeInterval,
                              sampleExpired: Bool, headers: String) throws -> Self {
        // curl's header dump can contain interim responses. Validate the final one.
        let responses = headers.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n").filter { $0.hasPrefix("HTTP/") }
        guard let response = responses.last else { throw LocationSpeedError.invalidResponse }
        let lines = response.components(separatedBy: "\n")
        guard let first = lines.first,
              let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw LocationSpeedError.invalidResponse
        }
        guard status == 200 else { throw LocationSpeedError.httpStatus(status) }
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].lowercased() == "content-encoding",
               pair[1].trimmingCharacters(in: .whitespaces).lowercased() != "identity" {
                throw LocationSpeedError.compressedResponse
            }
        }
        guard receivedBytes > 0, receivedBytes <= maximumBytes,
              elapsedSeconds.isFinite, elapsedSeconds > 0,
              sampleExpired || receivedBytes == maximumBytes else { throw LocationSpeedError.incomplete }
        return Self(receivedBytes: receivedBytes, elapsedSeconds: elapsedSeconds)
    }
}

public enum LocationSpeedError: LocalizedError {
    case invalidResponse, compressedResponse, incomplete, timedOut, failed
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Сервер теста скорости вернул некорректный ответ."
        case .compressedResponse: return "Сервер теста скорости вернул сжатые данные."
        case .incomplete: return "Сервер теста скорости завершил загрузку раньше времени."
        case .timedOut: return "Превышено время ожидания теста скорости."
        case .failed: return "Не удалось загрузить данные через выбранную локацию."
        case .httpStatus(let status): return "Сервер теста скорости вернул HTTP \(status)."
        }
    }
}
