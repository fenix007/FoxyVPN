import Foundation
import Testing
@testable import FoxyCore

struct TrafficStatisticsTests {
    @Test func countsInitialBytesAndDeltasOnce() {
        var meter = TrafficMeter()
        meter.beginSession()
        meter.sample(TrafficBytes(received: 100, sent: 50), interface: 4, at: 1)
        #expect(meter.receivedPerSecond == 0)
        meter.sample(TrafficBytes(received: 500, sent: 150), interface: 4, at: 3)
        #expect(meter.statistics.session == TrafficBytes(received: 500, sent: 150))
        #expect(meter.statistics.lifetime.total == 650)
        #expect(meter.receivedPerSecond == 200)
        #expect(meter.sentPerSecond == 50)
        meter.sample(TrafficBytes(received: 500, sent: 150), interface: 4, at: 4)
        #expect(meter.statistics.lifetime.total == 650)
        #expect(meter.receivedPerSecond == 0)
    }

    @Test func reconnectPreservesTotalsAndResetsSessionAndSpeed() throws {
        var meter = TrafficMeter()
        meter.sample(TrafficBytes(received: 100, sent: 50), interface: 4, at: 1)
        let saved = try JSONEncoder().encode(meter.statistics)
        meter = TrafficMeter(statistics: try JSONDecoder().decode(TrafficStatistics.self, from: saved))
        #expect(meter.statistics.session.total == 150)
        meter.beginSession()
        #expect(meter.statistics.session.total == 0)
        meter.sample(TrafficBytes(received: 20, sent: 10), interface: 4, at: 10)
        #expect(meter.statistics.lifetime.total == 180)
        #expect(meter.statistics.session.total == 30)
        meter.sample(TrafficBytes(received: 40, sent: 20), interface: 4, at: 11)
        meter.stopSpeed()
        #expect(meter.receivedPerSecond == 0)
        #expect(meter.sentPerSecond == 0)
    }

    @Test func handlesCounterResetAndInterfaceReplacementWithoutUnderflow() {
        var meter = TrafficMeter()
        meter.sample(TrafficBytes(received: 500, sent: 200), interface: 4, at: 1)
        meter.sample(TrafficBytes(received: 10, sent: 5), interface: 4, at: 2)
        meter.sample(TrafficBytes(received: 50, sent: 25), interface: 5, at: 3)
        #expect(meter.statistics.session == TrafficBytes(received: 560, sent: 230))
        #expect(meter.receivedPerSecond == 0)
    }
}
