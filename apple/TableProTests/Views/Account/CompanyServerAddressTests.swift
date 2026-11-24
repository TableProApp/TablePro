//
//  CompanyServerAddressTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct CompanyServerAddressTests {
    @Test("A host alone becomes its https origin, in lower case, without a trailing slash")
    func hostBecomesAnOrigin() {
        #expect(CompanyServerAddress.parse("TablePro.Example.com") == URL(string: "https://tablepro.example.com"))
        #expect(CompanyServerAddress.parse("  https://tablepro.example.com/ \n") == URL(string: "https://tablepro.example.com"))
        #expect(CompanyServerAddress.parse("https://tablepro.example.com:8443") == URL(string: "https://tablepro.example.com:8443"))
    }

    @Test("Plain http reaches only a server on this Mac")
    func httpOnlyOnLoopback() {
        #expect(CompanyServerAddress.parse("http://localhost:8080") == URL(string: "http://localhost:8080"))
        #expect(CompanyServerAddress.parse("http://127.0.0.1:8080") == URL(string: "http://127.0.0.1:8080"))
        #expect(CompanyServerAddress.parse("http://tablepro.example.com") == nil)
    }

    @Test("Anything that is not an origin is refused", arguments: [
        "",
        "   ",
        "ftp://tablepro.example.com",
        "https://",
        "https://admin:secret@tablepro.example.com",
        "https://tablepro.example.com/v2",
        "https://tablepro.example.com?server=1",
        "https://tablepro.example.com#top",
        "tablepro example.com"
    ])
    func refusesWhatIsNotAnOrigin(_ text: String) {
        #expect(CompanyServerAddress.parse(text) == nil)
    }
}
