import Foundation
import Testing
@testable import FoxyCore

struct LocationSpeedMeasurementTests {
    @Test func headersSplitAcrossPipeReadsDoNotCountAsBody() throws {
        var parser = LocationSpeedResponseParser()
        #expect(try parser.consume(Data("HTTP/2 200\r\nContent-Length: 5\r\n\r".utf8)) == 0)
        #expect(try parser.consume(Data("\nhello".utf8)) == 5)
        #expect(try parser.consume(Data("more".utf8)) == 4)
        #expect(parser.headers.hasPrefix("HTTP/2 200"))
    }

    @Test func interimResponseIsSkippedBeforeBody() throws {
        var parser = LocationSpeedResponseParser()
        #expect(try parser.consume(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/2 200\r\n\r\nbody".utf8)) == 4)
        #expect(parser.headers == "HTTP/2 200\r\n\r\n")
    }

    @Test func unboundedHeadersAreRejected() {
        var parser = LocationSpeedResponseParser()
        #expect(throws: (any Error).self) {
            try parser.consume(Data(repeating: 65, count: 64 * 1024 + 1))
        }
    }

    @Test func fullDownloadReportsDecimalMegabits() throws {
        let sample = try LocationSpeedMeasurement.finish(receivedBytes: 5_000_000,
            elapsedSeconds: 2, sampleExpired: false, headers: "HTTP/2 200\r\ncontent-length: 5000000\r\n\r\n")
        #expect(sample.megabitsPerSecond == 20)
    }

    @Test func sampleDeadlineAcceptsPartialBodyAndFinalHeaders() throws {
        let sample = try LocationSpeedMeasurement.finish(receivedBytes: 1_000_000,
            elapsedSeconds: 5, sampleExpired: true,
            headers: "HTTP/1.1 100 Continue\r\n\r\nHTTP/2 200\r\nContent-Encoding: identity\r\n\r\n")
        #expect(sample.megabitsPerSecond == 1.6)
    }

    @Test func rejectsTruncatedAndEmptyDownloads() {
        #expect(throws: (any Error).self) {
            try LocationSpeedMeasurement.finish(receivedBytes: 1_000_000,
                elapsedSeconds: 2, sampleExpired: false, headers: "HTTP/2 200\r\n\r\n")
        }
        #expect(throws: (any Error).self) {
            try LocationSpeedMeasurement.finish(receivedBytes: 0,
                elapsedSeconds: 5, sampleExpired: true, headers: "HTTP/2 200\r\n\r\n")
        }
    }

    @Test(arguments: ["HTTP/2 302\r\n\r\n", "HTTP/2 200\r\nContent-Encoding: gzip\r\n\r\n", "invalid"])
    func rejectsRedirectsCompressedAndMalformedResponses(headers: String) {
        #expect(throws: (any Error).self) {
            try LocationSpeedMeasurement.finish(receivedBytes: 5_000_000,
                elapsedSeconds: 2, sampleExpired: false, headers: headers)
        }
    }

    @Test(arguments: [0.0, -1.0, Double.infinity, Double.nan])
    func rejectsInvalidTiming(seconds: Double) {
        #expect(throws: (any Error).self) {
            try LocationSpeedMeasurement.finish(receivedBytes: 5_000_000,
                elapsedSeconds: seconds, sampleExpired: false, headers: "HTTP/2 200\r\n\r\n")
        }
    }
}
