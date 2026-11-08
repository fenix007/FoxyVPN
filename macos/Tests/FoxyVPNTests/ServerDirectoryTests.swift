import Foundation
import Testing
@testable import FoxyVPN

struct ServerDirectoryTests {
    @Test func testParsesOnlyUsableConnectCountries() throws {
        let json = #"""
        {"data":[
          {"country":{"code":"DE","name":"Germany","cities":[{"servers":[{"hostname":"de.example","port":443,"quarantined":false,"protocols":[{"name":"connect","host":"","port":0}]}]}]}},
          {"country":{"code":"US","name":"United States","cities":[{"servers":[{"hostname":"us.example","port":443,"quarantined":true,"protocols":[{"name":"connect"}]}]}]}},
          {"country":{"code":"CA","name":"Canada","cities":[{"servers":[{"hostname":"ca.example","port":443,"protocols":[{"name":"wireguard"}]}]}]}},
          {"country":{"code":"XX","name":"CatchAll Anycast","cities":[{"servers":[{"hostname":"any.example","port":443,"protocols":[]}]}]}}
        ]}
        """#

        let countries = try ServerDirectory.parse(Data(json.utf8))

        #expect(countries == [VPNCountry(code: "DE", name: "Germany")])
    }

    @Test func testMergesDuplicateCountryRecordsByCode() throws {
        let json = #"""
        {"data":[
          {"country":{"code":"JP","name":"Japan","cities":[{"servers":[{"hostname":"jp1.example","port":443,"protocols":[]}]}]}},
          {"country":{"code":"jp","name":"Japan","cities":[{"servers":[{"hostname":"jp2.example","port":443,"protocols":[]}]}]}}
        ]}
        """#

        let countries = try ServerDirectory.parse(Data(json.utf8))

        #expect(countries == [VPNCountry(code: "JP", name: "Japan")])
    }
}
