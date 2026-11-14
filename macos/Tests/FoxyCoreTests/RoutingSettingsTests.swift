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
        #expect(settings.mode == .allTraffic)
        #expect(settings.vpnDomains.isEmpty)
        #expect(!settings.routeCodingClients)
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

    @Test func oldPreferencesAndHelperPayloadKeepFullTunnel() throws {
        let legacy = Data(#"{"bypassRussianDomains":true,"directDomains":["bank.example"],"directIPCIDRs":["192.0.2.0/24"]}"#.utf8)
        let settings = try JSONDecoder().decode(RoutingSettings.self, from: legacy)
        #expect(settings.mode == .allTraffic)
        #expect(settings.vpnDomains.isEmpty)
        #expect(!settings.routeCodingClients)
        #expect(settings.bypassRussianDomains)
        #expect(settings.directDomains == ["bank.example"])
        #expect(settings.directIPCIDRs == ["192.0.2.0/24"])
        #expect(try RoutingSettings.fromHelperArgument(legacy.base64EncodedString()) == settings)
    }

    @Test func selectedDomainsNormalizeAndSurviveHelperRoundTrip() throws {
        let settings = try RoutingSettings.parse("bank.example\n203.0.113.8", bypassRussianDomains: true,
            mode: .selectedSites,
            vpnDomainsText: "# coding\nCODOTOK.sale\n*.codotok.sale.\ndomain:CLAUDE.AI\nпример.рф\n",
            routeCodingClients: true)
        #expect(settings.mode == .selectedSites)
        #expect(settings.routeCodingClients)
        #expect(settings.vpnDomains == ["claude.ai", "codotok.sale", "xn--e1afmkfd.xn--p1ai"])
        #expect(settings.vpnEntriesText == "claude.ai\ncodotok.sale\nxn--e1afmkfd.xn--p1ai")
        #expect(settings.directDomains == ["bank.example"])
        #expect(settings.directIPCIDRs == ["203.0.113.8/32"])
        #expect(try RoutingSettings.fromHelperArgument(settings.helperArgument()) == settings)
    }

    @Test(arguments: ["selectedApps", "", "proxy"])
    func rejectsUnknownSavedModes(_ mode: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "bypassRussianDomains": false, "directDomains": [], "directIPCIDRs": [], "mode": mode,
        ] as [String: Any])
        #expect(throws: Error.self) { try JSONDecoder().decode(RoutingSettings.self, from: data) }
        #expect(throws: Error.self) { try RoutingSettings.fromHelperArgument(data.base64EncodedString()) }
    }

    @Test(arguments: ["203.0.113.8", "203.0.113.0/24", "2001:db8::1", "https://codotok.sale",
        "codotok.sale/v1", "claude.ai:443", "com", "example.com;id", "example.com\"}],\"outbounds\":[{}]"])
    func selectedListAcceptsDomainsOnly(_ entry: String) {
        #expect(throws: Error.self) {
            try RoutingSettings.parse("", bypassRussianDomains: false, mode: .selectedSites, vpnDomainsText: entry)
        }
    }

    @Test func helperRevalidatesSelectedDomains() throws {
        for entry in ["127.0.0.1", "codotok.sale/path", "example.com; touch /tmp/pwned"] {
            let settings = RoutingSettings(mode: .selectedSites, vpnDomains: [entry], routeCodingClients: true)
            let payload = try JSONEncoder().encode(settings).base64EncodedString()
            #expect(throws: Error.self) { try RoutingSettings.fromHelperArgument(payload) }
        }
    }

    @Test func entryLimitIsSharedBetweenBothLists() throws {
        let direct = (0..<1024).map { "d\($0).example" }
        let selected = (0..<1024).map { "v\($0).example" }
        let settings = try RoutingSettings.parse(direct.joined(separator: "\n"), bypassRussianDomains: false,
            mode: .selectedSites, vpnDomainsText: selected.joined(separator: "\n"))
        #expect(settings.directDomains.count + settings.vpnDomains.count == 2048)
        #expect(throws: Error.self) {
            try RoutingSettings.parse((direct + ["overflow.example"]).joined(separator: "\n"),
                bypassRussianDomains: false, mode: .selectedSites, vpnDomainsText: selected.joined(separator: "\n"))
        }
        #expect(throws: Error.self) {
            try RoutingSettings(directDomains: direct, mode: .selectedSites,
                vpnDomains: selected + ["overflow.example"]).validated()
        }
    }

    @Test func byteLimitIsSharedBetweenBothLists() throws {
        let comment = "#" + String(repeating: "a", count: 16 * 1024 - 1)
        _ = try RoutingSettings.parse(comment, bypassRussianDomains: false,
            mode: .selectedSites, vpnDomainsText: comment)
        #expect(throws: Error.self) {
            try RoutingSettings.parse(comment, bypassRussianDomains: false,
                mode: .selectedSites, vpnDomainsText: comment + "a")
        }
    }

}
