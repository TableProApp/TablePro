//
//  JSONNodeRowViewTests.swift
//  TableProTests
//
//  What a link line of the JSON inspector prints and where a click on it goes.
//

import Foundation
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct JSONNodeRowViewTests {
    private static let address = "https://example.com/docs?id=42"

    @Test("The link covers the value's characters, not the quotes or the comma")
    func linkCoversTheValueOnly() throws {
        let url = try #require(URL(string: Self.address))
        let text = JSONNodeRowView.linkedText(Self.address, url: url, needsComma: true)

        let linked = text.runs.filter { $0.link != nil }
        #expect(linked.count == 1)
        let run = try #require(linked.first)
        #expect(run.link == url)
        #expect(String(text[run.range].characters) == Self.address)
        #expect(String(text.characters) == "\"\(Self.address)\",")
    }

    /// Copy Visible and a text selection both read the line, so a link must not change it.
    @Test("A link line prints what a plain line would")
    func linkedTextMatchesThePrintedValue() throws {
        let url = try #require(URL(string: Self.address))
        let printed = JSONScalarText.printed(.string(Self.address))

        let last = JSONNodeRowView.linkedText(Self.address, url: url, needsComma: false)
        let inner = JSONNodeRowView.linkedText(Self.address, url: url, needsComma: true)

        #expect(String(last.characters) == printed)
        #expect(String(inner.characters) == printed + ",")
    }

    /// The refused address names a file that does not exist, so a regression that hands it to the
    /// system opens nothing on the machine running the suite.
    @Test("A click on a link opens through the policy, and a refused address never reaches the opener")
    func openLinkGoesThroughThePolicy() throws {
        let original = DataLinkPolicy.opener
        defer { DataLinkPolicy.opener = original }
        var opened: [URL] = []
        DataLinkPolicy.opener = { opened.append($0) }

        let allowed = try #require(URL(string: Self.address))
        let refused = try #require(URL(string: "file:///var/empty/tablepro-refused-link"))
        JSONNodeRowView.openLink(refused)
        #expect(opened.isEmpty)

        JSONNodeRowView.openLink(allowed)
        #expect(opened == [allowed])
    }
}
