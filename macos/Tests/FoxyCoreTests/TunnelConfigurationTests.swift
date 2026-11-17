import Foundation
import Testing
@testable import FoxyCore

struct TunnelConfigurationTests {
    private func configuration(port: Int = 12_345, interface: String = "en0",
                               routing: RoutingSettings = RoutingSettings()) throws -> [String: Any] {
        let data = try TunnelConfiguration.data(port: port, interface: interface, routing: routing)
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
            ($0["process_name"] as? [String])?.contains("foxyvpn-proxy") == true &&
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
        let domainIndex = try #require(rules.firstIndex { $0["domain_suffix"] as? [String] == routing.domainSuffixes })
        let ipIndex = try #require(rules.firstIndex { $0["ip_cidr"] != nil })
        #expect(udpIndex < domainIndex && udpIndex < ipIndex)
        #expect(rules[domainIndex]["outbound"] as? String == "direct")
        #expect(rules[ipIndex]["outbound"] as? String == "direct")
        #expect(rules[ipIndex]["ip_cidr"] as? [String] == ["203.0.113.0/24"])
    }

    @Test func selectedSitesUseProxyDNSAndLeaveOtherTrafficDirect() throws {
        let routing = RoutingSettings(mode: .selectedSites, vpnDomains: ["claude.ai", "codotok.sale"])
        let root = try configuration(routing: routing)
        let route = try #require(root["route"] as? [String: Any])
        let dns = try #require(root["dns"] as? [String: Any])
        #expect(route["final"] as? String == "direct")
        #expect(dns["final"] as? String == "bootstrap-dns")
        #expect(dns["reverse_mapping"] as? Bool == true)
        let dnsRules = try #require(dns["rules"] as? [[String: Any]])
        #expect(dnsRules.contains {
            $0["domain_suffix"] as? [String] == routing.vpnDomains && $0["server"] as? String == "remote-dns"
        })
        let servers = try #require(dns["servers"] as? [[String: Any]])
        #expect(servers.first { $0["tag"] as? String == "remote-dns" }?["detour"] as? String == "proxy")
        let rules = try #require(route["rules"] as? [[String: Any]])
        let proxyRules = rules.filter { $0["outbound"] as? String == "proxy" }
        #expect(proxyRules.count == 1)
        #expect(proxyRules.first?["domain_suffix"] as? [String] == routing.vpnDomains)
        #expect(!rules.contains { $0["process_name"] as? [String] == RoutingSettings.codingProcessNames })
    }

    @Test func directExceptionsWinOverSelectedDomainsAndCodingClients() throws {
        let routing = try RoutingSettings.parse("codotok.sale\n203.0.113.0/24", bypassRussianDomains: true,
            mode: .selectedSites, vpnDomainsText: RoutingSettings.codingDomains.joined(separator: "\n"),
            routeCodingClients: true)
        let root = try configuration(routing: routing)
        let route = try #require(root["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        let domainIndex = try #require(rules.firstIndex {
            $0["domain_suffix"] as? [String] == routing.domainSuffixes && $0["outbound"] as? String == "direct"
        })
        let ipIndex = try #require(rules.firstIndex { $0["ip_cidr"] as? [String] == ["203.0.113.0/24"] })
        let selectedIndex = try #require(rules.firstIndex { $0["domain_suffix"] as? [String] == routing.vpnDomains })
        let processIndex = try #require(rules.firstIndex { $0["process_name"] as? [String] == RoutingSettings.codingProcessNames })
        let pathIndex = try #require(rules.firstIndex { $0["process_path_regex"] != nil })
        #expect(domainIndex < selectedIndex && ipIndex < selectedIndex)
        #expect(domainIndex < processIndex && ipIndex < processIndex)
        #expect(domainIndex < pathIndex && ipIndex < pathIndex)
        let dns = try #require(root["dns"] as? [String: Any])
        let dnsRules = try #require(dns["rules"] as? [[String: Any]])
        let directDNSIndex = try #require(dnsRules.firstIndex {
            $0["domain_suffix"] as? [String] == routing.domainSuffixes && $0["server"] as? String == "bootstrap-dns"
        })
        let selectedDNSIndex = try #require(dnsRules.firstIndex {
            $0["domain_suffix"] as? [String] == routing.vpnDomains && $0["server"] as? String == "remote-dns"
        })
        let clientDNSIndex = try #require(dnsRules.firstIndex { $0["process_name"] != nil })
        #expect(directDNSIndex < selectedDNSIndex && directDNSIndex < clientDNSIndex)
    }

    @Test func selectedModePreservesBackendPrivateAndControlPlaneBypass() throws {
        let root = try configuration(routing: RoutingSettings(mode: .selectedSites,
            vpnDomains: ["firefox.com", "mozilla.org"], routeCodingClients: true))
        let route = try #require(root["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        let proxyIndex = try #require(rules.firstIndex { $0["outbound"] as? String == "proxy" })
        let backendIndex = try #require(rules.firstIndex {
            ($0["process_name"] as? [String])?.contains("foxyvpn-proxy") == true && $0["outbound"] as? String == "direct"
        })
        let privateIndex = try #require(rules.firstIndex {
            $0["ip_is_private"] as? Bool == true && $0["outbound"] as? String == "direct"
        })
        let controlIndex = try #require(rules.firstIndex {
            ($0["domain_suffix"] as? [String])?.contains("fastly-masque.net") == true &&
                $0["outbound"] as? String == "direct"
        })
        #expect(backendIndex < proxyIndex && privateIndex < proxyIndex && controlIndex < proxyIndex)
        let dns = try #require(root["dns"] as? [String: Any])
        let dnsRules = try #require(dns["rules"] as? [[String: Any]])
        #expect(dnsRules.first?["server"] as? String == "bootstrap-dns")
        #expect((dnsRules.first?["domain_suffix"] as? [String])?.contains("firefox.com") == true)
    }

    @Test func selectedModeRejectsOnlyUDPThatWouldUseTheTCPProxy() throws {
        let root = try configuration(routing: RoutingSettings(mode: .selectedSites,
            vpnDomains: ["codotok.sale"], routeCodingClients: true))
        let route = try #require(root["route"] as? [String: Any])
        #expect(route["final"] as? String == "direct")
        let rules = try #require(route["rules"] as? [[String: Any]])
        let rejects = rules.filter { $0["network"] as? String == "udp" && $0["action"] as? String == "reject" }
        #expect(rejects.count == 3)
        for rule in rejects {
            // A global UDP reject would break unrelated games and calls in selected mode.
            #expect(rule["domain_suffix"] != nil || rule["process_name"] != nil || rule["process_path_regex"] != nil)
        }
        let proxies = rules.indices.filter { rules[$0]["outbound"] as? String == "proxy" }
        #expect(proxies.count == 3)
        for index in proxies {
            let proxy = rules[index]
            let rejection = try #require(rules[..<index].last { rule in
                guard rule["network"] as? String == "udp", rule["action"] as? String == "reject" else { return false }
                for key in ["domain_suffix", "process_name", "process_path_regex"] {
                    if let expected = proxy[key] as? [String], rule[key] as? [String] == expected { return true }
                }
                return false
            })
            #expect(rejection["network"] as? String == "udp")
        }
    }

    @Test func codingPresetCoversCodotokAndNativeClientsWithoutMatchingNode() throws {
        #expect(RoutingSettings.codingDomains.contains("codotok.sale"))
        #expect(RoutingSettings.codingDomains.contains("claudeusercontent.com"))
        let settings = RoutingSettings(mode: .selectedSites,
            vpnDomains: RoutingSettings.codingDomains, routeCodingClients: true)
        let root = try configuration(routing: settings)
        let route = try #require(root["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        let processRules = rules.filter { $0["process_name"] as? [String] == RoutingSettings.codingProcessNames }
        #expect(processRules.contains { $0["outbound"] as? String == "proxy" && $0["domain_suffix"] == nil })
        #expect(!RoutingSettings.codingProcessNames.contains("node"))
        #expect(!RoutingSettings.codingProcessNames.contains("Electron"))
        #expect(RoutingSettings.codingProcessNames.contains("codex"))
        #expect(RoutingSettings.codingProcessNames.contains("Claude Helper"))
        let regex = try #require(RoutingSettings.codingProcessPathRegex.first)
        #expect("/Users/alice/.local/share/claude/versions/2.1.323".range(of: regex, options: .regularExpression) != nil)
        #expect("/Users/alice/projects/node".range(of: regex, options: .regularExpression) == nil)
        #expect("/tmp/.local/share/claude/versions/2.1.323".range(of: regex, options: .regularExpression) == nil)
        #expect(rules.contains { $0["process_path_regex"] as? [String] == RoutingSettings.codingProcessPathRegex &&
            $0["outbound"] as? String == "proxy" && $0["domain_suffix"] == nil })
    }

    @Test func emptySelectedModeLeavesOnlyInfrastructureRules() throws {
        let root = try configuration(routing: RoutingSettings(mode: .selectedSites))
        let route = try #require(root["route"] as? [String: Any])
        let dns = try #require(root["dns"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(route["final"] as? String == "direct")
        #expect(dns["final"] as? String == "bootstrap-dns")
        #expect(!rules.contains { $0["outbound"] as? String == "proxy" || $0["action"] as? String == "reject" })
    }

    @Test func fullTunnelIgnoresSavedSelectionsUntilSelectedModeIsEnabled() throws {
        let root = try configuration(routing: RoutingSettings(mode: .allTraffic,
            vpnDomains: ["codotok.sale"], routeCodingClients: true))
        let route = try #require(root["route"] as? [String: Any])
        let dns = try #require(root["dns"] as? [String: Any])
        #expect(route["final"] as? String == "proxy")
        #expect(dns["final"] as? String == "remote-dns")
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(!rules.contains { $0["outbound"] as? String == "proxy" })
        #expect(!rules.contains { $0["process_path_regex"] != nil })
        let udpRules = rules.filter { $0["network"] as? String == "udp" }
        #expect(udpRules.count == 1)
        #expect(udpRules.first?["action"] as? String == "reject")
        #expect(udpRules.first?["domain_suffix"] == nil && udpRules.first?["process_name"] == nil)
    }

}
