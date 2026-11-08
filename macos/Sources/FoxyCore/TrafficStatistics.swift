import Darwin
import Foundation

public struct TrafficBytes: Codable, Equatable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public init(received: UInt64 = 0, sent: UInt64 = 0) {
        self.received = received
        self.sent = sent
    }
    public var total: UInt64 { received &+ sent }
}

public struct TrafficStatistics: Codable, Equatable {
    public var session = TrafficBytes()
    public var lifetime = TrafficBytes()
    public init() {}
}

public struct TrafficMeter {
    public private(set) var statistics: TrafficStatistics
    public private(set) var receivedPerSecond: Double = 0
    public private(set) var sentPerSecond: Double = 0
    private var previous: TrafficBytes?
    private var previousTime: TimeInterval?
    private var interfaceIndex: UInt32?

    public init(statistics: TrafficStatistics = TrafficStatistics()) { self.statistics = statistics }

    public mutating func beginSession() {
        statistics.session = TrafficBytes()
        previous = nil
        previousTime = nil
        interfaceIndex = nil
        stopSpeed()
    }

    public mutating func stopSpeed() {
        receivedPerSecond = 0
        sentPerSecond = 0
        // The next sample must not average across an interval with no readings.
        previousTime = nil
    }

    public mutating func sample(_ bytes: TrafficBytes, interface: UInt32, at time: TimeInterval) {
        let old = interfaceIndex == interface ? previous : nil
        let delta = TrafficBytes(
            received: old.map { bytes.received >= $0.received ? bytes.received - $0.received : bytes.received } ?? bytes.received,
            sent: old.map { bytes.sent >= $0.sent ? bytes.sent - $0.sent : bytes.sent } ?? bytes.sent)
        statistics.session.received &+= delta.received
        statistics.session.sent &+= delta.sent
        statistics.lifetime.received &+= delta.received
        statistics.lifetime.sent &+= delta.sent
        if old != nil, let previousTime, time > previousTime {
            receivedPerSecond = Double(delta.received) / (time - previousTime)
            sentPerSecond = Double(delta.sent) / (time - previousTime)
        } else {
            receivedPerSecond = 0
            sentPerSecond = 0
        }
        previous = bytes
        previousTime = time
        interfaceIndex = interface
    }
}

public enum TunnelTraffic {
    /// Read 64-bit kernel counters, without launching a process or needing root.
    public static func read() -> (index: UInt32, bytes: TrafficBytes)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(first) }
        var indices = Set<UInt32>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("utun") else { continue }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            if ipv4.sin_addr.s_addr == inet_addr("172.19.0.1") {
                indices.insert(if_nametoindex(entry.pointee.ifa_name))
            }
        }
        // Do not accidentally count another tunnel if addresses conflict.
        guard indices.count == 1, let index = indices.first, index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = Data(count: size)
        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length >= MemoryLayout<if_msghdr>.size, offset + length <= size else { return nil }
                if header.ifm_type == RTM_IFINFO2, header.ifm_index == index,
                   length >= MemoryLayout<if_msghdr2>.size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self).ifm_data
                    // The kernel sends app uploads OUT of utun; sing-box injects downloads IN.
                    return (index, TrafficBytes(received: info.ifi_ibytes, sent: info.ifi_obytes))
                }
                offset += length
            }
            return nil
        }
    }
}
