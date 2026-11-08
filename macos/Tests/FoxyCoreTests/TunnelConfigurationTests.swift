import Foundation
import Testing
@testable import FoxyCore

struct TunnelConfigurationTests {
    private func configuration(port: Int = 12_345, interface: String = "en0") throws -> [String: Any] {
        let data = try TunnelConfiguration.data(port: port, interface: interface)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func testConfigurationRoutesTCPThroughLocalProxyAndRejectsUDP() throws {
        let root = try configuration()
        let inbounds = try #require(root["inbounds"] as? [[String: Any]])
        // macOS requires an available utun interface; sing-box chooses its name.
        #expect(inbounds.first?["interface_name"] == nil)
        let outbounds = try #require(root["outbounds"] as? [[String: Any]])
        let proxy = try #require(outbounds.first { $0["tag"] as? String == "proxy" })
        #expect(proxy["server"] as? String == "127.0.0.1")
        #expect(proxy["server_port"] as? Int == 12_345)

        let route = try #require(root["route"] as? [String: Any])
        #expect(route["final"] as? String == "proxy")
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(rules.contains {
            $0["network"] as? String == "udp" && $0["action"] as? String == "reject"
        })
    }

    @Test func testControlPlaneDNSCannotDependOnTheVPNProxy() throws {
        let root = try configuration()
        let dns = try #require(root["dns"] as? [String: Any])
        let servers = try #require(dns["servers"] as? [[String: Any]])
        let bootstrap = try #require(servers.first { $0["tag"] as? String == "bootstrap-dns" })
        #expect(bootstrap["server"] as? String == "1.1.1.1")
        #expect(bootstrap["detour"] as? String == "direct")

        let rules = try #require(dns["rules"] as? [[String: Any]])
        let suffixes = try #require(rules.first?["domain_suffix"] as? [String])
        #expect(suffixes.contains("fastly-masque.net"))
        #expect(suffixes.contains("firefox.com"))
        #expect(suffixes.contains("mozilla.org"))
    }

    @Test func testProxyProcessUsesPhysicalInterfaceToAvoidRouteLoop() throws {
        let root = try configuration(interface: "en7")
        let outbounds = try #require(root["outbounds"] as? [[String: Any]])
        let direct = try #require(outbounds.first { $0["tag"] as? String == "direct" })
        #expect(direct["bind_interface"] as? String == "en7")

        let route = try #require(root["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(rules.contains {
            ($0["process_name"] as? [String]) == ["foxyvpn-proxy"] &&
                $0["outbound"] as? String == "direct"
        })
    }

    @Test func testRejectsUntrustedParameters() throws {
        #expect(throws: Error.self) { try TunnelConfiguration.data(port: 0, interface: "en0") }
        #expect(throws: Error.self) { try TunnelConfiguration.data(port: 65_536, interface: "en0") }
        #expect(throws: Error.self) { try TunnelConfiguration.data(port: 1_088, interface: "en0; id") }
        #expect(throws: Error.self) { try TunnelConfiguration.data(port: 1_088, interface: "../en0") }
    }

    @Test func testDirectExceptionsUseDirectDNSAndCannotEnableUDPProxying() throws {
        let routing = try RoutingSettings.parse("bank.example\n203.0.113.0/24", bypassRussianDomains: true)
        let data = try TunnelConfiguration.data(port: 12345, interface: "en7", routing: routing)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dns = try #require(root["dns"] as? [String: Any])
        #expect(dns["reverse_mapping"] as? Bool == true)
        #expect(dns["final"] as? String == "remote-dns")
        let dnsRules = try #require(dns["rules"] as? [[String: Any]])
        #expect(dnsRules.contains {
            $0["domain_suffix"] as? [String] == routing.domainSuffixes && $0["server"] as? String == "bootstrap-dns"
        })
        let route = try #require(root["route"] as? [String: Any])
        #expect(route["final"] as? String == "proxy")
        let rules = try #require(route["rules"] as? [[String: Any]])
        let udpIndex = try #require(rules.firstIndex { $0["network"] as? String == "udp" })
        let domainIndex = try #require(rules.firstIndex { $0["domain_suffix"] != nil })
        let ipIndex = try #require(rules.firstIndex { $0["ip_cidr"] != nil })
        #expect(udpIndex < domainIndex && udpIndex < ipIndex)
        #expect(rules[domainIndex]["outbound"] as? String == "direct")
        #expect(rules[ipIndex]["outbound"] as? String == "direct")
        #expect(rules[ipIndex]["ip_cidr"] as? [String] == ["203.0.113.0/24"])
    }
}
