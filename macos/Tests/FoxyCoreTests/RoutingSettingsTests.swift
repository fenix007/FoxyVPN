import Foundation
import Testing
@testable import FoxyCore

struct RoutingSettingsTests {
    @Test func normalizesDomainsAndKeepsIPRangesSeparate() throws {
        let settings = try RoutingSettings.parse("# comment\nEXAMPLE.com\ndomain:example.com\n*.example.com.\nпример.рф\n203.0.113.5\n2001:db8::/32\n", bypassRussianDomains: true)
        #expect(settings.directDomains == ["example.com", "xn--e1afmkfd.xn--p1ai"])
        #expect(settings.directIPCIDRs == ["2001:db8::/32", "203.0.113.5/32"])
        #expect(settings.domainSuffixes == ["example.com", "ru", "su", "xn--e1afmkfd.xn--p1ai", "xn--p1ai"])
    }

    @Test func emptySettingsPreserveFullTunnel() throws {
        let settings = try RoutingSettings.parse("\n", bypassRussianDomains: false)
        #expect(settings.domainSuffixes.isEmpty)
        #expect(settings.directIPCIDRs.isEmpty)
    }

    @Test(arguments: ["https://example.com", "example.com/path", "example.com:443", "foo..com", "-foo.com",
        "example.com;id", "1.2.3.999", "203.0.113.5/33", "2001:db8::/129", "::1%en0", "*", "geosite:ru", "com", "net", "ru"])
    func rejectsInvalidEntries(_ entry: String) {
        #expect(throws: Error.self) { try RoutingSettings.parse(entry, bypassRussianDomains: false) }
    }

    @Test func validatesHelperPayloadInsteadOfTrustingDecodedFields() throws {
        let settings = try RoutingSettings.parse("bank.example\n192.0.2.0/24", bypassRussianDomains: true)
        #expect(try RoutingSettings.fromHelperArgument(settings.helperArgument()) == settings)
        let malicious = RoutingSettings(directDomains: ["example.com; touch /tmp/pwned"])
        let payload = try JSONEncoder().encode(malicious).base64EncodedString()
        #expect(throws: Error.self) { try RoutingSettings.fromHelperArgument(payload) }
        #expect(throws: Error.self) { try RoutingSettings.fromHelperArgument("not base64") }
        #expect(throws: Error.self) { try RoutingSettings.fromHelperArgument(String(repeating: "A", count: 60 * 1024)) }
    }

    @Test func rejectsOversizedSettings() {
        #expect(throws: Error.self) { try RoutingSettings.parse(String(repeating: "a", count: 33 * 1024), bypassRussianDomains: false) }
        #expect(throws: Error.self) { try RoutingSettings(directDomains: Array(repeating: "example.com", count: 2049)).validated() }
    }
}
