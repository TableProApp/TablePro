//
//  AboutPanelCreditsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct AboutPanelCreditsTests {
    @Test("Named license holders follow the project links")
    func listsSupporters() throws {
        let credits = AboutPanelCredits.attributedString(supporters: ["Ada Lovelace", "Grace Hopper"]).string

        #expect(credits.contains("Thanks to these license holders"))
        #expect(credits.contains("Ada Lovelace, Grace Hopper"))
        let links = try #require(credits.range(of: "GitHub"))
        let names = try #require(credits.range(of: "Ada Lovelace"))
        #expect(links.lowerBound < names.lowerBound)
    }

    @Test("With nobody listed, the credits stay the project links alone")
    func emptyListAddsNothing() {
        let credits = AboutPanelCredits.attributedString(supporters: []).string

        #expect(!credits.contains("Thanks to these license holders"))
        #expect(!credits.contains("\n"))
    }

    @Test("Blank entries and stray spaces in the list never reach the panel")
    func decodeTrimsAndDropsBlanks() throws {
        let data = Data(#"{"supporters": ["  Ada Lovelace ", "", "   ", "Grace Hopper"]}"#.utf8)

        #expect(try SupporterList.decode(data) == ["Ada Lovelace", "Grace Hopper"])
    }

    @Test("The list the app ships decodes")
    func bundledListDecodes() throws {
        let url = try #require(Bundle.main.url(forResource: SupporterList.resourceName, withExtension: "json"))

        _ = try SupporterList.decode(Data(contentsOf: url))
    }
}
