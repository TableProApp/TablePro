//
//  DatedSaleScheduleTests.swift
//  TableProTests
//
//  The first entry is the date a TimelineView draws its first frame with, and the last entry is
//  never delivered, so each case checks both ends of the list.
//

import Foundation
import SwiftUI
@testable import TablePro
import Testing

struct DatedSaleScheduleTests {
    private let sale = DatedSale.blackFriday2026

    private var schedule: DatedSaleSchedule {
        DatedSaleSchedule(sale: sale)
    }

    @Test("Before the sale the view draws the present, then redraws at the start and the end")
    func beforeTheSale() {
        let now = sale.start.addingTimeInterval(-86_400)

        #expect(schedule.entries(from: now, mode: .normal) == [now, sale.start, sale.end, .distantFuture])
    }

    @Test("At the start the view draws the start, then redraws at the end")
    func atTheStart() {
        #expect(schedule.entries(from: sale.start, mode: .normal) == [sale.start, sale.end, .distantFuture])
    }

    @Test("During the sale only the end is still ahead")
    func duringTheSale() {
        let now = sale.end.addingTimeInterval(-1)

        #expect(schedule.entries(from: now, mode: .normal) == [now, sale.end, .distantFuture])
    }

    @Test("After the sale nothing is ahead")
    func afterTheSale() {
        #expect(schedule.entries(from: sale.end, mode: .normal) == [sale.end, .distantFuture])
    }
}
