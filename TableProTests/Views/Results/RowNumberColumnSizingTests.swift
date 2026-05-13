//
//  RowNumberColumnSizingTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Row Number Column Sizing")
@MainActor
struct RowNumberColumnSizingTests {
    @Test("Single-digit max number sizes to the configured floor")
    func singleDigitHonoursFloor() {
        let column = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        DataGridView.sizeRowNumberColumn(column, forMaxRowNumber: 1)
        #expect(column.width == DataGridMetrics.rowNumberColumnMinWidth)
        #expect(column.minWidth == column.width)
        #expect(column.maxWidth == column.width)
    }

    @Test("Zero and negative inputs are clamped to the floor")
    func zeroAndNegativeClampToFloor() {
        let zero = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        let negative = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        DataGridView.sizeRowNumberColumn(zero, forMaxRowNumber: 0)
        DataGridView.sizeRowNumberColumn(negative, forMaxRowNumber: -42)
        #expect(zero.width == DataGridMetrics.rowNumberColumnMinWidth)
        #expect(negative.width == DataGridMetrics.rowNumberColumnMinWidth)
    }

    @Test("Five-digit numbers grow past the floor")
    func fiveDigitGrowsPastFloor() {
        let column = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        DataGridView.sizeRowNumberColumn(column, forMaxRowNumber: 14_001)
        #expect(column.width > DataGridMetrics.rowNumberColumnMinWidth)
    }

    @Test("Width grows monotonically with digit count")
    func widthGrowsWithDigits() {
        let twoDigit = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        let fourDigit = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        let sixDigit = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        DataGridView.sizeRowNumberColumn(twoDigit, forMaxRowNumber: 99)
        DataGridView.sizeRowNumberColumn(fourDigit, forMaxRowNumber: 9_999)
        DataGridView.sizeRowNumberColumn(sixDigit, forMaxRowNumber: 999_999)
        #expect(fourDigit.width >= twoDigit.width)
        #expect(sixDigit.width >= fourDigit.width)
    }

    @Test("Min, max and width stay equal so the column is pinned")
    func widthIsPinned() {
        let column = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        DataGridView.sizeRowNumberColumn(column, forMaxRowNumber: 1_234_567)
        #expect(column.minWidth == column.width)
        #expect(column.maxWidth == column.width)
    }
}
