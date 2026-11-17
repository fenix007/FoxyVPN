import Foundation
import Testing
@testable import FoxyCore

struct VPNServerProfileTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func profile(server: String = "203.0.113.7") -> VPNServerProfile {
        VPNServerProfile(name: "Codotok", server: server, serverPort: 18443, password: key)
    }

    @Test func profileRoundTripPreservesConnectionAndRouting() throws {
        var source = profile()
        source.name = " Codotok "
        source.routing = try RoutingSettings.parse("bank.example", bypassRussianDomains: true,
            mode: .selectedSites, vpnDomainsText: "claude.ai\ncodotok.sale", routeCodingClients: true)
        let decoded = try VPNServerProfile.decode(data: JSONEncoder().encode(source))
        #expect(decoded.name == "Codotok")
        #expect(decoded.server == "203.0.113.7")
        #expect(decoded.serverPort == 18443)
        #expect(decoded.password == key)
        #expect(decoded.routing == source.routing)
    }

    @Test func minimalProfileUsesFullTunnelWithRussianDomainExceptions() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "name": "Codotok", "server": "203.0.113.7", "serverPort": 18443,
            "method": "2022-blake3-aes-256-gcm", "password": key,
        ])
        let decoded = try VPNServerProfile.decode(data: data)
        #expect(decoded.version == 1)
        #expect(decoded.routing.mode == .allTraffic)
        #expect(decoded.routing.bypassRussianDomains)
    }

    @Test(arguments: ["203.0.113.7", "2001:db8::1", "2001:DB8::A"])
    func acceptsLiteralIPv4AndIPv6(_ address: String) throws {
        #expect(try profile(server: address).validated().server == address.lowercased())
    }

    @Test(arguments: ["codotok.sale", "https://codotok.sale", "203.0.113.7:18443", "[2001:db8::1]",
        "127.0.0.1;id", "203.0.113.7/path", "203.0.113.7\n", "203.0.113.7\0.attacker.example", "1.2.3.999", "fe80::1%en0"])
    func rejectsNonliteralServerValues(_ address: String) {
        #expect(throws: Error.self) { try profile(server: address).validated() }
    }

    @Test func rejectsUnsupportedVersionMethodPortAndNameWithoutDisclosingCredentials() throws {
        var invalid = [VPNServerProfile]()
        var value = profile(); value.version = 2; invalid.append(value)
        value = profile(); value.method = "none"; invalid.append(value)
        value = profile(); value.serverPort = 0; invalid.append(value)
        value = profile(); value.serverPort = 65_536; invalid.append(value)
        value = profile(); value.name = "\n\t"; invalid.append(value)
        value = profile(); value.name = "Server\nInjected log"; invalid.append(value)
        value = profile(); value.name = String(repeating: "x", count: 101); invalid.append(value)
        for item in invalid {
            do {
                _ = try item.validated()
                Issue.record("Invalid server profile was accepted")
            } catch {
                #expect(!error.localizedDescription.contains(key))
            }
        }
    }

    @Test(arguments: ["", "not-a-key", Data(repeating: 7, count: 16).base64EncodedString(),
        Data(repeating: 7, count: 33).base64EncodedString(), Data(repeating: 7, count: 32).base64EncodedString() + "\n"])
    func rejectsInvalidEncryptionKeys(_ password: String) throws {
        var value = profile(); value.password = password
        #expect(throws: Error.self) { try value.validated() }
        #expect(throws: Error.self) { try VPNServerProfile.decode(data: JSONEncoder().encode(value)) }
    }

    @Test func rejectsOversizedMalformedAndInvalidRoutingProfiles() throws {
        #expect(throws: Error.self) { try VPNServerProfile.decode(data: Data()) }
        #expect(throws: Error.self) { try VPNServerProfile.decode(data: Data(repeating: 32, count: 48 * 1024 + 1)) }
        #expect(throws: Error.self) { try VPNServerProfile.decode(data: Data("{invalid}".utf8)) }
        var value = profile()
        value.routing.directDomains = ["https://bank.example"]
        #expect(throws: Error.self) { try value.validated() }
        #expect(throws: Error.self) { try VPNServerProfile.decode(data: JSONEncoder().encode(value)) }
    }

    @Test func relayUsesOnlyLoopbackAndEncryptedRemoteBoundToPhysicalInterface() throws {
        let data = try profile().relayConfiguration(port: 1088, interface: "en7")
        let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(config.keys) == ["log", "inbounds", "outbounds", "route"])
        let inbounds = try #require(config["inbounds"] as? [[String: Any]])
        #expect(inbounds.count == 1)
        #expect(inbounds[0]["type"] as? String == "socks")
        #expect(inbounds[0]["listen"] as? String == "127.0.0.1")
        #expect(inbounds[0]["listen_port"] as? Int == 1088)
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        #expect(outbounds.count == 1)
        let outbound = outbounds[0]
        #expect(outbound["type"] as? String == "shadowsocks")
        #expect(outbound["server"] as? String == "203.0.113.7")
        #expect(outbound["server_port"] as? Int == 18443)
        #expect(outbound["method"] as? String == "2022-blake3-aes-256-gcm")
        #expect(outbound["password"] as? String == key)
        #expect(outbound["network"] as? String == "tcp")
        #expect(outbound["bind_interface"] as? String == "en7")
        let route = try #require(config["route"] as? [String: Any])
        #expect(route["final"] as? String == "server")
    }

    @Test func arbitraryImportedSingBoxFieldsAreNeverForwarded() throws {
        let encoded = try JSONEncoder().encode(profile())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["experimental"] = ["clash_api": ["external_controller": "0.0.0.0:9090"]]
        object["outbounds"] = [["type": "direct"]]
        let decoded = try VPNServerProfile.decode(data: JSONSerialization.data(withJSONObject: object))
        let config = try #require(JSONSerialization.jsonObject(with: decoded.relayConfiguration(port: 1088, interface: "en0")) as? [String: Any])
        #expect(config["experimental"] == nil)
        #expect((config["outbounds"] as? [[String: Any]])?.first?["type"] as? String == "shadowsocks")
    }

    @Test func rejectsInvalidRelayParameters() {
        #expect(throws: Error.self) { try profile().relayConfiguration(port: 0, interface: "en0") }
        #expect(throws: Error.self) { try profile().relayConfiguration(port: 65_536, interface: "en0") }
        #expect(throws: Error.self) { try profile().relayConfiguration(port: 1088, interface: "en0;id") }
        #expect(throws: Error.self) { try profile().relayConfiguration(port: 1088, interface: "../en0") }
    }
}
