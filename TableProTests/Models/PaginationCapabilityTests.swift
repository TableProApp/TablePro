//
//  PaginationCapabilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Pagination capability")
@MainActor
struct PaginationCapabilityTests {
    private let leadingRows = PaginationCapability.leadingRowsOnly(maximumRows: 10_000)

    @Test("An offset engine seeks and caps nothing")
    func offsetEngine() {
        #expect(PaginationCapability.offset.allowsSeeking)
        #expect(PaginationCapability.offset.maximumRows == nil)
        #expect(PaginationCapability.offset.clampedRowCount(50_000) == 50_000)
    }

    @Test("A leading-rows engine never seeks and clamps to its ceiling")
    func leadingRowsEngine() {
        #expect(!leadingRows.allowsSeeking)
        #expect(leadingRows.maximumRows == 10_000)
        #expect(leadingRows.clampedRowCount(50_000) == 10_000)
        #expect(leadingRows.clampedRowCount(500) == 500)
    }

    @Test("Cloudflare R2 SQL reads its capability from the catalog, and other engines keep offset paging")
    func catalog() {
        #expect(PaginationCapability.of(.cloudflareR2SQL) == .leadingRowsOnly(maximumRows: 10_000))
        #expect(PaginationCapability.of(.postgresql) == .offset)
    }

    @Test("A leading-rows table query states a clamped LIMIT and never an OFFSET")
    func builderNeverOffsets() {
        let builder = TableQueryBuilder(databaseType: .cloudflareR2SQL, pagination: leadingRows)
        let query = builder.buildBaseQuery(tableName: "events", schemaName: "logs", limit: 50_000, offset: 0)

        #expect(query == #"SELECT * FROM "logs"."events" LIMIT 10000"#)
        #expect(!query.contains("OFFSET"))
    }

    @Test("An offset table query keeps LIMIT and OFFSET")
    func builderOffsets() {
        let builder = TableQueryBuilder(databaseType: .postgresql, pagination: .offset)
        let query = builder.buildBaseQuery(tableName: "events", limit: 100, offset: 200)

        #expect(query.hasSuffix("LIMIT 100 OFFSET 200"))
    }

    private func snapshot(rowCount: Int, pageSize: Int, capability: PaginationCapability) -> StatusBarSnapshot {
        StatusBarSnapshot(
            tabId: UUID(),
            tabType: .table,
            hasRows: rowCount > 0,
            hasColumns: true,
            rowCount: rowCount,
            hasTableName: true,
            pagination: PaginationState(pageSize: pageSize),
            statusMessage: nil,
            paginationCapability: capability
        )
    }

    @Test("A leading-rows table keeps the rows-per-page menu and drops page navigation")
    func controls() {
        let capped = ResultStatusModel(
            snapshot: snapshot(rowCount: 500, pageSize: 500, capability: leadingRows),
            viewMode: .data,
            selectedRowCount: 0
        )
        let paged = ResultStatusModel(
            snapshot: snapshot(rowCount: 500, pageSize: 500, capability: .offset),
            viewMode: .data,
            selectedRowCount: 0
        )

        #expect(capped.controls.showsPagination && !capped.controls.showsPageNavigation)
        #expect(paged.controls.showsPagination && paged.controls.showsPageNavigation)
    }

    @Test("The readout says what loaded: a range of unknown total at the limit, a count below it")
    func readout() {
        let atLimit = ResultStatusModel(
            snapshot: snapshot(rowCount: 500, pageSize: 500, capability: leadingRows),
            viewMode: .data,
            selectedRowCount: 0
        )
        let belowLimit = ResultStatusModel(
            snapshot: snapshot(rowCount: 37, pageSize: 500, capability: leadingRows),
            viewMode: .data,
            selectedRowCount: 0
        )

        #expect(atLimit.readout == .rangeOfUnknownTotal(start: 1, end: 500))
        #expect(belowLimit.readout == .rowCount(37))
    }

    @Test("Page-size presets stop at the engine's ceiling")
    func presets() {
        #expect(PaginationControlsView.pageSizePresets(upTo: nil) == [5, 10, 20, 100, 500, 1_000])
        #expect(PaginationControlsView.pageSizePresets(upTo: 100) == [5, 10, 20, 100])
    }

    @Test("Page commands are dimmed where the engine cannot skip rows")
    func pageCommands() {
        let selectors = [
            #selector(MainSplitViewController.goToFirstPage(_:)),
            #selector(MainSplitViewController.goToPreviousPage(_:)),
            #selector(MainSplitViewController.goToNextPage(_:)),
            #selector(MainSplitViewController.goToLastPage(_:))
        ]
        var context = MenuValidationContext()
        context.isConnected = true
        for selector in selectors {
            #expect(!MainSplitViewController.isEnabled(selector, context: context))
        }

        context.canNavigatePages = true
        for selector in selectors {
            #expect(MainSplitViewController.isEnabled(selector, context: context))
        }
    }
}
