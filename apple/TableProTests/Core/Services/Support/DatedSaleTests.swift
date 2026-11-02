//
//  DatedSaleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct DatedSaleTests {
    private let sale = DatedSale.blackFriday2026

    @Test("Black Friday runs from Nov 24 00:00 UTC to Dec 1 08:00 UTC")
    func blackFridayInstants() throws {
        #expect(sale.start == (try Date("2026-11-24T00:00:00Z", strategy: .iso8601)))
        #expect(sale.end == (try Date("2026-12-01T08:00:00Z", strategy: .iso8601)))
        #expect(sale.percentOff == 40)
    }

    @Test("The sale opens at its start, not a second before")
    func opensAtTheStart() {
        #expect(!sale.isLive(at: sale.start.addingTimeInterval(-1)))
        #expect(sale.isLive(at: sale.start))
    }

    @Test("The sale is still on a second before its end, and over at the end")
    func closesAtTheEnd() {
        #expect(sale.isLive(at: sale.end.addingTimeInterval(-1)))
        #expect(!sale.isLive(at: sale.end))
    }

    @Test("The notice opens the sale page tagged with where it was clicked")
    func pageCarriesItsReferrer() {
        #expect(sale.page.absoluteString == "https://tablepro.app/black-friday?ref=app-black-friday")
    }
}
